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

  require Ash.Query

  alias SdrAgent.Accounts.User
  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Guard
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

  The caller must be an active ADM or REV of the lead's tenant, for a new
  *and* an already-assigned lead; anyone else gets `Ash.Error.Forbidden`
  and nothing is written (an auditor's attempt is refused and audited by
  `SdrAgent.Audit.Guard`). The authoritative Lead row is re-read `FOR UPDATE`
  first (the supplied struct may be stale): `new` is assigned, `assigned`
  is accepted, any other state is `{:error, {:lead_not_assignable, status}}`;
  a lead with a queued or running AgentRun is `{:error, :assignment_active}`
  (an operator retry of a stopped run is `SdrAgent.Agents.retry_run/2`).
  The campaign must exist in the tenant.
  """
  def assign_lead(lead, opts) do
    actor = Keyword.get(opts, :actor)
    campaign_id = Keyword.fetch!(opts, :campaign_id)
    meta = %{resource: Sales.Lead, action: :sdr_assign_lead, subject_id: lead.id}

    Guard.run(meta, actor, fn -> assign_authorized(lead, campaign_id, actor, opts) end)
  end

  defp assign_authorized(lead, campaign_id, actor, opts) do
    with :ok <- authorize(actor, lead) do
      Audit.transaction(fn -> committed(do_assign(lead, campaign_id, actor, opts)) end)
    end
  end

  defp committed({:ok, value}), do: value
  defp committed({:error, error}), do: Repo.rollback(error)

  defp authorize(%User{role: role, status: :active, tenant_id: tenant_id}, %{tenant_id: tenant_id})
       when role in [:admin, :reviewer] and is_binary(tenant_id),
       do: :ok

  defp authorize(_actor, _lead), do: {:error, Ash.Error.Forbidden.exception([])}

  defp do_assign(lead, campaign_id, actor, opts) do
    agent = Actor.system(:agent_runtime, lead.tenant_id)
    correlation_id = Ecto.UUID.generate()

    with {:ok, lead} <- lock_lead(lead.id, actor),
         :ok <- no_active_run(lead, agent),
         {:ok, _campaign} <- Sales.fetch(Sales.Campaign, campaign_id, actor: actor),
         {:ok, lead} <- ensure_assigned(lead, opts, actor),
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

  defp ensure_assigned(lead, _opts, _actor), do: {:error, {:lead_not_assignable, lead.status}}

  # The authoritative row, locked before any audit append (lock order Lead →
  # chain head), so concurrent assignments of one lead serialise here.
  defp lock_lead(id, actor) do
    Sales.Lead
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(id == ^id and tenant_id == ^actor.tenant_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one()
    |> case do
      {:ok, %Sales.Lead{} = lead} -> {:ok, lead}
      {:ok, nil} -> {:error, Ash.Error.Query.NotFound.exception(resource: Sales.Lead)}
      error -> error
    end
  end

  defp no_active_run(lead, agent) do
    case Agents.active_runs_for_lead(lead.id, actor: agent) do
      {:ok, []} -> :ok
      {:ok, _runs} -> {:error, :assignment_active}
      error -> error
    end
  end

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
  when the run has no committed hand-off (disqualified, rejected by
  validation, refused or rolled-back enrollment). It is rebuilt only from
  the run's durable hand-off record — its `sdr.draft.completed` signal event,
  written in the hand-off transaction — and every id that record names must
  match: the `draft_proposal` Decision and its ModelInvocation of this run,
  the passed `claims_validation` and `personalization_validation` and the
  `enroll` Decision of this run, the enrollment of this run's lead and
  campaign, and the campaign sequence's step. Returns `%{run_id, lead_id,
  campaign_id, enrollment_id, sequence_step_id, recipient_contact_id,
  decision_id, model_invocation_id, output}` — `output` being the
  Zoi-validated OutreachProposal.
  """
  def proposal(run_id, opts) do
    actor = Keyword.fetch!(opts, :actor)

    with {:ok, run} <- Agents.get_run(run_id, actor: actor),
         {:ok, %{payload: %{"data" => data}}} <- handoff_event(run),
         {:ok, draft} <- decision(data["proposal_decision_id"], run, :draft_proposal, nil, actor),
         {:ok, _} <-
           decision(
             data["claims_validation_decision_id"],
             run,
             :claims_validation,
             "passed",
             actor
           ),
         {:ok, _} <-
           decision(
             data["personalization_validation_decision_id"],
             run,
             :personalization_validation,
             "passed",
             actor
           ),
         {:ok, _} <- decision(data["enrollment_decision_id"], run, :enrollment, "enroll", actor),
         true <- draft.model_invocation_id == data["model_invocation_id"],
         {:ok, invocation} <-
           Ash.get(Agents.ModelInvocation, draft.model_invocation_id, actor: actor),
         true <- invocation.agent_run_id == run.id,
         {:ok, output} <- Zoi.parse(Schemas.outreach_proposal(), invocation.parsed_output),
         {:ok, lead} <- Sales.fetch(Sales.Lead, run.lead_id, actor: actor),
         {:ok, campaign} <- Sales.fetch(Sales.Campaign, run.campaign_id, actor: actor),
         {:ok, enrollment} <-
           Sales.fetch(Sales.CampaignEnrollment, data["enrollment_id"], actor: actor),
         true <- enrollment.lead_id == lead.id and enrollment.campaign_id == campaign.id,
         {:ok, step} <- Sales.fetch(Sales.SequenceStep, data["sequence_step_id"], actor: actor),
         true <- step.sequence_id == campaign.sequence_id do
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

  # The run's durable hand-off record (read under kernel context once the
  # caller has been authorized to read the run).
  defp handoff_event(run) do
    Audit.AuditEvent
    |> Ash.Query.for_read(:read, %{}, Audit.Kernel.opts(run.tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^run.tenant_id and agent_run_id == ^run.id and
        event_type == "sdr.draft.completed" and category == :signal
    )
    |> Ash.read_one()
    |> case do
      {:ok, %{} = event} -> {:ok, event}
      _ -> :error
    end
  end

  defp decision(id, run, kind, outcome, actor) when is_binary(id) do
    case Ash.get(Agents.Decision, id, actor: actor) do
      {:ok, %{agent_run_id: run_id, kind: ^kind} = decision}
      when run_id == run.id and (is_nil(outcome) or decision.outcome == outcome) ->
        {:ok, decision}

      _ ->
        :error
    end
  end

  defp decision(_id, _run, _kind, _outcome, _actor), do: :error
end
