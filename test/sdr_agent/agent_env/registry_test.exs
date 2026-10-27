defmodule SdrAgent.AgentEnv.RegistryTest do
  @moduledoc """
  C2* S2 RED-1 (plan r1 `claude-c2star-s2-provisioning-plan-r1.md` §4.3,
  §5 and §7 row 1, Codex plan/entity PASS `aa42492e` with its binding OQ
  rulings; ADR-0004 agent-environment items 4 and 8; AC2 and the registry
  cases of T-G2): the compiled authorization registry
  `SdrAgent.AgentEnv.Registry` and its `Entry` struct.

    * **shipped**: production `entries/0` is `[]` (no authorization and
      no cap value exists at this head), every shipped entry validates
      (vacuously while it is empty), and `funded_scope/0` is exactly
      assignment × the three purposes.
    * **validate**: `validate/1` holds only for the closed AC2 shape, each
      rule checked positive and negative: environment `agentenv-1`; the
      OQ1 id pattern; the exact `funded_scope`; total ≥ 1; optional
      per-day ≥ 1; `profile_ids` a non-empty subset of the real profiles
      including `:claude_cli_opus`; ≥ 1 allocation, each with a distinct
      key from `ModelCallAllocation.keys/0`, `applies_to [:b1]`, attempts
      ≥ 1 and both window bounds, and no other key; pairwise disjoint
      half-open windows; attempts summing to at most the total;
      `starts_at < expires_at`; `decision_refs` the caps row plus `D-219`
      and `D-221`; at most one entry for `agentenv-1`. Validation is the
      shape only: an expired entry still validates, so provisioning can
      refuse it as expired (§5 order: validate, then the clock).
    * **digest**: `sha256/1` is the lowercase hex SHA-256 of the entry's
      `sdr-canonical-json/1` encoding, read here as the entry's fields as
      one object (`Map.from_struct/1`, no envelope); stable, and changed
      by any field.
    * **seam**: synthetic entries enter only through the test-seam
      configuration (`config :sdr_agent, SdrAgent.AgentEnv.Registry,
      test_entries: [...]`, plan §5), read on every call; the previous
      configuration is restored on exit. Its absence from dev and prod
      builds is the separate compiled-branch evidence of OQ17, not a
      suite test.

  Every entry here is a synthetic test fixture (total 6, per-day 4,
  `[:claude_cli_opus]`, two disjoint late-October windows, the stand-in
  caps row `D-999`): not a cap, not a decision row, never authority. The
  registry is pure: no database row, model, file or network is used.

  RED: `SdrAgent.AgentEnv.Registry` and its `Entry` struct do not exist.
  Every test fails on an explicit `c2star-s2:` module guard after its
  fixtures (structural), never in setup or compilation.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Agents.ModelCallAllocation
  alias SdrAgent.AI.ModelProfiles
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Clock

  @moduletag :c2star_s2

  @registry SdrAgent.AgentEnv.Registry
  @entry SdrAgent.AgentEnv.Registry.Entry

  @now ~U[2026-10-28 12:00:00.000000Z]
  @scope [{:assignment, [:qualification, :evidence_extraction, :outreach_proposal]}]

  # The planned Entry fields (plan §4.3); all but per_utc_day_attempts are
  # enforced keys.
  @enforced [
    :id,
    :decision_refs,
    :environment_id,
    :starts_at,
    :expires_at,
    :funded_scope,
    :total_attempts,
    :profile_ids,
    :allocations
  ]
  @fields [:per_utc_day_attempts | @enforced]

  # Synthetic fixture values, not caps. D-999 stands in for the owner's
  # caps decision row, which is not recorded yet.
  @caps_row "D-999"
  @refs [@caps_row, "D-219", "D-221"]
  @starts ~U[2026-10-27 00:00:00.000000Z]
  @expires ~U[2026-10-31 00:00:00.000000Z]
  @w1 {~U[2026-10-28 00:00:00.000000Z], ~U[2026-10-29 00:00:00.000000Z]}
  @w2 {~U[2026-10-29 00:00:00.000000Z], ~U[2026-10-31 00:00:00.000000Z]}

  setup do
    previous = Application.fetch_env(:sdr_agent, @registry)
    on_exit(fn -> restore_config(previous) end)
    Application.delete_env(:sdr_agent, @registry)
    Clock.freeze(@now)
    :ok
  end

  defp restore_config({:ok, config}), do: Application.put_env(:sdr_agent, @registry, config)
  defp restore_config(:error), do: Application.delete_env(:sdr_agent, @registry)

  ## Presence-guarded calls

  defp require_registry! do
    for module <- [@registry, @entry] do
      assert Code.ensure_loaded?(module), "c2star-s2: #{inspect(module)} is not implemented"
    end
  end

  defp call(fun, args) do
    require_registry!()

    assert function_exported?(@registry, fun, length(args)),
           "c2star-s2: Registry.#{fun}/#{length(args)} is not implemented"

    apply(@registry, fun, args)
  end

  # `{:ok, result}`, or `{:raised, exception}`: a raise by the subject is
  # reported by the assertion, not as a crash. Guard failures propagate.
  defp outcome(fun, args) do
    {:ok, call(fun, args)}
  rescue
    error in [ExUnit.AssertionError] -> reraise error, __STACKTRACE__
    error -> {:raised, error}
  end

  defp build(fields) do
    {:ok, struct!(@entry, fields)}
  rescue
    error -> {:raised, error}
  end

  defp entry!(fields) do
    require_registry!()
    built = build(fields)

    assert match?({:ok, %{__struct__: @entry}}, built),
           "c2star-s2: cannot build #{inspect(@entry)} from the planned fields: " <>
             inspect(built)

    elem(built, 1)
  end

  defp seam!(entries), do: Application.put_env(:sdr_agent, @registry, test_entries: entries)

  ## Synthetic fixtures

  defp alloc(key, attempts, {from, until}) do
    %{
      key: key,
      applies_to: [:b1],
      attempts: attempts,
      available_from: from,
      available_until: until
    }
  end

  defp fields(overrides \\ []) do
    Map.merge(
      %{
        id: "test-synthetic-1",
        decision_refs: @refs,
        environment_id: "agentenv-1",
        starts_at: @starts,
        expires_at: @expires,
        funded_scope: @scope,
        total_attempts: 6,
        per_utc_day_attempts: 4,
        profile_ids: [:claude_cli_opus],
        allocations: [alloc(:rehearsal, 2, @w1), alloc(:daily_use, 4, @w2)]
      },
      Map.new(overrides)
    )
  end

  defp at(%DateTime{} = dt, microseconds), do: DateTime.add(dt, microseconds, :microsecond)

  defp assert_valid(fields, label) do
    result = outcome(:validate, [entry!(fields)])
    assert result == {:ok, :ok}, "c2star-s2: #{label}: expected :ok, got #{inspect(result)}"
  end

  defp assert_invalid(fields, label) do
    result = outcome(:validate, [entry!(fields)])

    assert match?({:ok, {:error, reason}} when is_atom(reason), result),
           "c2star-s2: #{label}: expected {:error, reason}, got #{inspect(result)}"
  end

  defp digest!(entry) do
    digest = call(:sha256, [entry])

    assert is_binary(digest) and digest =~ ~r/\A[0-9a-f]{64}\z/,
           "c2star-s2: sha256/1 must be 64 lowercase hex characters, got #{inspect(digest)}"

    digest
  end

  # The AC2 oracle: the lowercase hex SHA-256 of the entry's canonical
  # (sdr-canonical-json/1) encoding, its fields as one object.
  defp canonical_digest(entry) do
    entry
    |> Map.from_struct()
    |> Canonical.sha256()
    |> Base.encode16(case: :lower)
  end

  ## Shipped

  describe "shipped" do
    test "entries/0 is empty: no authorization and no cap value exists at this head" do
      assert call(:entries, []) == [], "c2star-s2: the shipped registry must be empty"
      assert call(:current, []) == :none
      assert call(:fetch, ["agentenv-1"]) == :error
      assert call(:fetch, ["test-synthetic-1"]) == :error
    end

    test "every shipped entry validates (vacuously while the registry is empty)" do
      entries = call(:entries, [])
      invalid = for entry <- entries, call(:validate, [entry]) != :ok, do: entry

      assert invalid == [], "c2star-s2: invalid shipped entries: #{inspect(invalid)}"
      assert entries == []
    end

    test "funded_scope/0 is exactly assignment × the three funded purposes" do
      assert call(:funded_scope, []) == @scope
    end
  end

  ## Validate

  describe "validate" do
    test "the synthetic entry validates; expiry is not a shape rule" do
      assert_valid(fields(), "the synthetic entry")
      assert_valid(fields(per_utc_day_attempts: nil), "no per-day limit")
      assert_valid(fields(per_utc_day_attempts: 1), "a per-day limit of 1")

      Clock.freeze(at(@expires, 1))
      assert_valid(fields(), "a well-formed entry after its expires_at")
    end

    test "the Entry struct is closed: the planned fields, all but per_utc_day_attempts enforced" do
      require_registry!()
      keys = @entry |> struct() |> Map.from_struct() |> Map.keys() |> Enum.sort()

      assert keys == Enum.sort(@fields),
             "c2star-s2: Entry fields #{inspect(keys)} differ from the plan's #{inspect(@fields)}"

      for key <- @enforced do
        assert match?({:raised, %ArgumentError{}}, build(Map.delete(fields(), key))),
               "c2star-s2: #{key} must be an enforced Entry key"
      end

      assert match?({:ok, _}, build(Map.delete(fields(), :per_utc_day_attempts))),
             "c2star-s2: per_utc_day_attempts must be optional (default nil)"

      assert match?({:raised, %KeyError{}}, build(Map.put(fields(), :note, "extra"))),
             "c2star-s2: an unknown Entry field must be refused"
    end

    test "the id is a closed 1-64 character pattern (OQ1)" do
      for id <- [
            "a",
            "0",
            "test-synthetic-1",
            "agentenv-1.auth-2",
            "a" <> String.duplicate("b.-", 21)
          ] do
        assert_valid(fields(id: id), "id #{inspect(id)}")
      end

      for id <- [
            "",
            "-a",
            ".a",
            "Test-1",
            "test_1",
            "test 1",
            "test/1",
            "a" <> String.duplicate("b", 64),
            :test,
            nil
          ] do
        assert_invalid(fields(id: id), "id #{inspect(id)}")
      end
    end

    test "environment_id is exactly agentenv-1" do
      for environment <- ["agentenv-2", "agentenv", "AGENTENV-1", :"agentenv-1", nil] do
        assert_invalid(fields(environment_id: environment), "environment #{inspect(environment)}")
      end
    end

    test "funded_scope is exactly assignment × the three purposes, in that order" do
      cases = [
        {"another purpose order",
         [{:assignment, [:evidence_extraction, :qualification, :outreach_proposal]}]},
        {"a missing purpose", [{:assignment, [:qualification, :evidence_extraction]}]},
        {"an extra purpose",
         [
           {:assignment,
            [:qualification, :evidence_extraction, :outreach_proposal, :reply_classification]}
         ]},
        {"a repeated purpose",
         [
           {:assignment,
            [:qualification, :qualification, :evidence_extraction, :outreach_proposal]}
         ]},
        {"another origin",
         [{:reply, [:qualification, :evidence_extraction, :outreach_proposal]}]},
        {"an extra origin", @scope ++ [{:referral, [:qualification]}]},
        {"the scope twice", @scope ++ @scope},
        {"an empty scope", []},
        {"a map", %{assignment: [:qualification, :evidence_extraction, :outreach_proposal]}},
        {"strings",
         [{"assignment", ["qualification", "evidence_extraction", "outreach_proposal"]}]},
        {"nil", nil}
      ]

      for {label, scope} <- cases do
        assert_invalid(fields(funded_scope: scope), "funded_scope with #{label}")
      end
    end

    test "total_attempts is an integer of at least 1; per_utc_day_attempts is nil or at least 1" do
      for total <- [0, -1, 6.0, "6", nil] do
        assert_invalid(fields(total_attempts: total), "total_attempts #{inspect(total)}")
      end

      for per_day <- [0, -1, 4.0, "4"] do
        assert_invalid(
          fields(per_utc_day_attempts: per_day),
          "per_utc_day_attempts #{inspect(per_day)}"
        )
      end
    end

    test "profile_ids is a non-empty subset of the real profiles that includes claude_cli_opus" do
      for profiles <- [
            ModelProfiles.real_ids(),
            [:claude_cli_opus, :claude_cli_sonnet],
            [:claude_cli_sonnet, :claude_cli_opus]
          ] do
        assert_valid(fields(profile_ids: profiles), "profile_ids #{inspect(profiles)}")
      end

      for profiles <- [
            [],
            [:claude_cli_sonnet],
            [:fake, :claude_cli_opus],
            [:claude_cli_opus, :claude_cli_gpt],
            ["claude_cli_opus"],
            :claude_cli_opus,
            nil
          ] do
        assert_invalid(fields(profile_ids: profiles), "profile_ids #{inspect(profiles)}")
      end
    end

    test "allocations: one or more, distinct closed keys, applies_to [:b1], attempts, both bounds" do
      for key <- ModelCallAllocation.keys() do
        assert_valid(fields(allocations: [alloc(key, 6, @w1)]), "a single #{key} allocation")
      end

      [a, b] = fields().allocations

      cases = [
        {"no allocation", []},
        {"two allocations with one key", [a, %{b | key: :rehearsal}]},
        {"an unknown key", [%{a | key: :b9}, b]},
        {"a string key", [%{a | key: "rehearsal"}, b]},
        {"applies_to [:b1, :b5]", [%{a | applies_to: [:b1, :b5]}, b]},
        {"applies_to [:b2]", [%{a | applies_to: [:b2]}, b]},
        {"applies_to [:proof]", [%{a | applies_to: [:proof]}, b]},
        {"applies_to []", [%{a | applies_to: []}, b]},
        {"zero attempts", [%{a | attempts: 0}, b]},
        {"negative attempts", [%{a | attempts: -1}, b]},
        {"fractional attempts", [%{a | attempts: 1.5}, b]},
        {"no available_from", [%{a | available_from: nil}, b]},
        {"no available_until", [%{a | available_until: nil}, b]},
        {"a missing available_until key", [Map.delete(a, :available_until), b]},
        {"a missing attempts key", [Map.delete(a, :attempts), b]},
        {"an extra profile_id", [Map.put(a, :profile_id, :claude_cli_opus), b]},
        {"an extra key", [Map.put(a, :note, "extra"), b]},
        {"an allocation that is not a map", [{:rehearsal, 2}, b]},
        {"allocations that are not a list", nil}
      ]

      for {label, allocations} <- cases do
        assert_invalid(fields(allocations: allocations), "allocations with #{label}")
      end
    end

    test "allocation windows are pairwise disjoint, half-open (T-G2 registry case)" do
      [a, b] = fields().allocations
      {from1, until1} = @w1

      assert_valid(fields(), "touching windows (one's end is the next one's start)")
      assert_valid(fields(allocations: [b, a]), "disjoint windows listed out of order")

      x = alloc(:rehearsal, 2, {@starts, from1})
      y = alloc(:daily_use, 2, @w1)
      z = alloc(:workshop, 2, {~U[2026-10-27 12:00:00.000000Z], ~U[2026-10-27 18:00:00.000000Z]})
      later = alloc(:workshop, 2, @w2)

      assert_valid(fields(allocations: [x, y, later]), "three disjoint windows")

      cases = [
        {"an overlap of one microsecond", [a, %{b | available_from: at(until1, -1)}]},
        {"identical windows", [a, %{b | available_from: from1, available_until: until1}]},
        {"one window inside another",
         [%{a | available_from: @starts, available_until: @expires}, b]},
        {"the first and third of three overlapping", [x, y, z]}
      ]

      for {label, allocations} <- cases do
        assert_invalid(fields(allocations: allocations), label)
      end
    end

    test "allocation attempts sum to at most total_attempts (T-G2 registry case)" do
      [a, b] = fields().allocations

      assert_valid(fields(), "a sum equal to the total")
      assert_valid(fields(allocations: [%{a | attempts: 1}, b]), "a sum below the total")

      assert_invalid(
        fields(allocations: [%{a | attempts: 3}, b]),
        "a sum of 7 above a total of 6"
      )

      assert_invalid(fields(total_attempts: 5), "a total of 5 below a sum of 6")
    end

    test "starts_at is before expires_at" do
      assert_invalid(fields(expires_at: @starts), "equal bounds")
      assert_invalid(fields(starts_at: @expires, expires_at: @starts), "inverted bounds")
      assert_invalid(fields(starts_at: nil), "no starts_at")
      assert_invalid(fields(expires_at: nil), "no expires_at")
    end

    test "decision_refs are the caps row plus D-219 and D-221" do
      cases = [
        {"no refs", []},
        {"no caps row", ["D-219", "D-221"]},
        {"no D-219", [@caps_row, "D-221"]},
        {"no D-221", [@caps_row, "D-219"]},
        {"a second caps row", [@caps_row, "D-998", "D-219", "D-221"]},
        {"a repeated caps row", [@caps_row, @caps_row, "D-219", "D-221"]},
        {"D-219 in place of the caps row", ["D-219", "D-219", "D-221"]},
        {"a caps row that is not a decision id", ["owner caps", "D-219", "D-221"]},
        {"atoms", [:"D-999", :"D-219", :"D-221"]},
        {"one string", "D-999 D-219 D-221"},
        {"nil", nil}
      ]

      for {label, refs} <- cases do
        assert_invalid(fields(decision_refs: refs), "decision_refs with #{label}")
      end
    end

    test "at most one entry for agentenv-1: with two, neither validates and none is current" do
      one = entry!(fields())
      two = entry!(fields(id: "test-synthetic-2"))

      seam!([one])
      assert outcome(:validate, [one]) == {:ok, :ok}, "c2star-s2: control: a single entry"
      assert call(:current, []) == {:ok, one}

      seam!([one, two])
      assert call(:current, []) == :none, "c2star-s2: two agentenv-1 entries have no current one"

      for entry <- [one, two] do
        result = outcome(:validate, [entry])

        assert match?({:ok, {:error, reason}} when is_atom(reason), result),
               "c2star-s2: #{entry.id} validated beside a second agentenv-1 entry: " <>
                 inspect(result)
      end
    end
  end

  ## Digest

  describe "digest" do
    test "sha256/1 is the lowercase hex SHA-256 of the entry's sdr-canonical-json/1 encoding" do
      entry = entry!(fields())
      assert digest!(entry) == canonical_digest(entry)
    end

    test "stable: equal entries built separately share one digest, whatever a timestamp's precision" do
      digest = digest!(entry!(fields()))
      assert digest!(entry!(fields())) == digest

      coarse =
        entry!(fields(starts_at: ~U[2026-10-27 00:00:00Z], expires_at: ~U[2026-10-31 00:00:00Z]))

      assert digest!(coarse) == digest
    end

    test "any field change changes the digest" do
      base = entry!(fields())
      [a, b] = fields().allocations
      {from1, until1} = @w1

      changes = [
        id: "test-synthetic-2",
        decision_refs: ["D-998", "D-219", "D-221"],
        environment_id: "agentenv-2",
        starts_at: at(@starts, 1),
        expires_at: at(@expires, 1),
        funded_scope: [{:assignment, [:qualification]}],
        total_attempts: 7,
        per_utc_day_attempts: nil,
        profile_ids: [:claude_cli_opus, :claude_cli_sonnet],
        allocations: [%{a | attempts: 1}, b]
      ]

      assert changes |> Keyword.keys() |> Enum.sort() == Enum.sort(@fields),
             "fixture bug: every Entry field must be changed once"

      allocation_changes = [
        [%{a | key: :workshop}, b],
        [%{a | applies_to: [:b2]}, b],
        [%{a | available_from: at(from1, 1)}, b],
        [%{a | available_until: at(until1, -1)}, b]
      ]

      variants =
        Enum.map(changes, fn {field, value} -> entry!(fields([{field, value}])) end) ++
          Enum.map(allocation_changes, &entry!(fields(allocations: &1)))

      digests = Enum.map([base | variants], &digest!/1)

      assert length(Enum.uniq(digests)) == length(digests),
             "c2star-s2: a field change left the digest unchanged: #{inspect(digests)}"
    end
  end

  ## Seam

  describe "seam" do
    test "test entries are visible only through the seam, read on every call" do
      entry = entry!(fields())

      assert Application.get_env(:sdr_agent, :claude_cli_test_seams) == true,
             "precondition: this is a test-seam build"

      assert call(:entries, []) == []

      seam!([entry])
      assert call(:entries, []) == [entry]
      assert call(:fetch, [entry.id]) == {:ok, entry}
      assert call(:current, []) == {:ok, entry}

      Application.delete_env(:sdr_agent, @registry)
      assert call(:entries, []) == []
      assert call(:fetch, [entry.id]) == :error
      assert call(:current, []) == :none
    end

    test "no other configuration adds an entry" do
      entry = entry!(fields())
      Application.put_env(:sdr_agent, @registry, entries: [entry], authorizations: [entry])

      assert call(:entries, []) == []
      assert call(:fetch, [entry.id]) == :error
      assert call(:current, []) == :none
    end

    test "fetch/1 validates the id before any lookup (OQ1)" do
      odd = entry!(fields(id: "Test_Synthetic"))
      seam!([odd])
      assert call(:fetch, ["Test_Synthetic"]) == :error

      entry = entry!(fields())
      seam!([entry])

      for id <- [
            "",
            entry.id <> "-x",
            String.upcase(entry.id),
            "a" <> String.duplicate("b", 64)
          ] do
        assert call(:fetch, [id]) == :error, "c2star-s2: fetch(#{inspect(id)}) found an entry"
      end

      assert call(:fetch, [entry.id]) == {:ok, entry}
    end

    test "current/0 is only an agentenv-1 entry" do
      other = entry!(fields(environment_id: "agentenv-2"))
      seam!([other])
      assert call(:current, []) == :none
    end
  end
end
