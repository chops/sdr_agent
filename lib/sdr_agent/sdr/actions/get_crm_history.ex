defmodule SdrAgent.SDR.Actions.GetCRMHistory do
  @moduledoc """
  ResearchLeadFlow step "crm": reads the contact's CRM record and history
  through the configured `SdrAgent.Integrations.CRM` adapter and records it
  as a `crm_record` research artifact (high trust).
  """
  use SdrAgent.SDR.Action,
    name: "sdr_get_crm_history",
    description: "CRM context of the lead's contact.",
    schema: Zoi.object(%{lead_id: Zoi.string()})

  alias SdrAgent.Integrations
  alias SdrAgent.SDR.Support

  @impl SdrAgent.SDR.Action
  def perform(%{lead_id: lead_id}, ctx) do
    with {:ok, %{contact: contact}} <- Support.lead_context(ctx, lead_id),
         {:ok, record} <- Integrations.crm().fetch_contact(contact.crm_external_id),
         {:ok, artifact, ref} <-
           Support.record_artifact(ctx, lead_id, %{
             source_type: :crm_record,
             provider: :fake_crm,
             source_url: record.source_url,
             title: record.title,
             content: record.content,
             content_type: "application/json",
             trust_level: :high,
             metadata: %{"crm_external_id" => contact.crm_external_id}
           }) do
      {:ok, %{artifacts: [artifact]}, [], [ref]}
    end
  end
end
