defmodule SdrAgent.Agents.ReleaseMigrationTest do
  @moduledoc """
  C2* slice S3 T-S4 migration campaign (S3 plan r2 section 9; Codex
  7a93f224 OQ3/OQ5 and 7a9c7eea sequencing items 6-7): the actual S3
  migration (`priv/repo/migrations/<ts>_c2star_s3_demo_exception_release.exs`)
  on two owned disposable databases, through
  `SdrAgent.WitnessMigration.Harness` (claim, ownership, normal drop and
  uncertainty rules unchanged).

  **DB #1, continuity**, in order: the OLD (pre-S3) baseline build writes
  one withheld and one released ordinary release with their events and
  verifies them (`release_migration/baseline.exs`); the NEW build migrates
  up and verifies; the NEW build migrates down and the OLD build verifies;
  the NEW build migrates up again and verifies (`release_migration/probe.exs`).
  Every captured event and record hash stays byte-identical through every
  state, with legitimate boot appends accounted for; tampers run in
  rolled-back transactions; the T-H6 `DROP CONSTRAINT` runs here only.

  **DB #2, down refusal** (`release_migration/demo.exs`): the NEW build
  migrates up and commits one demo row plus its kernel event; the `down` must
  be refused with `check_violation`; the after-refusal probe proves the full
  rollback: the migration still applied, columns and every CHECK unchanged,
  the row and its record hash unchanged, its kernel event still committing
  that hash, every event captured before `down` byte-identical, nothing
  appended but the probes' own verification and provenance events, and a
  valid chain (validity alone is not preserved history; Codex ed67bbfe M1).

  The whole module is `:external`; the default test helper excludes that
  tag, so an ordinary `mix test` never compiles a child or touches a
  database for it. **It is not approved to run.** Before any execution,
  including the baseline database writes, it needs its own reviewed campaign
  packet (baseline, candidate, build and script hashes; the exact command
  and owned targets; identity negatives; lease and reservation; typed exits;
  retained-log and cleanup rules) pinned at the integrated head, plus a
  fresh reservation and preflight. The baseline checkout is named by
  `SDR_RELEASE_BASELINE_ROOT` and must be clean at `@baseline_tree`.

  **Targets and evidence** (Codex e95a7340 choices 1 and 2). DB #1 and
  DB #2 are predeclared by the driver, never drawn at random:
  `SDR_RELEASE_DB1_SUFFIX` and `SDR_RELEASE_DB2_SUFFIX`, read through
  `Harness.campaign_targets/2`, which refuses an absent, malformed,
  identical or parent target; `setup_all` publishes both exact names
  (`RM-RECEIPT targets.db1=<name>`, `targets.db2=<name>`) before any test,
  and fails the whole module on a refusal. Each target is still claimed by
  exclusive create, never adopted. The harness exports each database's
  evidence itself, before its folder is removed, into
  `SDR_RELEASE_EVIDENCE_ROOT/db1` and `/db2` (`:evidence_dir`).

  The harness options it uses (`versions/2`, `:probe`, `:runners`, `:plan`,
  `checked_runner/5`) have a stubbed, CPU-only contract in
  `SdrAgent.Agents.ReleaseMigrationHarnessTest`; the three release scripts
  share `test/support/release_migration/common.exs`. In the ordinary suite
  this module is compiled, never executed.
  """
  use ExUnit.Case, async: false

  alias SdrAgent.WitnessMigration.Harness

  @moduletag :external
  @moduletag timeout: 3_600_000

  @root Path.expand("../../..", __DIR__)
  @migrations Path.join(@root, "priv/repo/migrations")
  @rm Path.join(@root, "test/support/release_migration")
  @s3_suffix "_c2star_s3_demo_exception_release.exs"
  # The pre-S3 tree: main 91601082, the base of the integrated S3 head
  # (c2star-s3-int-r2 f25b8911). The campaign packet pins the exact commit.
  @baseline_tree "1c6e7de88d3510888c6c1b470e9f4d20917dbee1"
  @deadline 900_000

  @retained %{
    "chain_valid" => "permitted",
    "captured_events_unchanged" => "permitted",
    "captured_record_hashes_unchanged" => "permitted",
    "appends_accounted" => "permitted",
    "tamper_reason_detected" => "refused:record_hash_mismatch"
  }

  @baseline %{
    "baseline_written" => "permitted",
    "chain_valid" => "permitted",
    "withheld_event_record_hash" => "permitted",
    "released_event_record_hash" => "permitted",
    "exception_columns_absent" => "permitted"
  }

  @up Map.merge(@retained, %{
        "exception_columns_present" => "permitted",
        "old_row_exception_member_detected" => "refused:record_hash_mismatch",
        "old_row_json_null_refused" => "refused:check_violation"
      })

  @down Map.merge(@retained, %{
          "exception_columns_absent" => "permitted",
          "predecessor_constraints_restored" => "permitted"
        })

  @demo_up %{
    "demo_row_committed" => "permitted",
    "chain_valid" => "permitted",
    "tamper_basis_sha256_detected" => "refused:record_hash_mismatch",
    "demo_event_record_hash" => "permitted"
  }

  # Codex ed67bbfe M1: a valid chain is not preserved history; the captured
  # events, heads and the demo event must be retained as well.
  @after_refusal %{
    "migration_still_applied" => "permitted",
    "exception_columns_present" => "permitted",
    "constraints_unchanged" => "permitted",
    "demo_row_unchanged" => "permitted",
    "demo_event_record_hash" => "permitted",
    "chain_valid" => "permitted",
    "captured_events_unchanged" => "permitted",
    "appends_accounted" => "permitted"
  }

  @cleanup %{
    "child.drop" => "exit:0",
    "cleanup.drop_attempted" => "true",
    "cleanup.drop_mode" => "normal",
    "cleanup.drop_result" => "ok",
    "cleanup.drop_receipt" => "valid",
    "cleanup.drop_protocol" => "2",
    "cleanup.blocking_before_drop" => "0",
    "cleanup.database_absent_after_drop" => "true",
    "cleanup.temp_folder" => "removed",
    "evidence.claim" => "claimed",
    "evidence.export" => "sealed",
    "outcome" => "ok"
  }

  # The exact DB #1 and DB #2 names are published before any test runs
  # (Codex e95a7340 choice 1); an absent, malformed, identical or parent
  # target fails the whole module here, before any child.
  setup_all do
    targets = targets!()
    publish!("targets", db1: elem(targets.db1, 1), db2: elem(targets.db2, 1))
    :ok
  end

  # Only for the refusal test's never-created partitions and unconfigured
  # target; the campaign databases are predeclared (`targets!/0`).
  defp suffix, do: "_wm" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)

  # The campaign's two predeclared targets, from `SDR_RELEASE_DB1_SUFFIX`
  # and `SDR_RELEASE_DB2_SUFFIX`: no random fallback.
  defp targets! do
    parent = Application.fetch_env!(:sdr_agent, SdrAgent.Repo)[:database]

    case Harness.campaign_targets(System.get_env(), parent) do
      {:ok, targets} -> targets
      {:error, reason} -> flunk("campaign targets refused: #{inspect(reason)}")
    end
  end

  # This database's evidence directory, claimed by the harness itself
  # inside `SDR_RELEASE_EVIDENCE_ROOT` (which the harness validates).
  defp evidence_dir!(name) do
    root = System.get_env("SDR_RELEASE_EVIDENCE_ROOT") || flunk("SDR_RELEASE_EVIDENCE_ROOT unset")
    Path.join(root, name)
  end

  defp mix!, do: System.find_executable("mix") || flunk("mix is not on PATH")

  # The baseline checkout: named explicitly, a different directory, clean,
  # at exactly the pre-S3 tree.
  defp baseline_root! do
    root = System.get_env("SDR_RELEASE_BASELINE_ROOT") || flunk("SDR_RELEASE_BASELINE_ROOT unset")
    assert Path.type(root) == :absolute and Path.expand(root) == root, root
    refute root == @root, "the baseline is another checkout"
    assert git!(root, ["rev-parse", "HEAD^{tree}"]) == @baseline_tree, "baseline tree"
    assert git!(root, ["status", "--porcelain", "--untracked-files=all"]) == "", "baseline clean"
    root
  end

  defp git!(root, args) do
    {out, 0} = System.cmd("git", ["-C", root | args], env: SdrAgent.ChildEnv.cmd([]))
    String.trim(out)
  end

  # The r7b drain (protocol v2; Codex db034af6 Q6): only exact autovacuum
  # workers may remain at the drop, and they are counted, never zeroed.
  defp assert_drained!(facts) do
    assert facts["cleanup.backends_before_drop"] == facts["cleanup.excluded_before_drop"]
    assert facts["cleanup.backends_before_drop"] =~ ~r/\A(0|[1-9][0-9]{0,5})\z/
    assert facts["cleanup.drain_attempts"] =~ ~r/\A([1-9]|10)\z/
  end

  defp publish!(prefix, receipts),
    do:
      Enum.each(receipts, fn {key, value} ->
        :ok = IO.write("RM-RECEIPT #{prefix}.#{key}=#{value}\n")
      end)

  test "a real release child refuses a wrong target before any startup, connection or effect" do
    partition = suffix()
    runner = Harness.checked_runner(mix!(), partition, @root, 300_000)
    unconfigured = "sdr_agent_test" <> suffix()
    out = Path.join(System.tmp_dir!(), "sdr-rm-refusal" <> partition <> ".json")
    fixtures = out <> ".fixtures"

    for script <- ~w(baseline.exs probe.exs demo.exs),
        {target, reason} <- [
          {unconfigured, "target_not_configured"},
          {"sdr_agent_dev", "invalid_target"}
        ] do
      label = "#{script} #{target}"
      args = ["run", "--no-start", "--no-compile", "--no-deps-check", Path.join(@rm, script)]
      result = runner.(:refusal, args ++ [target, "predecessor", fixtures, out])
      status = Harness.target_refused()
      assert {:exit, ^status, output} = result, label
      assert output =~ "REFUSED #{reason}", "#{label}: #{output}"
      refute output =~ "VALIDATED", label
      refute File.exists?(out), label
      refute File.exists?(fixtures), label
    end
  end

  test "DB #1: OLD writes and verifies, NEW up, OLD verifies down, NEW up again" do
    assert {:ok, versions} = Harness.versions(@migrations, migration_suffix: @s3_suffix)
    baseline = baseline_root!()
    {sfx, database} = targets!().db1
    new = Harness.checked_runner(mix!(), sfx, @root, @deadline)
    old = Harness.checked_runner(mix!(), sfx, baseline, @deadline, toolchain: :root)

    {outcome, receipts} =
      Harness.prove_with_receipts(
        suffix: sfx,
        tmp_root: System.tmp_dir!(),
        evidence_dir: evidence_dir!("db1"),
        versions: versions,
        runner: new,
        runners: %{
          {:migrate, "predecessor"} => old,
          {:probe, "predecessor"} => old,
          {:probe, "down"} => old
        },
        probe: %{
          "predecessor" => Path.join(@rm, "baseline.exs"),
          "up" => Path.join(@rm, "probe.exs"),
          "down" => Path.join(@rm, "probe.exs"),
          "up_again" => Path.join(@rm, "probe.exs")
        }
      )

    publish!("db1", receipts)
    assert {:ok, states} = outcome

    assert states == %{
             "predecessor" => @baseline,
             "up" => @up,
             "down" => @down,
             "up_again" => @up
           }

    facts = Map.new(receipts)
    assert length(receipts) == map_size(facts), "one fact per key"
    assert facts["target_database"] == database
    assert facts["migration_new"] == Integer.to_string(versions.new)
    assert facts["migration_predecessor"] == Integer.to_string(versions.predecessor)

    for key <- ~w(migrate.predecessor probe.predecessor probe.down),
        do: assert(facts["runner." <> key] == "override", key)

    assert Map.take(facts, Map.keys(@cleanup)) == @cleanup
    assert_drained!(facts)
  end

  test "DB #2: a demo row makes down refuse with check_violation, fully rolled back" do
    assert {:ok, versions} = Harness.versions(@migrations, migration_suffix: @s3_suffix)
    {sfx, database} = targets!().db2

    {outcome, receipts} =
      Harness.prove_with_receipts(
        suffix: sfx,
        tmp_root: System.tmp_dir!(),
        evidence_dir: evidence_dir!("db2"),
        versions: versions,
        runner: Harness.checked_runner(mix!(), sfx, @root, @deadline),
        plan: :down_refusal,
        probe: Path.join(@rm, "demo.exs")
      )

    publish!("db2", receipts)
    assert {:ok, states} = outcome
    assert states == %{"up" => @demo_up, "after_refusal" => @after_refusal}

    facts = Map.new(receipts)
    assert facts["target_database"] == database
    assert facts["plan"] == "down_refusal"
    assert facts["migrate.down.expected"] == "refusal"
    assert facts["migrate.down.refusal"] == "check_violation"
    assert facts["child.migrate.down"] =~ ~r/\Aexit:[1-9][0-9]*\z/
    refute facts["child.migrate.down"] == "exit:#{Harness.target_refused()}"
    assert Map.take(facts, Map.keys(@cleanup)) == @cleanup
    assert_drained!(facts)
  end
end
