defmodule SdrAgent.SDR.Actions.HandOffProposal do
  @moduledoc """
  PrepareOutreachFlow step "proposal": the OutreachProposal hand-off to S8.

  A proposal that failed deterministic validation fails the run as invalid
  model output (operator attention) and is never handed off.

  A valid one is handed off in *one transaction*: the Lead row is locked
  `FOR UPDATE`, the Campaign, the recipient Contact and the AgentRun
  `FOR SHARE` before anything is appended to the audit chain (lock order
  Lead → Campaign → Contact → AgentRun → chain head; a concurrent operator
  stop, campaign pause, contact edit or run cancel either commits first and
  is seen here, or waits). The Contact and the AgentRun are the mutable
  parents the new Draft's foreign keys reference: locking them first means
  the Draft insert never waits for one of them while this transaction holds
  the chain head (review #13 MF2; the other parents are locked above, new in
  this transaction, or immutable), the deterministic gates (campaign active, recipient not
  suppressed) and the `enrollment` Decision are recorded against those
  rows, and on `enroll` the CampaignEnrollment, the Lead qualified →
  in_outreach transition and the durable hand-off record — the
  `sdr.draft.completed` signal event naming the run's exact draft,
  validation and enrollment Decisions, ModelInvocation, enrollment and
  sequence step — commit together or not at all. S8 creates the Draft from
  that record (`SdrAgent.SDR.proposal/2`, read inside the same transaction):
  the Draft and its agent revision 1 with citations
  (`SdrAgent.Outreach.propose_draft/2`) commit with the hand-off, so a
  committed hand-off always has its draft awaiting review. A refused
  enrollment ends the assignment.
  """
  use SdrAgent.SDR.Action,
    name: "sdr_hand_off_proposal",
    description: "Enroll the lead and hand the validated proposal to review.",
    schema:
      Zoi.object(%{
        lead_id: Zoi.string(),
        draft: Zoi.map(),
        claims_check: Zoi.map(),
        personalization_check: Zoi.map(),
        plan: Zoi.map()
      })

  require Ash.Query

  alias SdrAgent.Agents
  alias SdrAgent.Audit
  alias SdrAgent.Outreach
  alias SdrAgent.Repo
  alias SdrAgent.Sales
  alias SdrAgent.SDR.Context
  alias SdrAgent.SDR.Model
  alias SdrAgent.SDR.Signals
  alias SdrAgent.SDR.Support

  @impl SdrAgent.SDR.Action
  def perform(
        %{claims_check: %{passed: true}, personalization_check: %{passed: true}} = params,
        ctx
      ) do
    Audit.transaction(fn ->
      case hand_off(params, ctx) do
        {:ok, state} -> state
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  def perform(_params, ctx) do
    Model.halt_fail(
      ctx,
      nil,
      :invalid_model_output,
      "outreach proposal failed deterministic validation"
    )
  end

  defp hand_off(%{lead_id: lead_id, plan: plan} = params, ctx) do
    with {:ok, lead} <- lock(ctx, Sales.Lead, lead_id, :for_update),
         {:ok, campaign} <- lock(ctx, Sales.Campaign, plan.campaign_id, "FOR SHARE"),
         {:ok, contact} <- lock(ctx, Sales.Contact, lead.contact_id, "FOR SHARE"),
         {:ok, _run} <- lock(ctx, Agents.AgentRun, ctx.run_id, "FOR SHARE"),
         {:ok, campaign_check} <- Support.campaign_gate(ctx, campaign, lead_id, "enroll"),
         {:ok, suppression} <- Support.suppression_gate(ctx, contact, lead_id, "enroll") do
      enroll? =
        lead.status == :qualified and campaign_check.outcome == "active" and
          suppression.outcome == "not_suppressed"

      with {:ok, decision} <- enrollment_decision(ctx, lead, campaign_check, suppression, enroll?) do
        enroll(enroll?, ctx, lead, campaign, params, decision)
      end
    end
  end

  defp lock(%Context{} = ctx, resource, id, lock) do
    resource
    |> Ash.Query.for_read(:read, %{}, actor: ctx.actor)
    |> Ash.Query.filter(id == ^id and tenant_id == ^ctx.tenant_id)
    |> Ash.Query.lock(lock)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, Ash.Error.Query.NotFound.exception(resource: resource)}
      other -> other
    end
  end

  defp enrollment_decision(ctx, lead, campaign_check, suppression, enroll?) do
    Context.decide(
      ctx,
      %{
        kind: :enrollment,
        mode: :deterministic,
        rule_id: "sdr.enrollment",
        rule_version: "1",
        subject_id: lead.id,
        inputs: %{
          "lead_status" => Atom.to_string(lead.status),
          "campaign_state_check" => campaign_check.id,
          "suppression_check" => suppression.id
        },
        outcome: if(enroll?, do: "enroll", else: "refused")
      },
      "enroll",
      [lead]
    )
  end

  defp enroll(false, ctx, _lead, _campaign, _params, _decision),
    do: {:ok, %{ctx.agent_state | phase: :stop}}

  defp enroll(true, ctx, lead, campaign, params, decision) do
    %{draft: draft, plan: plan} = params

    with {:ok, enrollment} <-
           Sales.enroll_lead(%{campaign_id: campaign.id, lead_id: lead.id}, actor: ctx.actor),
         {:ok, _lead} <-
           Sales.update(lead, :start_outreach, %{decision_id: decision.id}, actor: ctx.actor),
         {:ok, run} <- Agents.get_run(ctx.run_id, actor: ctx.actor),
         {:ok, signal} <-
           Signals.build("sdr.draft.completed", %{
             lead_id: lead.id,
             campaign_id: campaign.id,
             enrollment_id: enrollment.id,
             sequence_step_id: plan.step.id,
             recipient_contact_id: lead.contact_id,
             proposal_decision_id: draft.decision_id,
             model_invocation_id: draft.model_invocation_id,
             claims_validation_decision_id: params.claims_check.decision_id,
             personalization_validation_decision_id: params.personalization_check.decision_id,
             enrollment_decision_id: decision.id
           }),
         {:ok, _event} <- Signals.record(signal, ctx.actor, run: run, parent: ctx.signal_id),
         {:ok, proposal} <- SdrAgent.SDR.proposal(ctx.run_id, actor: ctx.actor),
         {:ok, _draft} <- Outreach.propose_draft(draft_attrs(proposal), actor: ctx.actor) do
      {:ok,
       ctx.agent_state
       |> Map.put(:phase, :review)
       |> Map.put(:proposal_id, draft.decision_id)}
    end
  end

  # The Draft and its agent revision 1, rebuilt from the committed hand-off
  # record (`SdrAgent.SDR.proposal/2`, read inside this transaction).
  defp draft_attrs(%{output: output} = proposal) do
    claims =
      for claim <- output.claims,
          do: %{
            evidence_claim_id: claim.evidence_id,
            kind: :claim,
            text: claim.claim,
            confidence: claim.confidence
          }

    personalization =
      for item <- output.personalization,
          do: %{evidence_claim_id: item.evidence_id, kind: :personalization, text: item.text}

    %{
      lead_id: proposal.lead_id,
      enrollment_id: proposal.enrollment_id,
      sequence_step_id: proposal.sequence_step_id,
      campaign_id: proposal.campaign_id,
      recipient_contact_id: proposal.recipient_contact_id,
      origin_agent_run_id: proposal.run_id,
      subject: output.subject,
      body_text: output.body,
      angle: output.angle,
      cta: output.cta,
      risk_flags: output.risk_flags,
      decision_id: proposal.decision_id,
      model_invocation_id: proposal.model_invocation_id,
      citations:
        Enum.uniq_by(claims ++ personalization, &{&1.evidence_claim_id, &1.kind, &1.text})
    }
  end
end
