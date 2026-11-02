defmodule SdrAgent.Integrations.PublicWebTransportTest do
  @moduledoc """
  Discovery RED-B (Codex RED-A conditions): the real pinned transport
  `SdrAgent.Integrations.PublicWeb.Transport.request/4` and the robots.txt
  retrieval `SdrAgent.Integrations.PublicWeb.robots_txt/2`.

  `request(ip, host, path, opts)` connects to the given address only and uses
  `host` for Host, SNI and certificate verification (Req with Mint
  `connect_options: [hostname: host]`). It never follows a redirect, never
  retries, never uses a proxy, asks for no compression and refuses any
  content-encoding, and stops reading a body past `max_bytes` (default
  524_288) without buffering the rest. Results: `{:ok, %{status:, headers:,
  body:}}` (headers lower-cased) or a closed error: `:tls_failed`,
  `:timeout`, `:too_large`, `:unsupported_encoding`, `:transport_failed`.
  Test-only options: `port:` and `cacerts:`.

  `robots_txt(host, opts)` reads `https://host/robots.txt` under the same
  address rule and request function as `fetch/2`: `{:ok, body}` on 2xx,
  `{:ok, nil}` only on a confirmed 404, otherwise an error (never "absent").

  The servers here are local HTTPS servers on 127.0.0.1 with throwaway
  certificates; nothing leaves the machine.
  """
  use ExUnit.Case, async: false

  @transport SdrAgent.Integrations.PublicWeb.Transport
  @web SdrAgent.Integrations.PublicWeb
  @host "discovery.test"

  defmodule Site do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, %{test: test, mode: mode}) do
      send(test, {:hit, get_req_header(conn, "host"), get_req_header(conn, "accept-encoding")})
      respond(conn, mode, test)
    end

    defp respond(conn, :ok, _test),
      do: conn |> put_resp_content_type("text/html") |> send_resp(200, "<title>Hi</title>hello")

    defp respond(conn, :redirect, _test),
      do: conn |> put_resp_header("location", "https://elsewhere.test/") |> send_resp(302, "")

    defp respond(conn, {:status, status}, _test), do: send_resp(conn, status, "no")

    defp respond(conn, :declared_large, _test) do
      conn
      |> put_resp_header("content-length", "2000000")
      |> put_resp_content_type("text/html")
      |> send_resp(200, :binary.copy("a", 2_000_000))
    end

    defp respond(conn, :streamed_large, test) do
      conn = conn |> put_resp_content_type("text/html") |> send_chunked(200)
      chunk = :binary.copy("a", 65_536)

      {conn, sent} =
        Enum.reduce_while(1..64, {conn, 0}, fn _i, {conn, n} ->
          # Paced so kernel buffers cannot absorb the whole body before the
          # client stops reading (Codex RED-B reliability note).
          Process.sleep(25)

          case chunk(conn, chunk) do
            {:ok, conn} -> {:cont, {conn, n + 1}}
            {:error, _reason} -> {:halt, {conn, n}}
          end
        end)

      send(test, {:chunks_sent, sent})
      conn
    end

    defp respond(conn, :gzip, _test) do
      conn
      |> put_resp_header("content-encoding", "gzip")
      |> put_resp_content_type("text/html")
      |> send_resp(200, :zlib.gzip("hello"))
    end

    defp respond(conn, :slow, _test) do
      Process.sleep(2_000)
      send_resp(conn, 200, "late")
    end
  end

  defp pki(host) do
    san = [{:Extension, {2, 5, 29, 17}, false, [{:dNSName, String.to_charlist(host)}]}]
    # TLS 1.3 refuses the default test keys and SHA-1 signatures.
    key = [digest: :sha256, key: {:namedCurve, :secp256r1}]

    :public_key.pkix_test_data(%{
      server_chain: %{root: key, intermediates: [], peer: [extensions: san] ++ key},
      client_chain: %{root: key, intermediates: [], peer: key}
    })
  end

  defp serve(mode, cert_host \\ @host) do
    %{server_config: server, client_config: client} = pki(cert_host)

    pid =
      start_supervised!(
        {Bandit,
         plug: {Site, %{test: self(), mode: mode}},
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         thousand_island_options: [
           transport_options: [cert: server[:cert], key: server[:key]]
         ]},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    %{port: port, cacerts: client[:cacerts]}
  end

  defp request(site, opts \\ []) do
    assert Code.ensure_loaded?(@transport),
           "SdrAgent.Integrations.PublicWeb.Transport is not defined"

    opts = Keyword.merge([port: site.port, cacerts: site.cacerts], opts)
    Function.capture(@transport, :request, 4).({127, 0, 0, 1}, @host, "/", opts)
  end

  defp hits do
    receive do
      {:hit, _host, _enc} -> 1 + hits()
    after
      300 -> 0
    end
  end

  test "connects to the pinned address with the original host for Host, SNI and verification" do
    site = serve(:ok)

    assert {:ok, %{status: 200, body: "<title>Hi</title>hello", headers: headers}} = request(site)
    assert {"content-type", "text/html; charset=utf-8"} in headers
    assert_received {:hit, [@host <> _], encoding}
    assert encoding in [[], ["identity"]]
  end

  test "a certificate for another host is refused" do
    site = serve(:ok, "other.test")
    assert request(site) == {:error, :tls_failed}
  end

  test "a certificate from an untrusted authority is refused" do
    site = serve(:ok)
    %{client_config: stranger} = pki(@host)
    assert request(site, cacerts: stranger[:cacerts]) == {:error, :tls_failed}
  end

  test "a redirect is returned, never followed" do
    site = serve(:redirect)

    assert {:ok, %{status: 302, headers: headers}} = request(site)
    assert {"location", "https://elsewhere.test/"} in headers
    assert hits() == 1
  end

  test "server errors are returned once, never retried" do
    for status <- [500, 503, 429] do
      site = serve({:status, status})
      assert {:ok, %{status: ^status}} = request(site)
      assert hits() == 1, "status #{status} was retried"
    end
  end

  test "a declared oversized body is refused" do
    site = serve(:declared_large)
    assert request(site) == {:error, :too_large}
  end

  test "an oversized streamed body is cut off before it is all read" do
    site = serve(:streamed_large)

    assert request(site) == {:error, :too_large}
    assert_receive {:chunks_sent, sent}, 5_000
    assert sent < 64, "the whole 4 MiB body was read"
  end

  test "a compressed body is refused, never decompressed" do
    site = serve(:gzip)
    assert request(site) == {:error, :unsupported_encoding}
  end

  test "a slow server times out" do
    site = serve(:slow)
    assert request(site, timeout: 300) == {:error, :timeout}
  end

  test "a proxy in the environment is ignored" do
    site = serve(:ok)
    previous = System.get_env("HTTPS_PROXY")
    System.put_env("HTTPS_PROXY", "http://127.0.0.1:9")

    try do
      assert {:ok, %{status: 200}} = request(site)
    after
      if previous,
        do: System.put_env("HTTPS_PROXY", previous),
        else: System.delete_env("HTTPS_PROXY")
    end
  end

  describe "robots_txt/2" do
    defp robots(response) do
      assert Code.ensure_loaded?(@web)
      test = self()

      request = fn ip, host, path ->
        send(test, {:asked, ip, host, path})
        response
      end

      Function.capture(@web, :robots_txt, 2).("acme.example.com",
        resolver: fn "acme.example.com" -> {:ok, [{93, 184, 216, 34}]} end,
        request: request
      )
    end

    test "a 2xx body is the file, read from /robots.txt on the pinned address" do
      ok = {:ok, %{status: 200, headers: [{"content-type", "text/plain"}], body: "User-agent: *"}}
      assert robots(ok) == {:ok, "User-agent: *"}
      assert_received {:asked, {93, 184, 216, 34}, "acme.example.com", "/robots.txt"}
    end

    test "only a 404 means absent" do
      assert robots({:ok, %{status: 404, headers: [], body: ""}}) == {:ok, nil}

      for status <- [401, 403, 410, 429, 500, 503] do
        assert robots({:ok, %{status: status, headers: [], body: ""}}) == {:error, :http_status},
               "status #{status}"
      end
    end

    test "a transport failure is an error, never absent" do
      for reason <- [:timeout, :tls_failed, :transport_failed] do
        assert robots({:error, reason}) == {:error, :transport_failed}, inspect(reason)
      end
    end

    test "a non-public address is refused before any request" do
      assert Code.ensure_loaded?(@web)

      assert Function.capture(@web, :robots_txt, 2).("acme.example.com",
               resolver: fn _ -> {:ok, [{10, 0, 0, 1}]} end,
               request: fn _, _, _ -> flunk("requested") end
             ) == {:error, :address_not_public}
    end
  end
end
