defmodule SdrAgentWeb.HostedEnrollmentControllerTest do
  @moduledoc """
  S-B5 browser RED: fragment-only enrollment, CSRF POST, session renewal and
  closed failures. A route assertion precedes fixtures so absent routes fail
  on the intended missing contract, not on unrelated schema prerequisites.
  Domain consumption is real, never mocked. Only synthetic owner identities.
  """
  use SdrAgentWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias SdrAgent.Accounts
  alias SdrAgent.HostedOwnerFixtures, as: H

  @path "/hosted-enrollment"

  defp require_route!(verb) do
    routes = Phoenix.Router.routes(SdrAgentWeb.Router)

    assert Enum.any?(routes, &(&1.path == @path and &1.verb == verb)),
           "missing #{verb} #{@path} enrollment route"
  end

  test "GET is an inert no-store no-referrer form with only bundled scripts", %{conn: conn} do
    require_route!(:get)
    conn = get(conn, @path)
    html = html_response(conn, 200)
    document = LazyHTML.from_document(html)
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_session(conn, "user_token") == nil

    assert Enum.count(
             LazyHTML.query(
               document,
               "form#hosted-enrollment-form[method=post][action='#{@path}']"
             )
           ) == 1

    assert Enum.count(LazyHTML.query(document, "input[name=_csrf_token]")) == 1

    assert LazyHTML.attribute(LazyHTML.query(document, "input[name=enrollment_token]"), "value") in [
             [],
             [""]
           ]

    assert LazyHTML.attribute(LazyHTML.query(document, "button[type=submit]"), "disabled") != []

    for script <- LazyHTML.query(document, "script") do
      assert LazyHTML.attribute(script, "src") == ["/assets/js/app.js"]
    end

    refute html =~ "https://"
  end

  test "GET neither consumes the link nor places it in response or debug logs", %{conn: conn} do
    require_route!(:get)
    ctx = H.activated!()
    %{enrollment_token: link} = H.enrol!(ctx)

    log =
      capture_log([level: :debug], fn ->
        # A browser's fragment is not part of this HTTP request.
        body = conn |> get(@path) |> html_response(200)
        refute body =~ link
      end)

    refute log =~ link
    assert {:ok, _user} = H.consume(link)
  end

  test "the console URL presenter places the secret only in its fragment" do
    presenter = SdrAgentWeb.HostedEnrollment
    assert Code.ensure_loaded?(presenter), "missing console enrollment URL presenter"
    assert function_exported?(presenter, :url, 1)
    token = "synthetic.header.signature"
    uri = URI.parse(Kernel.apply(Function.capture(presenter, :url, 1), [token]))
    assert uri.path == @path
    assert uri.query == nil
    assert uri.userinfo == nil
    assert URI.decode_query(uri.fragment) == %{"enrollment_token" => token}

    assert Map.take(uri, [:scheme, :host, :port]) ==
             Map.take(URI.parse(SdrAgentWeb.Endpoint.url()), [:scheme, :host, :port])
  end

  test "POST exchanges a link, clears old session state and renews the session", %{conn: conn} do
    require_route!(:post)
    ctx = H.activated!()
    %{enrollment_token: link, user: user} = H.enrol!(ctx)

    conn =
      conn
      |> init_test_session(%{sentinel: "discard", return_to: "https://example.test/foreign"})
      |> post(@path, %{enrollment_token: link})

    assert redirected_to(conn) == "/"
    assert get_session(conn, :sentinel) == nil
    assert get_session(conn, :return_to) == nil
    assert conn.private[:plug_session_info] == :renew
    token = get_session(conn, "user_token")
    assert is_binary(token) and token != link
    assert {:ok, %{id: id}} = Accounts.current_operator(token)
    assert id == user.id
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
  end

  test "POST filters the JWT from debug request logs", %{conn: conn} do
    require_route!(:post)
    ctx = H.activated!()
    %{enrollment_token: link} = H.enrol!(ctx)

    log =
      capture_log([level: :debug], fn ->
        conn = post(conn, @path, %{enrollment_token: link})
        assert redirected_to(conn) == "/"
      end)

    refute log =~ link
  end

  test "malformed and missing links return the same closed failure without a session" do
    require_route!(:post)

    for params <- [%{}, %{enrollment_token: "not-a-token"}] do
      conn = post(build_conn(), @path, params)
      assert redirected_to(conn) == @path
      assert get_session(conn, "user_token") == nil
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Enrollment link is not valid."
    end
  end

  test "a replay cannot create a second browser session", %{conn: conn} do
    require_route!(:post)
    ctx = H.activated!()
    %{enrollment_token: link} = H.enrol!(ctx)
    first = post(conn, @path, %{enrollment_token: link})
    assert redirected_to(first) == "/"
    replay = post(build_conn(), @path, %{enrollment_token: link})
    assert redirected_to(replay) == @path
    assert get_session(replay, "user_token") == nil
  end

  test "a disabled owner cannot exchange an unused link", %{conn: conn} do
    require_route!(:post)
    ctx = H.activated!()
    %{enrollment_token: link, owner: owner} = H.enrol!(ctx)
    assert {:ok, _} = H.disable(ctx, owner.id)
    conn = post(conn, @path, %{enrollment_token: link})
    assert redirected_to(conn) == @path
    assert get_session(conn, "user_token") == nil
  end

  test "POST with CSRF protection enabled rejects an absent CSRF token", %{conn: conn} do
    require_route!(:post)

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      conn
      |> put_private(:plug_skip_csrf_protection, false)
      |> post(@path, %{enrollment_token: "synthetic-not-a-jwt"})
    end
  end
end
