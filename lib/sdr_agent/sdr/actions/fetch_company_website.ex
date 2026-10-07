defmodule SdrAgent.SDR.Actions.FetchCompanyWebsite do
  @moduledoc """
  ResearchLeadFlow step "company": fetches the account's website through
  the configured `SdrAgent.Integrations.WebFetch` adapter and records it.
  """
  use SdrAgent.SDR.Action,
    name: "sdr_fetch_company_website",
    description: "The company's own website.",
    schema: Zoi.object(%{lead_id: Zoi.string()})

  alias SdrAgent.SDR.Actions.ReadCompanyPage
  alias SdrAgent.SDR.Support

  @impl SdrAgent.SDR.Action
  def perform(%{lead_id: lead_id}, ctx) do
    with {:ok, %{account: account}} <- Support.lead_context(ctx, lead_id),
         {:ok, artifact, ref} <- ReadCompanyPage.read(ctx, lead_id, account.website_url) do
      {:ok, %{artifacts: [artifact], website_url: account.website_url}, [], [ref]}
    end
  end
end
