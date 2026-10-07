defmodule SdrAgent.Integrations.SearchProvider do
  @moduledoc """
  Search adapter behaviour (spec §17). `search/2` returns results (`url`,
  `title`, `snippet` — a verbatim excerpt of the page — and `published_at`,
  possibly nil) for a query; option `:domain` scopes it to one company.
  """

  @type result :: %{
          required(:url) => String.t(),
          required(:title) => String.t(),
          required(:snippet) => String.t(),
          required(:published_at) => DateTime.t() | nil
        }

  @callback search(query :: String.t(), opts :: keyword()) :: {:ok, [result()]}
end
