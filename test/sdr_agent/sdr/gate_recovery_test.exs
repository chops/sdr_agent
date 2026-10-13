defmodule SdrAgent.SDR.GateRecoveryTest do
  @moduledoc """
  R0-07 slice C, row G5 (REQ-07-6; section 6.4 bound R1): run recovery
  (`SdrAgent.SDR.StaleRunSweeper`) of a completed generation-2 ClaudeCLI
  invocation that has no release. Recovery never releases it, never calls
  a model again and never records a crash.

    * **R1, nothing persisted:** recovery runs the gated reconcile, then
      finalizes with `:gate_interrupted`, or `:witness_mismatch` for a
      known mismatch.
    * **R2, links or a cause already exist:** no reconcile; G5's selection
      decides.
    * **R1 and R2** stop the abandoned run (`:witness_unreconciled` or
      `:witness_mismatch`) and fail its Operation by the worker's rule.
    * **R3, a terminal run:** a withheld release only; the run and the
      Operation are unchanged.

  Job liveness and run state are decided again under finalization's
  locks: a run whose job is live, or that the gate already stopped, is
  left alone.
  """
  use SdrAgent.SDRCase, async: false

  import Ecto.Query, only: [from: 2]

  alias SdrAgent.Agents
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Clock
  alias SdrAgent.GateFixtures
  alias SdrAgent.Operations
  alias SdrAgent.SDR.StaleRunSweeper

  @v3_opus %{
    provider: :claude_cli,
    cli_version: "2.1.291",
    profile_id: :claude_cli_opus,
    model_id: "claude-opus-5-5",
    projection_version: "claude-message-json/3+prompt-builder/1",
    method: :propagated_id
  }

  setup ctx do
    AgentsFixtures.grant!(ctx.tenant, %{}, ctx.admin)
    root = GateFixtures.root!()
    previous = Application.get_env(:sdr_agent, SdrAgent.Agents.Witness, [])

    Application.put_env(
      :sdr_agent,
      SdrAgent.Agents.Witness,
      Keyword.merge(previous, store_root: root, reconciled_methods: [@v3_opus])
    )

    on_exit(fn ->
      Application.put_env(:sdr_agent, SdrAgent.Agents.Witness, previous)
      File.rm_rf!(root)
    end)

    %{run: run, operation: operation, job: job} = assign!(ctx, "01")
    {:ok, operation} = Operations.start_operation(operation, actor: ctx.agent)
    {:ok, run} = Agents.start_run(run, actor: ctx.agent)
    %{root: root, run: run, operation: operation, job: job}
  end

  # A completed generation-2 call whose worker died before the gate.
  defp crashed_before_gate!(ctx, variant) do
    invocation = GateFixtures.call_model!(ctx, variant)
    abandon!(ctx)
    invocation
  end

  defp abandon!(ctx) do
    {1, _} =
      Repo.update_all(from(j in Oban.Job, where: j.id == ^ctx.job.id), set: [state: "discarded"])

    started = run!(ctx, ctx.run).started_at
    Clock.freeze(DateTime.add(started, StaleRunSweeper.stale_after_seconds() + 1, :second))
  end

  defp gate(ctx), do: %{run_id: ctx.run.id, operation_id: ctx.run.operation_id}

  defp release!(ctx, invocation) do
    {:ok, release} = Agents.get_result_release(invocation.id, actor: ctx.agent)
    release
  end

  defp operation!(ctx) do
    {:ok, operation} = Operations.get_operation(ctx.operation.id, actor: ctx.admin)
    operation
  end

  defp assert_no_crash(ctx) do
    refute Enum.any?(
             events_of_type(ctx.tenant, "agents.run.failed"),
             &(&1.payload["changes"]["status_reason"] == "crash")
           )
  end

  describe "R1: nothing persisted" do
    test "a matching capture is still withheld :gate_interrupted; the run stops", ctx do
      invocation = crashed_before_gate!(ctx, "cli_shape_v3")
      assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)

      release = release!(ctx, invocation)
      assert {release.disposition, release.reason} == {:withheld, :gate_interrupted}
      run = run!(ctx, ctx.run)
      assert {run.status, run.status_reason} == {:failed, :witness_unreconciled}

      {:ok, cause} = Operations.get_failure(run.attention_failure_id, actor: ctx.admin)
      assert {cause.subject_id, cause.operation_id} == {invocation.id, ctx.operation.id}
      assert operation!(ctx).last_failure_id == cause.id
      assert operation!(ctx).status in [:failed, :discarded]
      assert [_one] = invocations!(ctx, run)
      assert_no_crash(ctx)
    end

    test "a known mismatch stays :witness_mismatch on its critical cause", ctx do
      invocation = crashed_before_gate!(ctx, "cli_shape_v3_mismatch")
      assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)

      assert release!(ctx, invocation).reason == :witness_mismatch
      run = run!(ctx, ctx.run)
      assert run.status_reason == :witness_mismatch
      {:ok, cause} = Operations.get_failure(run.attention_failure_id, actor: ctx.admin)
      assert cause.severity == :critical
      assert_no_crash(ctx)
    end
  end

  test "R2: the gate's reconcile persisted; recovery selects without reconciling", ctx do
    invocation = GateFixtures.call_model!(ctx, "none")
    {:timeout, receipt} = ResultGate.await(invocation, gate(ctx))
    abandon!(ctx)
    {:ok, links_before} = Agents.list_wire_witness_links(invocation.id, actor: ctx.aud)

    assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)

    assert release!(ctx, invocation).reason == :gate_interrupted
    run = run!(ctx, ctx.run)

    assert {run.status_reason, run.attention_failure_id} ==
             {:witness_unreconciled, receipt.cause_id}

    assert {:ok, ^links_before} = Agents.list_wire_witness_links(invocation.id, actor: ctx.aud)
    assert_no_crash(ctx)
  end

  test "R3: a terminal run gets a withheld release only", ctx do
    invocation = GateFixtures.call_model!(ctx, "cli_shape_v3")
    {:ok, cancelled} = Agents.cancel_run(run!(ctx, ctx.run), actor: ctx.admin)
    operation = operation!(ctx)
    abandon!(ctx)

    assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)

    assert release!(ctx, invocation).reason == :gate_interrupted
    run = run!(ctx, ctx.run)

    assert {run.status, run.status_reason, run.attention_failure_id} ==
             {cancelled.status, cancelled.status_reason, cancelled.attention_failure_id}

    assert operation!(ctx).status == operation.status
  end

  test "a run whose job is still live is left alone", ctx do
    invocation = GateFixtures.call_model!(ctx, "cli_shape_v3")
    started = run!(ctx, ctx.run).started_at
    Clock.freeze(DateTime.add(started, StaleRunSweeper.stale_after_seconds() + 1, :second))

    assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)
    assert {:ok, nil} = Agents.get_result_release(invocation.id, actor: ctx.agent)
    assert run!(ctx, ctx.run).status == :running
  end

  describe "a gate stop whose Operation was never failed (review MF1)" do
    test "the next sweep fails the stranded Operation on the live gate cause", ctx do
      invocation = GateFixtures.call_model!(ctx, "cli_shape_v3_mismatch")
      assert {:withheld, _release, stopped} = ResultGate.gate(invocation, gate(ctx))
      assert operation!(ctx).status == :running
      abandon!(ctx)

      assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)
      operation = operation!(ctx)
      assert operation.status in [:failed, :discarded]
      assert operation.last_failure_id == stopped.attention_failure_id
      assert_no_crash(ctx)

      events = length(events(ctx.tenant))
      assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)
      assert length(events(ctx.tenant)) == events
    end

    test "a resolved gate cause: the Operation fails with its own Failure naming it", ctx do
      invocation = GateFixtures.call_model!(ctx, "cli_shape_v3_mismatch")
      assert {:withheld, _release, stopped} = ResultGate.gate(invocation, gate(ctx))
      {:ok, cause} = Operations.get_failure(stopped.attention_failure_id, actor: ctx.admin)
      {:ok, _} = Operations.resolve_failure(cause, %{resolution_note: "seen"}, actor: ctx.admin)
      abandon!(ctx)

      assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)
      operation = operation!(ctx)
      assert operation.status in [:failed, :discarded]
      refute operation.last_failure_id == cause.id
      {:ok, own} = Operations.get_failure(operation.last_failure_id, actor: ctx.admin)
      assert own.message =~ cause.id
    end

    test "a live job's Operation is left to its worker", ctx do
      invocation = GateFixtures.call_model!(ctx, "cli_shape_v3_mismatch")
      assert {:withheld, _release, _stopped} = ResultGate.gate(invocation, gate(ctx))
      started = run!(ctx, ctx.run).started_at
      Clock.freeze(DateTime.add(started, StaleRunSweeper.stale_after_seconds() + 1, :second))

      assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)
      assert operation!(ctx).status == :running
    end
  end

  test "the finalizer won: recovery sees the stopped run and changes nothing", ctx do
    invocation = GateFixtures.call_model!(ctx, "cli_shape_v3_mismatch")
    assert {:withheld, release, _run} = ResultGate.gate(invocation, gate(ctx))
    abandon!(ctx)
    events = length(events(ctx.tenant))

    assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)
    assert release!(ctx, invocation).id == release.id
    assert run!(ctx, ctx.run).status_reason == :witness_mismatch
    # Only the Operation's failure, by the worker's rule, may follow.
    refute Enum.any?(Enum.drop(events(ctx.tenant), events), &(&1.event_type =~ "model.result"))
  end

  test "recovery won: the late finalizer respects its release (G7)", ctx do
    invocation = crashed_before_gate!(ctx, "cli_shape_v3")
    assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)
    recovered = release!(ctx, invocation)

    assert {:withheld, release, run} = ResultGate.gate(invocation, gate(ctx))
    assert release.id == recovered.id
    assert run.status_reason == :witness_unreconciled
    {:ok, all} = Agents.list_result_releases(actor: ctx.aud)
    assert Enum.count(all, &(&1.model_invocation_id == invocation.id)) == 1
  end
end
