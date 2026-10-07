defmodule SdrAgent.SDR.Actions.ReadCompanyPage do
  @moduledoc """
  ResearchLeadFlow step "pages" (mapped over the search URLs): fetches one
  page through the configured `SdrAgent.Integrations.WebFetch` adapter and
  records it with the source type and trust level the adapter reports.
  """
  use SdrAgent.SDR.Action,
    name: "sdr_read_company_page",
    description: "One page found by search.",
    schema: Zoi.object(%{lead_id: Zoi.string(), url: Zoi.string()})

  alias SdrAgent.Integrations
  alias SdrAgent.SDR.Support

  @impl SdrAgent.SDR.Action
  def perform(%{lead_id: lead_id, url: url}, ctx) do
    with {:ok, artifact, ref} <- read(ctx, lead_id, url) do
      {:ok, %{artifacts: [artifact]}, [], [ref]}
    end
  end

  @doc "Fetches and records one page (shared with `FetchCompanyWebsite`)."
  def read(ctx, lead_id, url) do
    with {:ok, page} <- Integrations.web().fetch(url) do
      Support.record_artifact(ctx, lead_id, %{
        source_type: page.source_type,
        provider: :fixture_web,
        source_url: page.url,
        title: page.title,
        content: page.content,
        content_type: page.content_type,
        published_at: page.published_at,
        trust_level: page.trust_level,
        metadata: %{}
      })
    end
  end
end
