defmodule SdrAgent.SDR.Flows.PrepareOutreachFlow do
  @moduledoc """
  PrepareOutreachFlow (spec §7): EvidenceBundle → ICP → trigger → angle →
  draft → validate claims → validate personalization → OutreachProposal.
  One Jido Flow, one agent turn (`sdr.draft.requested`):

    * "bundle" — `LoadEvidenceBundle` (accepted claims, current qualification);
    * "icp" — `EvaluateICP` (still qualified against the campaign's ICP;
      sequence step, sender);
    * "trigger" — `IdentifyTrigger`;
    * "draft" — `DraftEmail`: the model's OutreachProposal with its `angle`
      and `draft_proposal` Decisions;
    * "claims" — `ValidateClaims`, "personalization" —
      `ValidatePersonalization`: deterministic evidence checks;
    * "proposal" — `HandOffProposal`: enrollment gate, lead → in_outreach,
      `sdr.draft.completed` to S8; returns the complete agent state.

  There is no send step: delivery is S8 (Ash approval + Oban outbox).
  """
  use Jido.Flow,
    name: "sdr_prepare_outreach_flow",
    description: "Prepare an evidence-grounded OutreachProposal for human review.",
    schema: Zoi.object(%{lead_id: Zoi.string()})

  alias SdrAgent.SDR.Actions

  flow do
    step "bundle", action: Actions.LoadEvidenceBundle, params: %{lead_id: input(:lead_id)}

    step "icp",
      action: Actions.EvaluateICP,
      params: %{lead_id: input(:lead_id), qualification: result("bundle", :qualification)}

    step "trigger",
      action: Actions.IdentifyTrigger,
      params: %{claims: result("bundle", :claims), icp: result("icp", :icp)}

    step "draft",
      action: Actions.DraftEmail,
      params: %{
        lead_id: input(:lead_id),
        claims: result("bundle", :claims),
        triggers: result("trigger", :triggers),
        plan: result("icp")
      }

    step "claims",
      action: Actions.ValidateClaims,
      params: %{
        lead_id: input(:lead_id),
        draft: result("draft"),
        claims: result("bundle", :claims)
      }

    step "personalization",
      action: Actions.ValidatePersonalization,
      params: %{
        lead_id: input(:lead_id),
        draft: result("draft"),
        claims: result("bundle", :claims)
      }

    step "proposal",
      action: Actions.HandOffProposal,
      params: %{
        lead_id: input(:lead_id),
        draft: result("draft"),
        claims_check: result("claims"),
        personalization_check: result("personalization"),
        plan: result("icp")
      }

    output(result("proposal"))
  end
end
