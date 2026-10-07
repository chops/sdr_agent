defmodule SdrAgent.SDR.Actions.LoadEvidenceBundle do
  @moduledoc """
  PrepareOutreachFlow step "bundle": the EvidenceBundle as recorded in
  Postgres — the lead's accepted evidence claims and its current
  Qualification (the agent state holds only their ids).
  """
  use SdrAgent.SDR.Action,
    name: "sdr_load_evidence_bundle",
    description: "Accepted evidence and the current qualification of the lead.",
    schema: Zoi.object(%{lead_id: Zoi.string()})

  alias SdrAgent.Research
  alias SdrAgent.SDR.Support

  @impl SdrAgent.SDR.Action
  def perform(%{lead_id: lead_id}, ctx) do
    with {:ok, claims} <- Support.accepted_claims(ctx, lead_id),
         {:ok, %{} = qualification} <- Research.current_qualification(lead_id, actor: ctx.actor) do
      {:ok,
       %{
         claims: Enum.map(claims, &%{id: &1.id, claim: &1.claim}),
         qualification: %{
           id: qualification.id,
           qualified: qualification.qualified,
           icp_definition_id: qualification.icp_definition_id
         }
       }}
    else
      {:ok, nil} -> {:error, :no_qualification}
      error -> error
    end
  end
end
