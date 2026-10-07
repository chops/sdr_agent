defmodule SdrAgent.SDR do
  @moduledoc """
  The agent plane's public API (spec §1 AGENT plane; build plan S7). It
  orchestrates above every domain and calls only their code interfaces with
  an explicit actor.

    * `assign_lead/2` — ADM/REV assign a lead to the agent for a campaign.
      In one transaction (outbox): the lead new → assigned, the `SDRAgent`
      AgentDefinition (registered if absent), the Oban job, its Operation,
      the queued AgentRun and the `sdr.lead.assigned` signal event.
    * `pause_campaign/2` — ADM/REV pause a campaign and record
      `sdr.campaign.paused` (the agent re-checks campaign state
      deterministically before it works or enrolls a lead).
    * `proposal/2` — the validated OutreachProposal a run handed to S8
      (`sdr.draft.completed`), reconstructed from Postgres: the
      `draft_proposal` Decision, its ModelInvocation's parsed output
      (re-validated with the Zoi schema), the enrollment and sequence step.
  """

  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.Audit
  alias SdrAgent.Operations
  alias SdrAgent.Repo
  alias SdrAgent.Sales
  alias SdrAgent.SDR.AgentWorker
  alias SdrAgent.SDR.Schemas
  alias SdrAgent.SDR.SDRAgent
  alias SdrAgent.SDR.Signals

  @doc """
  Assigns `lead` (new, or already assigned) to the agent. Options: `actor:`
  (ADM/REV), `campaign_id:`, `owner_user_id:`, `max_model_calls:` (≤ 20),
  `max_tool_calls:` (default 60), `model:` (test/demo only: `provider:`
  fake | claude_cli module, `provider_options: [responder: module]`).
  Returns `{:ok, %{lead, run, operation, job, signal}}`.
  """
  def assign_lead(lead, opts) do
    actor = Keyword.fetch!(opts, :actor)
    campaign_id = Keyword.fetch!(opts, :campaign_id)

    Audit.transaction(fn ->
      case do_assign(lead, campaign_id, actor, opts) do
        {:ok, assignment} -> assignment
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  defp do_assign(lead, campaign_id, actor, opts) do
    agent = Actor.system(:agent_runtime, lead.tenant_id)
    correlation_id = Ecto.UUID.generate()

    with {:ok, lead} <- ensure_assigned(lead, opts, actor),
         {:ok, definition} <- SDRAgent.register(lead.tenant_id),
         {:ok, signal} <-
           Signals.build("sdr.lead.assigned", %{lead_id: lead.id, campaign_id: campaign_id}),
         {:ok, job} <- Oban.insert(AgentWorker.new(job_args(lead, signal, opts))),
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
               operation_id: operation.id,
               max_model_calls: min(Keyword.get(opts, :max_model_calls, 20), 20),
               max_tool_calls: Keyword.get(opts, :max_tool_calls, 60)
             },
             actor: agent
           ),
         {:ok, _event} <- Signals.record(signal, agent, run: run) do
      {:ok, %{lead: lead, run: run, operation: operation, job: job, signal: signal}}
    end
  end

  defp ensure_assigned(%{status: :new} = lead, opts, actor) do
    attrs = if owner = opts[:owner_user_id], do: %{owner_user_id: owner}, else: %{}
    Sales.update(lead, :assign, attrs, actor: actor)
  end

  defp ensure_assigned(%{status: :assigned} = lead, _opts, _actor), do: {:ok, lead}

  defp ensure_assigned(lead, _opts, _actor),
    do:
      {:error, Ash.Error.to_error_class("lead #{lead.id} is #{lead.status}, not new or assigned")}

  defp job_args(lead, signal, opts) do
    base = %{"tenant_id" => lead.tenant_id, "signal" => Signals.dump(signal)}

    case Keyword.get(opts, :model) do
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

  @doc "ADM/REV: pauses `campaign` and records `sdr.campaign.paused`, in one transaction."
  def pause_campaign(campaign, opts) do
    actor = Keyword.fetch!(opts, :actor)

    Audit.transaction(fn ->
      with {:ok, paused} <- Sales.update(campaign, :pause, %{}, actor: actor),
           {:ok, signal} <- Signals.build("sdr.campaign.paused", %{campaign_id: campaign.id}),
           {:ok, _event} <- Signals.record(signal, actor) do
        paused
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  @doc """
  The OutreachProposal run `run_id` handed off, or `{:error, :no_proposal}`
  when the run produced none (disqualified, rejected by validation, refused
  enrollment). Returns `%{run_id, lead_id, campaign_id, enrollment_id,
  sequence_step_id, recipient_contact_id, decision_id, model_invocation_id,
  output}` — `output` being the Zoi-validated OutreachProposal.
  """
  def proposal(run_id, opts) do
    actor = Keyword.fetch!(opts, :actor)

    with {:ok, run} <- Agents.get_run(run_id, actor: actor),
         {:ok, decisions} <- Agents.list_decisions(run_id, actor: actor),
         %{} = draft <- latest(decisions, :draft_proposal),
         %{outcome: "passed"} <- latest(decisions, :claims_validation),
         %{outcome: "passed"} <- latest(decisions, :personalization_validation),
         %{outcome: "enroll"} <- latest(decisions, :enrollment),
         {:ok, invocation} <-
           Ash.get(Agents.ModelInvocation, draft.model_invocation_id, actor: actor),
         {:ok, output} <- Zoi.parse(Schemas.outreach_proposal(), invocation.parsed_output),
         {:ok, lead} <- Sales.fetch(Sales.Lead, run.lead_id, actor: actor),
         {:ok, campaign} <- Sales.fetch(Sales.Campaign, run.campaign_id, actor: actor),
         {:ok, [enrollment]} <-
           Sales.list_records(Sales.CampaignEnrollment,
             filter: [lead_id: lead.id, campaign_id: campaign.id],
             actor: actor
           ),
         {:ok, [step]} <-
           Sales.list_records(Sales.SequenceStep,
             filter: [sequence_id: campaign.sequence_id, position: 1],
             actor: actor
           ) do
      {:ok,
       %{
         run_id: run.id,
         lead_id: lead.id,
         campaign_id: campaign.id,
         enrollment_id: enrollment.id,
         sequence_step_id: step.id,
         recipient_contact_id: lead.contact_id,
         decision_id: draft.id,
         model_invocation_id: invocation.id,
         output: output
       }}
    else
      _ -> {:error, :no_proposal}
    end
  end

  defp latest(decisions, kind),
    do: decisions |> Enum.filter(&(&1.kind == kind)) |> List.last()
end
