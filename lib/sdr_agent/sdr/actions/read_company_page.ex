defmodule SdrAgent.SDR.Actions.ReadCompanyPage do
  @moduledoc """
  ResearchLeadFlow step "pages" (mapped over the search URLs): fetches one
  page through the configured `SdrAgent.Integrations.WebFetch` adapter and
  records it with the source type and trust level the adapter reports.

  D-237 prototype runtime (supplement 1 r2 section 6a): the page is the
  dossier source whose `final_url` is the URL, read only through
  `SdrAgent.Research.read_dossier_sources/4`; its bytes are recorded
  unchanged (`ResearchArtifact :record` binds them to the source).
  """
  use SdrAgent.SDR.Action,
    name: "sdr_read_company_page",
    description: "One page found by search.",
    schema: Zoi.object(%{lead_id: Zoi.string(), url: Zoi.string()})

  alias SdrAgent.Integrations
  alias SdrAgent.SDR.Support

  @prototype_compiled Application.compile_env(:sdr_agent, :prototype_authority_compiled, false)

  @impl SdrAgent.SDR.Action
  def perform(%{lead_id: lead_id, url: url}, ctx) do
    with {:ok, artifact, ref} <- read(ctx, lead_id, url) do
      {:ok, %{artifacts: [artifact]}, [], [ref]}
    end
  end

  @doc "Fetches and records one page (shared with `FetchCompanyWebsite`)."
  def read(ctx, lead_id, url), do: dispatch(ctx, lead_id, url)

  @doc """
  Records one source returned by `SdrAgent.Research.read_dossier_sources/4`
  (shared with `SearchCompany`): its bytes unchanged, its `final_url` as the
  source URL, a company-site source as `:company_website`, any other as
  `:web_page`.
  """
  def record_source(ctx, lead_id, source) do
    Support.record_artifact(ctx, lead_id, %{
      source_type: page_type(source.source_type),
      provider: :public_dossier,
      source_url: source.final_url,
      title: nil,
      content: source.content,
      content_type: "text/plain",
      published_at: nil,
      trust_level: :unverified,
      metadata: %{}
    })
  end

  if @prototype_compiled do
    alias SdrAgent.Research

    defp dispatch(ctx, lead_id, url) do
      if SdrAgent.Prototype.runtime() == :prototype,
        do: read_dossier(ctx, lead_id, url),
        else: fetch(ctx, lead_id, url)
    end

    defp read_dossier(ctx, lead_id, url) do
      with {:ok, [source]} <-
             Research.read_dossier_sources(ctx.run_id, lead_id, {:final_url, url}, ctx.actor) do
        record_source(ctx, lead_id, source)
      end
    end
  else
    # No prototype authority in a production build: always the adapter.
    defp dispatch(ctx, lead_id, url), do: fetch(ctx, lead_id, url)
  end

  defp fetch(ctx, lead_id, url) do
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

  defp page_type(:company_site), do: :company_website
  defp page_type(_other), do: :web_page
end
