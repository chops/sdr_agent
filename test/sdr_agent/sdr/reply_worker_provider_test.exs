defmodule SdrAgent.SDR.ReplyWorkerProviderTest do
  @moduledoc """
  Q0.1 review: reply classification (`SdrAgent.SDR.ReplyWorker`) on the
  runtime-selected ClaudeCLI. Through the one named server (backed by the
  hermetic fake CLI) a matched reply's classification call completes and
  passes the R0-07 result gate: with a matching witness capture its output
  is released and the reply is assessed; with the witness store
  unconfigured it is withheld (`:store_unreadable`) and the run stops
  `:witness_unreconciled` on its gate cause — a reply run has no
  Operation, so the cause carries none and is bound by the withheld
  event (row G1) — never a crash, nothing classified. With the
  server missing the run fails `provider_error` with its critical Failure
  and no model call (no reservation), the job returning `{:error,
  :provider_not_running}`; a drifted attestation fails the invocation and
  opens the critical `provider_error` Failure on it.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures
  import SdrAgent.WebhookFixtures

  alias SdrAgent.Agents
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.Clock
  alias SdrAgent.GateFixtures
  alias SdrAgent.SDR.StaleRunSweeper
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Operations
  alias SdrAgent.Outreach

  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)

  # C9: real-model (ClaudeCLI) reservations are charged to a grant.
  setup ctx do
    SdrAgent.AgentsFixtures.grant!(ctx.tenant, %{}, ctx.admin)
    :ok
  end

  # The outreach is drafted and delivered on the Fake; only the reply's
  # classification runs with ClaudeCLI selected.
  setup ctx do
    approved = approved!(ctx, "01")
    assert %{success: 1} = deliver!()
    delivery = outreach!(ctx, approved.delivery)

    put_env!(:model_provider, ClaudeCLI)
    text = "Thanks, this sounds interesting. Could we set up a call next week?"
    assert {:ok, %{status: :accepted}} = ingest!("reply", reply_body(delivery, text))
    assert %{success: 1} = process!()

    {:ok, runs} = Agents.list_runs(actor: ctx.agent, lead_id: approved.lead.id)
    [run] = Enum.filter(runs, &(&1.trigger_signal_type == "sdr.reply.received"))
    assert run.status == :queued

    %{reply_run: run}
  end

  defp start_named!(args) do
    start_supervised!(
      {ClaudeCLI,
       name: ClaudeCLI.server(),
       command: System.find_executable("elixir"),
       test_launcher: true,
       command_args: [@fake | List.wrap(args)]}
    )
  end

  defp classify!, do: Oban.drain_queue(queue: :agent, with_safety: false)

  @v3_opus %{
    provider: :claude_cli,
    cli_version: "2.1.291",
    profile_id: :claude_cli_opus,
    model_id: "claude-opus-5-5",
    projection_version: "claude-message-json/3+prompt-builder/1",
    method: :propagated_id
  }

  # A trusted stand-in witness store with the exact v3 Opus tuple enabled.
  defp before_gate!(fun) do
    previous = Application.get_env(:sdr_agent, ResultGate, [])
    Application.put_env(:sdr_agent, ResultGate, Keyword.put(previous, :before_gate, fun))
    on_exit(fn -> Application.put_env(:sdr_agent, ResultGate, previous) end)
  end

  defp refute_crash(ctx) do
    refute Enum.any?(
             events_of_type(ctx.tenant, "agents.run.failed"),
             &(&1.payload["changes"]["status_reason"] == "crash")
           )
  end

  defp witnessed! do
    root = SdrAgent.Test.WitnessRoot.mkdir!("reply")
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

    root
  end

  test "a reply classified through the named server is released by the gate", ctx do
    start_named!(["sdr", witnessed!()])
    assert %{success: 1} = classify!()

    run = run!(ctx, ctx.reply_run)
    assert run.status == :succeeded, inspect({run.status_reason, run.failure_reason})
    assert [invocation] = invocations!(ctx, run)

    assert {:ok, %{disposition: :released}} =
             Agents.get_result_release(invocation.id, actor: ctx.agent)

    assert {:ok, %{}} = Agents.released_output(invocation, actor: ctx.agent)
  end

  # R0-07 slice C (REQ-07-4, row G1): an unconfigured store after spend
  # withholds the output; the run stops on its event-bound gate cause.
  test "an unconfigured witness store withholds the reply; the run stops", ctx do
    start_named!(["sdr"])
    assert %{success: 1} = classify!()

    run = run!(ctx, ctx.reply_run)

    assert {run.status, run.status_reason} == {:failed, :witness_unreconciled},
           inspect(run.failure_reason)

    assert [invocation] = invocations!(ctx, run)

    assert {invocation.provider, invocation.model_id, invocation.purpose, invocation.status} ==
             {:claude_cli, "claude-opus-5-5", :reply_classification, :completed}

    assert invocation.ledger_generation == 2

    assert {:ok, %{disposition: :withheld, reason: :store_unreadable}} =
             Agents.get_result_release(invocation.id, actor: ctx.agent)

    assert {:error, :result_not_released} =
             Agents.released_output(invocation, actor: ctx.agent)

    {:ok, cause} = Operations.get_failure(run.attention_failure_id, actor: ctx.admin)

    assert {cause.class, cause.subject_id, cause.operation_id, cause.status} ==
             {:reconciliation_required, invocation.id, nil, :open}

    {:ok, decisions} = Agents.list_decisions(run.id, actor: ctx.agent)
    refute Enum.any?(decisions, &(&1.model_invocation_id == invocation.id))
    assert {:ok, []} = Outreach.list_records(Outreach.ReplyAssessment, actor: ctx.admin)
  end

  # Review MF5: a competitor's withheld release (null-Operation cause bound
  # by its event) stops the reply run on that cause, never as a crash.
  test "a competitor's withheld release stops the reply run on its bound cause", ctx do
    root = witnessed!()
    parent = self()

    before_gate!(fn invocation ->
      cause = GateFixtures.cause!(invocation)
      GateFixtures.withhold!(invocation, ctx.agent, cause)
      send(parent, {:competing, cause.id})
    end)

    start_named!(["sdr", root])
    assert %{success: 1} = classify!()
    assert_received {:competing, cause_id}

    run = run!(ctx, ctx.reply_run)
    assert {run.status, run.status_reason} == {:failed, :witness_unreconciled}
    assert run.attention_failure_id == cause_id
    refute_crash(ctx)
  end

  # Interpretation 1 (accepted): no output, no success or crash; recovered.
  test "a reply gate that cannot commit is neither success nor crash; recovered later", ctx do
    root = witnessed!()
    parent = self()

    # A live critical bound to another Operation is unusable for a reply
    # run (row R7-2); one without an Operation would be bindable (row G1).
    %{operation: other} = SdrAgent.AgentsFixtures.operated_run(ctx.tenant)

    before_gate!(fn invocation ->
      stray = GateFixtures.cause!(invocation, severity: :critical, operation_id: other.id)
      send(parent, {:stray, stray})
    end)

    start_named!(["sdr", root, "cli_shape_v3_mismatch"])
    assert %{success: 1} = classify!()
    assert_received {:stray, stray}

    run = run!(ctx, ctx.reply_run)
    assert run.status == :running
    assert [invocation] = invocations!(ctx, run)
    assert {:ok, nil} = Agents.get_result_release(invocation.id, actor: ctx.agent)
    refute_crash(ctx)

    {:ok, _} = Operations.resolve_failure(stray, %{resolution_note: "seen"}, actor: ctx.admin)
    Clock.freeze(DateTime.add(run.started_at, StaleRunSweeper.stale_after_seconds() + 1, :second))
    assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)

    run = run!(ctx, run)
    assert {run.status, run.status_reason} == {:failed, :witness_mismatch}
    refute run.attention_failure_id == stray.id
    refute_crash(ctx)
  end

  test "with the server missing the run fails provider_not_running, no model call", ctx do
    assert %{discard: 1, success: 0} = classify!()

    run = run!(ctx, ctx.reply_run)
    assert {run.status, run.status_reason} == {:failed, :provider_error}
    assert run.failure_reason =~ "not running"
    assert invocations!(ctx, run) == []

    assert {:ok, failure} = Operations.get_failure(run.attention_failure_id, actor: ctx.admin)
    assert {failure.severity, failure.status} == {:critical, :open}
  end

  test "a drifted attestation fails the call and opens critical provider attention", ctx do
    start_named!("model_drift")
    assert %{success: 1} = classify!()

    run = run!(ctx, ctx.reply_run)
    assert {run.status, run.status_reason} == {:failed, :provider_error}

    assert [invocation] = invocations!(ctx, run)
    assert invocation.status == :failed

    {:ok, attention} = Operations.list_attention(actor: ctx.admin)

    assert Enum.any?(
             attention,
             &(&1.subject_id == invocation.id and &1.class == :provider_error and
                 &1.severity == :critical)
           )

    assert %{status: :drift, reason: :model_attestation_drift} = ClaudeCLI.attestation()
  end
end
