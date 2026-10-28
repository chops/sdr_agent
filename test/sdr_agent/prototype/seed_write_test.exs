defmodule SdrAgent.Prototype.SeedWriteTest do
  @moduledoc """
  The GTM seed write `SdrAgent.Prototype.Seed.run/2` (interfaces r6 IF-7
  "How it is written", IF-6 R4 SettingsRevision; supplement 1 r2 §3-§4, R5;
  plan r7 section 6 "GTM seed"): the profile and guide through
  `SettingsRevision :seed_prototype` (number 1 only, the actual content
  rules, the anchor as `created_by_id`, the provenance digest in the note,
  the provenance file as a scoped Payload), the ICP, the one-step sequence
  and the campaign through their `:seed_prototype` actions, then the
  seed-scoped activation; replay and a differing seed; value-free codes.
  Synthetic seed documents built directly in the `SeedDir.read/2` output
  shape, so these tests reach the seed write without the parser.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Agents.RunSettings.ContentRules
  alias SdrAgent.DossierFixtures, as: F

  @seed SdrAgent.Prototype.Seed

  setup do
    fixture = bound!()
    %{fixture: fixture, actor: fixture.actor, tenant: fixture.tenant}
  end

  defp seed(contents \\ F.seed_contents()), do: F.seed_read(contents)

  defp run!(seed, actor) do
    result = call(@seed, :run, [seed, actor])
    assert match?({:ok, %{result: _}}, result), "Seed.run/2 returned #{inspect(result)}"
    {:ok, summary} = result
    summary
  end

  defp count(table, where \\ "TRUE", params \\ []) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table} WHERE #{where}", params)
    n
  end

  # Benign text of exactly `n` characters: `unit` repeated (a word and one
  # space), never ending in a space, so trimming keeps every character.
  defp fill(n, unit) do
    text = unit |> String.duplicate(div(n, String.length(unit)) + 1) |> String.slice(0, n)
    if String.ends_with?(text, " "), do: String.slice(text, 0, n - 1) <> "z", else: text
  end

  defp secret_shaped?(text), do: ContentRules.secret_shaped?(text)

  # The content of one settings file of `contents` for `kind`.
  defp file_content(contents, :writing_guide), do: contents["writing_guide.json"]
  defp file_content(contents, :offering_profile), do: contents["offering_profile.json"]

  # The canonical size the profile rule measures (content_rules.ex
  # profile_size/2): the trimmed name, summary, audience and items.
  defp canonical_size(profile) do
    trimmed =
      Map.new([:name, :summary, :audience, :items], fn field ->
        {field, trim(profile[Atom.to_string(field)])}
      end)

    {:ok, bytes} = SdrAgent.Audit.Canonical.encode(trimmed)
    byte_size(bytes)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(list) when is_list(list), do: Enum.map(list, &trim/1)
  defp trim(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, trim(v)} end)
  defp trim(value), do: value

  # A valid profile whose canonical size is exactly `target` bytes: items of
  # 400 characters of two-byte text (each within the 400-character bound),
  # as many as keep the rest within the 1500-character summary, then an
  # ASCII summary that makes up the exact remainder.
  defp profile_of_bytes(target) do
    base = F.seed_contents()["offering_profile.json"]

    count =
      Enum.find(30..1//-1, fn k ->
        size = canonical_size(%{base | "summary" => "s", "items" => items(k)})
        size <= target and target - size < 1_499
      end)

    probe = %{base | "summary" => "s", "items" => items(count)}
    summary = fill(1 + target - canonical_size(probe), "abcd ")
    profile = %{probe | "summary" => summary}

    assert String.length(summary) <= 1_500
    assert Enum.all?(profile["items"], &(String.length(&1["text"]) == 400))
    refute Enum.any?([summary | Enum.map(profile["items"], & &1["text"])], &secret_shaped?/1)
    profile
  end

  defp items(k) do
    for i <- 1..k,
        do: %{"id" => "feature-#{i}", "kind" => "feature", "text" => fill(400, "éééé ")}
  end

  describe "a first seed" do
    test "writes revision 1 of the profile and the guide with the anchor and the provenance note",
         ctx do
      seed = seed()
      summary = run!(seed, ctx.actor)
      assert summary.result == :created
      assert summary.revisions == 2

      %{rows: rows} =
        Repo.query!(
          "SELECT kind, number, created_by_id, note, content_sha256 FROM settings_revisions ORDER BY kind",
          []
        )

      assert [
               ["offering_profile", 1, anchor_a, note_a, _],
               ["writing_guide", 1, anchor_b, note_b, _]
             ] = rows

      assert Ecto.UUID.cast!(anchor_a) == ctx.fixture.anchor.id
      assert Ecto.UUID.cast!(anchor_b) == ctx.fixture.anchor.id
      assert note_a =~ seed.sha256.provenance
      assert note_b =~ seed.sha256.provenance

      for event <- events_of_type(ctx.tenant, "settings.revision.created") do
        assert event.actor_type == :prototype_operator
        assert event.actor_id == ctx.actor.id
      end
    end

    test "stores the provenance file as a Payload, never as settings keys", ctx do
      seed = seed()
      run!(seed, ctx.actor)

      digest = Base.decode16!(seed.sha256.provenance, case: :lower)

      %{rows: [[content]]} =
        Repo.query!("SELECT content FROM payloads WHERE sha256 = $1", [digest])

      assert content == seed.provenance_bytes

      %{rows: profiles} =
        Repo.query!(
          "SELECT offering_profile::text FROM settings_revisions WHERE kind = 'offering_profile'",
          []
        )

      refute hd(hd(profiles)) =~ "public_url"
    end

    test "creates and activates the ICP, the one-step sequence and the campaign with the reserved sender",
         ctx do
      summary = run!(seed(), ctx.actor)

      %{rows: [[icp_status, icp_name]]} =
        Repo.query!("SELECT status, name FROM icp_definitions WHERE id = $1", [
          Ecto.UUID.dump!(summary.icp_id)
        ])

      assert {icp_status, icp_name} == {"active", "Synthetic small B2B software"}

      %{rows: [["active"]]} =
        Repo.query!("SELECT status FROM sequences WHERE id = $1", [
          Ecto.UUID.dump!(summary.sequence_id)
        ])

      %{rows: steps} =
        Repo.query!(
          "SELECT position, channel, delay_days, requires_approval, stop_on_reply FROM sequence_steps WHERE sequence_id = $1",
          [Ecto.UUID.dump!(summary.sequence_id)]
        )

      assert steps == [[1, "email", 0, true, true]]

      %{rows: [[status, sender_name, sender_email, icp_id, sequence_id]]} =
        Repo.query!(
          "SELECT status, sender_name, sender_email, icp_definition_id, sequence_id FROM campaigns WHERE id = $1",
          [Ecto.UUID.dump!(summary.campaign_id)]
        )

      assert {status, sender_name, sender_email} ==
               {"active", "the GTMscape team", "team@gtmscape.example"}

      assert byte_size(sender_name) == 17
      assert Ecto.UUID.cast!(icp_id) == summary.icp_id
      assert Ecto.UUID.cast!(sequence_id) == summary.sequence_id

      for type <-
            ~w(sales.icp_definition.activated sales.sequence.activated sales.campaign.activated) do
        assert [event] = events_of_type(ctx.tenant, type)
        assert {event.actor_type, event.actor_id} == {:prototype_operator, ctx.actor.id}
      end

      assert count("oban_jobs") == 0
    end

    test "the ICP criteria are the campaign file's, and only they reach qualification", ctx do
      summary = run!(seed(), ctx.actor)

      {:ok, icp} =
        Ash.get(
          SdrAgent.Sales.IcpDefinition,
          summary.icp_id,
          SdrAgent.Audit.Kernel.opts(ctx.tenant.id)
        )

      criteria = F.seed_contents()["campaign.json"]["icp"]["criteria"]

      assert icp.criteria.employee_count_min == criteria["employee_count_min"]
      assert icp.criteria.employee_count_max == criteria["employee_count_max"]
      assert icp.criteria.industries == criteria["industries"]
      assert icp.criteria.geographies == criteria["geographies"]
      assert icp.criteria.personas == criteria["personas"]
      assert icp.criteria.triggers == criteria["triggers"]
    end
  end

  # Codex 2cf8613e (must-fix): boundary fixtures use benign, space-separated
  # or multibyte text (never a secret-shaped run of 40 base64-like or 32 hex
  # characters), assert their constructed character lengths and canonical
  # byte sizes, and isolate the first refusal with the real content rules
  # before the seed runs. The Redactor and the size rule are never relaxed.
  describe "the actual settings content rules (no bypass)" do
    test "each single violation refuses the whole seed, and only that rule is broken", ctx do
      contents = F.seed_contents()
      guide = "the GTMscape team " <> fill(5_983, "abcde ")
      item = fill(401, "abcd ")

      cases = [
        {"a control character in the guide",
         put_in(contents, ["writing_guide.json", "text"], "Sign as the GTMscape team.\u0007"),
         {:writing_guide, [{:text, :control_character}]}},
        {"a guide of 6001 characters", put_in(contents, ["writing_guide.json", "text"], guide),
         {:writing_guide, [{:text, :too_long}]}},
        {"an item of 401 characters",
         F.update(contents, ["offering_profile.json", "items", 0, "text"], fn _ -> item end),
         {:offering_profile, [{:text, :too_long}]}},
        {"a control character in the step instructions",
         put_in(
           contents,
           ["campaign.json", "sequence", "step", "instructions"],
           "Ask one question.\u001B"
         ), nil}
      ]

      assert String.length(guide) == 6_001 and not secret_shaped?(guide)
      assert String.length(item) == 401 and not secret_shaped?(item)

      # Codex 9ada21de: every pure ContentRules isolation runs first, so no
      # seed call can hide a later exact-error check.
      for {label, bad, {kind, errors}} <- cases do
        assert ContentRules.validate(kind, file_content(bad, kind)) == {:error, errors},
               "#{label}: not exactly #{inspect(errors)}"
      end

      for {label, bad, _expected} <- cases do
        result = call(@seed, :run, [seed(bad), ctx.actor])

        assert result == {:error, :seed_invalid},
               "#{label}: Seed.run/2 returned #{inspect(result)}"

        assert count("settings_revisions") == 0
        assert count("icp_definitions") == 0
        assert count("campaigns") == 0
      end
    end

    test "the guide at exactly its 6000-character bound is accepted", ctx do
      text = "the GTMscape team " <> fill(5_982, "abcde ")
      assert String.length(text) == 6_000
      refute secret_shaped?(text)
      assert ContentRules.validate(:writing_guide, %{"text" => text}) == :ok

      contents = put_in(F.seed_contents(), ["writing_guide.json", "text"], text)
      assert run!(seed(contents), ctx.actor).result == :created
    end

    test "a canonical profile of exactly 16384 bytes is accepted", ctx do
      profile = profile_of_bytes(16_384)
      assert canonical_size(profile) == 16_384
      assert ContentRules.validate(:offering_profile, profile) == :ok

      contents = Map.put(F.seed_contents(), "offering_profile.json", profile)
      assert run!(seed(contents), ctx.actor).result == :created
    end

    test "a canonical profile of 16385 bytes is refused by its size alone", ctx do
      profile = profile_of_bytes(16_385)
      assert canonical_size(profile) == 16_385

      # Every field and item is within its own bounds and benign; only the
      # canonical size is over 16 KiB.
      assert ContentRules.validate(:offering_profile, profile) == {:error, [{:items, :too_large}]}

      contents = Map.put(F.seed_contents(), "offering_profile.json", profile)
      assert call(@seed, :run, [seed(contents), ctx.actor]) == {:error, :seed_invalid}
      assert count("settings_revisions") == 0
    end

    # Codex b8d624fe: the seed action is given its valid note (the stored
    # provenance Payload's exact reference), so a missing-note error cannot
    # stand in for content-rule parity; the comparison is of content errors.
    test "the seed action's content errors equal :create_revision's (field and rule, no value)",
         ctx do
      content = %{"text" => "Sign as the GTMscape team.\u0007"}
      note = F.stored_provenance!(ctx.actor).note

      errors = fn action, args ->
        SdrAgent.Agents.SettingsRevision
        |> Ash.Changeset.for_create(action, args, actor: ctx.actor)
        |> Map.fetch!(:errors)
        |> Enum.map(&{Map.get(&1, :field), &1 |> Map.get(:vars, []) |> Keyword.get(:rule)})
        |> Enum.sort()
      end

      seed_errors =
        errors.(:seed_prototype, %{kind: :writing_guide, content: content, note: note})

      ordinary =
        errors.(:create_revision, %{kind: :writing_guide, content: content, expected_number: 0})

      assert seed_errors != []
      assert seed_errors == ordinary
      refute inspect(seed_errors) =~ "\u0007"
    end
  end

  describe "replay, a differing seed and number 1 only" do
    test "an identical second run is a replay and writes nothing", ctx do
      seed = seed()
      first = run!(seed, ctx.actor)

      before =
        {count("settings_revisions"), count("icp_definitions"), count("campaigns"),
         length(events(ctx.tenant))}

      again = run!(seed, ctx.actor)
      assert again.result == :replay

      assert Map.take(again, [:icp_id, :sequence_id, :campaign_id]) ==
               Map.take(first, [:icp_id, :sequence_id, :campaign_id])

      assert {count("settings_revisions"), count("icp_definitions"), count("campaigns"),
              length(events(ctx.tenant))} == before
    end

    test "a seed with another provenance digest is refused, and no revision 2 is written", ctx do
      run!(seed(), ctx.actor)

      other =
        put_in(
          F.seed_contents(),
          ["writing_guide.json", "text"],
          "Sign as the GTMscape team. Be brief."
        )

      assert call(@seed, :run, [seed(other), ctx.actor]) == {:error, :seed_differs}
      assert count("settings_revisions", "number > 1") == 0
      assert count("icp_definitions") == 1
    end
  end

  describe "the campaign sender address" do
    test "the reserved-name guard stays on the campaign sender address", ctx do
      changeset =
        SdrAgent.Sales.Campaign
        |> Ash.Changeset.for_create(
          :seed_prototype,
          %{
            name: "x",
            icp_definition_id: Ecto.UUID.generate(),
            sender_name: "the GTMscape team",
            sender_email: "team@gtmscape.com",
            footer_template_version: "v1"
          },
          actor: ctx.actor
        )

      assert Enum.any?(changeset.errors, &(Map.get(&1, :field) == :sender_email)),
             "a non-reserved sender address passed: #{inspect(changeset.errors)}"
    end
  end
end
