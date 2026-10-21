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
    * after confirmed ownership, a step failure, a runner exception, an
      unreadable, non-object or malformed probe result all still drop the
      owned database, and a failed cleanup keeps both errors;
    * an unconfirmed child, or a claim that raised, is never cleaned up or
      dropped.

  These are tests of test support (not RED for production behaviour):
  they are expected to pass now.
  """
  use ExUnit.Case, async: true

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
        case Map.get(answers, step, {:ok, ""}) do
          fun when is_function(fun, 1) -> fun.(args)
          answer -> answer
        end

      write_probe(step, outcome, args, database, probe_body)
      outcome
    end

    {runner, fn -> Enum.reverse(Agent.get(log, & &1)) end}
  end

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

    test "a runner exception after ownership still drops the owned database" do
      for step <- [:migrate, :probe] do
        sfx = suffix()
        root = tmp_root()
        raising = fn _args -> raise "synthetic runner failure" end
        {runner, steps} = stub("sdr_agent_test" <> sfx, %{step => raising})

        assert {:error, {^step, {:raised, %RuntimeError{message: "synthetic runner failure"}}}} =
                 prove(sfx, runner, root)

        assert List.last(steps.()) == :drop, inspect(step)
        refute File.exists?(owned_tmp(root, sfx))
      end
    end

    test "a thrown or exited runner after ownership still drops the owned database" do
      for {label, fun} <- [
            {"throw", fn _args -> throw(:synthetic) end},
            {"exit", fn _args -> exit(:synthetic) end}
          ] do
        sfx = suffix()
        {runner, steps} = stub("sdr_agent_test" <> sfx, %{probe: fun})

        assert {:error, {:probe, {:raised, {_kind, :synthetic}}}} = prove(sfx, runner), label
        assert List.last(steps.()) == :drop, label
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
