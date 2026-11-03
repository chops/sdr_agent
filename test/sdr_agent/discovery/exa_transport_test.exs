defmodule SdrAgent.Discovery.ExaTransportTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  @transport SdrAgent.Discovery.ExaTransport
  @key "synthetic-exa-key-canary"

  setup do
    prior = Application.get_env(:sdr_agent, :prospect_search_req_options)
    Application.put_env(:sdr_agent, :prospect_search_req_options, plug: {Req.Test, @transport})

    on_exit(fn ->
      if prior,
        do: Application.put_env(:sdr_agent, :prospect_search_req_options, prior),
        else: Application.delete_env(:sdr_agent, :prospect_search_req_options)
    end)

    :ok
  end

  defp post(path \\ "/search", body \\ %{"query" => "synthetic-company"}) do
    assert Code.ensure_loaded?(@transport), "missing fixed-host Exa transport"
    assert function_exported?(@transport, :post, 3), "missing ExaTransport.post/3"
    Function.capture(@transport, :post, 3).(path, body, @key)
  end

  test "uses only fixed TLS API host, POST JSON, and selected authentication header" do
    Req.Test.stub(@transport, fn conn ->
      assert conn.host == "api.exa.ai"
      assert conn.scheme == :https
      assert conn.method == "POST"
      assert conn.request_path == "/search"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == [@key]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"query" => "synthetic-company"}
      Req.Test.json(conn, %{"results" => []})
    end)

    assert {:ok, %{"results" => []}} = post()
  end

  test "refuses caller-controlled endpoints and paths before any request" do
    parent = self()

    Req.Test.stub(@transport, fn conn ->
      send(parent, :unexpected_request)
      Req.Test.json(conn, %{})
    end)

    for path <- [
          "https://other.test/search",
          "//other.test/search",
          "/search?x=1",
          "/other",
          "/../search"
        ] do
      assert {:error, :invalid_input} = post(path)
    end

    refute_received :unexpected_request
  end

  test "does not follow a redirect or forward the credential" do
    parent = self()

    Req.Test.stub(@transport, fn conn ->
      send(parent, {:request_host, conn.host})

      conn
      |> Plug.Conn.put_resp_header("location", "https://other.test/search")
      |> Plug.Conn.send_resp(302, "")
    end)

    assert {:error, :provider_unavailable} = post()
    assert_received {:request_host, "api.exa.ai"}
    refute_received {:request_host, "other.test"}
  end

  test "rate limit and server errors are not retried" do
    parent = self()

    for {status, expected} <- [{429, :rate_limited}, {500, :provider_unavailable}] do
      Req.Test.stub(@transport, fn conn ->
        send(parent, {:attempt, status})
        Plug.Conn.send_resp(conn, status, "provider-body-canary")
      end)

      assert {:error, ^expected} = post()
      assert_received {:attempt, ^status}
      refute_received {:attempt, ^status}
    end
  end

  test "auth, quota and malformed response failures are closed codes" do
    for {status, expected} <- [
          {401, :provider_auth},
          {403, :provider_auth},
          {402, :quota_exceeded},
          {400, :invalid_response}
        ] do
      Req.Test.stub(@transport, &Plug.Conn.send_resp(&1, status, "sensitive-provider-error"))
      assert {:error, ^expected} = post()
    end

    Req.Test.stub(@transport, &Plug.Conn.send_resp(&1, 200, "not JSON: private-data-canary"))
    assert {:error, :invalid_response} = post()
  end

  test "declared and actual bodies above the hard byte cap are refused" do
    Req.Test.stub(@transport, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-length", "524289")
      |> Plug.Conn.send_resp(200, "{}")
    end)

    assert {:error, :too_large} = post()
    Req.Test.stub(@transport, &Plug.Conn.send_resp(&1, 200, String.duplicate("x", 524_289)))
    assert {:error, :too_large} = post()
  end

  test "encoded bodies are not transparently decompressed past the byte guard" do
    Req.Test.stub(@transport, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-encoding", "gzip")
      |> Plug.Conn.send_resp(200, :zlib.gzip("{}"))
    end)

    assert {:error, :invalid_response} = post()
  end

  test "transport timeout is a fixed outcome" do
    Req.Test.stub(@transport, &Req.Test.transport_error(&1, :timeout))
    assert {:error, :timeout} = post()
  end

  test "error output does not expose key, provider body or request query" do
    Req.Test.stub(@transport, &Plug.Conn.send_resp(&1, 500, @key <> " private-body-canary"))
    logs = capture_log(fn -> assert {:error, :provider_unavailable} = post() end)
    refute logs =~ @key
    refute logs =~ "private-body-canary"
    refute logs =~ "synthetic-company"
  end

  test "runtime test options cannot replace the fixed API endpoint" do
    Application.put_env(:sdr_agent, :prospect_search_req_options,
      plug: {Req.Test, @transport},
      base_url: "https://other.test",
      url: "https://other.test/search",
      redirect: true,
      retry: true,
      headers: [{"x-api-key", "forged"}]
    )

    Req.Test.stub(@transport, fn conn ->
      assert conn.host == "api.exa.ai"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == [@key]
      Req.Test.json(conn, %{"results" => []})
    end)

    assert {:ok, _} = post()
  end

  test "missing key refuses without egress and contents uses its positive fixed path" do
    assert Code.ensure_loaded?(@transport), "missing fixed-host Exa transport"
    parent = self()

    Req.Test.stub(@transport, fn conn ->
      send(parent, :requested)
      assert conn.request_path == "/contents"
      Req.Test.json(conn, %{"results" => []})
    end)

    for key <- [nil, ""] do
      assert {:error, :provider_auth} =
               Function.capture(@transport, :post, 3).("/search", %{}, key)
    end

    refute_received :requested
    assert {:ok, _} = post("/contents")
    assert_received :requested
  end

  test "real request builder pins verification, hostname and raw non-retrying behavior" do
    assert Code.ensure_loaded?(@transport), "missing fixed-host Exa transport"
    opts = Function.capture(@transport, :test_options, 0).()
    assert opts.request[:redirect] == false
    assert opts.request[:retry] == false
    assert opts.request[:decode_body] == false
    assert opts.connection[:hostname] == "api.exa.ai"
    assert opts.connection[:transport_opts][:verify] == :verify_peer
    assert is_list(opts.connection[:transport_opts][:cacerts])
    assert opts.connection[:transport_opts][:cacerts] != []
  end

  test "the actual shared request builder refuses an untrusted local TLS certificate" do
    assert Code.ensure_loaded?(@transport), "missing fixed-host Exa transport"
    key = [digest: :sha256, key: {:namedCurve, :secp256r1}]
    san = [{:Extension, {2, 5, 29, 17}, false, [{:dNSName, ~c"api.exa.ai"}]}]

    %{server_config: server} =
      :public_key.pkix_test_data(%{
        server_chain: %{root: key, intermediates: [], peer: [extensions: san] ++ key},
        client_chain: %{root: key, intermediates: [], peer: key}
      })

    parent = self()

    site =
      start_supervised!(
        {Bandit,
         plug: fn conn ->
           send(parent, :tls_hit)
           Req.Test.json(conn, %{})
         end,
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         thousand_island_options: [transport_options: [cert: server[:cert], key: server[:key]]]}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(site)
    options = Function.capture(@transport, :connection_options, 0).()

    start_supervised!(
      {Finch, name: SdrAgent.Discovery.Finch, pools: %{default: [conn_opts: options]}}
    )

    Application.delete_env(:sdr_agent, :prospect_search_req_options)

    assert {:error, :provider_unavailable} =
             Function.capture(@transport, :test_post, 3).(
               "https://127.0.0.1:#{port}/search",
               %{},
               @key
             )

    refute_received :tls_hit
  end
end
