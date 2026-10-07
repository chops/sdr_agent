defmodule SdrAgent.SDR.ReplyIntake do
  @moduledoc """
  Agent-plane implementation of `SdrAgent.Outreach.ReplyIntake`, run inside
  the matched reply's transaction (outbox): registers (or reuses) the
  `SDRAgent` definition, creates the queued AgentRun that will classify the
  reply (AGT; lead and campaign of the match; a small budget — one model
  call), inserts its `agent`-queue job (`SdrAgent.SDR.ReplyWorker`) and
  records the `sdr.reply.received` signal (data `reply_id`, `lead_id`,
  `campaign_id`, `enrollment_id`; actor the webhook ingestor) on that run.
  """
  @behaviour SdrAgent.Outreach.ReplyIntake

  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.SDR.ReplyWorker
  alias SdrAgent.SDR.SDRAgent
  alias SdrAgent.SDR.Signals

  @impl true
  def received(reply, match, actor) do
    agent = Actor.system(:agent_runtime, reply.tenant_id)

    with {:ok, definition} <- SDRAgent.register(reply.tenant_id),
         {:ok, signal} <-
           Signals.build("sdr.reply.received", %{
             reply_id: reply.id,
             lead_id: match.lead_id,
             campaign_id: match.campaign_id,
             enrollment_id: match.enrollment_id
           }),
         {:ok, run} <-
           Agents.create_run(
             %{
               agent_definition_id: definition.id,
               lead_id: match.lead_id,
               campaign_id: match.campaign_id,
               trigger_signal_type: signal.type,
               trigger_signal_id: signal.id,
               correlation_id: reply.webhook_event_id,
               phase: :reply,
               max_model_calls: 2,
               max_tool_calls: 5
             },
             actor: agent
           ),
         {:ok, _job} <-
           %{"tenant_id" => reply.tenant_id, "run_id" => run.id, "signal" => Signals.dump(signal)}
           |> ReplyWorker.new()
           |> Oban.insert(),
         {:ok, _event} <- Signals.record(signal, actor, run: run),
         do: :ok
  end
end
