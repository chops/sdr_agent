defmodule SdrAgent.Agents.WitnessLineageMigrationTest do
  @moduledoc """
  Witness response-block plan r5, T4 group 2 (section 6.5, technical MF3;
  Codex r4 mechanism answer): the actual new migration
  (`priv/repo/migrations/<ts>_v4_mismatch_lineage.exs`), run up, down and
  up again on an owned disposable database, with the installed lineage
  function's behaviour proved by inserts at each state:

    * at the immediate predecessor and after `down`: the old C3 behaviour
      exactly; a v4 successor of a `mismatch` head is permitted;
    * after each `up`: a v4 successor of a `mismatch` head is refused
      (`check_violation`), for v1, v2 and v3 heads and every successor
      status; C3 is otherwise unchanged; a v4 successor of a non-mismatch
      head is permitted.

  The whole module is tagged `:external`; the default test helper excludes
  that tag, so an ordinary `mix test` never launches this campaign. It is
  run only by the required separate command, under a claimed DB slot, with
  its exit code and up/down/up evidence recorded beside the focused and
  full gates:

      mix test test/sdr_agent/agents/witness_lineage_migration_test.exs --include external

  `SdrAgent.WitnessMigration.Harness` owns the lifecycle; its stubbed
  lifecycle and pure target checks run in the ordinary suite
  (`SdrAgent.Agents.WitnessMigrationHarnessTest`, no database). The child
  refusal controls below spawn real `mix run --no-start` children against
  a wrong target and show the refusal before any startup, connection or
  effect; a wrong environment or provider cannot be configured for a child
  without changing the project's configuration, so those refusals are
  covered by the pure `Harness.check_target/2` controls there.

  RED: until GREEN adds the migration, the campaign test fails at its
  presence check (no `*_v4_mismatch_lineage.exs`), before anything is
  claimed. That is a structural failure only: it is not up/down/up
  evidence.
  """
  use ExUnit.Case, async: false

  alias SdrAgent.WitnessMigration.Harness

  @moduletag :external
  @moduletag timeout: 1_800_000

  @root Path.expand("../../..", __DIR__)
  @migrations Path.join(@root, "priv/repo/migrations")
  @scripts Path.join(@root, "test/support/witness_migration")
  @states ~w(predecessor up down up_again)
  @cleanup_keys ~w(child.drop cleanup.drop_attempted cleanup.drop_mode cleanup.drop_result
                   cleanup.drop_receipt cleanup.backends_before_drop
                   cleanup.database_absent_after_drop cleanup.temp_folder outcome)

  defp suffix, do: "_wm" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)

  defp mix!, do: System.find_executable("mix") || flunk("mix is not on PATH")

  defp child_args(script, args),
    do: [
      "run",
      "--no-start",
      "--no-compile",
      "--no-deps-check",
      Path.join(@scripts, script) | args
    ]

  # The checks each probe state must report (`SdrAgent.WitnessMigration.checks/1`).
  defp expected(restricted?) do
    v4_on_mismatch =
      for head <- ~w(v1_mismatch v2_mismatch v3_mismatch),
          status <- ~w(inferred reconciled mismatch),
          into: %{} do
        {"v4_#{status}_on_#{head}",
         if(restricted?, do: "refused:check_violation", else: "permitted")}
      end

    Map.merge(v4_on_mismatch, %{
      "v3_on_v3_mismatch" => "refused:check_violation",
      "v2_on_v1_mismatch" => "permitted",
      "v4_on_v3_inferred" => "permitted"
    })
  end

  test "a real child refuses a wrong target before any startup, connection or effect" do
    # The children run under this partition, so the configured database is
    # `sdr_agent_test<partition>`; every target below differs from it.
    partition = suffix()
    runner = Harness.checked_runner(mix!(), partition, @root, 300_000)
    out = Path.join(System.tmp_dir!(), "sdr-wm-refusal" <> partition <> ".json")
    fixtures = out <> ".fixtures"
    unconfigured = "sdr_agent_test" <> suffix()

    for {label, script, args, reason} <- [
          {"claim, unconfigured", "claim.exs", [unconfigured], "target_not_configured"},
          {"claim, invalid name", "claim.exs", ["sdr_agent_dev"], "invalid_target"},
          {"migrate, unconfigured", "migrate.exs", [unconfigured, "up", "1"],
           "target_not_configured"},
          {"probe, unconfigured", "probe.exs", [unconfigured, "predecessor", fixtures, out],
           "target_not_configured"},
          {"drop, unconfigured", "drop.exs", [unconfigured], "target_not_configured"}
        ] do
      status = Harness.target_refused()
      result = runner.(:refusal, child_args(script, args))
      publish_refusal!(label, hd(args), result)
      assert {:exit, ^status, output} = result, label
      assert output =~ "REFUSED #{reason}", "#{label}: #{output}"
      refute output =~ "VALIDATED", label
      refute output =~ "STARTING", label
      refute File.exists?(out), "#{label}: no probe result"
      refute File.exists?(fixtures), "#{label}: no fixtures"
    end
  end

  test "the v4 lineage migration: up, down, up on an owned disposable database" do
    assert {:ok, versions} = Harness.versions(@migrations),
           "structural RED: the *_v4_mismatch_lineage.exs migration does not exist yet"

    sfx = suffix()

    {outcome, receipts} =
      Harness.prove_with_receipts(
        suffix: sfx,
        tmp_root: System.tmp_dir!(),
        versions: versions,
        runner: Harness.checked_runner(mix!(), sfx, @root, 600_000)
      )

    # The operational receipt is published before any assertion, after
    # every cleanup decision; a failed write fails the test.
    Enum.each(receipts, fn {key, value} -> publish!(key, value) end)

    assert {:ok, states} = outcome
    assert Enum.sort(Map.keys(states)) == Enum.sort(@states)
    assert states["predecessor"] == expected(false), "the predecessor is the old C3 exactly"
    assert states["up"] == expected(true), "after up: the v4 restriction is active"
    assert states["down"] == expected(false), "after down: the old C3 exactly, v4 permitted"
    assert states["up_again"] == expected(true), "after the second up: refused again"
    assert_receipt_complete(receipts, "sdr_agent_test" <> sfx, versions)
  end

  ## Operational receipts (Codex 9ef62e5 G2): `WM-RECEIPT key=value`, one
  ## fact per line, closed keys and closed or synthetic values only.

  defp publish!(key, value) do
    line = "WM-RECEIPT #{key}=#{value}\n"
    :ok = IO.write(line)
  end

  # The case key and refused target of one wrong-target child, and what it
  # did; never its output text beyond the closed refusal reason.
  defp publish_refusal!(label, target, result) do
    key = "refusal." <> (label |> String.replace(", ", "_") |> String.replace(" ", "_"))
    output = if match?({_, _, out} when is_binary(out), result), do: elem(result, 2), else: ""

    reason =
      case Regex.run(~r/^REFUSED ([a-z_]{1,64})$/m, output) do
        [_, reason] -> reason
        nil -> "none"
      end

    publish!(key <> ".target", target)
    publish!(key <> ".outcome", Harness.child_outcome(result))
    publish!(key <> ".reason", reason)
    publish!(key <> ".validated", to_string(output =~ "VALIDATED"))
    publish!(key <> ".started", to_string(output =~ "STARTING"))
  end

  # Every required fact was observed (receipt completeness, not behaviour:
  # the behaviour assertions above are unchanged).
  defp assert_receipt_complete(receipts, database, versions) do
    facts = Map.new(receipts)
    assert length(receipts) == map_size(facts), "one fact per key"
    assert facts["target_database"] == database
    assert facts["temp_folder"] =~ "sdr-witness-migration_wm"
    assert facts["migration_predecessor"] == Integer.to_string(versions.predecessor)
    assert facts["migration_new"] == Integer.to_string(versions.new)
    assert facts["child.claim"] == "exit:0"

    for state <- @states do
      assert facts["child.migrate.#{state}"] == "exit:0", state
      assert facts["child.probe.#{state}"] == "exit:0", state
      assert facts["state.#{state}.check_count"] == Integer.to_string(map_size(expected(true)))

      for {check, _} <- expected(true),
          do: assert(Map.has_key?(facts, "state.#{state}.check.#{check}"), "#{state} #{check}")
    end

    # Codex 7ad3bd0 G2-F1: the published values, not only their keys. Each
    # state's published checks equal that state's expected map exactly...
    for {state, restricted?} <- [
          {"predecessor", false},
          {"up", true},
          {"down", false},
          {"up_again", true}
        ] do
      published =
        for {key, value} <- facts,
            String.starts_with?(key, "state.#{state}.check."),
            into: %{},
            do: {String.replace_prefix(key, "state.#{state}.check.", ""), value}

      assert published == expected(restricted?), state
    end

    # ...and cleanup succeeded with exactly these facts.
    assert Map.take(facts, @cleanup_keys) == %{
             "child.drop" => "exit:0",
             "cleanup.drop_attempted" => "true",
             "cleanup.drop_mode" => "normal",
             "cleanup.drop_result" => "ok",
             "cleanup.drop_receipt" => "valid",
             "cleanup.backends_before_drop" => "0",
             "cleanup.database_absent_after_drop" => "true",
             "cleanup.temp_folder" => "removed",
             "outcome" => "ok"
           }

    refute Map.has_key?(facts, "cleanup.temp_folder_retained_reason")
  end
end
