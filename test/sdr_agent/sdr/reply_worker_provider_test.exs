defmodule SdrAgent.SDR.ReplyWorkerProviderTest do
  @moduledoc """
  Q0.1 review: reply classification (`SdrAgent.SDR.ReplyWorker`) on the
  runtime-selected ClaudeCLI. Through the one named server (backed by the
  hermetic fake CLI) a matched reply is classified and handed off; with the
  server missing the run fails `provider_error` with its critical Failure
  and no model call (no reservation), the job returning `{:error,
  :provider_not_running}`; a drifted attestation fails the invocation and
  opens the critical `provider_error` Failure on it.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures
  import SdrAgent.WebhookFixtures

  alias SdrAgent.Agents
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Operations
  alias SdrAgent.Outreach

  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)

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

  defp start_named!(mode) do
    start_supervised!(
      {ClaudeCLI,
       name: ClaudeCLI.server(),
       command: System.find_executable("elixir"),
       command_args: [@fake, mode]}
    )
  end

  defp classify!, do: Oban.drain_queue(queue: :agent, with_safety: false)

  test "a reply is classified through the named server", ctx do
    start_named!("sdr")
    assert %{success: 1} = classify!()

    run = run!(ctx, ctx.reply_run)
    assert run.status == :succeeded, inspect({run.status_reason, run.failure_reason})

    assert [invocation] = invocations!(ctx, run)

    assert {invocation.provider, invocation.model_id, invocation.purpose, invocation.status} ==
             {:claude_cli, "claude-opus-5-5", :reply_classification, :completed}

    {:ok, [assessment]} = Outreach.list_records(Outreach.ReplyAssessment, actor: ctx.admin)
    assert {assessment.classification, assessment.source} == {:interested, :agent}
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
