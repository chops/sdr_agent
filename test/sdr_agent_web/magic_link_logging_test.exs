defmodule SdrAgentWeb.MagicLinkLoggingTest do
  @moduledoc """
  No log line carries a magic-link token, at any level the logger can emit
  (debug included): the endpoint's request line skips `/magic_link/…`
  paths, and the router, LiveView mount/event and parameter logs filter
  `token` (`config :phoenix, :filter_parameters`). The whole flow is
  captured at :debug — request the link, open its page (dead and connected
  render), submit the confirmation, sign in — and the token string appears
  nowhere, while ordinary request lines are still logged.
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

      for {key, value} <- previous_env do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    tenant = bootstrap!()
    reviewer = human(:reviewer, tenant)
    System.put_env("SDR_LOGIN_ALLOWLIST", to_string(reviewer.email))
    System.put_env("SDR_MAIL_FROM", "sign-in@example.test")
    Logger.configure(level: :debug)
    %{reviewer: reviewer}
  end

  test "requesting, opening and using a link logs no token at :debug", %{conn: conn} = ctx do
    email = to_string(ctx.reviewer.email)

    log =
      capture_log([level: :debug], fn ->
        requested =
          conn
          |> put_req_header("x-forwarded-for", "198.18.200.7")
          |> post("/auth/user/magic_link/request", %{"user" => %{"email" => email}})

        assert redirected_to(requested) == "/sign-in"
        assert_received {:email, %{text_body: body}}
        [_, token] = Regex.run(~r{/magic_link/([A-Za-z0-9._-]+)}, body)
        send(self(), {:token, token})

        assert build_conn() |> get("/magic_link/#{token}") |> html_response(200)

        {:ok, view, _html} = live(build_conn(), "/magic_link/#{token}")
        view |> element("form") |> render_submit()

        signed_in = post(build_conn(), "/auth/user/magic_link", %{"user" => %{"token" => token}})
        assert redirected_to(signed_in) == "/"
      end)

    assert_received {:token, token}

    # The capture really ran at :debug and :info (positive controls).
    assert log =~ "POST /auth/user/magic_link/request"
    assert log =~ "Processing with"
    assert log =~ "[FILTERED]"

    refute log =~ token
    refute log =~ "GET /magic_link/"
  end

  test "the endpoint's request-line level skips only magic-link paths" do
    assert SdrAgentWeb.Endpoint.log_level(%Plug.Conn{path_info: ["magic_link", "abc"]}) == false
    assert SdrAgentWeb.Endpoint.log_level(%Plug.Conn{path_info: ["sign-in"]}) == :info
    assert SdrAgentWeb.Endpoint.log_level(%Plug.Conn{path_info: []}) == :info
    assert "token" in Application.get_env(:phoenix, :filter_parameters)
  end
end
