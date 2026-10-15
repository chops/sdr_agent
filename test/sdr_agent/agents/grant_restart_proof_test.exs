defmodule SdrAgent.Agents.GrantRestartProofTest do
  @moduledoc """
  C9-04 (#44) "survives restart": grant terms, allocations, an owner's
  release, revisions and charged attempts are all database state, read back
  by a fresh application boot. Characterization of merged behavior (no
  production change), not a RED test.

  `SdrAgent.RestartProof.Harness` owns the lifecycle:
    * an exclusively created temporary folder and database
      (`sdr_agent_test_rp<hex>`, validated before it is created);
    * separate OS processes, each with a scrubbed environment and a
      deadline;
    * cleanup of only what it claimed, which fails the test if it fails.

  The lifecycle tests below use a stubbed runner and never touch a
  database. The proof itself runs the real children.
  """
  use ExUnit.Case, async: false

  alias SdrAgent.ChildEnv
  alias SdrAgent.RestartProof.Harness

  @moduletag :restart_proof
  @moduletag timeout: 900_000

  @root Path.expand("../../..", __DIR__)
  @checks ~w(grant_revision_persisted total_attempts_persisted allocations_persisted
    workshop_release_persisted setup_charges_still_counted
    setup_charges_bound_to_their_allocations full_b5_refused_exactly next_b1_charged_to_b1
    full_b1_refused_exactly no_borrowing_or_extra_debit grant_total_counted)

  defp suffix, do: "_rp" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)

  defp tmp_root do
    root = Path.join(System.tmp_dir!(), "sdr-rp-lifecycle-" <> suffix())
    :ok = File.mkdir(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  # A stub runner: records every step it is asked to run and answers from
  # `answers` (default `{:ok, ""}`); `:setup` and `:verify` also write the
  # JSON files a real child would.
  defp stub(answers) do
    {:ok, log} = Agent.start_link(fn -> [] end)

    runner = fn step, args ->
      Agent.update(log, &[step | &1])
      outcome = Map.get(answers, step, {:ok, ""})

      case {step, outcome} do
        {:setup, {:ok, _}} -> File.write!(Enum.at(args, -1), JSON.encode!(answers.setup_json))
        {:verify, {:ok, _}} -> File.write!(Enum.at(args, -1), ~s({"ok":true,"checks":{}}))
        _ -> :ok
      end

      outcome
    end

    {runner, fn -> Enum.reverse(Agent.get(log, & &1)) end}
  end

  defp setup_json(suffix), do: %{"database" => "sdr_agent_test" <> suffix}

  describe "lifecycle (stubbed children, no database)" do
    test "a pre-existing folder is refused before any child runs" do
      root = tmp_root()
      sfx = suffix()
      existing = Path.join(root, "sdr-restart-proof" <> sfx)
      File.mkdir!(existing)
      File.write!(Path.join(existing, "keep"), "x")
      {runner, steps} = stub(%{setup_json: setup_json(sfx)})

      assert {:error, {:tmp_not_claimed, ^existing, :eexist}} =
               Harness.prove(suffix: sfx, tmp_root: root, runner: runner)

      assert steps.() == []
      assert File.read!(Path.join(existing, "keep")) == "x"
    end

    test "a pre-existing database is refused: never migrated or dropped" do
      root = tmp_root()
      sfx = suffix()
      {runner, steps} = stub(%{claim: {:exit, 3, "exists"}, setup_json: setup_json(sfx)})

      assert {:error, {:database_not_claimed, "exists"}} =
               Harness.prove(suffix: sfx, tmp_root: root, runner: runner)

      assert steps.() == [:claim]
      assert File.ls!(root) == []
    end

    test "an invalid target name is refused before anything is claimed" do
      root = tmp_root()
      {runner, steps} = stub(%{setup_json: %{}})

      assert {:error, {:invalid_target, "sdr_agent_test_dev"}} =
               Harness.prove(suffix: "_dev", tmp_root: root, runner: runner)

      assert steps.() == []
      assert File.ls!(root) == []
    end

    test "a failed drop fails the proof" do
      root = tmp_root()
      sfx = suffix()

      {runner, steps} =
        stub(%{drop: {:exit, 1, "drop failed"}, setup_json: setup_json(sfx)})

      assert {:error, {:cleanup_failed, {:drop, {:exit, 1, "drop failed"}}, {:ok, _}}} =
               Harness.prove(suffix: sfx, tmp_root: root, runner: runner)

      assert steps.() == [:claim, :migrate, :setup, :verify, :drop]
    end

    test "an unconfirmed timeout leaves everything in place and fails" do
      root = tmp_root()
      sfx = suffix()

      {runner, steps} =
        stub(%{setup: {:timeout, :unconfirmed, ""}, setup_json: setup_json(sfx)})

      assert {:error, {:cleanup_skipped_unconfirmed_child, _, %{database: database}}} =
               Harness.prove(suffix: sfx, tmp_root: root, runner: runner)

      assert database == "sdr_agent_test" <> sfx
      assert steps.() == [:claim, :migrate, :setup]
      assert File.ls!(root) == ["sdr-restart-proof" <> sfx]
    end

    test "a confirmed timeout cleans up what was claimed and fails" do
      root = tmp_root()
      sfx = suffix()

      {runner, steps} =
        stub(%{verify: {:timeout, :confirmed, ""}, setup_json: setup_json(sfx)})

      assert {:error, {:step_timeout, {:timeout, :confirmed, ""}}} =
               Harness.prove(suffix: sfx, tmp_root: root, runner: runner)

      assert steps.() == [:claim, :migrate, :setup, :verify, :drop]
      assert File.ls!(root) == []
    end
  end

  describe "the bounded child" do
    test "a child past its deadline is killed and its exit confirmed" do
      sleep = System.find_executable("sleep") || flunk("sleep is not on PATH")

      assert {:timeout, :confirmed, _} =
               Harness.spawn_bounded(sleep, ["30"], @root, ChildEnv.port([]), 200, 5_000)
    end
  end

  test "a fresh boot reads persisted grant state and keeps counting charged attempts" do
    sfx = suffix()
    mix = System.find_executable("mix") || flunk("mix is not on PATH")

    outcome =
      Harness.prove(
        suffix: sfx,
        tmp_root: System.tmp_dir!(),
        runner: Harness.port_runner(mix, sfx, @root, 300_000)
      )

    assert {:ok, %{setup: setup, result: result}} = outcome
    assert setup["database"] == "sdr_agent_test" <> sfx
    assert length(setup["allocations"]) == 3
    assert result["checks"] |> Map.keys() |> Enum.sort() == Enum.sort(@checks)
    assert Enum.all?(result["checks"], fn {_, value} -> value === true end), inspect(result)
    assert result["ok"] === true
  end
end
