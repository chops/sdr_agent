defmodule SdrAgent.SDR.Assignment do
  @moduledoc """
  The queue part of a lead assignment (C3-02 G4; plan r8 section 6.3),
  shared by standalone `SdrAgent.SDR.assign_lead/2` and the lead admission
  (`SdrAgent.SDR.admit_lead/2`). It runs inside the caller's transaction,
  on a lead the caller has already locked, checked and assigned, and
  writes, in order: the `sdr.lead.assigned` signal, the Oban job, its
  Operation, the queued AgentRun (bound to its run settings snapshot under
  the chain head, `Agents.Changes.BuildSettingsSnapshot`) and the signal
  event. It reads and registers no definition: the caller passes the
  committed `SDRAgent` definition it looked up. It writes nothing else and
  decides nothing about the lead.
  """

  alias SdrAgent.Agents
  alias SdrAgent.Operations
  alias SdrAgent.SDR.AgentWorker
  alias SdrAgent.SDR.Signals

  @doc """
  Queues the agent's work for `lead`. Options (all required unless noted):
  `campaign_id:`; `definition:` (the committed `SDRAgent` definition);
  `usage_origin:` (server-owned, e.g. `:assignment`; never input);
  `agent:` (the agent runtime actor); `correlation_id:`; `job_opts:`
  (optional, default `[]`: `model:` for test/demo, `max_model_calls:` and
  `max_tool_calls:`, which may only lower the snapshot's limits).
  Returns `{:ok, %{lead, run, operation, job, signal}}` or the first
  `{:error, reason}`; the caller rolls its transaction back on an error.
  """
  def queue(lead, opts) do
    campaign_id = Keyword.fetch!(opts, :campaign_id)
    definition = Keyword.fetch!(opts, :definition)
    agent = Keyword.fetch!(opts, :agent)
    correlation_id = Keyword.fetch!(opts, :correlation_id)
    job_opts = Keyword.get(opts, :job_opts, [])

    with {:ok, signal} <-
           Signals.build("sdr.lead.assigned", %{lead_id: lead.id, campaign_id: campaign_id}),
         {:ok, job} <- Oban.insert(AgentWorker.new(job_args(lead, signal, job_opts))),
         {:ok, operation} <-
           Operations.create_operation(
             %{
               kind: :research_lead,
               queue: :research,
               oban_job_id: job.id,
               subject_resource: "SdrAgent.Sales.Lead",
               subject_id: lead.id,
               idempotency_key: "assignment:#{lead.id}:#{signal.id}",
               correlation_id: correlation_id,
               max_attempts: 1
             },
             actor: agent
           ),
         {:ok, run} <-
           Agents.create_run(
             %{
               agent_definition_id: definition.id,
               lead_id: lead.id,
               campaign_id: campaign_id,
               trigger_signal_type: signal.type,
               trigger_signal_id: signal.id,
               correlation_id: correlation_id,
               phase: :discover,
               usage_origin: Keyword.fetch!(opts, :usage_origin),
               operation_id: operation.id,
               max_model_calls: Keyword.get(job_opts, :max_model_calls),
               max_tool_calls: Keyword.get(job_opts, :max_tool_calls)
             },
             actor: agent
           ),
         {:ok, _event} <- Signals.record(signal, agent, run: run) do
      {:ok, %{lead: lead, run: run, operation: operation, job: job, signal: signal}}
    end
  end

  defp job_args(lead, signal, job_opts) do
    base = %{"tenant_id" => lead.tenant_id, "signal" => Signals.dump(signal)}

    case Keyword.get(job_opts, :model) do
      nil ->
        base

      model ->
        responder = get_in(model, [:provider_options, :responder])

        provider =
          if model[:provider] == SdrAgent.AI.ModelProvider.ClaudeCLI,
            do: "claude_cli",
            else: "fake"

        Map.put(base, "model", %{
          "provider" => provider,
          "responder" => responder && inspect(responder)
        })
    end
  end
end
