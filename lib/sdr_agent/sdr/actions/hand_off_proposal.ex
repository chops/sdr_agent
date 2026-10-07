defmodule SdrAgent.SDR.Actions.HandOffProposal do
  @moduledoc """
  PrepareOutreachFlow step "proposal": the OutreachProposal hand-off to S8.

  A proposal that failed deterministic validation fails the run as invalid
  model output (operator attention) and is never handed off. A valid one is
  gated again deterministically (campaign active, recipient not suppressed)
  and recorded as an `enrollment` Decision; enrolling then creates the
  CampaignEnrollment and moves the lead qualified → in_outreach (citing that
  Decision), and `sdr.draft.completed` carries the proposal's ids to S8,
  which creates the Draft and its revision. A refused enrollment ends the
  assignment.
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

  alias SdrAgent.Sales
  alias SdrAgent.SDR.Context
  alias SdrAgent.SDR.Model
  alias SdrAgent.SDR.Support

  @impl SdrAgent.SDR.Action
  def perform(
        %{claims_check: %{passed: true}, personalization_check: %{passed: true}} = params,
        ctx
      ) do
    %{lead_id: lead_id, draft: draft, plan: plan} = params

    with {:ok, %{lead: lead, contact: contact}} <- Support.lead_context(ctx, lead_id),
         {:ok, campaign} <- Support.fetch(ctx, Sales.Campaign, plan.campaign_id),
         {:ok, campaign_check} <- Support.campaign_gate(ctx, campaign, lead_id, "enroll"),
         {:ok, suppression} <- Support.suppression_gate(ctx, contact, lead_id, "enroll") do
      enroll? =
        lead.status == :qualified and campaign_check.outcome == "active" and
          suppression.outcome == "not_suppressed"

      with {:ok, decision} <- enrollment_decision(ctx, lead, campaign_check, suppression, enroll?) do
        enroll(enroll?, ctx, lead, campaign, draft, plan, decision)
      end
    end
  end

  def perform(_params, ctx) do
    Model.halt_fail(
      ctx,
      nil,
      :invalid_model_output,
      "outreach proposal failed deterministic validation"
    )
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

  defp enroll(false, ctx, _lead, _campaign, _draft, _plan, _decision),
    do: {:ok, %{ctx.agent_state | phase: :stop}}

  defp enroll(true, ctx, lead, campaign, draft, plan, decision) do
    with {:ok, enrollment} <-
           Sales.enroll_lead(%{campaign_id: campaign.id, lead_id: lead.id}, actor: ctx.actor),
         {:ok, _lead} <-
           Sales.update(lead, :start_outreach, %{decision_id: decision.id}, actor: ctx.actor) do
      {:ok,
       ctx.agent_state |> Map.put(:phase, :review) |> Map.put(:proposal_id, draft.decision_id),
       [
         Support.emit("sdr.draft.completed", %{
           lead_id: lead.id,
           campaign_id: campaign.id,
           enrollment_id: enrollment.id,
           sequence_step_id: plan.step.id,
           recipient_contact_id: lead.contact_id,
           proposal_decision_id: draft.decision_id,
           model_invocation_id: draft.model_invocation_id
         })
       ]}
    end
  end
end
