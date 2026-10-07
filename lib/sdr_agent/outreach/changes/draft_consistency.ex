defmodule SdrAgent.Outreach.Changes.DraftConsistency do
  @moduledoc """
  Draft `:propose` invariants, checked in the create transaction against the
  rows it names: the lead is `in_outreach`; the enrollment is `active` and
  is this lead's enrollment in this campaign; the sequence step belongs to
  the campaign's sequence; the recipient is the lead's contact; the origin
  agent run worked this lead.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Sales.Campaign
  alias SdrAgent.Sales.CampaignEnrollment
  alias SdrAgent.Sales.Lead
  alias SdrAgent.Sales.SequenceStep

  @impl true
  def change(changeset, _opts, _context), do: Ash.Changeset.before_action(changeset, &check/1)

  defp check(changeset) do
    get = &Ash.Changeset.get_attribute(changeset, &1)
    lead = read(Lead, get.(:lead_id))
    enrollment = read(CampaignEnrollment, get.(:enrollment_id))
    campaign = read(Campaign, get.(:campaign_id))
    step = read(SequenceStep, get.(:sequence_step_id))
    run = read(AgentRun, get.(:origin_agent_run_id))
    recipient = get.(:recipient_contact_id)

    [
      {:lead_id, "must be in outreach", match?(%{status: :in_outreach}, lead)},
      {:enrollment_id, "must be the lead's active enrollment in the campaign",
       enrollment_of?(enrollment, lead, campaign)},
      {:sequence_step_id, "must be a step of the campaign's sequence", step_of?(step, campaign)},
      {:recipient_contact_id, "must be the lead's contact",
       match?(%{contact_id: ^recipient}, lead)},
      {:origin_agent_run_id, "must be a run of this lead", run_of?(run, lead)}
    ]
    |> Enum.reject(&elem(&1, 2))
    |> Enum.reduce(changeset, fn {field, message, _}, acc ->
      Ash.Changeset.add_error(acc, field: field, message: message)
    end)
  end

  defp enrollment_of?(
         %{status: :active, lead_id: lead_id, campaign_id: campaign_id},
         %{id: lead_id},
         %{
           id: campaign_id
         }
       ),
       do: true

  defp enrollment_of?(_enrollment, _lead, _campaign), do: false

  defp step_of?(%{sequence_id: id}, %{sequence_id: id}) when is_binary(id), do: true
  defp step_of?(_step, _campaign), do: false

  defp run_of?(%{lead_id: id}, %{id: id}), do: true
  defp run_of?(_run, _lead), do: false

  defp read(_resource, nil), do: nil

  # Internal invariant reads; nothing read here is returned to the caller.
  defp read(resource, id),
    do: resource |> Ash.Query.filter(id == ^id) |> Ash.read_one!(authorize?: false)
end
