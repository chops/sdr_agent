defmodule SdrAgent.Discovery.ExaTransport do
  @moduledoc """
  Bounded authenticated JSON POSTs to the fixed Exa API (ADR-0027). Only
  /search and /contents are admitted. No redirects, retries, proxy, implicit
  decompression or unbounded JSON decoding. All failures are value-free codes.

  A dedicated Finch pool uses connection_options/0 for peer verification and
  the fixed api.exa.ai TLS hostname. The caller's supervised task additionally
  bounds the entire action, including connection and response processing.
  Test seams exist only in the hermetic compiled test build; only a Req.Test
  plug is configurable. The local-TLS seam shares the identical request builder.
  """

  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)
  @base "https://api.exa.ai"
  @max_bytes 524_288

  @doc "TLS connection options used by the dedicated Finch pool."
  def connection_options do
    [
      hostname: "api.exa.ai",
      timeout: 10_000,
      protocols: [:http1],
      transport_opts: [verify: :verify_peer, cacerts: :public_key.cacerts_get(), depth: 4]
    ]
  end

  @doc "One fixed-path request; the key stays in the server-side transport only."
  def post(path, payload, key) when path in ["/search", "/contents"] and is_map(payload) do
    if key?(key), do: request(@base <> path, payload, key), else: {:error, :provider_auth}
  end

  def post(_, _, _), do: {:error, :invalid_input}

  defp key?(key) when is_binary(key) and byte_size(key) in 1..4096,
    do:
      String.valid?(key) and String.trim(key) != "" and
        not String.contains?(key, ["\r", "\n", <<0>>])

  defp key?(_), do: false

  defp options(url, payload, key, ref) do
    [
      method: :post,
      url: url,
      body: Jason.encode!(payload),
      headers: [
        {"content-type", "application/json"},
        {"accept", "application/json"},
        {"accept-encoding", "identity"},
        {"x-api-key", key}
      ],
      redirect: false,
      retry: false,
      decode_body: false,
      raw: true,
      compressed: false,
      finch: [name: SdrAgent.Discovery.Finch],
      receive_timeout: 10_000,
      request_timeout: 30_000,
      into: &collect(&1, &2, ref)
    ] ++ test_options_from_config()
  end

  if @test_seams do
    defp test_options_from_config,
      do:
        Application.get_env(:sdr_agent, :prospect_search_req_options, []) |> Keyword.take([:plug])

    @doc false
    def test_options,
      do: %{
        request: options(@base <> "/search", %{}, "synthetic-key", make_ref()),
        connection: connection_options()
      }

    @doc false
    def test_post(url, payload, key) do
      case URI.parse(url) do
        %URI{scheme: "https", host: "127.0.0.1", path: path}
        when path in ["/search", "/contents"] ->
          request(url, payload, key)

        _ ->
          {:error, :invalid_input}
      end
    end
  else
    defp test_options_from_config, do: []
  end

  defp request(url, payload, key) do
    :logger.update_process_metadata(%{sdr_sensitive_input: true})
    ref = make_ref()

    try do
      opts = options(url, payload, key, ref)

      if byte_size(opts[:body]) <= 16_384 do
        opts |> Req.new() |> Req.request() |> result(Process.get(ref))
      else
        {:error, :invalid_input}
      end
    rescue
      _ -> {:error, :provider_unavailable}
    catch
      _, _ -> {:error, :provider_unavailable}
    after
      Process.delete(ref)
    end
  end

  defp collect({:data, data}, {req, resp}, ref) do
    cond do
      encoded?(resp) -> refuse(:invalid_response, req, resp, ref)
      declared(resp) > @max_bytes -> refuse(:too_large, req, resp, ref)
      byte_size(body(resp)) + byte_size(data) > @max_bytes -> refuse(:too_large, req, resp, ref)
      true -> {:cont, {req, %{resp | body: body(resp) <> data}}}
    end
  end

  defp refuse(code, req, resp, ref) do
    Process.put(ref, code)
    {:halt, {req, resp}}
  end

  defp body(%{body: value}) when is_binary(value), do: value
  defp body(_), do: ""

  defp encoded?(resp),
    do:
      Enum.any?(
        Req.Response.get_header(resp, "content-encoding"),
        &(String.downcase(String.trim(&1)) not in ["", "identity"])
      )

  defp declared(resp) do
    case Req.Response.get_header(resp, "content-length") do
      [value | _] ->
        case Integer.parse(value) do
          {n, ""} when n >= 0 -> n
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp result(_, code) when not is_nil(code), do: {:error, code}
  defp result({:error, %{reason: :timeout}}, _), do: {:error, :timeout}
  defp result({:error, _}, _), do: {:error, :provider_unavailable}

  defp result({:ok, resp}, nil) do
    cond do
      encoded?(resp) -> {:error, :invalid_response}
      declared(resp) > @max_bytes or byte_size(body(resp)) > @max_bytes -> {:error, :too_large}
      resp.status in 200..299 -> decode(body(resp))
      true -> {:error, status_code(resp.status)}
    end
  end

  defp status_code(status) when status in [401, 403], do: :provider_auth
  defp status_code(402), do: :quota_exceeded
  defp status_code(429), do: :rate_limited
  defp status_code(status) when status in [408, 504], do: :timeout
  defp status_code(status) when status in [400, 413], do: :invalid_response
  defp status_code(_), do: :provider_unavailable

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      _ -> {:error, :invalid_response}
    end
  end
end
