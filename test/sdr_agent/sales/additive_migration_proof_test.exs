defmodule SdrAgent.Sales.AdditiveMigrationProofTest do
  @moduledoc """
  C3-02 G2 (Codex carry-forward on T-E10..T-E12: the migration's pre-check
  dispatch must be real; a source scan is not proof). The real additive
  migration `20261020053346_c3_02_admission_additive`, run by
  `Ecto.Migrator` on an owned database migrated to just before it:

    * with a canonical domain collision and a covered contact with an open
      lead, it aborts with `AdmissionPrechecks.Aborted` (the pre-checks run
      first), counts only;
    * with only the covered contact, it aborts with `CutoverFence.Aborted`,
      counts only;
    * after each abort no DDL of the migration is present (not even
      `sdr_canonical_domain(text)`, created before the pre-checks), its
      version is not recorded and the planned rows are unchanged;
    * with neither, it applies, and the same facts all read true (the
      facts can see the DDL).

  `SdrAgent.MigrationProof.Harness` owns the lifecycle: an exclusively
  created folder and database (`sdr_agent_test_mp<hex>`, validated before it
  is created), separate OS processes with a scrubbed environment and a
  deadline, and cleanup of only what it claimed, which fails the test if it
  fails. The lifecycle tests use a stubbed runner and touch no database.
  """
  use ExUnit.Case, async: false

  alias SdrAgent.MigrationProof.Harness

  @moduletag :migration_proof
  @moduletag timeout: 900_000

  @root Path.expand("../../..", __DIR__)
  @facts ~w(version_applied canonical_function lead_admissions_table canonical_index
            one_open_per_account_index leads_admission_id users_id_tenant_key referred_status)

  defp suffix, do: "_mp" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)

  defp tmp_root do
    root = Path.join(System.tmp_dir!(), "sdr-mp-lifecycle-" <> suffix())
    :ok = File.mkdir(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  # A stub runner: records every step and answers from `answers` (default
  # `{:ok, ""}`); a successful phase writes the JSON a real child would.
  defp stub(answers) do
    {:ok, log} = Agent.start_link(fn -> [] end)

    runner = fn step, args ->
      Agent.update(log, &[step | &1])
      outcome = Map.get(answers, step, {:ok, ""})

      if step in Harness.phases() and match?({:ok, _}, outcome),
        do: File.write!(Enum.at(args, -1), ~s({"phase":"#{step}"}))

      outcome
    end

    {runner, fn -> Enum.reverse(Agent.get(log, & &1)) end}
  end

  @all_steps [:claim, :before, :prechecks, :fence, :clean, :drop]

  describe "lifecycle (stubbed children, no database)" do
    test "a pre-existing folder is refused before any child runs" do
      root = tmp_root()
      sfx = suffix()
      existing = Path.join(root, "sdr-migration-proof" <> sfx)
      File.mkdir!(existing)
      File.write!(Path.join(existing, "keep"), "x")
      {runner, steps} = stub(%{})

      assert {:error, {:tmp_not_claimed, ^existing, :eexist}} =
               Harness.prove(suffix: sfx, tmp_root: root, runner: runner)

      assert steps.() == []
      assert File.ls!(existing) == ["keep"]
    end

    test "an invalid target name is refused before anything is claimed" do
      root = tmp_root()
      {runner, steps} = stub(%{})

      assert {:error, {:invalid_target, "sdr_agent_test_dev"}} =
               Harness.prove(suffix: "_dev", tmp_root: root, runner: runner)

      assert steps.() == []
      assert File.ls!(root) == []
    end

    test "a pre-existing database is refused: never migrated or dropped" do
      root = tmp_root()
      {runner, steps} = stub(%{claim: {:exit, 3, "exists"}})

      assert {:error, {:database_not_claimed, "exists"}} =
               Harness.prove(suffix: suffix(), tmp_root: root, runner: runner)

      assert steps.() == [:claim]
      assert File.ls!(root) == []
    end

    test "every phase runs in order, then the claimed database is dropped" do
      root = tmp_root()
      {runner, steps} = stub(%{})

      assert {:ok, %{results: results, outputs: outputs}} =
               Harness.prove(suffix: suffix(), tmp_root: root, runner: runner)

      assert steps.() == @all_steps
      assert Enum.sort(Map.keys(results)) == Enum.sort(Harness.phases())
      assert Enum.sort(Map.keys(outputs)) == Enum.sort(Harness.phases())
      assert File.ls!(root) == []
    end

    test "a failed phase stops the phases and still drops what was claimed" do
      root = tmp_root()
      {runner, steps} = stub(%{prechecks: {:exit, 1, "failed"}})

      assert {:error, {:prechecks, {:exit, 1, "failed"}}} =
               Harness.prove(suffix: suffix(), tmp_root: root, runner: runner)

      assert steps.() == [:claim, :before, :prechecks, :drop]
      assert File.ls!(root) == []
    end

    test "a failed drop fails the proof" do
      root = tmp_root()
      {runner, steps} = stub(%{drop: {:exit, 1, "drop failed"}})

      assert {:error, {:cleanup_failed, {:drop, {:exit, 1, "drop failed"}}, {:ok, _}}} =
               Harness.prove(suffix: suffix(), tmp_root: root, runner: runner)

      assert steps.() == @all_steps
    end

    test "an unconfirmed timeout leaves everything in place and fails" do
      root = tmp_root()
      sfx = suffix()
      {runner, steps} = stub(%{fence: {:timeout, :unconfirmed, ""}})

      assert {:error, {:cleanup_skipped_unconfirmed_child, _, %{database: database}}} =
               Harness.prove(suffix: sfx, tmp_root: root, runner: runner)

      assert database == "sdr_agent_test" <> sfx
      assert steps.() == [:claim, :before, :prechecks, :fence]
      assert File.ls!(root) == ["sdr-migration-proof" <> sfx]
    end

    test "a confirmed timeout cleans up what was claimed and fails" do
      root = tmp_root()
      {runner, steps} = stub(%{clean: {:timeout, :confirmed, ""}})

      assert {:error, {:step_timeout, {:timeout, :confirmed, ""}}} =
               Harness.prove(suffix: suffix(), tmp_root: root, runner: runner)

      assert steps.() == @all_steps
      assert File.ls!(root) == []
    end
  end

  test "the additive migration runs the pre-checks, then the fence, before any DDL" do
    sfx = suffix()
    mix = System.find_executable("mix") || flunk("mix is not on PATH")

    outcome =
      Harness.prove(
        suffix: sfx,
        tmp_root: System.tmp_dir!(),
        runner: Harness.port_runner(mix, sfx, @root, 300_000)
      )

    assert {:ok, %{plan: plan, results: results, outputs: outputs}} = outcome

    before = results[:before]
    assert facts(before) == Map.new(@facts, &{&1, false}), inspect(before)

    prechecks = results[:prechecks]

    assert_aborted!(prechecks, "SdrAgent.Sales.AdmissionPrechecks.Aborted", %{
      "canonical_collisions" => 2,
      "double_open_leads" => 0,
      "legacy_identity" => 0
    })

    fence = results[:fence]

    assert_aborted!(fence, "SdrAgent.Sales.CutoverFence.Aborted", %{
      "a" => 1,
      "b1" => 0,
      "b2" => 0,
      "b3" => 0,
      "b4" => 0
    })

    # The fence phase deleted one account of the collision, nothing else.
    assert fence["rows_before"]["collision_plain_id"] == "absent"
    assert prechecks["rows_after"]["collision_plain_id"] != "absent"

    for key <- ~w(collision_www_id fence_account_id contact_id lead_id suppression_id) do
      assert fence["rows_before"][key] == prechecks["rows_after"][key], key
    end

    clean = results[:clean]
    assert clean["outcome"] == %{"result" => "applied", "versions" => [Harness.version()]}
    assert facts(clean) == Map.new(@facts, &{&1, true}), inspect(clean)

    # Counts only: no planned value in any abort or in any child's output.
    rendered =
      [prechecks["outcome"], fence["outcome"]]
      |> Enum.map(&JSON.encode!/1)
      |> Enum.concat(Map.values(outputs))

    for text <- rendered, token <- [plan["token_collision"], plan["token_fence"]] do
      refute text =~ token, "C3-02: an abort or a child output carries a planned value"
    end
  end

  defp facts(result), do: Map.take(result["facts"], @facts)

  defp assert_aborted!(result, module, counts) do
    outcome = result["outcome"]
    assert outcome["result"] == "aborted", inspect(result)
    assert outcome["module"] == module, "C3-02: #{outcome["module"]}: #{outcome["message"]}"
    assert outcome["counts"] == counts

    for {category, count} <- counts, count > 0 do
      assert outcome["message"] =~ "#{category}=#{count}"
    end

    assert facts(result) == Map.new(@facts, &{&1, false}),
           "C3-02: an aborted migration leaves no DDL: #{inspect(result["facts"])}"

    assert result["rows_after"] == result["rows_before"],
           "C3-02: an aborted migration changes no row"

    planned = Map.delete(result["rows_before"], "collision_plain_id")
    refute "absent" in Map.values(planned), inspect(result["rows_before"])
  end
end
