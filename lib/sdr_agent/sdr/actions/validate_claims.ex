defmodule SdrAgent.SDR.Actions.ValidateClaims do
  @moduledoc """
  PrepareOutreachFlow step "claims" (deterministic, spec §9–§10): every
  proposal claim must cite an accepted evidence claim of this lead and
  appear verbatim in the body. A claim without evidence (or citing evidence
  of another lead, or not in the body) rejects the proposal. Records a
  `claims_validation` Decision.

  Limits (for the human reviewer): `passed` establishes citation
  membership and verbatim presence only — not that the cited evidence
  entails the claim, nor that the free-text body contains no other,
  uncited assertion. Tier-0 human review remains the check for those.
  """
  use SdrAgent.SDR.Action,
    name: "sdr_validate_claims",
    description: "Claims must cite accepted evidence and appear in the body.",
    schema: Zoi.object(%{lead_id: Zoi.string(), draft: Zoi.map(), claims: Zoi.list(Zoi.map())})

  alias SdrAgent.SDR.Actions.ValidatePersonalization

  @impl SdrAgent.SDR.Action
  def perform(%{lead_id: lead_id, draft: draft, claims: evidence}, ctx) do
    ValidatePersonalization.validate(ctx, lead_id, draft, evidence, %{
      kind: :claims_validation,
      rule: "sdr.claims_cite_evidence",
      items: draft.proposal.claims,
      text: & &1.claim,
      minimum: 0
    })
  end
end
