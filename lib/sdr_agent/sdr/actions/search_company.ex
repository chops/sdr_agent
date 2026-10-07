defmodule SdrAgent.SDR.Actions.SearchCompany do
  @moduledoc """
  ResearchLeadFlow step "search": recent-information search for the company
  through the configured `SdrAgent.Integrations.SearchProvider`. Each result
  snippet is recorded as a low-trust `search_result` artifact; the result
  URLs other than the company website (already fetched) are returned for
  the "pages" step.
  """
  use SdrAgent.SDR.Action,
    name: "sdr_search_company",
    description: "Recent information about the company.",
    schema: Zoi.object(%{lead_id: Zoi.string(), website_url: Zoi.string()})

  alias SdrAgent.Integrations
  alias SdrAgent.SDR.Support

  @impl SdrAgent.SDR.Action
  def perform(%{lead_id: lead_id, website_url: website_url}, ctx) do
    with {:ok, %{account: account}} <- Support.lead_context(ctx, lead_id),
         {:ok, results} <- Integrations.search().search(account.name, domain: account.domain),
         {:ok, recorded} <- record_all(ctx, lead_id, results) do
      urls =
        results
        |> Enum.map(& &1.url)
        |> Enum.reject(&(String.trim_trailing(&1, "/") == String.trim_trailing(website_url, "/")))
        |> Enum.uniq()

      {artifacts, refs} = Enum.unzip(recorded)
      {:ok, %{artifacts: artifacts, urls: urls}, [], refs}
    end
  end

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
