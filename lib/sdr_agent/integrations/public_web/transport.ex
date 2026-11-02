defmodule SdrAgent.Integrations.PublicWeb.Transport do
  @moduledoc """
  The pinned HTTPS transport of public-web discovery (Codex RED-A
  conditions). `request/4` sends one GET for `path` to the given address
  only, and uses `host` for the Host header, SNI and certificate
  verification (Req with Mint `connect_options: [hostname: host]`). It
  never resolves a name.

    * Verification: `verify_peer` against the system CA store
      (`:public_key.cacerts_get/0`); any TLS failure is `:tls_failed`.
    * No redirect is followed, no request is retried, no proxy is used and
      no compression is asked for (`accept-encoding: identity`); a response
      with any content-encoding other than identity is
      `:unsupported_encoding` and is never decoded.
    * The body is streamed and reading stops past `max_bytes` (default
      524_288): a larger declared length or streamed body is `:too_large`.
    * `timeout:` (default 10_000 ms) bounds the connect and each receive;
      expiry is `:timeout`. Every other failure is `:transport_failed`.

  Returns `{:ok, %{status:, headers:, body:}}` with lower-cased header
  names. Errors are closed atoms; no URL, address or body is echoed.

  `port:` and `cacerts:` exist only in the test build
  (`:public_web_test_seams`), for local HTTPS servers; every other build
  ignores them and always uses port 443 and the system CA store.
  """

  @test_seams Application.compile_env(:sdr_agent, :public_web_test_seams, false)
  @max_bytes 524_288
  @timeout 10_000

  @type error ::
          :tls_failed | :timeout | :too_large | :unsupported_encoding | :transport_failed

  @doc "One pinned GET of `path` at `ip`, verified as `host`."
  @spec request(:inet.ip_address(), String.t(), String.t(), keyword()) ::
          {:ok, %{status: integer(), headers: [{String.t(), String.t()}], body: binary()}}
          | {:error, error()}
  def request(ip, host, path, opts \\ []) when is_binary(host) and is_binary(path) do
    max = Keyword.get(opts, :max_bytes, @max_bytes)
    timeout = Keyword.get(opts, :timeout, @timeout)
    {port, cacerts} = seams(opts)
    # A halted stream can surface as a closed-connection error, so the refusal
    # is kept in this process (the stream callback runs here) under a fresh key.
    key = {__MODULE__, make_ref()}

    try do
      send_request(ip, host, path, port, cacerts, max, timeout, key)
    rescue
      _error -> {:error, :transport_failed}
    after
      Process.delete(key)
    end
  end

  defp send_request(ip, host, path, port, cacerts, max, timeout, key) do
    [
      method: :get,
      url: "https://#{literal(ip)}:#{port}#{path}",
      headers: [{"accept-encoding", "identity"}],
      redirect: false,
      retry: false,
      raw: true,
      receive_timeout: timeout,
      connect_options: [
        hostname: host,
        timeout: timeout,
        protocols: [:http1],
        transport_opts: [verify: :verify_peer, cacerts: cacerts, depth: 4]
      ],
      into: &collect(&1, &2, max, key)
    ]
    |> Req.new()
    |> Req.request()
    |> result(max, Process.get(key))
  end

  if @test_seams do
    defp seams(opts),
      do: {Keyword.get(opts, :port, 443), Keyword.get_lazy(opts, :cacerts, &system_cacerts/0)}
  else
    defp seams(_opts), do: {443, system_cacerts()}
  end

  defp system_cacerts, do: :public_key.cacerts_get()

  defp literal({_, _, _, _} = ip), do: :inet.ntoa(ip) |> to_string()
  defp literal(ip), do: "[" <> to_string(:inet.ntoa(ip)) <> "]"

  # Streams the body; stops at the first sign of an encoded or oversized body.
  defp collect({:data, data}, {req, resp}, max, key) do
    cond do
      encoded?(resp) ->
        refuse(key, :unsupported_encoding, req, resp)

      declared(resp) > max ->
        refuse(key, :too_large, req, resp)

      byte_size(body(resp)) + byte_size(data) > max ->
        refuse(key, :too_large, req, resp)

      true ->
        {:cont, {req, %{resp | body: body(resp) <> data}}}
    end
  end

  defp refuse(key, reason, req, resp) do
    Process.put(key, reason)
    {:halt, {req, resp}}
  end

  defp body(%{body: body}) when is_binary(body), do: body
  defp body(_resp), do: ""

  defp result(_outcome, _max, refused) when refused != nil, do: {:error, refused}
  defp result({:ok, %Req.Response{} = resp}, max, nil), do: final(resp, max)
  defp result({:error, exception}, _max, nil), do: {:error, reason(exception)}

  defp final(resp, max) do
    cond do
      encoded?(resp) -> {:error, :unsupported_encoding}
      declared(resp) > max -> {:error, :too_large}
      true -> {:ok, %{status: resp.status, headers: headers(resp), body: body(resp)}}
    end
  end

  defp headers(resp),
    do:
      for(
        {name, values} <- resp.headers,
        value <- List.wrap(values),
        do: {String.downcase(name), value}
      )

  defp encoded?(resp) do
    Enum.any?(Req.Response.get_header(resp, "content-encoding"), fn value ->
      String.downcase(String.trim(value)) not in ["", "identity"]
    end)
  end

  defp declared(resp) do
    case Req.Response.get_header(resp, "content-length") do
      [value | _] ->
        case Integer.parse(String.trim(value)) do
          {n, ""} -> n
          _ -> 0
        end

      [] ->
        0
    end
  end

  defp reason(%{reason: :timeout}), do: :timeout
  defp reason(%{reason: {:tls_alert, _alert}}), do: :tls_failed
  defp reason(%{reason: {:options, _detail}}), do: :tls_failed
  defp reason(_exception), do: :transport_failed
end
