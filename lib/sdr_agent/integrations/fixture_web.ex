defmodule SdrAgent.Integrations.FixtureWeb do
  @moduledoc """
  Web-fetch adapter over the demo seed (`SdrAgent.Integrations.Fixtures`).
  Only http(s) URLs on reserved (synthetic) hosts are accepted
  (`SdrAgent.Sales.Synthetic`); anything else is `:host_not_allowed`, an
  unknown page `:not_found`. Never touches the network.
  """
  @behaviour SdrAgent.Integrations.WebFetch

  alias SdrAgent.Integrations.Fixtures
  alias SdrAgent.Sales.Synthetic

  @impl true
  def fetch(url) when is_binary(url) do
    with :ok <- allowed(url) do
      case Map.fetch(Fixtures.pages(), Fixtures.normalize(url)) do
        {:ok, page} -> {:ok, page}
        :error -> {:error, :not_found}
      end
    end
  end

  defp allowed(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        if Synthetic.reserved_domain?(host), do: :ok, else: {:error, :host_not_allowed}

      _ ->
        {:error, :host_not_allowed}
    end
  end
end
