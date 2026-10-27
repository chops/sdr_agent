defmodule SdrAgent.Agents.WitnessMigrationHarnessTest do
  @moduledoc """
  The projection v4 lineage migration campaign harness itself
  (`SdrAgent.WitnessMigration.Harness`; witness response-block plan r5,
  T4 group 2), without any database: target refusal, version discovery
  and the ownership lifecycle under a stubbed runner. These run in the
  ordinary suite; the campaign itself is
  `SdrAgent.Agents.WitnessLineageMigrationTest` (`:external`).

  Covered (Codex static review of 6c40982, must-fix 2 and 3):

    * the target check refuses a wrong name, an unconfigured name, another
      host or port, a non-test environment and a non-Fake provider; each
      child script validates as its first effectful statement, before any
      startup, connection or effect (an ordering control over the scripts'
      top-level statements; the runtime refusal of a real child is in the
      external campaign file);
    * after confirmed ownership, a confirmed step failure (exit or
      timeout), a typed pre-spawn failure (`{:not_started, _}`), and an
      unreadable, non-object or malformed probe result all still drop the
      owned database, and a failed cleanup keeps both errors;
    * an unconfirmed child, any untyped runner exception, throw or exit
      (including the real runner's kill-failure path), and a claim that
      raised are never cleaned up or dropped (Codex static review of
      336c1cc, R2-1).

  These are tests of test support (not RED for production behaviour):
  they are expected to pass now.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.RestartProof.Harness, as: Bounded
  alias SdrAgent.WitnessMigration.Harness

  @versions %{new: 20_261_021_000_000, predecessor: 20_261_016_052_435}
  @states ~w(predecessor up down up_again)
  @scripts Path.expand("../../support/witness_migration", __DIR__)

  defp suffix, do: "_wm" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)

  defp tmp_root do
    root = Path.join(System.tmp_dir!(), "sdr-wm-lifecycle" <> suffix())
    :ok = File.mkdir(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp facts(database, overrides \\ %{}) do
    Map.merge(
      %{
        database: database,
        hostname: "localhost",
        port: 5520,
        env: :test,
        provider: SdrAgent.AI.ModelProvider.Fake
      },
      overrides
    )
  end

  # A stub runner: records every step and answers from `answers` (default
  # `{:ok, ""}`; a function answer is called with the args). A successful
  # `:probe` writes `probe_body` (default: a valid result for its database
  # and label) where a real child would.
  defp stub(database, answers \\ %{}, probe_body \\ nil) do
    {:ok, log} = Agent.start_link(fn -> [] end)

    runner = fn step, args ->
      Agent.update(log, &[step | &1])

      outcome =
        case Map.get(answers, step, default_answer(step)) do
          fun when is_function(fun, 1) -> fun.(args)
          answer -> answer
        end

      write_probe(step, outcome, args, database, probe_body)
      outcome
    end

    {runner, fn -> Enum.reverse(Agent.get(log, & &1)) end}
  end

  # A successful drop child now reports its two closed facts (Codex 7ad3bd0
  # G2-F1); every other child answers `{:ok, ""}` by default.
  @valid_drop_output "WM-CHILD backends_before_drop=0\nWM-CHILD database_absent_after_drop=true\n"

  defp default_answer(:drop), do: {:ok, @valid_drop_output}
  defp default_answer(_step), do: {:ok, ""}

  defp write_probe(:probe, {:ok, _}, args, database, probe_body) do
    [label, _fixtures, out] = Enum.take(args, -3)

    body =
      probe_body ||
        JSON.encode!(%{
          "database" => database,
          "label" => label,
          "checks" => %{"stub" => "ok"}
        })

    File.write!(out, body)
  end

  defp write_probe(_step, _outcome, _args, _database, _body), do: :ok

  defp prove(sfx, runner, root \\ nil),
    do:
      Harness.prove(
        suffix: sfx,
        tmp_root: root || tmp_root(),
        versions: @versions,
        runner: runner
      )

  defp owned_tmp(root, sfx), do: Path.join(root, "sdr-witness-migration" <> sfx)

  describe "target check (before any startup, connection or effect)" do
    test "the owned, configured test target with the Fake provider is accepted" do
      database = "sdr_agent_test" <> suffix()
      assert Harness.check_target(database, facts(database)) == :ok
    end

    test "a wrong target name is refused" do
      for database <- [
            "sdr_agent_test",
            "sdr_agent_dev",
            "sdr_agent_test_rp0123456789",
            "sdr_agent_test_wm0123456789x",
            "sdr_agent_test_wmABCDEF0123",
            "sdr_agent_test_wm012345678",
            nil
          ] do
        assert Harness.check_target(database, facts(database)) == {:error, :invalid_target},
               inspect(database)
      end

      configured = "sdr_agent_test" <> suffix()

      assert Harness.check_target("sdr_agent_test" <> suffix(), facts(configured)) ==
               {:error, :target_not_configured}
    end

    test "another host or port is refused" do
      database = "sdr_agent_test" <> suffix()

      assert Harness.check_target(database, facts(database, %{hostname: "db.example.test"})) ==
               {:error, :host_not_local}

      assert Harness.check_target(database, facts(database, %{port: 5432})) ==
               {:error, :port_not_5520}
    end

    test "a non-test environment is refused" do
      database = "sdr_agent_test" <> suffix()

      for env <- [:dev, :prod, nil] do
        assert Harness.check_target(database, facts(database, %{env: env})) ==
                 {:error, :env_not_test},
               inspect(env)
      end
    end

    test "a provider other than the Fake is refused" do
      database = "sdr_agent_test" <> suffix()

      for provider <- [SdrAgent.AI.ModelProvider.ClaudeCLI, nil, :fake] do
        assert Harness.check_target(database, facts(database, %{provider: provider})) ==
                 {:error, :provider_not_fake},
               inspect(provider)
      end
    end

    # Ordering control over each script's top-level statements (structural:
    # the runtime refusal of a real child is in the external campaign file).
    test "every child script validates its target before any startup, connection or effect" do
      effects =
        ~w(storage_up storage_down ensure_all_started start_link checkout run fixtures! checks
           write! stop)a

      for {script, validation} <- [
            {"claim.exs", :validate_target!},
            {"migrate.exs", :validate_target!},
            {"drop.exs", :validate_target!},
            {"probe.exs", :start!}
          ] do
        calls = script |> top_level_calls() |> Enum.reject(&(&1 in [:require_file, :argv]))
        assert hd(calls) == validation, "#{script}: #{inspect(calls)}"
        assert Enum.any?(calls, &(&1 in effects)), "#{script}: #{inspect(calls)}"
      end

      # The probe's `start!/1` validates before it starts the application.
      common = File.read!(Path.join(@scripts, "common.exs"))
      [_, start] = String.split(common, "def start!(database) do", parts: 2)
      [validate, rest] = String.split(start, "validate_target!(database)", parts: 2)
      refute validate =~ "ensure_all_started"
      assert rest =~ "ensure_all_started"
    end
  end

  describe "versions" do
    test "the new migration must exist exactly once and have a predecessor" do
      dir = tmp_root()
      assert Harness.versions(dir) == {:error, :migration_absent}

      File.write!(Path.join(dir, "20261016052435_c2_02b2b_resolution_check.exs"), "")
      File.write!(Path.join(dir, "20261007021151_s3_audit_kernel.exs"), "")
      assert Harness.versions(dir) == {:error, :migration_absent}

      File.write!(Path.join(dir, "20261021000000_v4_mismatch_lineage.exs"), "")

      assert Harness.versions(dir) ==
               {:ok, %{new: 20_261_021_000_000, predecessor: 20_261_016_052_435}}

      File.write!(Path.join(dir, "20261022000000_v4_mismatch_lineage.exs"), "")
      assert {:error, {:migration_ambiguous, [_, _]}} = Harness.versions(dir)
    end

    test "a new migration with no predecessor is refused" do
      dir = tmp_root()
      File.write!(Path.join(dir, "20261021000000_v4_mismatch_lineage.exs"), "")
      assert Harness.versions(dir) == {:error, :no_predecessor}
    end
  end

  describe "lifecycle (stubbed children, no database)" do
    test "the sequence: claim, then migrate and probe at each state, then drop" do
      sfx = suffix()
      root = tmp_root()
      {runner, steps} = stub("sdr_agent_test" <> sfx)

      assert {:ok, states} = prove(sfx, runner, root)
      assert Enum.sort(Map.keys(states)) == Enum.sort(@states)
      assert Enum.all?(states, fn {_label, checks} -> checks == %{"stub" => "ok"} end)

      assert steps.() ==
               [:claim] ++ List.flatten(List.duplicate([:migrate, :probe], 4)) ++ [:drop]

      refute File.exists?(owned_tmp(root, sfx))
    end

    test "every child is run with --no-start" do
      sfx = suffix()
      {:ok, seen} = Agent.start_link(fn -> [] end)

      runner = fn step, args ->
        Agent.update(seen, &[{step, args} | &1])
        {runner, _} = stub("sdr_agent_test" <> sfx)
        runner.(step, args)
      end

      assert {:ok, _} = prove(sfx, runner)

      for {step, args} <- Agent.get(seen, & &1) do
        assert Enum.take(args, 2) == ["run", "--no-start"], "#{step}: #{inspect(args)}"
      end
    end

    test "an invalid target name is refused before anything is claimed" do
      {runner, steps} = stub("sdr_agent_test")

      assert {:error, {:invalid_target, "sdr_agent_test"}} = prove("", runner)
      assert {:error, {:invalid_target, _}} = prove("_rp0123456789", runner)
      assert steps.() == []
    end

    test "a pre-existing database is refused: never migrated, probed or dropped" do
      sfx = suffix()
      {runner, steps} = stub("sdr_agent_test" <> sfx, %{claim: {:exit, 3, "exists"}})

      assert {:error, {:database_not_claimed, "exists"}} = prove(sfx, runner)
      assert steps.() == [:claim]
    end

    test "a child that refused its target is not owned and never dropped" do
      sfx = suffix()
      refused = {:exit, Harness.target_refused(), "REFUSED env_not_test"}
      {runner, steps} = stub("sdr_agent_test" <> sfx, %{claim: refused})

      assert {:error, {:claim_failed, ^refused}} = prove(sfx, runner)
      assert steps.() == [:claim]
    end

    test "a failed migration still drops the owned database, and fails" do
      sfx = suffix()
      {runner, steps} = stub("sdr_agent_test" <> sfx, %{migrate: {:exit, 1, "boom"}})

      assert {:error, {:migrate, {:exit, 1, "boom"}}} = prove(sfx, runner)
      assert steps.() == [:claim, :migrate, :drop]
    end

    # Codex static review of 336c1cc, R2-1: a runner exception proves
    # nothing about its child, so it retains the database and the folder.
    test "an unknown runner failure after ownership: no drop and no removal" do
      for {label, step, fun} <- [
            {"raise in migrate", :migrate, fn _args -> raise "synthetic runner failure" end},
            {"raise in probe", :probe, fn _args -> raise "synthetic runner failure" end},
            {"throw", :probe, fn _args -> throw(:synthetic) end},
            {"exit", :migrate, fn _args -> exit(:synthetic) end}
          ] do
        sfx = suffix()
        root = tmp_root()
        {runner, steps} = stub("sdr_agent_test" <> sfx, %{step => fun})

        assert {:error,
                {:cleanup_skipped_unconfirmed_child, {:error, {^step, {:raised, _}}}, owned}} =
                 prove(sfx, runner, root),
               label

        assert owned.database == "sdr_agent_test" <> sfx, label
        refute :drop in steps.(), label
        assert File.dir?(owned_tmp(root, sfx)), label
      end
    end

    # The real runner's own timeout path: past the deadline it kills the
    # child, and the kill itself fails while the child may still run.
    test "the kill-failure path of the real runner retains the database and the folder" do
      sfx = suffix()
      root = tmp_root()

      kill_fails = fn _args ->
        expired = System.monotonic_time(:millisecond) - 1

        Bounded.await_output(make_ref(), expired, 10, fn ->
          raise ErlangError, original: :enoent
        end)
      end

      {runner, steps} = stub("sdr_agent_test" <> sfx, %{migrate: kill_fails})

      assert {:error,
              {:cleanup_skipped_unconfirmed_child,
               {:error, {:migrate, {:raised, %ErlangError{original: :enoent}}}}, _owned}} =
               prove(sfx, runner, root)

      assert steps.() == [:claim, :migrate]
      assert File.dir?(owned_tmp(root, sfx))
    end

    test "a known pre-spawn or confirmed-termination failure after ownership is cleaned up" do
      for {label, step, outcome} <- [
            {"not started", :migrate, {:not_started, {:executable_unusable, "/nonexistent"}}},
            {"not started probe", :probe, {:not_started, {:executable_unusable, "/nonexistent"}}},
            {"confirmed exit", :probe, {:exit, 1, "boom"}},
            {"confirmed exit by signal", :migrate, {:exit, 137, ""}}
          ] do
        sfx = suffix()
        root = tmp_root()
        {runner, steps} = stub("sdr_agent_test" <> sfx, %{step => outcome})

        assert {:error, {^step, ^outcome}} = prove(sfx, runner, root), label
        assert List.last(steps.()) == :drop, label
        refute File.exists?(owned_tmp(root, sfx)), label
      end
    end

    test "a claim that was typed not-started is not owned: folder removed, nothing dropped" do
      sfx = suffix()
      root = tmp_root()
      outcome = {:not_started, {:executable_unusable, "/nonexistent"}}
      {runner, steps} = stub("sdr_agent_test" <> sfx, %{claim: outcome})

      assert {:error, {:claim_failed, ^outcome}} = prove(sfx, runner, root)
      assert steps.() == [:claim]
      refute File.exists?(owned_tmp(root, sfx))
    end

    test "the real runner proves an unusable executable before spawning anything" do
      root = tmp_root()
      not_executable = Path.join(root, "not-executable")
      File.write!(not_executable, "#!/bin/sh\nexit 0\n")
      File.chmod!(not_executable, 0o600)

      for path <- [Path.join(root, "missing"), root, not_executable, nil] do
        runner = Harness.checked_runner(path, suffix(), root, 1_000)

        assert runner.(:claim, ["run"]) == {:not_started, {:executable_unusable, path}},
               inspect(path)
      end
    end

    test "an unreadable, non-object or malformed probe result still drops, and fails" do
      cases = fn database ->
        [
          {"not JSON", "not json", :unreadable_result},
          {"a JSON array", "[1, 2]", :probe_result_not_a_map},
          {"a JSON string", ~s("checks"), :probe_result_not_a_map},
          {"JSON null", "null", :probe_result_not_a_map},
          {"no checks", JSON.encode!(%{"database" => database, "label" => "predecessor"}),
           :probe_result_invalid},
          {"another label",
           JSON.encode!(%{"database" => database, "label" => "up", "checks" => %{"a" => "b"}}),
           :probe_result_invalid},
          {"another database",
           JSON.encode!(%{
             "database" => "sdr_agent_test_wm0000000000",
             "label" => "predecessor",
             "checks" => %{"a" => "b"}
           }), :probe_database},
          {"empty checks",
           JSON.encode!(%{"database" => database, "label" => "predecessor", "checks" => %{}}),
           :probe_result_invalid},
          {"checks not a map",
           JSON.encode!(%{"database" => database, "label" => "predecessor", "checks" => ["a"]}),
           :probe_result_invalid},
          {"a non-string check result",
           JSON.encode!(%{
             "database" => database,
             "label" => "predecessor",
             "checks" => %{"a" => true}
           }), :probe_checks_invalid}
        ]
      end

      for {label, _template, reason} <- cases.("sdr_agent_test_wm1111111111") do
        sfx = suffix()
        database = "sdr_agent_test" <> sfx
        {_, body, _} = Enum.find(cases.(database), &(elem(&1, 0) == label))
        {runner, steps} = stub(database, %{}, body)

        assert {:error, error} = prove(sfx, runner), label
        assert elem(error, 0) == reason, "#{label}: #{inspect(error)}"
        assert steps.() == [:claim, :migrate, :probe, :drop], label
      end
    end

    test "a failed drop fails the campaign and keeps the original outcome" do
      sfx = suffix()
      {runner, _steps} = stub("sdr_agent_test" <> sfx, %{drop: {:exit, 1, "busy"}})

      assert {:error, {:cleanup_failed, {:drop, {:exit, 1, "busy"}}, {:ok, _}}} =
               prove(sfx, runner)
    end

    test "a failed step and a failed cleanup keep both errors" do
      sfx = suffix()
      raising = fn _args -> raise "synthetic drop failure" end

      {runner, _steps} =
        stub("sdr_agent_test" <> sfx, %{migrate: {:exit, 1, "boom"}, drop: raising})

      assert {:error,
              {:cleanup_failed, {:drop, {:raised, %RuntimeError{}}},
               {:error, {:migrate, {:exit, 1, "boom"}}}}} = prove(sfx, runner)
    end

    test "a claim that raised is never owned: nothing is dropped or removed" do
      sfx = suffix()
      root = tmp_root()
      raising = fn _args -> raise "synthetic claim failure" end
      {runner, steps} = stub("sdr_agent_test" <> sfx, %{claim: raising})

      assert {:error, {:cleanup_skipped_unconfirmed_child, {:error, {:claim_failed, _}}, _}} =
               prove(sfx, runner, root)

      assert steps.() == [:claim]
      assert File.dir?(owned_tmp(root, sfx))
    end

    test "an unconfirmed timeout leaves everything in place and fails" do
      sfx = suffix()
      root = tmp_root()
      {runner, steps} = stub("sdr_agent_test" <> sfx, %{probe: {:timeout, :unconfirmed, ""}})

      assert {:error, {:cleanup_skipped_unconfirmed_child, _, _}} = prove(sfx, runner, root)
      refute :drop in steps.()
      assert File.dir?(owned_tmp(root, sfx))
    end

    test "a confirmed timeout cleans up what was claimed and fails" do
      sfx = suffix()
      root = tmp_root()
      {runner, steps} = stub("sdr_agent_test" <> sfx, %{migrate: {:timeout, :confirmed, ""}})

      assert {:error, {:step_timeout, "predecessor", {:timeout, :confirmed, ""}}} =
               prove(sfx, runner, root)

      assert List.last(steps.()) == :drop
      refute File.exists?(owned_tmp(root, sfx))
    end
  end

  # Codex 9ef62e5 G2: the operational receipt (`Harness.prove_with_receipts/1`).
  describe "operational receipts (stubbed children, no database)" do
    @drop_facts "WM-CHILD backends_before_drop=0\nWM-CHILD database_absent_after_drop=true\n"

    test "a completed run records target, versions, child outcomes, states and cleanup" do
      sfx = suffix()
      root = tmp_root()
      {runner, _steps} = stub("sdr_agent_test" <> sfx, %{drop: {:ok, @drop_facts}})

      assert {{:ok, _states}, receipts} =
               Harness.prove_with_receipts(
                 suffix: sfx,
                 tmp_root: root,
                 versions: @versions,
                 runner: runner
               )

      facts = Map.new(receipts)
      assert length(receipts) == map_size(facts), "one fact per key"
      assert facts["target_database"] == "sdr_agent_test" <> sfx
      assert facts["temp_folder"] == owned_tmp(root, sfx)
      assert facts["migration_predecessor"] == "20261016052435"
      assert facts["migration_new"] == "20261021000000"
      assert facts["child.claim"] == "exit:0"

      for state <- @states do
        assert facts["child.migrate.#{state}"] == "exit:0", state
        assert facts["child.probe.#{state}"] == "exit:0", state
        assert facts["state.#{state}.check_count"] == "1", state
        assert facts["state.#{state}.check.stub"] == "unexpected", "closed results only"
      end

      assert {facts["migrate.down.direction"], facts["migrate.down.version"]} ==
               {"down", "20261021000000"}

      assert {facts["migrate.predecessor.direction"], facts["migrate.predecessor.version"]} ==
               {"up", "20261016052435"}

      assert Map.take(facts, ~w(child.drop cleanup.drop_attempted cleanup.drop_mode
                               cleanup.drop_result cleanup.backends_before_drop
                               cleanup.database_absent_after_drop cleanup.temp_folder outcome)) ==
               %{
                 "child.drop" => "exit:0",
                 "cleanup.drop_attempted" => "true",
                 "cleanup.drop_mode" => "normal",
                 "cleanup.drop_result" => "ok",
                 "cleanup.backends_before_drop" => "0",
                 "cleanup.database_absent_after_drop" => "true",
                 "cleanup.temp_folder" => "removed",
                 "outcome" => "ok"
               }

      refute Map.has_key?(facts, "cleanup.temp_folder_retained_reason")
    end

    test "an unconfirmed child records the hold: no drop, folder retained, and why" do
      sfx = suffix()
      {runner, _steps} = stub("sdr_agent_test" <> sfx, %{probe: {:timeout, :unconfirmed, ""}})

      assert {{:error, _}, receipts} =
               Harness.prove_with_receipts(
                 suffix: sfx,
                 tmp_root: tmp_root(),
                 versions: @versions,
                 runner: runner
               )

      facts = Map.new(receipts)
      assert facts["child.probe.predecessor"] == "timeout:unconfirmed"

      assert Map.take(facts, ~w(cleanup.drop_attempted cleanup.temp_folder
                               cleanup.temp_folder_retained_reason outcome)) == %{
               "cleanup.drop_attempted" => "false",
               "cleanup.temp_folder" => "retained",
               "cleanup.temp_folder_retained_reason" => "unconfirmed_child",
               "outcome" => "error"
             }

      refute Map.has_key?(facts, "child.drop")
    end

    test "a failed drop records its outcome and the retained folder" do
      sfx = suffix()
      {runner, _steps} = stub("sdr_agent_test" <> sfx, %{drop: {:exit, 1, "busy"}})

      assert {{:error, {:cleanup_failed, _, _}}, receipts} =
               Harness.prove_with_receipts(
                 suffix: sfx,
                 tmp_root: tmp_root(),
                 versions: @versions,
                 runner: runner
               )

      facts = Map.new(receipts)

      assert Map.take(facts, ~w(child.drop cleanup.drop_result cleanup.backends_before_drop
                               cleanup.database_absent_after_drop cleanup.temp_folder
                               cleanup.temp_folder_retained_reason)) == %{
               "child.drop" => "exit:1",
               "cleanup.drop_result" => "failed",
               "cleanup.backends_before_drop" => "unreported",
               "cleanup.database_absent_after_drop" => "unreported",
               "cleanup.temp_folder" => "retained",
               "cleanup.temp_folder_retained_reason" => "drop_failed"
             }
    end

    test "child outcomes and drop facts are closed labels only" do
      assert Enum.map(
               [
                 {:ok, "secret output"},
                 {:exit, 4, "REFUSED x"},
                 {:timeout, :confirmed, "x"},
                 {:timeout, :unconfirmed, "x"},
                 {:not_started, {:executable_unusable, "/x"}},
                 {:raised, %RuntimeError{message: "x"}},
                 :other
               ],
               &Harness.child_outcome/1
             ) ==
               ~w(exit:0 exit:4 timeout:confirmed timeout:unconfirmed not_started raised unknown)

      assert Harness.drop_facts(@drop_facts) ==
               %{"backends_before_drop" => "0", "database_absent_after_drop" => "true"}

      assert Harness.drop_facts(
               "WM-CHILD backends_before_drop=many\nWM-CHILD database_absent_after_drop=yes\n" <>
                 "WM-CHILD other=1\nnoise backends_before_drop=0\n"
             ) == %{}
    end

    test "prove/1 still returns the bare outcome" do
      sfx = suffix()
      {runner, _steps} = stub("sdr_agent_test" <> sfx)
      assert {:ok, states} = prove(sfx, runner)
      assert Enum.sort(Map.keys(states)) == Enum.sort(@states)
    end
  end

  # Codex 7ad3bd0 G2-F1: cleanup facts are enforced, not merely printed or
  # present: the harness rejects an exit-0 drop child without valid facts.
  # The v1 receipt (exactly `backends_before_drop=0` and
  # `database_absent_after_drop=true`) keeps its semantics here; the drop
  # child's decision itself is now the r7b drain (protocol v2, below).
  describe "enforced cleanup facts (no database)" do
    defp harness(function, args) do
      Code.ensure_loaded(Harness)

      if function_exported?(Harness, function, length(args)),
        do: apply(Harness, function, args),
        else: {:not_implemented, function, length(args)}
    end

    test "the drop child's receipt: exactly the two successful facts, once each" do
      assert harness(:verify_drop_receipt, [@valid_drop_output]) ==
               {:ok, %{"backends_before_drop" => "0", "database_absent_after_drop" => "true"}}

      absent = "WM-CHILD database_absent_after_drop=true\n"
      zero = "WM-CHILD backends_before_drop=0\n"

      for {label, output, reason} <- [
            {"no facts", "", :facts_missing},
            {"backends only", zero, :facts_missing},
            {"absence only", absent, :facts_missing},
            {"non-numeric backends", "WM-CHILD backends_before_drop=many\n" <> absent,
             :facts_malformed},
            {"non-boolean absence", zero <> "WM-CHILD database_absent_after_drop=yes\n",
             :facts_malformed},
            {"an unknown fact", @valid_drop_output <> "WM-CHILD other=1\n", :facts_malformed},
            {"a malformed fact line", @valid_drop_output <> "WM-CHILD backends_before_drop\n",
             :facts_malformed},
            {"duplicate backends", zero <> @valid_drop_output, :facts_duplicate},
            {"duplicate absence", @valid_drop_output <> absent, :facts_duplicate},
            {"contradictory backends", "WM-CHILD backends_before_drop=2\n" <> absent,
             :facts_contradictory},
            {"contradictory absence", zero <> "WM-CHILD database_absent_after_drop=false\n",
             :facts_contradictory}
          ] do
        assert harness(:verify_drop_receipt, [output]) == {:error, reason}, label
      end
    end

    test "an exit-0 drop child without valid facts fails cleanup and keeps the evidence" do
      for {label, output, reason} <- [
            {"no facts", "", :facts_missing},
            {"malformed",
             "WM-CHILD backends_before_drop=x\nWM-CHILD database_absent_after_drop=true\n",
             :facts_malformed},
            {"duplicate", "WM-CHILD backends_before_drop=0\n" <> @valid_drop_output,
             :facts_duplicate},
            {"contradictory",
             "WM-CHILD backends_before_drop=1\nWM-CHILD database_absent_after_drop=true\n",
             :facts_contradictory}
          ] do
        sfx = suffix()
        root = tmp_root()
        {runner, steps} = stub("sdr_agent_test" <> sfx, %{drop: {:ok, output}})

        {outcome, receipts} =
          Harness.prove_with_receipts(
            suffix: sfx,
            tmp_root: root,
            versions: @versions,
            runner: runner
          )

        assert match?(
                 {:error, {:cleanup_failed, {:drop, {:receipt_invalid, ^reason}}, {:ok, _}}},
                 outcome
               ),
               "#{label}: #{inspect(outcome)}"

        facts = Map.new(receipts)
        assert facts["child.drop"] == "exit:0", label
        assert facts["cleanup.drop_result"] == "failed", label
        assert facts["cleanup.drop_receipt"] == Atom.to_string(reason), label
        assert facts["cleanup.temp_folder"] == "retained", label
        assert facts["cleanup.temp_folder_retained_reason"] == "drop_receipt_invalid", label
        assert facts["outcome"] == "error", label
        assert List.last(steps.()) == :drop, label
        assert File.dir?(owned_tmp(root, sfx)), "#{label}: evidence retained"
      end
    end

    test "a valid drop receipt is recorded as such" do
      sfx = suffix()
      {runner, _steps} = stub("sdr_agent_test" <> sfx)

      assert {{:ok, _}, receipts} =
               Harness.prove_with_receipts(
                 suffix: sfx,
                 tmp_root: tmp_root(),
                 versions: @versions,
                 runner: runner
               )

      assert Map.new(receipts)["cleanup.drop_receipt"] == "valid"
    end
  end

  ## RED-8: the drop child drains like the standing runner's r7b (Codex
  ## db034af6 Q6). Exactly `backend_type COLLATE "C" = 'autovacuum worker'`
  ## does not block; NULL, custom, case or whitespace variants and every
  ## other type do. One fixed monotonic budget, bounded observations and
  ## resampling, a final clock check at acceptance, the accepted record
  ## written before the plain drop; actual counts kept (protocol v2 facts).

  @av "x6175746f76616375756d20776f726b6572"
  @t0 1_000

  defp drain_protocol?,
    do: Code.ensure_loaded?(Harness) and function_exported?(Harness, :parse_backends, 1)

  # The drop child's decision under the drain protocol (RED: structural; a
  # dynamic call, so no result type is inferred from the v1 decision).
  defp drain_drop(effects) do
    if drain_protocol?(),
      do: Function.capture(Harness, :drop_flow, 1).(effects),
      else: {:not_implemented, :drain_protocol}
  end

  # One observation's output lines, as `Harness.backends_sql/0` prints them:
  # the header (the server's blocking count by exact equality unless
  # given), one line per distinct type in byte order, the end line.
  defp observation(types, blocking \\ nil) do
    total = types |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    blocking =
      blocking || Enum.sum(for {type, n} <- types, type != "autovacuum worker", do: n)

    ["backends total=#{total} blocking=#{blocking} groups=#{length(types)}"] ++
      for(
        {type, n} <- Enum.sort_by(types, &token(elem(&1, 0))),
        do: "type=#{token(type)} count=#{n}"
      ) ++ ["end groups=#{length(types)}"]
  end

  defp token(nil), do: "N"
  defp token(type), do: "x" <> Base.encode16(type, case: :lower)

  # Scripted effects: `clock` (integers, or anything else for an unreadable
  # read) and `observe` are consumed in order; every call is reported to
  # this process; `emit_fails` names the lines whose write fails.
  defp drain_effects(script) do
    test = self()
    queues = %{clock: script.clock, observe: Map.get(script, :observe, [])}
    {:ok, agent} = Agent.start_link(fn -> queues end)
    fails? = Map.get(script, :emit_fails, fn _line -> false end)

    pop = fn key -> Agent.get_and_update(agent, &pop_next(&1, key)) end

    %{
      clock: fn ->
        send(test, :clock)

        case pop.(:clock) do
          ms when is_integer(ms) -> {:ok, ms}
          unreadable -> unreadable
        end
      end,
      observe: fn ms ->
        send(test, {:observe, ms})
        pop.(:observe)
      end,
      pause: fn ->
        send(test, :pause)
        Map.get(script, :pause, :ok)
      end,
      storage_down: fn ->
        send(test, :storage_down)
        Map.get(script, :storage_down, :ok)
      end,
      count_present: fn ->
        send(test, :count_present)
        Map.get(script, :count_present, {:ok, 0})
      end,
      emit: fn line ->
        send(test, {:emit, line})
        if fails?.(line), do: {:error, :closed}, else: :ok
      end
    }
  end

  defp pop_next(state, key) do
    case Map.fetch!(state, key) do
      [next | rest] -> {next, Map.put(state, key, rest)}
      [] -> {:exhausted, state}
    end
  end

  defp emitted(acc \\ []) do
    receive do
      {:emit, line} -> emitted([line | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp observed_bounds(acc \\ []) do
    receive do
      {:observe, ms} -> observed_bounds([ms | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp count_received(message, n \\ 0) do
    receive do
      ^message -> count_received(message, n + 1)
    after
      0 -> n
    end
  end

  # Every effect call, in order (RED-8b): clock reads, observations, the
  # drain and fact lines by their first token, the drop and the proof.
  defp sequence(acc \\ []) do
    receive do
      :clock -> sequence([:clock | acc])
      {:observe, _ms} -> sequence([:observe | acc])
      {:emit, "WM-DRAIN " <> line} -> sequence([{:drain, first_token(line)} | acc])
      {:emit, "WM-CHILD " <> fact} -> sequence([{:fact, first_token(fact)} | acc])
      :pause -> sequence([:pause | acc])
      :storage_down -> sequence([:storage_down | acc])
      :count_present -> sequence([:count_present | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp first_token(line), do: line |> String.split([" ", "="], parts: 2) |> hd()

  defp facts_of(lines), do: for("WM-CHILD " <> fact <- lines, do: fact)
  defp drain_lines(lines), do: for("WM-DRAIN " <> line <- lines, do: line)

  defp v2_facts(total, attempts) do
    ~w(drop_protocol=2 backends_before_drop=#{total} blocking_before_drop=0
       excluded_before_drop=#{total} drain_attempts=#{attempts})
  end

  describe "the r7b drain before the drop (protocol v2; Codex db034af6 Q6)" do
    test "zero backends: accepted at once, the v2 facts, the plain drop, the absence proof" do
      assert drain_protocol?(), "Harness.parse_backends/1 (the drain protocol) is not implemented"

      effects =
        drain_effects(%{clock: [@t0, @t0, 1_040, 1_050], observe: [{:ok, observation([])}]})

      assert drain_drop(effects) == :ok
      lines = emitted()
      assert facts_of(lines) == v2_facts(0, 1) ++ ["database_absent_after_drop=true"]

      assert [start, attempt, accepted] = drain_lines(lines)

      assert start ==
               "budget_ms=10000 max_attempts=10 pause_ms=1000 connect_timeout_ms=2000 " <>
                 "slack_ms=500 min_statement_ms=500"

      assert attempt ==
               "attempt=01 start_elapsed_ms=0 end_elapsed_ms=40 remaining_ms=10000 " <>
                 "statement_timeout_ms=7500 lock_timeout_ms=7500 result=valid " <>
                 "detail=[total=0 blocking=0 groups=0] types=[] decision=eligible"

      assert accepted == "accepted attempt=01 final_check_elapsed_ms=50"
      assert observed_bounds() == [7_500]
      assert_received :storage_down
      assert_received :count_present

      assert Harness.verify_drop_receipt(Enum.join(lines, "\n")) ==
               {:ok,
                %{
                  "drop_protocol" => "2",
                  "backends_before_drop" => "0",
                  "blocking_before_drop" => "0",
                  "excluded_before_drop" => "0",
                  "drain_attempts" => "1",
                  "database_absent_after_drop" => "true"
                }}
    end

    test "an autovacuum worker alone does not block, and is never reported as zero" do
      assert drain_protocol?(), "Harness.parse_backends/1 (the drain protocol) is not implemented"

      effects =
        drain_effects(%{
          clock: [@t0, @t0, 1_040, 1_050],
          observe: [{:ok, observation([{"autovacuum worker", 1}])}]
        })

      assert drain_drop(effects) == :ok
      lines = emitted()
      assert facts_of(lines) == v2_facts(1, 1) ++ ["database_absent_after_drop=true"]

      assert Enum.at(drain_lines(lines), 1) =~
               "detail=[total=1 blocking=0 groups=1] types=[#{@av}:1] decision=eligible"

      assert {:ok, %{"backends_before_drop" => "1", "excluded_before_drop" => "1"}} =
               Harness.verify_drop_receipt(Enum.join(lines, "\n"))

      assert_received :storage_down
    end

    test "every other type blocks: client, NULL, empty, custom, case and whitespace variants" do
      assert drain_protocol?(), "Harness.parse_backends/1 (the drain protocol) is not implemented"

      for type <- [
            "client backend",
            nil,
            "",
            "autovacuum worker ",
            " autovacuum worker",
            "Autovacuum Worker",
            "autovacuum launcher",
            "autovacuum workers",
            "parallel worker"
          ] do
        # Too late for a recheck: 11000 - 7100 - (1000 + 2000 + 500) < 500.
        effects =
          drain_effects(%{
            clock: [@t0, @t0, 7_100],
            observe: [{:ok, observation([{"autovacuum worker", 1}, {type, 2}])}]
          })

        assert drain_drop(effects) == {:error, {:backends_present, 2}}, inspect(type)
        lines = emitted()
        assert facts_of(lines) == [], inspect(type)
        assert Enum.at(drain_lines(lines), 1) =~ "blocking=2 groups=2", inspect(type)
        assert Enum.at(drain_lines(lines), 1) =~ "decision=retain", inspect(type)
        assert List.last(drain_lines(lines)) == "retained: backends_present", inspect(type)
        refute_received :storage_down
      end
    end

    # RED-8b: an observation's end is read after the observation, the final
    # check after that attempt's line, every pre-drop fact before the drop.
    test "the order: t0, bounds, start, observation, its end, its line, final check, facts, drop" do
      assert drain_protocol?(), "Harness.parse_backends/1 (the drain protocol) is not implemented"

      effects =
        drain_effects(%{
          clock: [@t0, @t0, 1_040, 2_100, 2_140, 2_150],
          observe: [{:ok, observation([{"client backend", 1}])}, {:ok, observation([])}]
        })

      assert drain_drop(effects) == :ok

      assert sequence() == [
               :clock,
               {:drain, "budget_ms"},
               :clock,
               :observe,
               :clock,
               {:drain, "attempt"},
               :pause,
               :clock,
               :observe,
               :clock,
               {:drain, "attempt"},
               :clock,
               {:drain, "accepted"},
               {:fact, "drop_protocol"},
               {:fact, "backends_before_drop"},
               {:fact, "blocking_before_drop"},
               {:fact, "excluded_before_drop"},
               {:fact, "drain_attempts"},
               :storage_down,
               :count_present,
               {:fact, "database_absent_after_drop"}
             ]
    end

    test "a blocker that vanishes is rechecked after the pause, then accepted" do
      assert drain_protocol?(), "Harness.parse_backends/1 (the drain protocol) is not implemented"

      effects =
        drain_effects(%{
          clock: [@t0, @t0, 1_040, 2_100, 2_140, 2_150],
          observe: [
            {:ok, observation([{"client backend", 1}, {"autovacuum worker", 1}])},
            {:ok, observation([])}
          ]
        })

      assert drain_drop(effects) == :ok
      lines = emitted()
      assert facts_of(lines) == v2_facts(0, 2) ++ ["database_absent_after_drop=true"]
      assert [_start, first, second, accepted] = drain_lines(lines)
      assert first =~ "attempt=01 " and first =~ "blocking=1 groups=2" and first =~ "recheck"
      assert second =~ "attempt=02 start_elapsed_ms=1100 " and second =~ "decision=eligible"
      assert accepted == "accepted attempt=02 final_check_elapsed_ms=1150"
      assert observed_bounds() == [7_500, 6_400], "the deadline is never renewed"
      assert count_received(:pause) == 1
    end

    test "a persistent blocker: bounded rechecks, no renewal, no drop" do
      assert drain_protocol?(), "Harness.parse_backends/1 (the drain protocol) is not implemented"

      starts = [1_000, 2_100, 3_200, 4_300, 5_400, 6_500, 7_600]
      clock = [@t0 | Enum.flat_map(starts, &[&1, &1 + 40])]
      blocked = {:ok, observation([{"client backend", 1}])}

      effects =
        drain_effects(%{clock: clock, observe: List.duplicate(blocked, length(starts))})

      assert drain_drop(effects) == {:error, {:backends_present, 1}}
      assert observed_bounds() == [7_500, 6_400, 5_300, 4_200, 3_100, 2_000, 900]
      assert count_received(:pause) == 6
      lines = emitted()
      assert facts_of(lines) == []
      assert List.last(drain_lines(lines)) == "retained: backends_present"
      refute_received :storage_down
    end

    test "at most ten observations, even with time left" do
      assert drain_protocol?(), "Harness.parse_backends/1 (the drain protocol) is not implemented"

      blocked = {:ok, observation([{"client backend", 1}])}

      effects =
        drain_effects(%{
          clock: List.duplicate(@t0, 1 + 2 * 10),
          observe: List.duplicate(blocked, 11)
        })

      assert drain_drop(effects) == {:error, {:backends_present, 1}}
      assert length(observed_bounds()) == 10
      refute_received :storage_down
    end

    test "the deadline: a late observation is not read; a start without room is not made" do
      assert drain_protocol?(), "Harness.parse_backends/1 (the drain protocol) is not implemented"

      for ended <- [11_000, 11_500] do
        effects =
          drain_effects(%{clock: [@t0, @t0, ended], observe: [{:ok, observation([])}]})

        assert drain_drop(effects) == {:error, :deadline_expired}, inspect(ended)
        lines = emitted()
        assert facts_of(lines) == []
        assert Enum.at(drain_lines(lines), 1) =~ "result=late"
        assert observed_bounds() == [7_500]
        refute_received :storage_down
      end

      # After a recheck, 11000 - 8100 - (2000 + 500) < 500: no second observation.
      effects =
        drain_effects(%{
          clock: [@t0, @t0, 1_040, 8_100],
          observe: [{:ok, observation([{"client backend", 1}])}]
        })

      assert drain_drop(effects) == {:error, :deadline_expired}
      assert observed_bounds() == [7_500]
      assert List.last(drain_lines(emitted())) == "retained: deadline_expired"
    end

    test "the final acceptance check: at or after the deadline, unreadable or backward" do
      assert drain_protocol?(), "Harness.parse_backends/1 (the drain protocol) is not implemented"

      for {final, reason} <- [
            {11_000, :deadline_expired},
            {12_000, :deadline_expired},
            {:unreadable, :clock_unreadable},
            {1_030, :clock_backward}
          ] do
        effects =
          drain_effects(%{clock: [@t0, @t0, 1_040, final], observe: [{:ok, observation([])}]})

        assert drain_drop(effects) == {:error, reason}, inspect(final)
        lines = emitted()
        assert facts_of(lines) == [], inspect(final)
        assert Enum.at(drain_lines(lines), 1) =~ "decision=eligible"
        refute_received :storage_down
      end
    end

    test "an unreadable or backward clock refuses before or after an observation" do
      assert drain_protocol?(), "Harness.parse_backends/1 (the drain protocol) is not implemented"

      blocked = {:ok, observation([{"client backend", 1}])}

      for {label, clock, observations, reason} <- [
            {"at t0", [:unreadable], 0, :clock_unreadable},
            {"before the first", [@t0, :unreadable], 0, :clock_unreadable},
            {"after an observation", [@t0, @t0, :unreadable], 1, :clock_unreadable},
            {"back after an observation", [@t0, @t0, 990], 1, :clock_backward},
            {"back before a recheck", [@t0, @t0, 1_040, 1_030], 1, :clock_backward}
          ] do
        effects = drain_effects(%{clock: clock, observe: [blocked]})
        assert drain_drop(effects) == {:error, reason}, label
        assert length(observed_bounds()) == observations, label
        assert facts_of(emitted()) == [], label
        refute_received :storage_down
      end
    end

    test "a failed or malformed observation refuses at once" do
      assert drain_protocol?(), "Harness.parse_backends/1 (the drain protocol) is not implemented"

      header = "backends total=0 blocking=0 groups=0"
      one = "backends total=1 blocking=1 groups=1"

      for {label, observed, reason} <- [
            {"a failed query", {:error, :timeout}, {:observation_failed, :timeout}},
            {"no rows", {:ok, []}, {:observation_malformed, :no_header}},
            {"a non-text row", {:ok, [nil]}, {:observation_malformed, :not_text}},
            {"no end line", {:ok, [header]}, {:observation_malformed, :no_end}},
            {"a noncanonical number", {:ok, ["backends total=00 blocking=0 groups=0"]},
             {:observation_malformed, :bad_header}},
            {"an unknown line", {:ok, [header, "noise", "end groups=0"]},
             {:observation_malformed, :bad_line}},
            {"a zero count", {:ok, [one, "type=x41 count=0", "end groups=1"]},
             {:observation_malformed, :bad_line}},
            {"odd hex", {:ok, [one, "type=x4 count=1", "end groups=1"]},
             {:observation_malformed, :bad_line}},
            {"upper-case hex", {:ok, [one, "type=x4A count=1", "end groups=1"]},
             {:observation_malformed, :bad_line}},
            {"a repeated type",
             {:ok,
              [
                "backends total=2 blocking=2 groups=2",
                "type=x41 count=1",
                "type=x41 count=1",
                "end groups=2"
              ]}, {:observation_malformed, :repeated_type}},
            {"a line after the end", {:ok, [header, "end groups=0", "end groups=0"]},
             {:observation_malformed, :line_after_end}},
            {"groups that do not reconcile", {:ok, [one, "end groups=1"]},
             {:observation_malformed, :groups_mismatch}},
            {"a total that does not reconcile",
             {:ok, ["backends total=2 blocking=2 groups=1", "type=x41 count=1", "end groups=1"]},
             {:observation_malformed, :total_mismatch}},
            {"the server's zero against a NULL type", {:ok, observation([{nil, 1}], 0)},
             {:observation_malformed, :blocking_mismatch}},
            {"the server's blocker against an autovacuum worker",
             {:ok, observation([{"autovacuum worker", 1}], 1)},
             {:observation_malformed, :blocking_mismatch}},
            {"not a list", {:ok, "backends total=0"}, {:observation_malformed, :not_text}}
          ] do
        effects = drain_effects(%{clock: [@t0, @t0, 1_040], observe: [observed]})
        assert drain_drop(effects) == {:error, reason}, label
        assert length(observed_bounds()) == 1, label
        lines = emitted()
        assert facts_of(lines) == [], label
        assert Enum.at(drain_lines(lines), 1) =~ "decision=retain", label
        refute_received :storage_down
      end
    end

    test "an evidence write failure refuses; at the accepted record it vetoes the drop" do
      assert drain_protocol?(), "Harness.parse_backends/1 (the drain protocol) is not implemented"

      for {label, prefix, observations} <- [
            {"the bounds line", "WM-DRAIN budget_ms=", 0},
            {"an attempt line", "WM-DRAIN attempt=01", 1},
            {"the accepted line", "WM-DRAIN accepted", 1},
            {"the protocol fact", "WM-CHILD drop_protocol=", 1},
            {"the backends fact", "WM-CHILD backends_before_drop=", 1},
            {"the blocking fact", "WM-CHILD blocking_before_drop=", 1},
            {"the excluded fact", "WM-CHILD excluded_before_drop=", 1},
            {"the attempts fact", "WM-CHILD drain_attempts=", 1}
          ] do
        effects =
          drain_effects(%{
            clock: [@t0, @t0, 1_040, 1_050],
            observe: [{:ok, observation([])}],
            emit_fails: &String.starts_with?(&1, prefix)
          })

        assert drain_drop(effects) == {:error, :receipt_write_failed}, label
        assert length(observed_bounds()) == observations, label
        refute_received :storage_down
        _ = emitted()
      end

      effects =
        drain_effects(%{
          clock: [@t0, @t0, 1_040, 1_050],
          observe: [{:ok, observation([])}],
          emit_fails: &String.starts_with?(&1, "WM-CHILD database_absent_after_drop=")
        })

      assert drain_drop(effects) == {:error, :receipt_write_failed}
      assert_received :storage_down
    end

    test "a failed pause, a failed drop and a failed absence proof refuse" do
      assert drain_protocol?(), "Harness.parse_backends/1 (the drain protocol) is not implemented"

      zero = [{:ok, observation([])}]
      accepted = [@t0, @t0, 1_040, 1_050]

      effects =
        drain_effects(%{
          clock: [@t0, @t0, 1_040],
          observe: [{:ok, observation([{"client backend", 1}])}],
          pause: {:error, :interrupted}
        })

      assert drain_drop(effects) == {:error, :pause_failed}
      refute_received :storage_down

      effects = drain_effects(%{clock: accepted, observe: zero, storage_down: {:error, :busy}})
      assert drain_drop(effects) == {:error, {:drop_failed, :busy}}
      refute_received :count_present
      refute Enum.any?(emitted(), &(&1 =~ "database_absent_after_drop"))

      effects =
        drain_effects(%{clock: accepted, observe: zero, count_present: {:error, :timeout}})

      assert drain_drop(effects) == {:error, {:absence_unproven, :timeout}}
      refute Enum.any?(emitted(), &(&1 =~ "database_absent_after_drop"))

      effects = drain_effects(%{clock: accepted, observe: zero, count_present: {:ok, 1}})
      assert drain_drop(effects) == {:error, :database_present_after_drop}
      assert "database_absent_after_drop=false" in facts_of(emitted())
    end

    test "each refusal has a closed child label" do
      assert drain_protocol?(), "Harness.parse_backends/1 (the drain protocol) is not implemented"

      assert Enum.map(
               [
                 {:backends_present, 2},
                 {:drop_failed, :busy},
                 :database_present_after_drop,
                 :receipt_write_failed,
                 :clock_unreadable,
                 :clock_backward,
                 :deadline_expired,
                 :pause_failed,
                 {:observation_failed, :timeout},
                 {:observation_malformed, :bad_line},
                 {:absence_unproven, :timeout}
               ],
               &Harness.drop_refusal_label/1
             ) ==
               ~w(backends_present drop_failed database_present_after_drop receipt_write_failed
                  clock_unreadable clock_backward deadline_expired pause_failed
                  observation_failed observation_malformed absence_unproven)
    end

    test "the bounds are the standing runner's r7b values" do
      assert harness(:drop_bounds, []) == %{
               budget_ms: 10_000,
               max_attempts: 10,
               pause_ms: 1_000,
               connect_timeout_ms: 2_000,
               slack_ms: 500,
               min_statement_ms: 500,
               drop_connect_timeout_ms: 10_000,
               drop_statement_timeout_ms: 120_000,
               drop_lock_timeout_ms: 10_000
             }
    end

    test "the observation statement: exact bytes, one pg_stat_activity read, types only" do
      sql =
        "with a as materialized (select backend_type as t from pg_stat_activity " <>
          "where datname = $1), g as (select t, count(*) as n from a group by t) " <>
          "select l from (select 0 as k, '' as o, 'backends total=' || " <>
          "(select count(*) from a) || ' blocking=' || (select count(*) from a " <>
          "where t collate \"C\" is distinct from 'autovacuum worker') || ' groups=' || " <>
          "(select count(*) from g) as l union all select 1, v, 'type=' || v || " <>
          "' count=' || n from (select case when t is null then 'N' else 'x' || " <>
          "encode(convert_to(t, 'UTF8'), 'hex') end as v, n from g) e union all " <>
          "select 2, '', 'end groups=' || (select count(*) from g)) z " <>
          "order by k, o collate \"C\""

      assert harness(:backends_sql, []) == sql

      for word <- ~w(query usename pid client_addr application_name pg_terminate_backend
                     pg_cancel_backend force) do
        refute sql =~ word, word
      end
    end

    test "parse_backends/1 keeps the actual total, blocking and types" do
      assert harness(:parse_backends, [
               observation([{"autovacuum worker", 1}, {nil, 1}, {"client backend", 2}])
             ]) ==
               {:ok,
                %{
                  total: 4,
                  blocking: 3,
                  groups: 3,
                  types: [{"N", 1}, {@av, 1}, {token("client backend"), 2}]
                }}
    end

    test "the drop child wires the drain: real monotonic clock, bounded reads, plain drop" do
      source = File.read!(Path.join(@scripts, "drop.exs"))
      ast = Code.string_to_quoted!(source)

      for {label, pattern} <- [
            {"the decision", "Harness.drop_flow("},
            {"the statement", "Harness.backends_sql()"},
            {"the bounds", "Harness.drop_bounds()"},
            {"the monotonic clock", "System.monotonic_time(:millisecond)"},
            {"a bounded statement", "set_config('statement_timeout', $1, true)"},
            {"a bounded lock wait", "set_config('lock_timeout', $1, true)"},
            {"the plain drop", "Ecto.Adapters.Postgres.storage_down("}
          ] do
        assert source =~ pattern, label
      end

      {_ast, strings} =
        Macro.prewalk(ast, [], fn
          string, acc when is_binary(string) -> {string, [string | acc]}
          node, acc -> {node, acc}
        end)

      for string <- strings,
          word <- ~w(FORCE pg_terminate_backend pg_cancel_backend pg_signal_backend ALTER) do
        refute String.contains?(String.upcase(string), String.upcase(word)),
               "#{inspect(string)} contains #{word}"
      end

      refute source =~ "count_backends", "the v1 exact-zero count is no longer wired"
    end
  end

  describe "the drop receipt, protocol v2 (Codex db034af6 Q6: versioned and additive)" do
    @v2 "WM-CHILD drop_protocol=2\nWM-CHILD backends_before_drop=1\n" <>
          "WM-CHILD blocking_before_drop=0\nWM-CHILD excluded_before_drop=1\n" <>
          "WM-CHILD drain_attempts=2\nWM-CHILD database_absent_after_drop=true\n"

    defp v2_without(key),
      do: @v2 |> String.split("\n", trim: true) |> Enum.reject(&(&1 =~ key)) |> Enum.join("\n")

    defp v2_with(key, value),
      do:
        @v2
        |> String.split("\n", trim: true)
        |> Enum.map_join(
          "\n",
          &if(&1 =~ "WM-CHILD #{key}=", do: "WM-CHILD #{key}=#{value}", else: &1)
        )

    test "a v2 receipt: exactly its six facts, the excluded workers counted, never zeroed" do
      assert harness(:verify_drop_receipt, [@v2]) ==
               {:ok,
                %{
                  "drop_protocol" => "2",
                  "backends_before_drop" => "1",
                  "blocking_before_drop" => "0",
                  "excluded_before_drop" => "1",
                  "drain_attempts" => "2",
                  "database_absent_after_drop" => "true"
                }}

      for {label, output, reason} <-
            [
              {"another protocol", v2_with("drop_protocol", "3"), :facts_malformed},
              {"no attempt", v2_with("drain_attempts", "0"), :facts_malformed},
              {"eleven attempts", v2_with("drain_attempts", "11"), :facts_malformed},
              {"a noncanonical excluded count", v2_with("excluded_before_drop", "01"),
               :facts_malformed},
              {"a duplicate fact", @v2 <> "WM-CHILD drain_attempts=2\n", :facts_duplicate},
              {"the v1 pair plus the protocol only",
               "WM-CHILD drop_protocol=2\n" <> @valid_drop_output, :facts_missing},
              {"a blocker", v2_with("blocking_before_drop", "1"), :facts_contradictory},
              {"an unexcluded backend", v2_with("backends_before_drop", "2"),
               :facts_contradictory},
              {"a present database", v2_with("database_absent_after_drop", "false"),
               :facts_contradictory}
            ] ++
              for(
                key <- ~w(drop_protocol backends_before_drop blocking_before_drop
                            excluded_before_drop drain_attempts database_absent_after_drop),
                do: {"no #{key}", v2_without(key), :facts_missing}
              ) do
        assert harness(:verify_drop_receipt, [output]) == {:error, reason}, label
      end
    end

    test "the v2 facts are recorded beside the v1 pair; a v1 receipt records none of them" do
      sfx = suffix()
      {runner, _steps} = stub("sdr_agent_test" <> sfx, %{drop: {:ok, "noise\n" <> @v2}})

      assert {{:ok, _}, receipts} =
               Harness.prove_with_receipts(
                 suffix: sfx,
                 tmp_root: tmp_root(),
                 versions: @versions,
                 runner: runner
               )

      facts = Map.new(receipts)
      assert length(receipts) == map_size(facts), "one fact per key"

      assert Map.take(facts, ~w(cleanup.drop_receipt cleanup.drop_result cleanup.drop_protocol
                               cleanup.backends_before_drop cleanup.blocking_before_drop
                               cleanup.excluded_before_drop cleanup.drain_attempts
                               cleanup.database_absent_after_drop)) == %{
               "cleanup.drop_receipt" => "valid",
               "cleanup.drop_result" => "ok",
               "cleanup.drop_protocol" => "2",
               "cleanup.backends_before_drop" => "1",
               "cleanup.blocking_before_drop" => "0",
               "cleanup.excluded_before_drop" => "1",
               "cleanup.drain_attempts" => "2",
               "cleanup.database_absent_after_drop" => "true"
             }

      assert Harness.drop_facts(@v2)["excluded_before_drop"] == "1"

      sfx = suffix()
      {runner, _steps} = stub("sdr_agent_test" <> sfx)

      assert {{:ok, _}, receipts} =
               Harness.prove_with_receipts(
                 suffix: sfx,
                 tmp_root: tmp_root(),
                 versions: @versions,
                 runner: runner
               )

      for key <- ~w(cleanup.drop_protocol cleanup.blocking_before_drop
                    cleanup.excluded_before_drop cleanup.drain_attempts) do
        refute Map.has_key?(Map.new(receipts), key), key
      end
    end
  end

  ## Helpers

  # The names of a script's top-level calls, in order (`Mod.fun(...)`,
  # `fun(...)`, also as the right side of a match).
  defp top_level_calls(script) do
    {:__block__, _, statements} =
      @scripts |> Path.join(script) |> File.read!() |> Code.string_to_quoted!()

    Enum.flat_map(statements, &calls_in/1)
  end

  defp calls_in({:=, _, [_pattern, expression]}), do: calls_in(expression)
  defp calls_in({:case, _, [expression | _]}), do: calls_in(expression)
  defp calls_in({:|>, _, [left, _right]}), do: calls_in(left)
  defp calls_in({{:., _, [_module, name]}, _, _args}) when is_atom(name), do: [name]
  defp calls_in({:alias, _, _}), do: []

  defp calls_in({name, _, args}) when is_atom(name) and is_list(args) do
    if name in [:__block__, :%{}, :{}], do: [], else: [name]
  end

  defp calls_in(_other), do: []
end
