defmodule SdrAgent.Integrations.PublicWeb do
  @moduledoc """
  The fetch policy of public-web discovery (design r1 §1b). `fetch/2` reads
  one public page under these rules; the address lookup and the request
  are injected (`resolver:`, `request:`):

    * The URL rule is the dossier's (`DossierParser.Rules.url/2`): https,
      no port, userinfo, query, fragment, IP literal or special-use host.
    * Every resolved address must be public
      (`SdrAgent.Discovery.PublicAddress`). The request goes to the first
      one, pinned, with the original host name, which the transport must
      use for Host, SNI and certificate verification; nothing inside the
      request may resolve again.
    * Redirects (301, 302, 303, 307, 308) are followed here, at most 3. Each
      Location is resolved against the current URL and must pass the URL
      rule (`:redirect_invalid`); its host is resolved and checked again.
    * Bounds: a body over 524_288 bytes is `:too_large`; only text/html and
      text/plain are read (`:unsupported_content`); any other final status
      is `:http_status`; a failed request is `:transport_failed`.

  The page: the requested `url`, the `final_url`, the `<title>` text, the
  verbatim `content`, its `content_sha256` (lowercase hex), `content_type`,
  `published_at: nil`, `source_type: :company_site` and
  `trust_level: :unverified`. Errors are closed atoms; no URL or body is
  ever echoed.

  The default request is a refusing transport (`:transport_failed`): a real
  pinned, streaming transport needs its own reviewed checkpoint (Codex
  review of RED-A). The default resolver is the system resolver.

  Options: `resolver: (host -> {:ok, [ip]} | {:error, term})` and
  `request: (ip, host, path -> {:ok, %{status:, headers:, body:}} | {:error, term})`.
  """

  alias SdrAgent.Discovery.PublicAddress
  alias SdrAgent.Prototype.DossierParser.Rules

  @max_bytes 524_288
  @max_redirects 3
  @redirects [301, 302, 303, 307, 308]
  @types ["text/html", "text/plain"]

  @type error ::
          :unsafe_url
          | :resolve_failed
          | :address_not_public
          | :redirect_invalid
          | :too_many_redirects
          | :too_large
          | :unsupported_content
          | :http_status
          | :transport_failed

  @doc "Fetches one public page under the discovery fetch policy."
  @spec fetch(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def fetch(url, opts \\ []) do
    resolver = Keyword.get(opts, :resolver, &resolve/1)
    request = Keyword.get(opts, :request, &refuse/3)

    if safe?(url),
      do: step(url, url, 0, resolver, request),
      else: {:error, :unsafe_url}
  end

  defp safe?(url), do: is_binary(url) and Rules.url(url, "url") == :ok

  defp step(current, original, hops, resolver, request) do
    %URI{host: host, path: path} = URI.parse(current)

    with {:ok, ip} <- address(host, resolver),
         {:ok, response} <- call(request, ip, host, path || "/") do
      respond(response, current, original, hops, resolver, request)
    end
  end

  defp address(host, resolver) do
    case resolver.(host) do
      {:ok, [_ | _] = ips} ->
        if Enum.all?(ips, &PublicAddress.public?/1),
          do: {:ok, hd(ips)},
          else: {:error, :address_not_public}

      _ ->
        {:error, :resolve_failed}
    end
  end

  defp call(request, ip, host, path) do
    case request.(ip, host, path) do
      {:ok, %{status: status, headers: headers, body: body} = response}
      when is_integer(status) and is_list(headers) and is_binary(body) ->
        {:ok, response}

      _ ->
        {:error, :transport_failed}
    end
  end

  defp respond(%{status: status} = response, current, original, hops, resolver, request)
       when status in @redirects do
    with {:ok, next} <- location(response, current) do
      if hops >= @max_redirects,
        do: {:error, :too_many_redirects},
        else: step(next, original, hops + 1, resolver, request)
    end
  end

  defp respond(%{status: status, headers: headers, body: body}, current, original, _hops, _r, _q)
       when status in 200..299 do
    type = content_type(headers)

    cond do
      byte_size(body) > @max_bytes -> {:error, :too_large}
      type not in @types -> {:error, :unsupported_content}
      true -> {:ok, page(original, current, type, body)}
    end
  end

  defp respond(_response, _current, _original, _hops, _resolver, _request),
    do: {:error, :http_status}

  defp location(%{headers: headers}, current) do
    with value when is_binary(value) and value != "" <- header(headers, "location"),
         {:ok, next} <- merge(current, value),
         true <- safe?(next) do
      {:ok, next}
    else
      _ -> {:error, :redirect_invalid}
    end
  end

  defp merge(current, value) do
    {:ok, current |> URI.merge(value) |> URI.to_string()}
  rescue
    _error -> :error
  end

  defp content_type(headers) do
    case header(headers, "content-type") do
      value when is_binary(value) ->
        value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()

      _ ->
        nil
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) -> if String.downcase(key) == name, do: value
      _other -> nil
    end)
  end

  defp page(url, final_url, type, body) do
    %{
      url: url,
      final_url: final_url,
      title: title(body),
      content: body,
      content_sha256: Base.encode16(:crypto.hash(:sha256, body), case: :lower),
      content_type: type,
      published_at: nil,
      source_type: :company_site,
      trust_level: :unverified
    }
  end

  defp title(body) do
    case Regex.run(~r/<title[^>]*>(.*?)<\/title>/is, body, capture: :all_but_first) do
      [text] -> String.trim(text)
      _ -> ""
    end
  end

  defp resolve(host) do
    name = String.to_charlist(host)

    ips =
      for family <- [:inet, :inet6],
          {:ok, addrs} <- [:inet.getaddrs(name, family)],
          addr <- addrs,
          do: addr

    if ips == [], do: {:error, :nxdomain}, else: {:ok, ips}
  end

  defp refuse(_ip, _host, _path), do: {:error, :transport_not_enabled}
end
