defmodule SdrAgent.Agents.SettingsRevisionTest do
  @moduledoc """
  C4-01a (`docs/product/c4/readiness.md`, section 5 tests 1-3 and 6-9):
  admin-only, append-only settings revisions — numbering, the
  `supersedes_id` chain and `content_sha256` (section 3.7), the write
  policy and its audited denials, stale `expected_number`, the content
  field policy, and the validation of limits (3.3), raise confirmation
  (7a), time fields (7b), the booking link (C4-R13) and settings text (3.5).

  RED: `SettingsRevision` and `Agents.create_settings_revision/2` do not
  exist yet; every call is presence-guarded (`SdrAgent.SettingsFixtures`),
  so each test fails on an explicit `C4-01a:` assertion after its fixtures.
  """
  use SdrAgent.AuditCase, async: false

  import SdrAgent.SettingsFixtures

  alias SdrAgent.Accounts
  alias SdrAgent.Test.SecretShapes

  @moduletag :c4_01a

  setup do
    tenant = bootstrap!()
    %{tenant: tenant, admin: human(:admin, tenant)}
  end

  defp revision_events(ctx), do: events_of_type(ctx.tenant, "settings.revision.created")

  defp denials(ctx) do
    ctx.tenant
    |> events_of_type("authz.denied")
    |> Enum.filter(&(&1.payload["resource"] == "SdrAgent.Agents.SettingsRevision"))
  end

  defp attempt(ctx, kind, content, opts \\ []) do
    actor = Keyword.get(opts, :actor, ctx.admin)
    observe(fn -> create_revision(revision_attrs(kind, content, ctx.admin, opts), actor) end)
  end

  defp assert_invalid(result, field, label) do
    errors = invalid_errors(result)

    assert errors, "C4-01a: #{label} was not refused as {:invalid, _}: #{short(result)}"

    if field,
      do:
        assert(
          Keyword.has_key?(errors, field),
          "C4-01a: #{label}: errors do not name #{field}: #{short(result)}"
        )

    errors
  end

  defp short(term), do: inspect(term, limit: 6, printable_limit: 120)

  defp nothing_written(ctx, kind, number) do
    assert latest_number(ctx.tenant.id, kind) == number
  end

  ## Test 1

  describe "test 1: revisions" do
    test "an admin saves revision 1 of each kind; a later save chains to it", ctx do
      revisions =
        for kind <- kinds(),
            do: {kind, save!(kind, content(kind), ctx.admin, expected_number: 0)}

      for {kind, revision} <- revisions do
        assert {revision.kind, revision.number, revision.supersedes_id} == {kind, 1, nil}
        assert revision.created_by_id == ctx.admin.id
        assert revision.tenant_id == ctx.tenant.id
        assert revision.raised_fields == []
        assert revision.content_sha256 =~ ~r/\A[0-9a-f]{64}\z/
        assert revision.content_sha256 == recompute_content_sha256(revision)
      end

      {:writing_guide, guide1} = List.keyfind(revisions, :writing_guide, 0)
      guide2_content = content(:writing_guide, %{text: "A second synthetic guide."})
      guide2 = save!(:writing_guide, guide2_content, ctx.admin, expected_number: 1)

      assert {guide2.number, guide2.supersedes_id} == {2, guide1.id}
      assert guide2.content_sha256 == recompute_content_sha256(guide2)
      refute guide2.content_sha256 == guide1.content_sha256

      events = revision_events(ctx)
      assert length(events) == 6, "one settings.revision.created per save"

      for revision <- [guide2 | Enum.map(revisions, &elem(&1, 1))] do
        assert [event] = Enum.filter(events, &(&1.subject_id == revision.id))
        changes = event.payload["changes"]

        assert {changes["kind"], changes["number"], changes["supersedes_id"]} ==
                 {Atom.to_string(revision.kind), revision.number, revision.supersedes_id}

        assert changes["content_sha256"] == revision.content_sha256
        refute Map.has_key?(changes, Atom.to_string(revision.kind))
        refute Map.has_key?(changes, "note")
        assert Atom.to_string(revision.kind) in event.payload["redacted"]
        assert is_binary(event.payload["record_sha256"])
      end

      rendered = inspect(Enum.map(events, & &1.payload), limit: :infinity)

      for text <- ["Example Widgets Scheduler", "book.example.test", "A second synthetic guide"] do
        refute rendered =~ text, "settings content #{inspect(text)} reached an event payload"
      end
    end
  end

  ## Test 2

  describe "test 2: write policy" do
    test "reviewer, auditor, disabled or demoted admin and every system actor are refused",
         ctx do
      disabled = new_human(:admin, ctx.tenant)
      {:ok, _} = Accounts.change_status(disabled, :disabled, actor: ctx.admin)
      demoted = new_human(:admin, ctx.tenant)
      {:ok, _} = Accounts.change_role(demoted, :reviewer, actor: ctx.admin)

      refused =
        [
          reviewer: human(:reviewer, ctx.tenant),
          auditor: human(:auditor, ctx.tenant),
          disabled_admin: disabled,
          demoted_admin: demoted
        ] ++
          for(
            type <- [:agent_runtime, :scheduler, :seeder, :kernel],
            do: {type, system_actor(type, ctx.tenant)}
          )

      for {label, actor} <- refused do
        result = attempt(ctx, :writing_guide, content(:writing_guide), actor: actor)
        assert forbidden?(result), "C4-01a: #{label} was not refused: #{short(result)}"
      end

      # A missing actor and another tenant's admin are refused too.
      foreign = %{ctx.admin | tenant_id: Ash.UUIDv7.generate()}

      for actor <- [nil, foreign] do
        result =
          observe(fn -> attempt(ctx, :writing_guide, content(:writing_guide), actor: actor) end)

        refute match?({:ok, _}, result), "C4-01a: #{short(actor)} saved a revision"
      end

      nothing_written(ctx, :writing_guide, 0)
      assert revision_events(ctx) == []
      assert length(denials(ctx)) >= length(refused), "each guarded denial is audited"

      # Allow case: the same save by the active admin succeeds.
      assert save!(:writing_guide, content(:writing_guide), ctx.admin).number == 1
    end
  end

  ## Test 3

  describe "test 3: stale expected_number" do
    test "a stale expected_number is refused with the current number, writing nothing", ctx do
      first = attempt(ctx, :offering_profile, content(:offering_profile), expected_number: 1)

      assert first == {:error, {:stale_revision, 0}},
             "C4-01a: a first save with expected_number 1: #{short(first)}"

      nothing_written(ctx, :offering_profile, 0)

      save!(:offering_profile, content(:offering_profile), ctx.admin, expected_number: 0)

      for expected <- [0, 2] do
        result =
          attempt(ctx, :offering_profile, content(:offering_profile), expected_number: expected)

        assert result == {:error, {:stale_revision, 1}}, "expected_number #{expected}"
      end

      nothing_written(ctx, :offering_profile, 1)
      assert length(revision_events(ctx)) == 1
    end
  end

  ## Test 6

  describe "test 6: content field policy" do
    test "admin, reviewer, agent runtime, auditor CLI and kernel read content; others do not",
         ctx do
      saved = save!(:writing_guide, content(:writing_guide), ctx.admin, note: "Synthetic note.")
      revision = require_module!(revision_resource())

      readers = [
        admin: ctx.admin,
        reviewer: human(:reviewer, ctx.tenant),
        agent_runtime: system_actor(:agent_runtime, ctx.tenant),
        auditor_cli: system_actor(:auditor_cli, ctx.tenant),
        kernel: system_actor(:kernel, ctx.tenant)
      ]

      for {label, actor} <- readers do
        assert {:ok, rows} = Ash.read(revision, actor: actor)
        assert [row] = Enum.filter(rows, &(&1.id == saved.id)), "#{label} cannot read the row"
        assert row.writing_guide == saved.writing_guide, "#{label} cannot read the content"
        assert row.note == "Synthetic note.", "#{label} cannot read the note"
      end

      outsiders =
        for(
          type <- [:scheduler, :seeder, :webhook_ingestor, :model_runtime, :delivery_worker],
          do: {type, system_actor(type, ctx.tenant)}
        ) ++
          [
            foreign_agent:
              struct(SdrAgent.Actor, type: :agent_runtime, tenant_id: Ash.UUIDv7.generate())
          ]

      for {label, actor} <- outsiders do
        result = Ash.read(revision, actor: actor)

        hidden =
          case result do
            {:error, %Ash.Error.Forbidden{}} ->
              true

            {:ok, rows} ->
              Enum.all?(rows, fn row ->
                row.id != saved.id or
                  (match?(%Ash.ForbiddenField{}, row.writing_guide) and
                     match?(%Ash.ForbiddenField{}, row.note))
              end)

            _other ->
              false
          end

        assert hidden, "C4-01a: #{label} read settings content: #{short(result)}"
      end

      # OQ-6: the reviewer reads, but cannot write.
      reviewer = human(:reviewer, ctx.tenant)
      result = attempt(ctx, :writing_guide, content(:writing_guide), actor: reviewer)
      assert forbidden?(result), "C4-01a: a reviewer wrote a revision: #{short(result)}"
      nothing_written(ctx, :writing_guide, 1)
    end
  end

  ## Test 7

  # `limits` with `field` at `value`, other fields moved just enough to keep
  # the cross-field rules of the OperationalLimits row.
  defp consistent(limits, field) do
    limits
    |> pair(field, :research_max_model_calls, :run_max_model_calls)
    |> pair(field, :research_max_source_chars, :research_max_total_source_chars)
    |> pair(field, :research_target_seconds, :research_job_limit_seconds)
  end

  # Keeps `small <= large`, moving the field that was not set.
  defp pair(limits, field, small, large) do
    cond do
      limits[small] <= limits[large] -> limits
      field == small -> Map.put(limits, large, limits[small])
      true -> Map.put(limits, small, limits[large])
    end
  end

  defp save_chain!(ctx, cases) do
    Enum.reduce(cases, {0, limit_defaults()}, fn {label, limits}, {number, previous} ->
      result =
        attempt(ctx, :operational_limits, limits,
          expected_number: number,
          confirm_raised: raised(limits, previous)
        )

      assert match?({:ok, %{number: n}} when n == number + 1, result),
             "C4-01a: #{label} was refused: #{short(result)}"

      {number + 1, limits}
    end)
  end

  describe "test 7: limit validation" do
    test "each limit passes at its minimum and at the sanity maximum", ctx do
      cases =
        for {field, min} <- limit_minimums(), value <- [min, int_max()] do
          {"#{field} = #{value}", limit_defaults() |> Map.put(field, value) |> consistent(field)}
        end

      {number, _} = save_chain!(ctx, cases)
      assert number == 24
    end

    test "minimum - 1, maximum + 1, a non-integer and nil are refused; nothing is written",
         ctx do
      for {field, min} <- limit_minimums(), value <- [min - 1, int_max() + 1, 1.5, "ten", nil] do
        limits = Map.put(limit_defaults(), field, value)
        confirm = if is_integer(value) and value > limit_defaults()[field], do: [field], else: []

        result =
          attempt(ctx, :operational_limits, limits, expected_number: 0, confirm_raised: confirm)

        assert_invalid(result, field, "#{field} = #{inspect(value)}")
      end

      nothing_written(ctx, :operational_limits, 0)
      assert revision_events(ctx) == []
    end

    test "the cross-field rules are refused, never clamped", ctx do
      cases = [
        {%{research_max_source_chars: 5_000, research_max_total_source_chars: 4_999},
         [:research_max_source_chars, :research_max_total_source_chars]},
        {%{research_max_model_calls: 21}, [:research_max_model_calls, :run_max_model_calls]},
        {%{research_target_seconds: 601}, [:research_target_seconds, :research_job_limit_seconds]}
      ]

      for {overrides, fields} <- cases do
        limits = Map.merge(limit_defaults(), overrides)

        result =
          attempt(ctx, :operational_limits, limits,
            expected_number: 0,
            confirm_raised: raised(limits, limit_defaults())
          )

        errors = assert_invalid(result, nil, inspect(overrides))
        assert Enum.any?(fields, &Keyword.has_key?(errors, &1)), short(errors)
      end

      nothing_written(ctx, :operational_limits, 0)
    end

    test "a value far above the built-in default passes with confirmation (no policy ceiling)",
         ctx do
      limits = Map.put(limit_defaults(), :run_max_model_calls, 1_000)

      revision =
        save!(:operational_limits, limits, ctx.admin,
          expected_number: 0,
          confirm_raised: [:run_max_model_calls]
        )

      assert revision.operational_limits.run_max_model_calls == 1_000
      assert revision.raised_fields == [:run_max_model_calls]
    end
  end

  describe "test 7a: raise confirmation" do
    test "a raise needs exactly the raised fields confirmed; refusals write nothing", ctx do
      raise_both = Map.merge(limit_defaults(), %{run_max_model_calls: 30, run_max_tool_calls: 70})

      raise_one_lower_one =
        Map.merge(limit_defaults(), %{run_max_model_calls: 30, run_max_tool_calls: 50})

      raise_one = Map.put(limit_defaults(), :run_max_model_calls, 30)

      mismatches = [
        {"no confirmation", raise_one, []},
        {"a missing field", raise_both, [:run_max_model_calls]},
        {"an extra field", raise_one, [:run_max_model_calls, :run_max_tool_calls]},
        {"a lowered field", raise_one_lower_one, [:run_max_model_calls, :run_max_tool_calls]}
      ]

      for {label, limits, confirm} <- mismatches do
        result =
          attempt(ctx, :operational_limits, limits, expected_number: 0, confirm_raised: confirm)

        assert result == {:error, {:invalid, [confirm_raised: :mismatch]}},
               "C4-01a: #{label}: #{short(result)}"
      end

      nothing_written(ctx, :operational_limits, 0)
      assert revision_events(ctx) == []

      # The first save compares against the built-in default.
      revision =
        save!(:operational_limits, raise_both, ctx.admin,
          expected_number: 0,
          confirm_raised: [:run_max_model_calls, :run_max_tool_calls]
        )

      assert revision.raised_fields == [:run_max_model_calls, :run_max_tool_calls]
      assert [event] = revision_events(ctx)

      assert event.payload["changes"]["raised_fields"] ==
               ["run_max_model_calls", "run_max_tool_calls"]

      # A pure lowering needs no confirmation.
      lowered = Map.merge(raise_both, %{run_max_model_calls: 10, research_max_sources: 3})
      lower = save!(:operational_limits, lowered, ctx.admin, expected_number: 1)
      assert {lower.number, lower.raised_fields} == {2, []}
    end

    test "a first save at or below the built-in defaults needs no confirmation", ctx do
      limits = Map.put(limit_defaults(), :research_max_sources, 5)
      revision = save!(:operational_limits, limits, ctx.admin, expected_number: 0)
      assert revision.raised_fields == []
    end

    test "confirm_raised with a duplicate, unknown or non-limit name is refused", ctx do
      unknown = "c4_unknown_limit_" <> "field_zq"

      assert match?(
               {:raised, %ArgumentError{}},
               observe(fn -> String.to_existing_atom(unknown) end)
             )

      limits = Map.put(limit_defaults(), :run_max_model_calls, 30)

      for confirm <- [
            [:run_max_model_calls, :run_max_model_calls],
            [:run_max_model_calls, unknown],
            [:offering_profile, :run_max_model_calls],
            [:run_max_model_calls, :kind]
          ] do
        result =
          attempt(ctx, :operational_limits, limits, expected_number: 0, confirm_raised: confirm)

        assert_invalid(result, :confirm_raised, "confirm_raised #{inspect(confirm)}")
      end

      nothing_written(ctx, :operational_limits, 0)

      assert match?(
               {:raised, %ArgumentError{}},
               observe(fn -> String.to_existing_atom(unknown) end)
             ),
             "an unknown confirm_raised string created an atom"
    end
  end

  describe "test 7b: time fields" do
    test "large job limits pass and convert to exact milliseconds the runtime accepts", ctx do
      values = [86_401, 4_294_968, 2_147_483_647]

      Enum.reduce(values, {0, limit_defaults()}, fn seconds, {number, previous} ->
        limits = Map.put(previous, :research_job_limit_seconds, seconds)

        revision =
          save!(:operational_limits, limits, ctx.admin,
            expected_number: number,
            confirm_raised: raised(limits, previous)
          )

        assert revision.operational_limits.research_job_limit_seconds == seconds

        assert call(run_settings_module(), :milliseconds, [seconds]) == {:ok, seconds * 1000}
        timer = :erlang.start_timer(seconds * 1000, self(), :c4_job_limit)
        assert is_integer(:erlang.cancel_timer(timer))
        {number + 1, limits}
      end)

      too_large = Map.put(limit_defaults(), :research_job_limit_seconds, 2_147_483_648)

      result =
        attempt(ctx, :operational_limits, too_large,
          expected_number: 3,
          confirm_raised: [:research_job_limit_seconds]
        )

      assert_invalid(result, :research_job_limit_seconds, "2,147,483,648 s")

      assert match?({:error, _}, call(run_settings_module(), :milliseconds, [2_147_483_648])),
             "the conversion must refuse a value outside the stored range"

      nothing_written(ctx, :operational_limits, 3)
    end
  end

  ## Test 8

  describe "test 8: booking link" do
    test "unsafe or unreserved links are refused; a reserved https link passes", ctx do
      token = Enum.join(["to", "ken"]) <> "=" <> String.duplicate("0123456789abcdef", 2)
      long = "https://book.example.test/" <> String.duplicate("a", 2_049 - 26)
      assert byte_size(long) == 2_049

      refused = [
        {"http", "http://book.example.test/demo/intro"},
        {"javascript", "javascript:alert(1)"},
        {"user info", "https://someone:pw@book.example.test/demo"},
        {"IPv4 literal", "https://192.0.2.10/demo"},
        {"IPv6 literal", "https://[2001:db8::1]/demo"},
        {"localhost", "https://localhost/demo"},
        {".local", "https://book.local/demo"},
        {"port 8443", "https://book.example.test:8443/demo"},
        {"over 2,048 bytes", long},
        {"non-reserved host (guard off)", "https://calendar.nonreserved-c4-fixture.org/intro"},
        {"token-shaped query", "https://book.example.test/demo?" <> token},
        {"whitespace", "https://book.example.test/demo intro"},
        {"no host", "https:///demo"}
      ]

      for {label, url} <- refused do
        result = attempt(ctx, :booking_link, %{url: url}, expected_number: 0)
        assert_invalid(result, :url, label)
      end

      refute inspect(attempt(ctx, :booking_link, %{url: "https://book.example.test/?" <> token})) =~
               token

      nothing_written(ctx, :booking_link, 0)

      exact = "https://book.example.test/" <> String.duplicate("a", 2_048 - 26)

      for {url, number} <- [
            {"https://book.example.test/demo/intro", 1},
            {"https://book.example.test:443/demo/intro", 2},
            {exact, 3}
          ] do
        revision = save!(:booking_link, %{url: url}, ctx.admin)
        assert {revision.number, revision.booking_link.url} == {number, url}
      end
    end
  end

  ## Test 9

  describe "test 9: settings text" do
    test "control characters and secret-shaped text are refused without echoing it", ctx do
      for {label, text} <- [{"BEL", "Hello\athere"}, {"NUL", "Hello\0there"}, {"ESC", "Hi\e[0m"}] do
        result = attempt(ctx, :writing_guide, %{text: text}, expected_number: 0)
        assert_invalid(result, nil, label)
      end

      for secret <- SecretShapes.samples() do
        texts = [
          {:writing_guide, %{text: "Guide. " <> secret}},
          {:research_brief, content(:research_brief, %{guidance: "Brief. " <> secret})},
          {:offering_profile, content(:offering_profile, %{summary: "Offer. " <> secret})}
        ]

        for {kind, content} <- texts do
          result = attempt(ctx, kind, content, expected_number: 0)
          assert_invalid(result, nil, "secret-shaped #{kind}")
          refute inspect(result, limit: :infinity) =~ secret, "the error echoed the secret"
        end

        result =
          attempt(ctx, :writing_guide, content(:writing_guide),
            expected_number: 0,
            note: "Note " <> secret
          )

        assert_invalid(result, :note, "secret-shaped note")
        refute inspect(result, limit: :infinity) =~ secret
      end

      for kind <- [:writing_guide, :research_brief, :offering_profile] do
        nothing_written(ctx, kind, 0)
      end
    end

    test "over-size text and malformed offering items are refused; caps are inclusive", ctx do
      words = fn n ->
        String.duplicate("abcd ", div(n, 5) - 1) <> String.duplicate("e", 5 + rem(n, 5))
      end

      assert String.length(words.(6_001)) == 6_001
      item = fn id, text -> %{id: id, kind: :feature, text: text} end
      items = fn n -> for i <- 1..n, do: item.("item_#{i}", "Synthetic item #{i}.") end

      # 30 items of 400 two-byte characters: every field within its cap, the
      # canonical profile above 16 KiB.
      wide =
        content(:offering_profile, %{
          items: for(i <- 1..30, do: item.("w#{i}", String.duplicate("é", 400)))
        })

      assert byte_size(SdrAgent.Audit.Canonical.encode!(wide)) > 16 * 1024

      refused = [
        {:writing_guide, %{text: words.(6_001)}, "guide 6,001"},
        {:writing_guide, %{text: ""}, "empty guide"},
        {:research_brief, content(:research_brief, %{guidance: words.(12_001)}), "brief 12,001"},
        {:research_brief, content(:research_brief, %{depth: :deep}), "depth :deep"},
        {:offering_profile, content(:offering_profile, %{name: String.duplicate("n", 121)}),
         "name 121"},
        {:offering_profile, content(:offering_profile, %{name: ""}), "empty name"},
        {:offering_profile, content(:offering_profile, %{summary: words.(1_501)}),
         "summary 1,501"},
        {:offering_profile, content(:offering_profile, %{audience: words.(1_501)}),
         "audience 1,501"},
        {:offering_profile, content(:offering_profile, %{items: []}), "no items"},
        {:offering_profile, content(:offering_profile, %{items: items.(31)}), "31 items"},
        {:offering_profile, content(:offering_profile, %{items: [item.("x", words.(401))]}),
         "item 401"},
        {:offering_profile,
         content(:offering_profile, %{items: [item.("dup", "A."), item.("dup", "B.")]}),
         "duplicate item id"},
        {:offering_profile, content(:offering_profile, %{items: [item.("Bad Id", "A.")]}),
         "bad id"},
        {:offering_profile, content(:offering_profile, %{items: [item.("-lead", "A.")]}),
         "leading dash"},
        {:offering_profile,
         content(:offering_profile, %{items: [item.(String.duplicate("a", 41), "A.")]}),
         "41-char id"},
        {:offering_profile,
         content(:offering_profile, %{items: [%{id: "x", kind: :pricing, text: "A."}]}),
         "unknown item kind"},
        {:offering_profile, wide, "canonical above 16 KiB"}
      ]

      for {kind, content, label} <- refused do
        result = attempt(ctx, kind, content, expected_number: 0)
        assert_invalid(result, nil, label)
      end

      result =
        attempt(ctx, :writing_guide, content(:writing_guide),
          expected_number: 0,
          note: String.duplicate("n", 201)
        )

      assert_invalid(result, :note, "note 201")

      for kind <- [:writing_guide, :research_brief, :offering_profile],
          do: nothing_written(ctx, kind, 0)

      # The caps themselves pass.
      assert save!(:writing_guide, %{text: words.(6_000)}, ctx.admin,
               note: String.duplicate("n", 200)
             ).number == 1

      assert save!(
               :research_brief,
               content(:research_brief, %{guidance: words.(12_000)}),
               ctx.admin
             ).number == 1

      offering =
        content(:offering_profile, %{
          name: String.duplicate("n", 120),
          items: [item.(String.duplicate("a", 40), "A."), item.("b", words.(400))]
        })

      assert save!(:offering_profile, offering, ctx.admin).number == 1
    end
  end
end
