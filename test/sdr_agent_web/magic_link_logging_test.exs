defmodule SdrAgentWeb.MagicLinkLoggingTest do
  @moduledoc """
  No log line carries a magic-link token or a requester's email address, at
  any level the logger can emit, debug included (Codex M2). The endpoint's
  own request line is suppressed for `/magic_link/…` before routing, and
  the router, LiveView (mount, params, events) and parameter logs filter
  `token` and `email` (`config :phoenix, :filter_parameters`). Each flow is
  captured at :debug through the real routes — request a link, GET the
  confirmation page (dead and connected render), submit it, POST the
  sign-in — for success, refusal (a spent or unlisted link) and error (a
  malformed token); ordinary request lines are still logged.
  """
  use SdrAgentWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import SdrAgent.AuditCase, only: [bootstrap!: 0, human: 2]

  @env ["SDR_LOGIN_ALLOWLIST", "SDR_MAIL_FROM"]

  setup do
    previous_env = Map.new(@env, &{&1, System.get_env(&1)})
    previous_level = Logger.level()

    on_exit(fn ->
      Logger.configure(level: previous_level)
      SdrAgent.TestSupport.RateLimits.reset()

      for {key, value} <- previous_env do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    SdrAgent.TestSupport.RateLimits.reset()
    tenant = bootstrap!()
    reviewer = human(:reviewer, tenant)
    System.put_env("SDR_LOGIN_ALLOWLIST", to_string(reviewer.email))
    System.put_env("SDR_MAIL_FROM", "sign-in@example.test")
    Logger.configure(level: :debug)
    %{reviewer: reviewer, email: to_string(reviewer.email)}
  end

  defp request(email) do
    build_conn()
    |> put_req_header("x-forwarded-for", "198.18.200.7")
    |> post("/auth/user/magic_link/request", %{"user" => %{"email" => email}})
  end

  # GET the confirmation page (dead render), connect to it and submit its
  # form, then POST the sign-in, as the browser does.
  defp open_and_sign_in(token) do
    assert build_conn() |> get("/magic_link/#{token}") |> html_response(200)
    {:ok, view, _html} = live(build_conn(), "/magic_link/#{token}")
    view |> element("form") |> render_submit()
    post(build_conn(), "/auth/user/magic_link", %{"user" => %{"token" => token}})
  end

  defp assert_clean(log, secrets) do
    # The capture really ran at :info and :debug (positive controls).
    assert log =~ "POST /auth/user/magic_link"
    assert log =~ "Processing with"

    for secret <- secrets do
      refute String.contains?(String.downcase(log), String.downcase(secret)),
             "the log contains #{inspect(String.slice(secret, 0, 6))}…"
    end

    refute log =~ "/magic_link/ey"
  end

  test "success: request, confirmation page and sign-in log no token or address", ctx do
    log =
      capture_log([level: :debug], fn ->
        assert redirected_to(request(ctx.email)) == "/sign-in"
        assert_received {:email, %{text_body: body}}
        [_, token] = Regex.run(~r{/magic_link/([A-Za-z0-9._-]+)}, body)
        send(self(), {:token, token})
        assert redirected_to(open_and_sign_in(token)) == "/"
      end)

    assert_received {:token, token}
    assert_clean(log, [token, ctx.email])
  end

  test "refusal: a spent link and an unlisted request log no token or address", ctx do
    assert redirected_to(request(ctx.email)) == "/sign-in"
    assert_received {:email, %{text_body: body}}
    [_, token] = Regex.run(~r{/magic_link/([A-Za-z0-9._-]+)}, body)
    assert redirected_to(open_and_sign_in(token)) == "/"

    log =
      capture_log([level: :debug], fn ->
        assert redirected_to(open_and_sign_in(token)) == "/sign-in"
        assert redirected_to(request("unlisted.person@example.test")) == "/sign-in"
      end)

    assert_clean(log, [token, ctx.email, "unlisted.person@example.test"])
  end

  test "error: a malformed token is not logged" do
    token =
      "eyJmalformed.not-a-real.token-" <> Integer.to_string(System.unique_integer([:positive]))

    log =
      capture_log([level: :debug], fn ->
        assert redirected_to(open_and_sign_in(token)) == "/sign-in"
      end)

    assert log =~ "POST /auth/user/magic_link"
    refute log =~ token
    refute log =~ "/magic_link/ey"
  end

  # Crashes the connected view by an event it does not handle (as a
  # malformed or hostile client message would) and returns the captured log.
  defp crash(view) do
    Process.flag(:trap_exit, true)

    capture_log([level: :debug], fn ->
      catch_exit(render_hook(view, "no-such-event", %{"x" => "1"}))
      ref = Process.monitor(view.pid)
      assert_receive {:DOWN, ^ref, _, _, _}, 2_000
      Process.sleep(100)
    end)
  end

  test "a crashing confirmation page reports no token (OTP report withheld)", ctx do
    {:ok, token} =
      AshAuthentication.Strategy.MagicLink.request_token_for(
        AshAuthentication.Info.strategy!(SdrAgent.Accounts.User, :magic_link),
        ctx.reviewer
      )

    {:ok, view, _html} = live(build_conn(), "/magic_link/#{token}")
    log = crash(view)

    # Positive control: a report about the crash was emitted.
    assert log =~ ~r/terminating|diagnostic withheld/
    refute log =~ token
  end

  test "a crashing sign-in page reports no typed password or address", ctx do
    {:ok, view, _html} = live(build_conn(), "/sign-in")
    typed = "typed-secret-" <> Integer.to_string(System.unique_integer([:positive]))

    view
    |> element("#user-password-sign-in-with-password")
    |> render_change(%{"user" => %{"email" => ctx.email, "password" => typed}})

    log = crash(view)

    assert log =~ ~r/terminating|diagnostic withheld/
    refute log =~ typed
    refute String.downcase(log) =~ String.downcase(ctx.email)
  end

  test "an authenticated console mount at :debug logs no session token", ctx do
    assert redirected_to(request(ctx.email)) == "/sign-in"
    assert_received {:email, %{text_body: body}}
    [_, token] = Regex.run(~r{/magic_link/([A-Za-z0-9._-]+)}, body)
    signed_in = post(build_conn(), "/auth/user/magic_link", %{"user" => %{"token" => token}})
    session_token = get_session(signed_in, "user_token")
    assert is_binary(session_token)

    log =
      capture_log([level: :debug], fn ->
        {:ok, _view, _html} = signed_in |> recycle() |> live("/")
      end)

    # Positive control: the connected mount was logged at :debug.
    assert log =~ "MOUNT SdrAgentWeb.DashboardLive"
    refute log =~ session_token
    refute log =~ token
  end
end
