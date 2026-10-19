defmodule SdrAgent.CalibrationConsole.CalibrateTest do
  @moduledoc """
  R0-07 slice E, sub-slice d3c part 3: the `calibrate` orchestration
  (packet 8.14.1, 8.14.4, 8.14.8 and 8.14.9; entity PASS at 125102e and
  623e7db). Rows driven by existing seams only; the rows that need the
  ordering hook (4b, 5, 7, 8) follow its exact-head recheck.

  Hermetic: no real model call. The private server runs a stand-in command
  (a shell CLI, or the fake CLI playing shim and proxy store) under a
  synthetic pinned executable. Every assertion reads the record on disk,
  the committed rows and the evidence directory, never only the command's
  return value.

  **The clock** (packet 8.14.10): every test runs frozen at 2026-10-15
  12:00 UTC, inside G-R0's code-owned window (it ends 2026-10-19 05:59
  UTC), and each private server follows the test's clock (`clock_from:`).
  So the suite does not depend on today's date, and the window's real
  expiry rule is exercised at its boundary.
  """
  use SdrAgent.AuditCase, async: false

  defmodule ConsoleProbe do
    @moduledoc "The real ProcessProbe, except for a group answer set per test."
    use Agent

    alias SdrAgent.CalibrationConsole.ProcessProbe

    def start_link(_), do: Agent.start_link(fn -> :real end, name: __MODULE__)

    # `{:plus, pid}`: the real group plus a phantom member that never exits.
    def put(group), do: Agent.update(__MODULE__, fn _ -> group end)

    def self_pid, do: ProcessProbe.self_pid()
    def start_identity(pid), do: ProcessProbe.start_identity(pid)

    def group_members(pgid) do
      case Agent.get(__MODULE__, & &1) do
        :real ->
          ProcessProbe.group_members(pgid)

        # One failed group read, then the real probe again.
        :error_once ->
          put(:real)
          {:error, :ps_failed}

        {:plus, extra} ->
          with {:ok, members} <- ProcessProbe.group_members(pgid),
               do: {:ok, members ++ [extra]}
      end
    end
  end

  defmodule LaunchProbe do
    @moduledoc """
    The d3a launch-receipt probe (`:calibration_launch_probe`): the real
    ProcessProbe (`:real`), a root that reads as already gone
    (`:identity_absent`: an unverified receipt), or the real probe that
    then leaves a phantom member in the console probe's group
    (`:then_phantom`: quiescence is never established after the call).
    """
    use Agent

    alias SdrAgent.CalibrationConsole.ProcessProbe

    def start_link(_), do: Agent.start_link(fn -> :real end, name: __MODULE__)
    def put(mode), do: Agent.update(__MODULE__, fn _ -> mode end)

    def start_identity(pid) do
      case Agent.get(__MODULE__, & &1) do
        :identity_absent ->
          :absent

        :then_phantom ->
          ConsoleProbe.put({:plus, 999_999})
          ProcessProbe.start_identity(pid)

        :then_error_once ->
          ConsoleProbe.put(:error_once)
          ProcessProbe.start_identity(pid)

        :real ->
          ProcessProbe.start_identity(pid)
      end
    end

    def group_members(pgid), do: ProcessProbe.group_members(pgid)
  end

  require Ash.Query

  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.Agents.AgentDefinition
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.Checks.CalibrationAdmission
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.Agents.Witness
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.CalibrationConsole
  alias SdrAgent.CalibrationConsole.Authority
  alias SdrAgent.CalibrationConsole.Calibrate
  alias SdrAgent.CalibrationConsole.Evidence
  alias SdrAgent.CalibrationConsole.LaunchRecord
  alias SdrAgent.CalibrationConsole.ProcessProbe
  alias SdrAgent.CalibrationConsole.Prompt
  alias SdrAgent.Clock
  alias SdrAgent.Operations.Failure
  alias SdrAgent.Test.GatedCommand
  alias SdrAgent.Test.PinnedCLI
  alias SdrAgent.Test.WitnessRoot

  @moduletag :tmp_dir
  @profile :claude_cli_opus
  @typed "CALIBRATE claude_cli_opus"
  @v3 "claude-message-json/3+prompt-builder/1"
  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)
  @now ~U[2026-10-15 12:00:00.000000Z]
  @expiry ~U[2026-10-19 05:59:00.000000Z]

  setup %{tmp_dir: tmp} = tags do
    Clock.freeze(@now)
    on_exit(&Clock.unfreeze/0)
    start_supervised!(ConsoleProbe)
    start_supervised!(LaunchProbe)
    start_supervised!(Authority)
    %{root: store} = AdmissionFixtures.admit_tuples!()
    tenant = bootstrap!()
    grant = if Map.get(tags, :grant, true), do: g_r0!(tenant)

    previous = Application.get_env(:sdr_agent, :calibration_launch_probe)
    Application.put_env(:sdr_agent, :calibration_launch_probe, LaunchProbe)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:sdr_agent, :calibration_launch_probe, previous),
        else: Application.delete_env(:sdr_agent, :calibration_launch_probe)
    end)

    # The synthetic pin: a harmless executable under a stand-in store.
    pins = Path.join(tmp, "pins")
    bin = Path.join([pins, String.duplicate("a", 32) <> "-app-claude-cli-2.1.294", "bin"])
    File.mkdir_p!(bin)
    executable = Path.join(bin, "claude-code")
    File.write!(executable, "#!/bin/sh\nexit 1\n")
    File.chmod!(executable, 0o555)
    PinnedCLI.inject_identity!(executable, store: pins)

    ran = Path.join(tmp, "ran")
    root = private_dir!(tmp, "launch")
    evidence = private_dir!(tmp, "evidence")

    ctx = %{
      tenant: tenant,
      store: store,
      executable: executable,
      ran: ran,
      root: root,
      evidence: evidence,
      tmp: tmp,
      grant: grant
    }

    # After every fixture: a missing command fails as an assertion.
    assert Code.ensure_loaded?(Calibrate), "SdrAgent.CalibrationConsole.Calibrate is not defined"
    assert function_exported?(Calibrate, :run, 2), "Calibrate.run/2 is not defined"

    Map.put(ctx, :cli, shell_cli!(ctx, 1))
  end

  ## R0-07f: the console-applied root and budget (contract PASS 0ee216e)

  describe "R0-07f: the console-applied witness root and result wait" do
    # The real calibration path, run without `AdmissionFixtures.admitting/1`:
    # the shipped allowlist is empty throughout, the root and the budget
    # come from `current/1 → plan/1 → apply_capture!/1` with
    # `SDR_WITNESS_STORE_ROOT`, and the CLI hides its capture before it
    # answers; this test publishes it about 1.5 s later.
    test "a calibration observes a capture published after 1 s, with no shipped methods", ctx do
      witness = Application.get_env(:sdr_agent, Witness, [])
      gate = Application.get_env(:sdr_agent, ResultGate)
      variable = System.get_env("SDR_WITNESS_STORE_ROOT")

      Application.put_env(
        :sdr_agent,
        Witness,
        Keyword.merge(witness, reconciled_methods: [], store_root: nil)
      )

      store = WitnessRoot.mkdir!("r007f-calibrate")

      on_exit(fn ->
        File.rm_rf!(store)

        if gate,
          do: Application.put_env(:sdr_agent, ResultGate, gate),
          else: Application.delete_env(:sdr_agent, ResultGate)

        if variable,
          do: System.put_env("SDR_WITNESS_STORE_ROOT", variable),
          else: System.delete_env("SDR_WITNESS_STORE_ROOT")
      end)

      System.put_env("SDR_WITNESS_STORE_ROOT", store)

      {:ok, plan} =
        :test
        |> CalibrationConsole.current()
        |> Map.put(:secrets, %{
          secret_key_base: Base.encode64(:binary.copy(<<1>>, 64)),
          token_signing_secret: Base.encode64(:binary.copy(<<2>>, 64))
        })
        |> CalibrationConsole.plan()

      assert function_exported?(CalibrationConsole, :apply_capture!, 1),
             "R0-07f: CalibrationConsole.apply_capture!/1 is not implemented"

      :ok = CalibrationConsole.apply_capture!(plan)
      assert Witness.store_root() == store
      assert Witness.reconciled_methods() == []

      hide =
        ~s(mv #{sh(store)}/witnesses/"$SDR_MODEL_INVOCATION_ID" ) <>
          ~s(#{sh(store)}/held-"$SDR_MODEL_INVOCATION_ID")

      cli = witness_cli!(%{ctx | store: store}, "cli_shape_v3", hide)
      {_runs, invocations} = counts(ctx)
      opts = Keyword.merge(base_opts(ctx), server: server(ctx, cli))
      calibration = Task.async(fn -> Calibrate.run(@profile, opts) end)

      # The calibration task is joined, or shut down, before cleanup.
      {id, result} =
        try do
          held = await_held!(store, 60_000)
          Process.sleep(1_500)
          id = held |> Path.basename() |> String.replace_prefix("held-", "")
          File.rename!(held, Path.join([store, "witnesses", id]))
          {id, Task.await(calibration, 60_000)}
        after
          Task.shutdown(calibration, :brutal_kill)
        end

      assert {:ok, summary} = result
      assert summary.outcome == "match"
      assert summary.invocation_id == id
      assert elem(counts(ctx), 1) == invocations + 1, "a second invocation was made"
      assert Witness.reconciled_methods() == []
    end
  end

  defp await_held!(store, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      case Path.wildcard(Path.join(store, "held-*")) do
        [held] ->
          held

        [] ->
          System.monotonic_time(:millisecond) < deadline || flunk("the CLI never hid its capture")
          Process.sleep(20)
          nil
      end
    end)
    |> Enum.find(& &1)
  end

  ## Row 1: the claim

  describe "row 1: the claim" do
    test "a live claim refuses; nothing is created and the held record is untouched", ctx do
      {:ok, held} = LaunchRecord.claim(ctx.root, probe: ProcessProbe)
      before = counts(ctx)

      assert {:stop, :calibration_in_progress, summary} = run(ctx)
      assert summary.record == :none
      assert LaunchRecord.read(ctx.root) == {:ok, held}
      assert counts(ctx) == before
      refute File.exists?(ctx.ran), "the CLI ran"
      refute_received {:confirm, _prompt}
    end

    test "an unsafe root refuses before anything is created", ctx do
      File.chmod!(ctx.root, 0o755)
      before = counts(ctx)

      assert {:stop, :launch_record_unsafe, %{record: :none}} = run(ctx)
      assert counts(ctx) == before
      refute File.exists?(Path.join(ctx.root, "run.lock"))
    end
  end

  ## Row 2: preflight refusals (aborted, then released)

  describe "row 2: preflight" do
    for {name, line} <- [
          declined: "no",
          mistyped: "calibrate claude_cli_opus",
          other_profile: "CALIBRATE claude_cli_sonnet",
          blank: ""
        ] do
      test "a #{name} confirmation aborts and releases; no run, no reservation", ctx do
        before = counts(ctx)

        assert {:stop, :calibration_not_confirmed, summary} =
                 run(ctx, confirm: confirm(unquote(line)))

        assert summary.record == :released
        assert_received {:confirm, prompt}
        assert prompt =~ @typed
        assert released?(ctx)
        assert counts(ctx) == before
        refute File.exists?(ctx.ran), "the CLI ran"
      end
    end

    @tag grant: false
    test "no G-R0 aborts and releases", ctx do
      before = counts(ctx)

      assert {:stop, :calibration_grant_unavailable, %{record: :released}} = run(ctx)
      assert released?(ctx)
      assert counts(ctx) == before
    end

    test "an untrusted witness store aborts and releases", ctx do
      AdmissionFixtures.admit_tuples!(root: Path.join(ctx.tmp, "no-store"))
      before = counts(ctx)

      assert {:stop, :witness_store_untrusted, %{record: :released}} = run(ctx)
      assert released?(ctx)
      assert counts(ctx) == before
    end

    test "a pin that fails its check aborts and releases", ctx do
      PinnedCLI.inject_identity!(ctx.executable,
        store: Path.join(ctx.tmp, "pins"),
        sha256: String.duplicate("0", 64)
      )

      before = counts(ctx)

      assert {:stop, :pinned_cli_unavailable, %{record: :released}} = run(ctx)
      assert released?(ctx)
      assert counts(ctx) == before
    end

    # 8.14.9 round 4: an unusable evidence directory is refused before any
    # charge.
    test "an unsafe evidence directory aborts and releases; no run, no launch", ctx do
      File.chmod!(ctx.evidence, 0o755)
      before = counts(ctx)

      assert {:stop, :evidence_dir_unsafe, %{record: :released}} = run(ctx)
      assert released?(ctx)
      assert counts(ctx) == before
      assert launches(ctx) == 0
    end

    test "unavailable isolation aborts and releases", ctx do
      before = counts(ctx)

      assert {:stop, :calibration_isolation_unavailable, %{record: :released}} =
               run(ctx, isolation: [target: "printf ready"])

      assert released?(ctx)
      assert counts(ctx) == before
    end
  end

  ## Row 3: an unconfirmed isolation cleanup is a hard owner conflict

  test "row 3: unconfirmed isolation cleanup keeps the claim; no reservation", ctx do
    ConsoleProbe.put({:plus, 999_999})
    before = counts(ctx)

    assert {:stop, :calibration_isolation_cleanup_unconfirmed, summary} = run(ctx)
    assert summary.record == {:kept, "claimed"}
    assert {:ok, %{state: "claimed"}} = LaunchRecord.read(ctx.root)
    assert counts(ctx) == before
    refute File.exists?(ctx.ran), "the CLI ran"
  end

  ## Row 6: the launch_pending write fails

  test "row 6: a failed launch_pending write keeps the claim; the reservation is bound", ctx do
    assert {:stop, :launch_record_write_failed, summary} =
             run(ctx, record: [replace: fail_writing("launch_pending")])

    assert summary.record == {:kept, "claimed"}
    assert {:ok, %{state: "claimed", instance_id: claim}} = LaunchRecord.read(ctx.root)
    assert %ModelInvocation{status: :reserved, sent_at: nil} = invocation!(summary.invocation_id)
    assert reserved_claim(ctx, summary.invocation_id) == claim
    refute File.exists?(ctx.ran), "the CLI ran"
    assert unconsumed_entries() == 0
  end

  ## Rows 9 and 11: the normal path

  describe "rows 9 and 11: the normal path" do
    # No capture keeps the bounded await pending to its deadline, so the
    # genuine receipt is a timeout (Codex babd986 part 3a review).
    test "an uncaptured call finishes: timeout, evidence latched, run latched, released", ctx do
      unrelated = make_ref()
      send(self(), {:unrelated, unrelated})

      assert {:ok, summary} = run(ctx)
      assert summary.record == :released
      assert summary.outcome == "timeout"
      assert released?(ctx)

      invocation = invocation!(summary.invocation_id)
      assert invocation.status == :completed
      assert launches(ctx) == 1
      assert_latched(ctx, invocation, summary)

      # Unrelated mailbox traffic is kept; this protocol's receipts are gone.
      assert_received {:unrelated, ^unrelated}
      refute_received {:calibration_launched, _ref, _receipt}
      refute_received {:calibration_launch_unverified, _ref, _receipt}
      assert unconsumed_entries() == 0
    end

    test "a captured exchange under the candidate is a match", ctx do
      cli = witness_cli!(ctx, "cli_shape_v3")

      assert {:ok, summary} = run(ctx, server: server(ctx, cli))
      assert summary.outcome == "match"

      invocation = invocation!(summary.invocation_id)
      document = assert_latched(ctx, invocation, summary)
      assert [%{"id" => link_id}] = document["links"]
      assert document["evaluated_projection_version"] == @v3
      assert document["evaluated_method"] == "propagated_id"
      assert is_binary(link_id)
    end

    test "a stale or foreign receipt in the mailbox is ignored", ctx do
      LaunchProbe.put(:identity_absent)

      forged = %{
        invocation_id: Ash.UUIDv7.generate(),
        root_pid: 1,
        root_identity: "forged",
        process_group_id: 1,
        server: self()
      }

      send(self(), {:calibration_launched, make_ref(), forged})

      # The real receipt is unverified: the forged one never makes the
      # record launched.
      assert {:stop, :calibration_launch_unverified, summary} = run(ctx)
      assert summary.record == {:kept, "launch_pending"}
    end

    test "every record write is made by the command process", ctx do
      test = self()

      writes = fn temp, final ->
        send(test, {:record_write, self(), File.read!(temp)})
        File.rename(temp, final)
      end

      assert {:ok, _summary} = run(ctx, record: [replace: writes])
      writers = collect_writes()
      assert writers != []
      assert Enum.all?(writers, fn {pid, _bytes} -> pid == test end)
    end
  end

  ## Row 10: sent, but the launch was never verified

  test "row 10: an unverified receipt keeps launch_pending; no evidence, no latch", ctx do
    LaunchProbe.put(:identity_absent)

    assert {:stop, :calibration_launch_unverified, summary} = run(ctx)
    assert summary.record == {:kept, "launch_pending"}
    assert {:ok, %{state: "launch_pending"}} = LaunchRecord.read(ctx.root)

    invocation = invocation!(summary.invocation_id)
    refute is_nil(invocation.sent_at)
    assert File.ls!(ctx.evidence) == []
    assert releases(invocation) == []
    assert launches(ctx) == 1
    assert unconsumed_entries() == 0
  end

  ## Row 12: no quiescence

  test "row 12: quiescence not established keeps launched; no evidence, no latch", ctx do
    LaunchProbe.put(:then_phantom)

    assert {:stop, :calibration_not_quiescent, summary} = run(ctx)
    assert summary.record == {:kept, "launched"}
    assert {:ok, %{state: "launched"}} = LaunchRecord.read(ctx.root)
    assert File.ls!(ctx.evidence) == []
    assert releases(invocation!(summary.invocation_id)) == []
  end

  # Codex d3c@712e53a MF1: a probe error is never absence, and is not
  # retried into a later success.
  test "row 12: one failed quiescence probe stops at once; launched kept, nothing published",
       ctx do
    LaunchProbe.put(:then_error_once)

    assert {:stop, :probe_unavailable, summary} = run(ctx)
    assert summary.record == {:kept, "launched"}
    assert summary.evidence == nil
    assert {:ok, %{state: "launched"}} = LaunchRecord.read(ctx.root)
    assert File.ls!(ctx.evidence) == []
    assert releases(invocation!(summary.invocation_id)) == []
  end

  ## Row 13: evidence, E1, finished and release failures

  describe "row 13" do
    # Made unsafe after preflight's own check (8.14.9 round 4): still
    # caught at publication, with the launched record kept.
    test "an evidence directory made unsafe after preflight stops before any latch", ctx do
      hook = fn
        :before_call, _context -> File.chmod!(ctx.evidence, 0o755)
        _phase, _context -> :ok
      end

      assert {:stop, :evidence_dir_unsafe, summary} = run(ctx, hook: hook)
      assert summary.record == {:kept, "launched"}
      assert releases(invocation!(summary.invocation_id)) == []
      assert run_of(summary.invocation_id).status == :running
    end

    test "a failed finished write keeps launched after the latch", ctx do
      assert {:stop, :launch_record_write_failed, summary} =
               run(ctx, record: [replace: fail_writing("finished")])

      assert summary.record == {:kept, "launched"}
      invocation = invocation!(summary.invocation_id)
      assert [%ModelResultRelease{disposition: :calibration}] = releases(invocation)
      assert {:ok, %{state: "launched"}} = LaunchRecord.read(ctx.root)
      assert_published(summary)
    end

    # Codex d3c@712e53a MF2: once published, the file's path and hash stay
    # in the summary through every later failure.
    test "a failed latch after publication keeps launched and reports the file", ctx do
      fail_events!(ctx, ["model.result.calibration"])

      assert {:stop, :calibration_finish_failed, summary} = run(ctx)
      assert summary.record == {:kept, "launched"}
      assert releases(invocation!(summary.invocation_id)) == []
      assert_published(summary)
    end

    test "a failed release keeps finished; nothing removed", ctx do
      assert {:stop, :launch_record_write_failed, summary} =
               run(ctx, record: [remove: fn _path -> {:error, :eio} end])

      assert summary.record == {:kept, "finished"}
      assert {:ok, %{state: "finished"}} = LaunchRecord.read(ctx.root)
      assert_published(summary)
    end
  end

  ## 8.14.8: the bounded observation of the actual store

  describe "8.14.8: store failures are typed receipts" do
    test "a store root removed after the call is unreadable; the document has no link", ctx do
      cli = shell_cli!(ctx, 1, "rm -rf #{sh(ctx.store)}")

      assert {:ok, summary} = run(ctx, server: server(ctx, cli))
      assert summary.outcome == "unreadable"
      document = assert_latched(ctx, invocation!(summary.invocation_id), summary)
      assert document["links"] == []
      assert document["inventory_sha256"] == nil
    end

    test "an actual unreadable blob: unreadable, nil projection, propagated_id, valid init",
         ctx do
      cli = witness_cli!(ctx, "cli_shape_v3", "rm -f #{sh(ctx.store)}/witness/sha256/*/*.json")

      assert {:ok, summary} = run(ctx, server: server(ctx, cli))
      assert summary.outcome == "unreadable"

      invocation = invocation!(summary.invocation_id)
      document = assert_latched(ctx, invocation, summary)
      assert [%{"id" => _link}] = document["links"]
      assert document["evaluated_projection_version"] == nil
      assert document["evaluated_method"] == "propagated_id"
      assert document["attested_cli_version"] == invocation.provider_version
      assert document["attested_model_id"] == invocation.model_id
    end

    test "an unreadable inventory record is unreadable", ctx do
      corrupt =
        ~s(for f in #{sh(ctx.store)}/witnesses/"$SDR_MODEL_INVOCATION_ID"/*.json; ) <>
          ~s(do printf 'not json' > "$f"; done)

      cli = witness_cli!(ctx, "cli_shape_v3", corrupt)

      assert {:ok, summary} = run(ctx, server: server(ctx, cli))
      assert summary.outcome == "unreadable"
      assert_latched(ctx, invocation!(summary.invocation_id), summary)
    end

    test "a mismatch opens one critical Failure that stays open after the latch", ctx do
      cli = witness_cli!(ctx, "cli_shape_v3_mismatch")

      assert {:ok, summary} = run(ctx, server: server(ctx, cli))
      assert summary.outcome == "mismatch"

      invocation = invocation!(summary.invocation_id)
      assert_latched(ctx, invocation, summary)

      assert [%Failure{severity: :critical, status: status}] = attention(ctx, invocation)
      assert status != :resolved
      assert run_of(invocation.id).attention_failure_id == nil
      assert Enum.map(releases(invocation), & &1.disposition) == [:calibration]
    end
  end

  ## 8.14.10: the clock

  describe "8.14.10: the clock" do
    test "the private server follows the test's clock: the call is sent at the frozen instant",
         ctx do
      assert {:ok, summary} = run(ctx)
      assert invocation!(summary.invocation_id).sent_at == @now
      # The stand-in really ran: this test's name (so its tmp_dir) has an
      # apostrophe, which a quoted path must survive.
      assert File.read!(ctx.ran) == "run\n"
    end

    test "at exactly G-R0's expiry, preflight selects no grant: released, nothing created", ctx do
      Clock.freeze(@expiry)
      before = counts(ctx)

      assert {:stop, :calibration_grant_unavailable, %{record: :released}} = run(ctx)
      assert counts(ctx) == before
      assert launches(ctx) == 0
    end

    test "reaching the expiry before the call: the server's launch admission refuses (row 8)",
         ctx do
      hook = fn
        :before_call, _context -> Clock.freeze(@expiry)
        _phase, _context -> :ok
      end

      before = MapSet.new(all_failures(ctx), & &1.id)

      assert {:stop, :calibration_launch_refused, summary} = run(ctx, hook: hook)
      assert summary.record == :released
      assert summary.outcome == "launch_failed"

      invocation = invocation!(summary.invocation_id)
      assert {invocation.status, invocation.sent_at} == {:failed, nil}
      run = run_of(invocation.id)

      assert [refused] =
               ctx.tenant
               |> events_of_type("model.launch.refused")
               |> Enum.filter(&(&1.subject_id == invocation.id))

      # The existing receipt shape: the launch-grant refusal, by its check.
      assert {refused.payload["reason"], refused.payload["check"]} ==
               {"grant_ineligible_at_launch", "grant_expired"}

      assert {refused.agent_run_id, refused.idempotency_key} ==
               {run.id, invocation.idempotency_key}

      assert [cause] = Enum.reject(all_failures(ctx), &MapSet.member?(before, &1.id))
      assert refused.payload["failure_id"] == cause.id
      assert {run.status, run.status_reason} == {:failed, :model_not_admitted}
      assert run.attention_failure_id == cause.id

      assert [stop] = run_events(ctx, run, "agents.run.failed")
      assert stop.payload["arguments"]["refusal_failure_id"] == cause.id

      assert [latch] =
               ctx.tenant
               |> events_of_type("model.result.calibration")
               |> Enum.filter(&(&1.model_invocation_id == invocation.id))

      assert stop.sequence < latch.sequence
      # The reservation's charge stays where it was.
      assert run.budget.model_calls_reserved == 1
      assert launches(ctx) == 0
    end
  end

  ## Extras (8.14.7)

  test "command death while the VM lives: another recoverer refuses :owner_alive", ctx do
    cli = shell_cli!(ctx, 5)
    # #197: one deadline covers the clock report and the launch.
    deadline = GatedCommand.deadline(10_000)

    command =
      GatedCommand.start!(:result, fn -> run(ctx, server: server(ctx, cli)) end)
      |> GatedCommand.open!(@now, deadline)

    assert GatedCommand.await!(command, deadline, fn ->
             match?({:ok, %{state: "launched"}}, LaunchRecord.read(ctx.root))
           end)

    Process.exit(command.pid, :kill)

    assert LaunchRecord.recover(ctx.root, probe: ProcessProbe) == {:error, :owner_alive}
  end

  ## 8.14.9: the option contract, the tenant and the wiring

  describe "8.14.9: options" do
    for {name, change} <- [
          unknown_key: {:put, :extra, 1},
          missing_required: {:delete, :record},
          duplicate_key: {:duplicate, :root},
          relative_root: {:put, :root, "relative/launch"},
          relative_evidence: {:put, :evidence_dir, "evidence"},
          confirm_wrong_arity: {:put, :confirm, {:function, 2}},
          probe_not_a_module: {:put, :probe, "ProcessProbe"},
          server_not_a_list: {:put, :server, %{}},
          isolation_not_a_list: {:put, :isolation, nil},
          record_not_a_list: {:put, :record, :none},
          tenant_not_an_id: {:put, :tenant, 42},
          tenant_not_a_uuid: {:put, :tenant, "console"},
          hook_wrong_arity: {:put, :hook, {:function, 1}},
          hook_not_a_function: {:put, :hook, :before_call}
        ] do
      test "#{name} is refused before anything", ctx do
        before = {counts(ctx), length(events_of_type(ctx.tenant, "agents.definition.registered"))}

        assert {:stop, :calibration_options_invalid, %{record: :none}} =
                 run_with(ctx, unquote(Macro.escape(change)))

        assert {counts(ctx), length(events_of_type(ctx.tenant, "agents.definition.registered"))} ==
                 before

        refute File.exists?(Path.join(ctx.root, "run.lock"))
        refute_received {:confirm, _prompt}
      end
    end

    test "an unknown tenant id refuses before the definition or the claim", ctx do
      assert {:stop, :calibration_tenant_unavailable, %{record: :none}} =
               run(ctx, tenant: Ash.UUIDv7.generate())

      assert events_of_type(ctx.tenant, "agents.definition.registered") == []
      refute File.exists?(Path.join(ctx.root, "run.lock"))
    end

    test "the :console selector resolves the singleton tenant", ctx do
      assert {:stop, :calibration_not_confirmed, %{record: :released}} =
               run(ctx, tenant: :console, confirm: confirm("no"))

      assert [_registered] = events_of_type(ctx.tenant, "agents.definition.registered")
    end

    test "command/1 is pure and names exactly console_opts/1" do
      assert function_exported?(Calibrate, :command, 1), "Calibrate.command/1 is not defined"

      assert function_exported?(Calibrate, :console_opts, 1),
             "Calibrate.console_opts/1 is not defined"

      assert Calibrate.command(["claude_cli_opus"]) ==
               {:run, :claude_cli_opus, Calibrate.console_opts(:claude_cli_opus)}

      assert Calibrate.command(["claude_cli_sonnet"]) ==
               {:run, :claude_cli_sonnet, Calibrate.console_opts(:claude_cli_sonnet)}

      for argv <- [[], ["fake"], ["claude_cli_opus", "extra"], ["CLAUDE_CLI_OPUS"], ["unknown"]],
          do: assert(Calibrate.command(argv) == {:error, :usage}, inspect(argv))

      opts = Calibrate.console_opts(:claude_cli_opus)

      assert Keyword.keys(opts) |> Enum.sort() ==
               Enum.sort([
                 :tenant,
                 :root,
                 :evidence_dir,
                 :confirm,
                 :probe,
                 :server,
                 :isolation,
                 :record
               ])

      # The canonical paths (packet 8.4 and E2): the lock is
      # calibration/run.lock, shared with calibrate-recover.
      calibration = Path.join(System.user_home!(), ".local/state/sdr-agent/calibration")
      assert opts[:root] == calibration
      assert opts[:evidence_dir] == Path.join(calibration, "evidence")
      assert Keyword.get(opts, :tenant) == :console
      assert Keyword.get(opts, :probe) == ProcessProbe
      assert {opts[:server], opts[:isolation], opts[:record]} == {[], [], []}
      assert is_function(opts[:confirm], 1)
      assert Path.type(opts[:root]) == :absolute
      assert Path.type(opts[:evidence_dir]) == :absolute
      refute Keyword.has_key?(opts, :hook)
    end
  end

  ## 8.14.9: the fixed definition

  describe "8.14.9: the definition" do
    test "registered once as the tenant's kernel actor; a repeat writes no event", ctx do
      for _ <- 1..2 do
        assert {:stop, :calibration_not_confirmed, %{record: :released}} =
                 run(ctx, confirm: confirm("no"))
      end

      assert [event] = events_of_type(ctx.tenant, "agents.definition.registered")
      assert event.actor_type == :kernel
      definition = console_definition!(ctx)

      assert {definition.module, definition.status} ==
               {"SdrAgent.CalibrationConsole.Calibrate", :active}

      assert definition.definition == fixed_definition_body()
    end

    for variant <- [:other_body, :other_module, :retired] do
      test "a #{variant} definition is a conflict before the claim", ctx do
        prepare_definition!(ctx, unquote(variant))
        before = counts(ctx)

        assert {:stop, :calibration_definition_conflict, %{record: :none}} = run(ctx)
        assert counts(ctx) == before
        refute File.exists?(Path.join(ctx.root, "run.lock"))
      end
    end
  end

  ## 8.14.9: the proof run

  test "the proof run carries exactly the 8.14.9 attributes", ctx do
    assert {:ok, summary} = run(ctx)
    run = run_of(summary.invocation_id)

    assert run.agent_definition_id == console_definition!(ctx).id

    assert {run.usage_origin, run.operation_id, run.lead_id, run.campaign_id} ==
             {:proof, nil, nil, nil}

    assert run.trigger_signal_type == "calibration.console"
    assert run.trigger_signal_id == reserved_claim(ctx, summary.invocation_id)

    assert {run.phase, run.budget.max_model_calls, run.budget.max_tool_calls,
            run.budget.max_tokens} ==
             {:research, 1, 0, 100_000}

    assert is_binary(run.correlation_id)
  end

  describe "8.14.9: run creation failures (row 5)" do
    test "a failed creation: no run, aborted, released", ctx do
      fail_events!(ctx, ["agents.run.created"])
      before = counts(ctx)

      assert {:stop, :calibration_run_unavailable, %{record: :released}} = run(ctx)
      assert counts(ctx) == before
    end

    test "a failed start: the queued run is cancelled, then released", ctx do
      fail_events!(ctx, ["agents.run.started"])

      assert {:stop, :calibration_run_unavailable, %{record: :released}} = run(ctx)
      assert [%AgentRun{status: :cancelled}] = proof_runs(ctx)
      assert count(ModelInvocation, ctx.tenant) == 0
    end

    test "a failed start whose cancel also fails keeps the claim", ctx do
      fail_events!(ctx, ["agents.run.started", "agents.run.cancelled"])

      assert {:stop, :calibration_run_stop_failed, summary} = run(ctx)
      assert summary.record == {:kept, "claimed"}
      assert {:ok, %{state: "claimed"}} = LaunchRecord.read(ctx.root)
    end
  end

  ## 8.14.9: the ordering hook

  describe "8.14.9: the hook" do
    test "called once per closed phase, in order, in the command, outside a transaction, ids only",
         ctx do
      test = self()

      hook = fn phase, context ->
        send(test, {:hook, phase, context, self(), SdrAgent.Repo.in_transaction?()})
        {:error, :ignored}
      end

      assert {:ok, summary} = run(ctx, hook: hook)

      assert_received {:hook, :before_issue, first, ^test, false}
      assert_received {:hook, :before_call, second, ^test, false}
      refute_received {:hook, _phase, _context, _pid, _tx}

      for context <- [first, second] do
        assert context == %{
                 invocation_id: summary.invocation_id,
                 run_id: run_of(summary.invocation_id).id,
                 tenant_id: ctx.tenant.id
               }
      end
    end

    test "a raising hook is a conservative stop; the record is kept", ctx do
      hook = fn
        :before_issue, _context -> raise "synthetic hook failure"
        _phase, _context -> :ok
      end

      assert {:stop, :calibration_hook_failed, summary} = run(ctx, hook: hook)
      assert summary.record == {:kept, "launch_pending"}

      assert %ModelInvocation{status: :reserved, sent_at: nil} =
               invocation!(summary.invocation_id)

      assert launches(ctx) == 0
      assert File.ls!(ctx.evidence) == []
    end
  end

  ## Row 4: a typed reservation refusal

  describe "row 4: a reservation %Refused{}" do
    setup ctx do
      spend_opus_allocation!(ctx)
      :ok
    end

    test "the run is stopped with that receipt, then aborted and released", ctx do
      before = MapSet.new(all_failures(ctx), & &1.id)

      assert {:stop, :calibration_reservation_refused, %{record: :released}} = run(ctx)

      assert [run] =
               Enum.filter(proof_runs(ctx), &(&1.trigger_signal_type == "calibration.console"))

      assert {run.status, run.status_reason} == {:budget_exhausted, :grant_exhausted}
      assert [failure] = Enum.reject(all_failures(ctx), &MapSet.member?(before, &1.id))
      # The stored cause is the receipt's Failure; the stop event records
      # the exact receipt it was given.
      assert run.attention_failure_id == failure.id
      assert [stop] = run_events(ctx, run, "agents.run.budget_exhausted")
      assert stop.payload["arguments"]["refusal_failure_id"] == failure.id
      assert launches(ctx) == 0
    end

    test "4b: a failed run stop keeps the claim (never a released running run)", ctx do
      fail_events!(ctx, ["agents.run.budget_exhausted"])

      assert {:stop, :calibration_run_stop_failed, summary} = run(ctx)
      assert summary.record == {:kept, "claimed"}
      assert {:ok, %{state: "claimed"}} = LaunchRecord.read(ctx.root)
    end
  end

  ## Row 5: reserve fails without a typed refusal

  test "row 5: a failed reservation append: no invocation, the run cancelled, released", ctx do
    fail_events!(ctx, ["model.invocation.reserved"])

    assert {:stop, :calibration_reservation_failed, %{record: :released}} = run(ctx)
    assert count(ModelInvocation, ctx.tenant) == 0
    assert [%AgentRun{status: :cancelled}] = proof_runs(ctx)
    assert launches(ctx) == 0
  end

  ## Row 7: Authority.issue fails

  test "row 7: Authority unavailable: unlaunched recovery, evidence, latch, released", ctx do
    hook = fn
      :before_issue, _context -> :ok = stop_supervised(Authority)
      _phase, _context -> :ok
    end

    assert {:stop, :calibration_authority_unavailable, summary} = run(ctx, hook: hook)
    assert summary.record == :released
    assert summary.outcome == "launch_failed"
    invocation = invocation!(summary.invocation_id)
    assert {invocation.status, invocation.sent_at} == {:failed, nil}
    assert_unlaunched_latched(ctx, invocation, summary)
    assert launches(ctx) == 0
  end

  ## Row 8: sent_at nil after the call

  describe "row 8: unlaunched after the call" do
    test "an actual launch refusal: stop_refused before E1, then evidence, latch, release", ctx do
      hook = fn
        :before_call, _context -> revoke_g_r0!(ctx)
        _phase, _context -> :ok
      end

      before = MapSet.new(all_failures(ctx), & &1.id)

      assert {:stop, :calibration_launch_refused, summary} = run(ctx, hook: hook)
      assert summary.record == :released
      assert summary.outcome == "launch_failed"

      invocation = invocation!(summary.invocation_id)
      assert {invocation.status, invocation.sent_at} == {:failed, nil}
      run = run_of(invocation.id)

      # The launch receipt: its one immutable event for this invocation,
      # run and request, naming the one new Failure.
      assert [refused] =
               ctx.tenant
               |> events_of_type("model.launch.refused")
               |> Enum.filter(&(&1.subject_id == invocation.id))

      assert {refused.agent_run_id, refused.idempotency_key} ==
               {run.id, invocation.idempotency_key}

      assert [cause] = Enum.reject(all_failures(ctx), &MapSet.member?(before, &1.id))
      assert refused.payload["failure_id"] == cause.id

      # The refusal's own stop holds, with that exact cause; E1 never turns
      # it into a success.
      assert {run.status, run.status_reason} == {:failed, :model_not_admitted}
      assert run.attention_failure_id == cause.id
      assert [stop] = run_events(ctx, run, "agents.run.failed")
      assert stop.payload["arguments"]["refusal_failure_id"] == cause.id
      assert stop.payload["arguments"]["refusal_request_id"] == invocation.idempotency_key

      # The stop precedes the calibration latch in the tenant's sequence. A
      # cause resolved before the stop is still linked by that same action
      # (model_not_admitted_worker_test.exs, "a launch refusal resolved
      # before the stop"); this test pins that calibrate forwards the exact
      # receipt to it.
      assert [latch] =
               ctx.tenant
               |> events_of_type("model.result.calibration")
               |> Enum.filter(&(&1.model_invocation_id == invocation.id))

      assert stop.sequence < latch.sequence

      assert_unlaunched_latched(ctx, invocation, summary, run_status: :failed)
      assert launches(ctx) == 0
    end

    test "a failed refusal stop keeps launch_pending: no evidence, no latch", ctx do
      hook = fn
        :before_call, _context ->
          revoke_g_r0!(ctx)
          fail_events!(ctx, ["agents.run.failed"])

        _phase, _context ->
          :ok
      end

      assert {:stop, :calibration_run_stop_failed, summary} = run(ctx, hook: hook)
      assert summary.record == {:kept, "launch_pending"}
      assert File.ls!(ctx.evidence) == []
      assert releases(invocation!(summary.invocation_id)) == []
    end

    test "a pre-launch pin loss leaves it reserved: unlaunched recovery, evidence, latch", ctx do
      hook = fn
        :before_call, _context -> File.rm!(ctx.executable)
        _phase, _context -> :ok
      end

      assert {:stop, :pinned_cli_unavailable, summary} = run(ctx, hook: hook)
      assert summary.record == :released
      assert summary.outcome == "launch_failed"
      invocation = invocation!(summary.invocation_id)
      assert {invocation.status, invocation.sent_at} == {:failed, nil}
      assert_unlaunched_latched(ctx, invocation, summary)
      assert launches(ctx) == 0
    end
  end

  ## Fixtures

  defp run(ctx, overrides \\ []) do
    opts = Keyword.merge(base_opts(ctx), overrides)
    AdmissionFixtures.admitting(fn -> Calibrate.run(@profile, opts) end)
  end

  defp base_opts(ctx),
    do: [
      tenant: ctx.tenant.id,
      root: ctx.root,
      evidence_dir: ctx.evidence,
      confirm: confirm(@typed),
      probe: ConsoleProbe,
      server: server(ctx, ctx.cli),
      isolation: [],
      record: []
    ]

  # A run with one option changed, removed or duplicated.
  defp run_with(ctx, change) do
    opts = base_opts(ctx)

    opts =
      case change do
        {:put, key, value} -> Keyword.put(opts, key, materialize(value))
        {:delete, key} -> Keyword.delete(opts, key)
        {:duplicate, key} -> opts ++ [{key, Keyword.fetch!(opts, key)}]
      end

    AdmissionFixtures.admitting(fn -> Calibrate.run(@profile, opts) end)
  end

  # Functions cannot be escaped into generated tests: `{:function, arity}`
  # names one of that arity.
  defp materialize({:function, 1}), do: fn _a -> :ok end
  defp materialize({:function, 2}), do: fn _a, _b -> "x" end
  defp materialize(value), do: value

  defp fixed_definition_body,
    do: %{
      "allowed_actions" => [],
      "model_policy" => %{"provider" => "claude_cli", "max_model_calls_per_run" => 1}
    }

  defp console_definition!(ctx) do
    AgentDefinition
    |> Ash.Query.filter(
      tenant_id == ^ctx.tenant.id and name == "CalibrationConsole" and version == 1
    )
    |> Ash.read_one!(authorize?: false)
  end

  defp prepare_definition!(ctx, variant) do
    kernel = system_actor(:kernel, ctx.tenant)

    attrs = %{
      name: "CalibrationConsole",
      version: 1,
      module: "SdrAgent.CalibrationConsole.Calibrate",
      definition: fixed_definition_body()
    }

    attrs =
      case variant do
        :other_body -> %{attrs | definition: %{"allowed_actions" => [], "model_policy" => %{}}}
        :other_module -> %{attrs | module: "SdrAgent.SomethingElse"}
        :retired -> attrs
      end

    {:ok, definition} = Agents.register_definition(attrs, actor: kernel)
    if variant == :retired, do: {:ok, _} = Agents.retire_definition(definition, actor: kernel)
  end

  # Spends both attempts of G-R0's opus allocation through real proof
  # reservations, each settled and latched, so preflight still selects the
  # grant and the console's own reservation is refused.
  defp spend_opus_allocation!(ctx) do
    for _ <- 1..2 do
      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant, usage_origin: :proof)

      {:ok, binding} =
        Agents.select_calibration_grant(ctx.tenant.id, @profile, actor: agent)

      marker =
        CalibrationAdmission.context(@profile, AdmissionFixtures.entry(@profile, @v3),
          claim: Ash.UUIDv7.generate(),
          binding: binding
        )

      prompt = Prompt.prompt_ref()
      schema = Prompt.schema_ref()

      attrs =
        "spend-#{System.unique_integer([:positive])}"
        |> AgentsFixtures.claude_attrs()
        |> Map.merge(%{
          prompt_template_id: prompt.id,
          prompt_template_version: prompt.version,
          prompt_template_sha256: prompt.sha256,
          output_schema_id: schema.id,
          output_schema_version: schema.version,
          output_schema_sha256: schema.sha256
        })

      {:ok, reserved} =
        AdmissionFixtures.admitting(fn ->
          Agents.reserve_model_invocation(run, attrs, actor: agent, calibration: marker)
        end)

      # Settled and latched, so the predecessor barrier (B4') stays clear.
      {:ok, failed} =
        Agents.fail_model_invocation(reserved, %{error: %{"kind" => "provider_error"}},
          actor: agent
        )

      {:ok, _latched} =
        Agents.finish_calibration(failed, %{sha256: String.duplicate("0", 64)}, actor: agent)
    end
  end

  defp revoke_g_r0!(ctx) do
    {:ok, _revoked} =
      Agents.revoke_grant(ctx.grant, %{expected_revision: ctx.grant.revision},
        actor: human(:admin, ctx.tenant)
      )
  end

  # Test-only fault: inserting any of `event_types` raises, inside the
  # test's sandbox transaction (rolled back with it).
  defp fail_events!(_ctx, event_types) do
    name = "sdr_test_fail_#{System.unique_integer([:positive])}"
    types = Enum.map_join(event_types, ", ", &"'#{&1}'")

    Ecto.Adapters.SQL.query!(
      SdrAgent.Repo,
      "CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS " <>
        "$$ BEGIN RAISE EXCEPTION 'injected event failure'; END $$",
      []
    )

    Ecto.Adapters.SQL.query!(
      SdrAgent.Repo,
      "CREATE TRIGGER #{name} BEFORE INSERT ON audit_events FOR EACH ROW " <>
        "WHEN (NEW.event_type IN (#{types})) EXECUTE FUNCTION #{name}()",
      []
    )
  end

  # The events of `event_type` whose subject is `subject` (a run or an
  # invocation), in sequence order.
  defp run_events(ctx, subject, event_type) do
    ctx.tenant
    |> events_of_type(event_type)
    |> Enum.filter(&(&1.subject_id == subject.id))
    |> Enum.sort_by(& &1.sequence)
  end

  defp proof_runs(ctx) do
    AgentRun
    |> Ash.Query.filter(tenant_id == ^ctx.tenant.id and usage_origin == :proof)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.trigger_signal_type == "calibration.console"))
  end

  defp all_failures(ctx), do: Ash.read!(Failure, SdrAgent.Audit.Kernel.opts(ctx.tenant.id))

  # The unlaunched document (launch_failed, no evaluation or attestation)
  # is published, validated and latched; the run keeps `run_status`.
  defp assert_unlaunched_latched(ctx, invocation, summary, opts \\ []) do
    agent = system_actor(:agent_runtime, ctx.tenant)
    %{path: path, sha256: sha} = summary.evidence

    target = %{
      invocation_id: invocation.id,
      run_id: invocation.agent_run_id,
      tenant_id: ctx.tenant.id,
      profile_id: @profile
    }

    assert {:ok, _validated} = Evidence.validate(path, target, actor: agent)
    document = path |> File.read!() |> Jason.decode!()
    assert document["outcome"] == "launch_failed"
    assert document["links"] == []
    assert {document["attested_cli_version"], document["attested_model_id"]} == {nil, nil}

    assert [%ModelResultRelease{disposition: :calibration, evidence_sha256: ^sha}] =
             releases(invocation)

    run = run_of(invocation.id)

    case Keyword.get(opts, :run_status) do
      nil -> assert {run.status, run.status_reason} == {:succeeded, :calibration_latched}
      status -> assert run.status == status
    end
  end

  # The test's own private server, following the test's clock (8.14.10).
  defp server(ctx, command),
    do: [command: command, executable: ctx.executable, environment: %{}, clock_from: self()]

  # The confirmation reader: reports the prompt it was shown, answers `line`.
  defp confirm(line) do
    test = self()

    fn prompt ->
      send(test, {:confirm, prompt})
      line
    end
  end

  # A stand-in CLI: reads the prompt, stays alive `delay` seconds (to be
  # probed), answers in the calibration schema, then runs `after`.
  defp shell_cli!(ctx, delay, after_script \\ "") do
    path = Path.join(ctx.tmp, "cli-#{System.unique_integer([:positive])}")

    init =
      ~s({"type":"system","subtype":"init","model":"claude-opus-5-5","claude_code_version":"2.1.294","tools":[],"mcp_servers":[],"slash_commands":[]})

    result =
      ~s({"type":"result","subtype":"success","is_error":false,"result":"{\\"answer\\":\\"blue\\",\\"confidence\\":0.9}","usage":{"input_tokens":1,"output_tokens":1}})

    File.write!(path, """
    #!/bin/sh
    echo run >> #{sh(ctx.ran)}
    cat > /dev/null
    sleep #{delay}
    #{after_script}
    printf '%s\\n' '#{init}'
    printf '%s\\n' '#{result}'
    """)

    File.chmod!(path, 0o555)
    path
  end

  # The fake CLI playing shim and proxy store for one call: it captures the
  # exchange of `variant` under the propagated invocation id, then runs
  # `after` (an actual store fault made after capture).
  defp witness_cli!(ctx, variant, after_script \\ "") do
    path = Path.join(ctx.tmp, "witness-cli-#{System.unique_integer([:positive])}")
    elixir = System.find_executable("elixir")

    File.write!(path, """
    #!/bin/sh
    echo run >> #{sh(ctx.ran)}
    out=$(#{sh(elixir)} #{sh(@fake)} witness #{sh(ctx.store)} #{variant} calibration "$@")
    status=$?
    #{after_script}
    printf '%s\\n' "$out"
    exit $status
    """)

    File.chmod!(path, 0o555)
    path
  end

  # One single-quoted shell word. A test's name, and so its tmp_dir, may
  # contain an apostrophe, which a bare '...' around a path would end.
  defp sh(path), do: "'" <> String.replace(path, "'", ~S('\'')) <> "'"

  defp private_dir!(tmp, name) do
    path = Path.join(tmp, name)
    File.mkdir_p!(path)
    File.chmod!(path, 0o700)
    path
  end

  # Creates the tenant's one G-R0 grant in its fixed shape (its expiry is
  # code-owned, `Admission.g_r0?/2`).
  defp g_r0!(tenant) do
    AgentsFixtures.grant!(tenant, %{
      name: "G-R0",
      profile_ids: [:claude_cli_opus, :claude_cli_sonnet],
      total_attempts: 4,
      starts_at: ~U[2026-10-12 00:00:00.000000Z],
      expires_at: ~U[2026-10-19 05:59:00.000000Z],
      allocations: [
        %{key: :proof, applies_to: [:proof], attempts: 2, profile_id: :claude_cli_opus},
        %{key: :proof, applies_to: [:proof], attempts: 2, profile_id: :claude_cli_sonnet}
      ]
    })
  end

  # A record write that fails exactly when it would write `state`.
  defp fail_writing(state) do
    fn temp, final ->
      if File.read!(temp) =~ ~s("state":"#{state}"),
        do: {:error, :eio},
        else: File.rename(temp, final)
    end
  end

  defp collect_writes do
    receive do
      {:record_write, pid, bytes} -> [{pid, bytes} | collect_writes()]
    after
      0 -> []
    end
  end

  # The document is published, validated against the committed rows, and
  # its hash is the one the `:calibration` latch carries; the run is
  # latched. Returns the decoded document.
  defp assert_latched(ctx, invocation, summary) do
    agent = system_actor(:agent_runtime, ctx.tenant)
    %{path: path, sha256: sha} = summary.evidence

    target = %{
      invocation_id: invocation.id,
      run_id: invocation.agent_run_id,
      tenant_id: ctx.tenant.id,
      profile_id: @profile
    }

    assert {:ok, _validated} = Evidence.validate(path, target, actor: agent)
    bytes = File.read!(path)
    assert sha == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    assert [%ModelResultRelease{disposition: :calibration, evidence_sha256: ^sha}] =
             releases(invocation)

    run = run_of(invocation.id)
    assert {run.status, run.status_reason} == {:succeeded, :calibration_latched}
    refute bytes =~ Prompt.render()
    Jason.decode!(bytes)
  end

  # The summary names the one published file: it exists, validates by
  # name and its bytes hash to the reported digest.
  defp assert_published(summary) do
    assert %{path: path, sha256: sha} = summary.evidence
    assert File.regular?(path)
    assert sha == Base.encode16(:crypto.hash(:sha256, File.read!(path)), case: :lower)
  end

  defp released?(ctx), do: LaunchRecord.read(ctx.root) == {:ok, :none}

  defp counts(ctx) do
    {count(AgentRun, ctx.tenant), count(ModelInvocation, ctx.tenant)}
  end

  defp count(resource, tenant) do
    resource
    |> Ash.Query.filter(tenant_id == ^tenant.id)
    |> Ash.read!(authorize?: false)
    |> length()
  end

  defp invocation!(id), do: Ash.get!(ModelInvocation, id, authorize?: false)

  defp run_of(invocation_id),
    do: Ash.get!(AgentRun, invocation!(invocation_id).agent_run_id, authorize?: false)

  defp releases(invocation) do
    ModelResultRelease
    |> Ash.Query.filter(model_invocation_id == ^invocation.id)
    |> Ash.read!(authorize?: false)
  end

  defp attention(ctx, invocation) do
    Failure
    |> Ash.read!(SdrAgent.Audit.Kernel.opts(ctx.tenant.id))
    |> Enum.filter(&(&1.subject_id == invocation.id))
  end

  # The claim the invocation's original reservation event recorded.
  defp reserved_claim(ctx, invocation_id) do
    [event] =
      ctx.tenant
      |> events_of_type("model.invocation.reserved")
      |> Enum.filter(&(&1.subject_id == invocation_id))

    get_in(event.payload, ["arguments", "calibration_claim", "instance_id"])
  end

  defp launches(ctx) do
    case File.read(ctx.ran) do
      {:ok, lines} -> lines |> String.split("\n", trim: true) |> length()
      {:error, :enoent} -> 0
    end
  end

  defp unconsumed_entries do
    Authority.table()
    |> :ets.tab2list()
    |> Enum.count(&match?({_key, _binding, :unconsumed}, &1))
  end
end
