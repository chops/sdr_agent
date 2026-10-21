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

  `SdrAgent.WitnessMigration.Harness` owns the lifecycle (target
  validation, ownership by creation, child VMs, cleanup of only what it
  claimed). The lifecycle tests use a stubbed runner and touch no
  database.

  RED: until GREEN adds the migration, the campaign test fails at its
  presence check (no `*_v4_mismatch_lineage.exs`), before anything is
  claimed. That is a structural failure only: it is not up/down/up
  evidence.
  """
  use ExUnit.Case, async: false

  alias SdrAgent.RestartProof.Harness, as: Bounded
  alias SdrAgent.WitnessMigration.Harness

  @moduletag :external
  @moduletag timeout: 1_800_000

  @root Path.expand("../../..", __DIR__)
  @migrations Path.join(@root, "priv/repo/migrations")
  @versions %{new: 20_261_021_000_000, predecessor: 20_261_016_052_435}
  @states ~w(predecessor up down up_again)

  defp suffix, do: "_wm" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)

  defp tmp_root do
    root = Path.join(System.tmp_dir!(), "sdr-wm-lifecycle" <> suffix())
    :ok = File.mkdir(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

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

  # A stub runner: records every step and answers from `answers` (default
  # `{:ok, ""}`); a successful `:probe` writes the JSON a real child would.
  defp stub(database, answers \\ %{}) do
    {:ok, log} = Agent.start_link(fn -> [] end)

    runner = fn step, args ->
      Agent.update(log, &[step | &1])
      outcome = Map.get(answers, step, {:ok, ""})

      case {step, outcome} do
        {:probe, {:ok, _}} ->
          File.write!(
            List.last(args),
            JSON.encode!(%{"database" => database, "checks" => %{"stub" => "ok"}})
          )

        _other ->
          :ok
      end

      outcome
    end

    {runner, fn -> Enum.reverse(Agent.get(log, & &1)) end}
  end

  describe "versions (no database)" do
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
  end

  describe "lifecycle (stubbed children, no database)" do
    test "the sequence: claim, then migrate and probe at each state, then drop" do
      sfx = suffix()
      {runner, steps} = stub("sdr_agent_test" <> sfx)

      assert {:ok, states} =
               Harness.prove(
                 suffix: sfx,
                 tmp_root: tmp_root(),
                 versions: @versions,
                 runner: runner
               )

      assert Enum.sort(Map.keys(states)) == Enum.sort(@states)

      assert steps.() ==
               [:claim] ++ List.flatten(List.duplicate([:migrate, :probe], 4)) ++ [:drop]
    end

    test "an invalid target name is refused before anything is claimed" do
      {runner, steps} = stub("sdr_agent_test")

      assert {:error, {:invalid_target, "sdr_agent_test"}} =
               Harness.prove(
                 suffix: "",
                 tmp_root: tmp_root(),
                 versions: @versions,
                 runner: runner
               )

      assert {:error, {:invalid_target, _}} =
               Harness.prove(
                 suffix: "_rp0123456789",
                 tmp_root: tmp_root(),
                 versions: @versions,
                 runner: runner
               )

      assert steps.() == []
    end

    test "a pre-existing database is refused: never migrated, probed or dropped" do
      sfx = suffix()
      {runner, steps} = stub("sdr_agent_test" <> sfx, %{claim: {:exit, 3, "exists"}})

      assert {:error, {:database_not_claimed, "exists"}} =
               Harness.prove(
                 suffix: sfx,
                 tmp_root: tmp_root(),
                 versions: @versions,
                 runner: runner
               )

      assert steps.() == [:claim]
    end

    test "a failed migration still drops the owned database, and fails" do
      sfx = suffix()
      {runner, steps} = stub("sdr_agent_test" <> sfx, %{migrate: {:exit, 1, "boom"}})

      assert {:error, {:migrate, {:exit, 1, "boom"}}} =
               Harness.prove(
                 suffix: sfx,
                 tmp_root: tmp_root(),
                 versions: @versions,
                 runner: runner
               )

      assert steps.() == [:claim, :migrate, :drop]
    end

    test "a failed drop fails the campaign" do
      sfx = suffix()
      {runner, _steps} = stub("sdr_agent_test" <> sfx, %{drop: {:exit, 1, "busy"}})

      assert {:error, {:cleanup_failed, {:drop, {:exit, 1, "busy"}}, {:ok, _}}} =
               Harness.prove(
                 suffix: sfx,
                 tmp_root: tmp_root(),
                 versions: @versions,
                 runner: runner
               )
    end

    test "an unconfirmed timeout leaves everything in place and fails" do
      sfx = suffix()
      root = tmp_root()
      {runner, steps} = stub("sdr_agent_test" <> sfx, %{probe: {:timeout, :unconfirmed, ""}})

      assert {:error, {:cleanup_skipped_unconfirmed_child, _, _}} =
               Harness.prove(suffix: sfx, tmp_root: root, versions: @versions, runner: runner)

      refute :drop in steps.()
      assert File.dir?(Path.join(root, "sdr-witness-migration" <> sfx))
    end
  end

  test "the v4 lineage migration: up, down, up on an owned disposable database" do
    assert {:ok, versions} = Harness.versions(@migrations),
           "structural RED: the *_v4_mismatch_lineage.exs migration does not exist yet"

    sfx = suffix()
    mix = System.find_executable("mix") || flunk("mix is not on PATH")

    outcome =
      Harness.prove(
        suffix: sfx,
        tmp_root: System.tmp_dir!(),
        versions: versions,
        runner: Bounded.port_runner(mix, sfx, @root, 600_000)
      )

    assert {:ok, states} = outcome
    assert Enum.sort(Map.keys(states)) == Enum.sort(@states)
    assert states["predecessor"] == expected(false), "the predecessor is the old C3 exactly"
    assert states["up"] == expected(true), "after up: the v4 restriction is active"
    assert states["down"] == expected(false), "after down: the old C3 exactly, v4 permitted"
    assert states["up_again"] == expected(true), "after the second up: refused again"
  end
end
