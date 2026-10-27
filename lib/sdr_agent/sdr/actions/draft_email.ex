defmodule SdrAgent.SDR.Actions.DraftEmail do
  @moduledoc """
  PrepareOutreachFlow steps "angle" and "draft": one model call returning a
  Zoi-validated OutreachProposal (spec §9). Two LLM Decisions cite it: the
  `angle` (output pointer `/angle`) and the `draft_proposal` (the whole
  proposal). The proposal is not trusted yet — ValidateClaims,
  ValidatePersonalization and ValidateDraftShape check it deterministically.

  Version 2 (B1-05, plan `claude-b1-research-draft-plan-r2.md`): after the
  run's pinned definition is checked to declare this version, the model
  input also carries the run's settings snapshot — the `offering` profile,
  the `writing_guide` and the `research_brief` (from which the model derives
  the angle) — read here from the snapshot, never passed through Flow
  params, outputs or agent state. It has no booking-link slot (B1 Q1). An
  unreadable snapshot is the fixed `:crash` stop of
  `SdrAgent.SDR.Preconditions`, before any model call.
  """
  use SdrAgent.SDR.Action,
    name: "sdr_draft_email",
    description: "Angle and first-touch draft (model, Zoi-validated).",
    version: "2",
    schema:
      Zoi.object(%{
        lead_id: Zoi.string(),
        claims: Zoi.list(Zoi.map()),
        triggers: Zoi.list(Zoi.map()),
        plan: Zoi.map()
      })

  alias SdrAgent.SDR.Context
  alias SdrAgent.SDR.Model
  alias SdrAgent.SDR.Preconditions

  @impl SdrAgent.SDR.Action
  def perform(%{lead_id: lead_id, claims: claims, triggers: triggers, plan: plan}, ctx) do
    with :ok <- Preconditions.declared(ctx, __MODULE__),
         {:ok, settings} <- Preconditions.settings(ctx),
         {:ok, offering, guide, brief} <- draft_settings(ctx, settings) do
      input = %{
        contact: plan.contact,
        company: plan.company,
        sender: plan.sender,
        step: %{instructions: plan.step.instructions},
        evidence: claims,
        triggers: triggers,
        offering: offering,
        writing_guide: guide,
        research_brief: brief
      }

      with {:ok, proposal, invocation} <- Model.call(ctx, :outreach_proposal, input, lead_id),
           {:ok, _angle} <-
             decide(ctx, lead_id, invocation, :angle, "/angle", "selected", proposal),
           {:ok, draft} <-
             decide(ctx, lead_id, invocation, :draft_proposal, "", "proposed", proposal) do
        {:ok, %{proposal: proposal, model_invocation_id: invocation.id, decision_id: draft.id}}
      end
    end
  end

  defp draft_settings(ctx, settings) do
    with {:ok, offering} <- Preconditions.offering(settings),
         {:ok, guide} <- Preconditions.writing_guide(settings),
         {:ok, brief} <- Preconditions.brief(settings) do
      {:ok, offering, guide, brief}
    else
      _ -> Preconditions.unavailable(ctx)
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
