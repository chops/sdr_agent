defmodule SdrAgent.Integrations.WebFetch do
  @moduledoc """
  Web-fetch adapter behaviour (spec §17). `fetch/1` returns one page (`url`,
  `title`, verbatim `content`, `content_type`, `published_at`, `source_type`
  and `trust_level` as the adapter knows them), `{:error, :not_found}`, or
  `{:error, :host_not_allowed}` for anything but an http(s) URL on a
  reserved (synthetic) host.
  """

  @type page :: %{
          required(:url) => String.t(),
          required(:title) => String.t(),
          required(:content) => String.t(),
          required(:content_type) => String.t(),
          required(:published_at) => DateTime.t() | nil,
          required(:source_type) => atom(),
          required(:trust_level) => atom()
        }

  @callback fetch(url :: String.t()) ::
              {:ok, page()} | {:error, :not_found | :host_not_allowed}
end
