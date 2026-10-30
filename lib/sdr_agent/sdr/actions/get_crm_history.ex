defmodule SdrAgent.SDR.Actions.GetCRMHistory do
  @moduledoc """
  ResearchLeadFlow step "crm": reads the contact's CRM record and history
  through the configured `SdrAgent.Integrations.CRM` adapter and records it
  as a `crm_record` research artifact (high trust).

  D-237 prototype runtime (D-268 M8): an imported dossier contact has no
  CRM record, so the step calls no CRM adapter and records no artifact; it
  never invents CRM evidence. A production build always uses the adapter.
  """
  use SdrAgent.SDR.Action,
    name: "sdr_get_crm_history",
    description: "CRM context of the lead's contact.",
    schema: Zoi.object(%{lead_id: Zoi.string()})

  alias SdrAgent.Integrations
  alias SdrAgent.SDR.Support

  @prototype_compiled Application.compile_env(:sdr_agent, :prototype_authority_compiled, false)

  @impl SdrAgent.SDR.Action
  def perform(%{lead_id: lead_id}, ctx), do: dispatch(ctx, lead_id)

  if @prototype_compiled do
    defp dispatch(ctx, lead_id) do
      if SdrAgent.Prototype.runtime() == :prototype,
        do: {:ok, %{artifacts: []}, [], []},
        else: fetch(ctx, lead_id)
    end
  else
    # No prototype authority in a production build: always the adapter.
    defp dispatch(ctx, lead_id), do: fetch(ctx, lead_id)
  end

  defp fetch(ctx, lead_id) do
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
