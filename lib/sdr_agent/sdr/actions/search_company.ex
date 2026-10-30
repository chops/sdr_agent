defmodule SdrAgent.SDR.Actions.SearchCompany do
  @moduledoc """
  ResearchLeadFlow step "search": recent-information search for the company
  through the configured `SdrAgent.Integrations.SearchProvider`. Each result
  snippet is recorded as a low-trust `search_result` artifact; the result
  URLs other than the company website (already fetched) are returned for
  the "pages" step.

  D-237 prototype runtime (supplement 1 r2 section 6a, Codex C1 ruling):
  no search adapter is called. Every dossier source of the run's lead
  entry other than the website (already recorded) is read through
  `SdrAgent.Research.read_dossier_sources/4` and recorded once, unchanged;
  no URL is returned, so the "pages" step records nothing twice.
  """
  use SdrAgent.SDR.Action,
    name: "sdr_search_company",
    description: "Recent information about the company.",
    schema: Zoi.object(%{lead_id: Zoi.string(), website_url: Zoi.string()})

  alias SdrAgent.Integrations
  alias SdrAgent.SDR.Support

  @prototype_compiled Application.compile_env(:sdr_agent, :prototype_authority_compiled, false)

  @impl SdrAgent.SDR.Action
  def perform(%{lead_id: lead_id, website_url: website_url}, ctx),
    do: dispatch(ctx, lead_id, website_url)

  if @prototype_compiled do
    alias SdrAgent.Research
    alias SdrAgent.SDR.Actions.ReadCompanyPage

    defp dispatch(ctx, lead_id, website_url) do
      if SdrAgent.Prototype.runtime() == :prototype,
        do: dossier(ctx, lead_id, website_url),
        else: search(ctx, lead_id, website_url)
    end

    defp dossier(ctx, lead_id, website_url) do
      with {:ok, sources} <- Research.read_dossier_sources(ctx.run_id, lead_id, :all, ctx.actor),
           {:ok, recorded} <-
             record_sources(
               ctx,
               lead_id,
               Enum.reject(sources, &same_url?(&1.final_url, website_url))
             ) do
        {artifacts, refs} = Enum.unzip(recorded)
        {:ok, %{artifacts: artifacts, urls: []}, [], refs}
      end
    end

    defp record_sources(ctx, lead_id, sources) do
      Enum.reduce_while(sources, {:ok, []}, fn source, {:ok, acc} ->
        case ReadCompanyPage.record_source(ctx, lead_id, source) do
          {:ok, artifact, ref} -> {:cont, {:ok, acc ++ [{artifact, ref}]}}
          error -> {:halt, error}
        end
      end)
    end
  else
    # No prototype authority in a production build: always the adapter.
    defp dispatch(ctx, lead_id, website_url), do: search(ctx, lead_id, website_url)
  end

  defp search(ctx, lead_id, website_url) do
    with {:ok, %{account: account}} <- Support.lead_context(ctx, lead_id),
         {:ok, results} <- Integrations.search().search(account.name, domain: account.domain),
         {:ok, recorded} <- record_all(ctx, lead_id, results) do
      urls =
        results
        |> Enum.map(& &1.url)
        |> Enum.reject(&same_url?(&1, website_url))
        |> Enum.uniq()

      {artifacts, refs} = Enum.unzip(recorded)
      {:ok, %{artifacts: artifacts, urls: urls}, [], refs}
    end
  end

  defp same_url?(url, website_url),
    do: String.trim_trailing(url, "/") == String.trim_trailing(website_url, "/")

  defp record_all(ctx, lead_id, results) do
    Enum.reduce_while(results, {:ok, []}, fn result, {:ok, acc} ->
      case Support.record_artifact(ctx, lead_id, %{
             source_type: :search_result,
             provider: :fixture_search,
             source_url: result.url,
             title: result.title,
             content: result.snippet,
             published_at: result.published_at,
             trust_level: :low,
             metadata: %{"query" => "company"}
           }) do
        {:ok, artifact, ref} -> {:cont, {:ok, acc ++ [{artifact, ref}]}}
        error -> {:halt, error}
      end
    end)
  end
end
