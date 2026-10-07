defmodule SdrAgent.Integrations.FixtureSearch do
  @moduledoc """
  Search adapter over the demo seed (`SdrAgent.Integrations.Fixtures`):
  returns the company's news article and website, in that order. Offline
  and deterministic; an unknown company has no results.
  """
  @behaviour SdrAgent.Integrations.SearchProvider

  alias SdrAgent.Integrations.Fixtures

  @impl true
  def search(query, opts) when is_binary(query) do
    {:ok, Fixtures.search_results(query, Keyword.get(opts, :domain))}
  end
end
