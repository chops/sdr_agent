defmodule SdrAgentWeb.AuthErrorBoundaryTest do
  @moduledoc """
  Error reports of credential-bearing requests through the real HTTP and
  WebSocket boundary (Codex P2, I1, R1, R2): a Bandit listener serving
  `SdrAgentWeb.Endpoint` itself, raw HTTP and WebSocket over a socket
  (`SdrAgent.TestSupport.RawHttp`), and the raw `:logger` events (message
  and metadata, after the primary filters) captured by
  `SdrAgent.TestSupport.RawLog`.

  The listener logs every exception status, 400..599, so parser (400),
  CSRF (403) and content-negotiation (406) failures produce reports too.
  Each expected report is correlated to the server process that handled
  the tested connection, and the secrecy assertions scan the complete raw
  capture (Codex R3). A credential-bearing request's report must be
  emitted and withheld, with no sentinel, cookie or token anywhere in its
  message or metadata:

    * P2/I1: auth-route crashes after and failures before the router (the
      sentinel in stack arguments, query or body);
    * R1: an ordinary route with a real signed session cookie holding a
      real JWT, or a bearer token, failing before the session is decoded;
      on one keep-alive connection, after an auth request and after a
      credential-free request;
    * R2: the LiveView socket, which Phoenix dispatches before every
      declared plug: a handshake failure, and a transport crash after the
      upgrade and before any channel, with the session decoded into the
      transport; long polling is not served.

  Positive controls: a credential-free ordinary request's report is
  emitted unwithheld, with its request id and a status, its conn reduced
  to method, path and status; and on one connection an auth request's tag
  does not withhold a later credential-free report.
  """
  use SdrAgentWeb.ConnCase, async: false

  import SdrAgent.AuditCase, only: [bootstrap!: 0, human: 2, test_password: 0]

  alias SdrAgent.TestSupport.RawHttp
  alias SdrAgent.TestSupport.RawLog

  setup do
    sentinel = "SENTINEL" <> Integer.to_string(System.unique_integer([:positive]))
    Map.merge(RawHttp.listener(), %{sentinel: sentinel, ref: RawLog.start()})
  end

  # A real signed-in session: a real JWT in a real signed session cookie.
  defp signed_in(_ctx) do
    tenant = bootstrap!()
    reviewer = human(:reviewer, tenant)
    {:ok, user} = SdrAgent.Accounts.sign_in(to_string(reviewer.email), test_password())
    jwt = user.__metadata__.token
    {masked_csrf, csrf_state} = RawHttp.csrf_pair()
    {name, value} = RawHttp.session_cookie(%{"user_token" => jwt, "_csrf_token" => csrf_state})
    %{jwt: jwt, cookie: value, cookie_header: "cookie: #{name}=#{value}\r\n", csrf: masked_csrf}
  end

  defp assert_withheld(ctx, pid, secrets \\ []) do
    event = RawLog.report_of(ctx.ref, pid)
    RawLog.assert_absent(ctx.ref, [ctx.sentinel | secrets])
    assert RawLog.withheld?(event)
  end

  # A credential-free request's report: emitted, not withheld, with its
  # request id and a status; its conn reduced to method, path and status.
  defp assert_reported(ctx, pid, method, path) do
    event = RawLog.report_of(ctx.ref, pid)
    refute RawLog.withheld?(event)
    assert is_binary(event.meta[:request_id])
    refute match?(%Plug.Conn{}, event.meta[:conn])
    assert %{method: ^method, request_path: ^path, status: status} = event.meta[:conn]
    assert is_integer(status)
    RawLog.assert_absent(ctx.ref, [ctx.sentinel])
    event
  end

  defp malformed_json(sentinel), do: ~s({"user": {"email": "x", "password": "#{sentinel}")

  # A malformed JSON body: the parser raises before the router. Under Bandit,
  # Phoenix then renders with the conn from before the body was read, Bandit
  # refuses it as stale, and the answer is a 500 whose report carries that
  # conn (headers, path, query) in metadata; the sentinel also rides in the
  # query string, where a credential can (a token query).
  defp parser_failure(path, sentinel, headers \\ ""),
    do:
      RawHttp.post(
        path <> "?token=#{sentinel}",
        "application/json",
        malformed_json(sentinel),
        headers
      )

  # --- P2: after the auth pipeline -------------------------------------

  test "a crash on an auth route after its pipeline is reported withheld", ctx do
    # The accept phase reads `user` as a map; a string crashes it
    # (FunctionClauseError in Access.get/3, the sentinel among its arguments).
    query = "token=#{ctx.sentinel}&user=#{ctx.sentinel}"
    assert {[500], pid} = RawHttp.exchange(ctx, [RawHttp.get("/auth/user/magic_link?" <> query)])
    assert_withheld(ctx, pid)
  end

  # --- I1: before the router reaches the auth routes ---------------------

  test "a body-parser failure on an auth path is reported withheld, any spelling", ctx do
    for path <- ["/auth/user/password/sign_in", "/%61uth/user/password/sign_in"] do
      assert {[status], pid} = RawHttp.exchange(ctx, [parser_failure(path, ctx.sentinel)])
      assert status in [400, 500]
      assert_withheld(ctx, pid)
    end
  end

  test "a CSRF failure on an auth path is reported withheld", ctx do
    body = "user[email]=x&user[password]=#{ctx.sentinel}"
    path = "/auth/user/password/sign_in?token=#{ctx.sentinel}"
    request = RawHttp.post(path, "application/x-www-form-urlencoded", body)
    assert {[403], pid} = RawHttp.exchange(ctx, [request])
    assert_withheld(ctx, pid)
  end

  test "a content-negotiation failure on a confirmation path is reported withheld", ctx do
    for prefix <- ["magic_link", "%6dagic_link"] do
      request = RawHttp.get("/#{prefix}/#{ctx.sentinel}", "accept: application/json\r\n")
      assert {[406], pid} = RawHttp.exchange(ctx, [request])
      assert_withheld(ctx, pid)
    end
  end

  # --- R1: credential-bearing ordinary requests --------------------------

  describe "R1: an ordinary route" do
    setup :signed_in

    test "with a real session cookie, failing before the session is decoded, is withheld",
         ctx do
      request = parser_failure("/leads", ctx.sentinel, ctx.cookie_header)
      assert {[status], pid} = RawHttp.exchange(ctx, [request])
      assert status in [400, 500]
      assert_withheld(ctx, pid, [ctx.cookie, ctx.jwt])
    end

    test "with a bearer token is withheld", ctx do
      request = parser_failure("/leads", ctx.sentinel, "authorization: Bearer #{ctx.jwt}\r\n")
      assert {[status], pid} = RawHttp.exchange(ctx, [request])
      assert status in [400, 500]
      assert_withheld(ctx, pid, [ctx.jwt])
    end

    test "after an auth request on one connection, a session-bearing failure is withheld",
         ctx do
      assert {[200, status], pid} =
               RawHttp.exchange(ctx, [
                 RawHttp.get("/magic_link/not-a-real-token"),
                 parser_failure("/leads", ctx.sentinel, ctx.cookie_header)
               ])

      assert status in [400, 500]
      assert_withheld(ctx, pid, [ctx.cookie, ctx.jwt])
    end

    test "after a credential-free request on one connection, a session-bearing failure is withheld",
         ctx do
      assert {[200, status], pid} =
               RawHttp.exchange(ctx, [
                 RawHttp.get("/health"),
                 parser_failure("/leads", ctx.sentinel, ctx.cookie_header)
               ])

      assert status in [400, 500]
      assert_withheld(ctx, pid, [ctx.cookie, ctx.jwt])
    end
  end

  # --- R2: the LiveView socket (dispatched before every declared plug) ---

  describe "R2: the LiveView socket" do
    setup :signed_in

    test "a handshake failure is reported withheld", ctx do
      # Invalid UTF-8 in the query: the transport's query parsing raises
      # before it decodes the session or calls the socket handler.
      request =
        RawHttp.ws_upgrade(
          "/live/websocket?vsn=2.0.0&probe=%FF#{ctx.sentinel}&_csrf_token=#{ctx.csrf}",
          ctx.cookie_header
        )

      assert {[status], pid} = RawHttp.exchange(ctx, [request])
      assert status in 400..599
      assert_withheld(ctx, pid, [ctx.cookie, ctx.jwt])
    end

    test "a transport crash after the upgrade, before any channel, is reported withheld",
         ctx do
      previous = Logger.level()
      on_exit(fn -> Logger.configure(level: previous) end)
      # :debug, so a terminating process's report includes its state.
      Logger.configure(level: :debug)

      {socket, pid} = RawHttp.open(ctx)
      path = "/live/websocket?vsn=2.0.0&_csrf_token=#{ctx.csrf}"
      assert RawHttp.request(socket, RawHttp.ws_upgrade(path, ctx.cookie_header)) == 101

      # Not JSON: the serializer raises in the transport process.
      :ok = :gen_tcp.send(socket, RawHttp.ws_text_frame(~s(["1","1",#{ctx.sentinel})))
      assert_withheld(ctx, pid, [ctx.cookie, ctx.jwt])
      :gen_tcp.close(socket)
    end

    test "long polling is not served", ctx do
      [{"/live", _socket, config}] =
        Enum.filter(SdrAgentWeb.Endpoint.__sockets__(), &(elem(&1, 0) == "/live"))

      assert config[:longpoll] == false
      assert {[404], _pid} = RawHttp.exchange(ctx, [RawHttp.get("/live/longpoll?vsn=2.0.0")])
    end
  end

  # --- positive controls and process reuse -------------------------------

  test "a credential-free parser failure on an ordinary path is reported, conn reduced", ctx do
    assert {[status], pid} = RawHttp.exchange(ctx, [parser_failure("/leads", ctx.sentinel)])
    assert status in [400, 500]
    assert_reported(ctx, pid, "POST", "/leads")
  end

  test "on one connection, an auth request's tag does not withhold a later credential-free report",
       ctx do
    assert {[200, status], pid} =
             RawHttp.exchange(ctx, [
               RawHttp.get("/magic_link/not-a-real-token"),
               parser_failure("/leads", ctx.sentinel)
             ])

    assert status in [400, 500]
    assert_reported(ctx, pid, "POST", "/leads")
  end

  test "on one connection, an ordinary request does not unprotect a later auth crash", ctx do
    query = "token=#{ctx.sentinel}&user=#{ctx.sentinel}"

    assert {[200, 500], pid} =
             RawHttp.exchange(ctx, [
               RawHttp.get("/health"),
               RawHttp.get("/auth/user/magic_link?" <> query)
             ])

    assert_withheld(ctx, pid)
  end
end
