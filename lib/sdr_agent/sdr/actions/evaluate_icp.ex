defmodule SdrAgent.SDR.Actions.EvaluateICP do
  @moduledoc """
  PrepareOutreachFlow step "icp": checks the qualification is still the
  current, qualified result against the campaign's ICP version, and gathers
  what the draft needs — ICP criteria, the first sequence step's
  instructions, the sender, and the recipient's and company's names.
  """
  use SdrAgent.SDR.Action,
    name: "sdr_evaluate_icp",
    description: "ICP, sequence step and sender for the first touch.",
    schema: Zoi.object(%{lead_id: Zoi.string(), qualification: Zoi.map()})

  alias SdrAgent.Sales
  alias SdrAgent.SDR.Support

  @impl SdrAgent.SDR.Action
  def perform(%{lead_id: lead_id, qualification: qualification}, ctx) do
    with {:ok, %{contact: contact, account: account}} <- Support.lead_context(ctx, lead_id),
         {:ok, campaign} <- Support.fetch(ctx, Sales.Campaign, ctx.agent_state.campaign_id),
         {:ok, icp} <- Support.fetch(ctx, Sales.IcpDefinition, campaign.icp_definition_id),
         :ok <- current(qualification, icp),
         {:ok, [step | _]} <-
           Sales.list_records(Sales.SequenceStep,
             filter: [sequence_id: campaign.sequence_id, position: 1],
             actor: ctx.actor
           ) do
      {:ok,
       %{
         icp: %{triggers: icp.criteria.triggers, personas: icp.criteria.personas},
         campaign_id: campaign.id,
         step: %{id: step.id, instructions: step.instructions},
         sender: %{name: campaign.sender_name},
         contact: %{first_name: contact.first_name, title: contact.title},
         company: %{name: account.name}
       }}
    end
  end

  defp current(%{qualified: true, icp_definition_id: id}, %{id: id}), do: :ok
  defp current(_qualification, _icp), do: {:error, :qualification_not_current}
end
