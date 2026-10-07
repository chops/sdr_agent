defmodule SdrAgent.SDR.Actions.DraftEmail do
  @moduledoc """
  PrepareOutreachFlow steps "angle" and "draft": one model call returning a
  Zoi-validated OutreachProposal (spec §9). Two LLM Decisions cite it: the
  `angle` (output pointer `/angle`) and the `draft_proposal` (the whole
  proposal). The proposal is not trusted yet — ValidateClaims and
  ValidatePersonalization check it deterministically.
  """
  use SdrAgent.SDR.Action,
    name: "sdr_draft_email",
    description: "Angle and first-touch draft (model, Zoi-validated).",
    schema:
      Zoi.object(%{
        lead_id: Zoi.string(),
        claims: Zoi.list(Zoi.map()),
        triggers: Zoi.list(Zoi.map()),
        plan: Zoi.map()
      })

  alias SdrAgent.SDR.Context
  alias SdrAgent.SDR.Model

  @impl SdrAgent.SDR.Action
  def perform(%{lead_id: lead_id, claims: claims, triggers: triggers, plan: plan}, ctx) do
    input = %{
      contact: plan.contact,
      company: plan.company,
      sender: plan.sender,
      step: %{instructions: plan.step.instructions},
      evidence: claims,
      triggers: triggers
    }

    with {:ok, proposal, invocation} <- Model.call(ctx, :outreach_proposal, input, lead_id),
         {:ok, _angle} <- decide(ctx, lead_id, invocation, :angle, "/angle", "selected", proposal),
         {:ok, draft} <-
           decide(ctx, lead_id, invocation, :draft_proposal, "", "proposed", proposal) do
      {:ok, %{proposal: proposal, model_invocation_id: invocation.id, decision_id: draft.id}}
    end
  end

  defp decide(ctx, lead_id, invocation, kind, pointer, outcome, proposal) do
    Context.decide(
      ctx,
      %{
        kind: kind,
        mode: :llm,
        subject_id: lead_id,
        model_invocation_id: invocation.id,
        output_pointer: pointer,
        inputs: %{"evidence_ids" => proposal.evidence_ids},
        outcome: outcome,
        outcome_detail: %{"angle" => proposal.angle},
        rationale: proposal.angle
      },
      "draft"
    )
  end
end
