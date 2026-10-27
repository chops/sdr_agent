defmodule SdrAgentWeb.AuthControllerTest do
  @moduledoc """
  Password and magic-link sign-in and sign-out through the browser auth
  routes: each outcome is recorded in the audit chain; self-service routes
  (registration, reset, confirmation) do not exist, and a magic link is
  mailed only to an existing user on `SDR_LOGIN_ALLOWLIST`, with the same
  response whether or not one was sent.
  """
  use SdrAgentWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  import SdrAgent.AuditCase,
    only: [bootstrap!: 0, human: 2, events_of_type: 2, test_password: 0]

  import Swoosh.TestAssertions

  @env ["SDR_LOGIN_ALLOWLIST", "SDR_MAIL_FROM"]

  setup do
    previous = Map.new(@env, &{&1, System.get_env(&1)})

    on_exit(fn ->
      SdrAgent.TestSupport.RateLimits.reset()

      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    SdrAgent.TestSupport.RateLimits.reset()
    System.delete_env("SDR_LOGIN_ALLOWLIST")
    System.put_env("SDR_MAIL_FROM", "sign-in@example.test")
    tenant = bootstrap!()
    %{tenant: tenant, reviewer: human(:reviewer, tenant)}
  end

  defp sign_in(conn, email, password) do
    post(conn, "/auth/user/password/sign_in", %{
      "user" => %{"email" => email, "password" => password}
    })
  end

  test "a correct password signs in and is recorded", %{conn: conn} = ctx do
    conn = sign_in(conn, to_string(ctx.reviewer.email), test_password())

    assert redirected_to(conn) == "/"
    assert [event] = events_of_type(ctx.tenant, "auth.sign_in.succeeded")
    assert event.actor_id == ctx.reviewer.id
  end

  test "a wrong password is refused and recorded anonymously", %{conn: conn} = ctx do
    conn = sign_in(conn, to_string(ctx.reviewer.email), "wrong-password-0")

    assert redirected_to(conn) == "/sign-in"
    assert [event] = events_of_type(ctx.tenant, "auth.sign_in.failed")
    assert event.actor_type == :anonymous
  end

  test "signing out is recorded for the signed-in user", %{conn: conn} = ctx do
    conn = sign_in(conn, to_string(ctx.reviewer.email), test_password())
    conn = conn |> recycle() |> delete("/sign-out")

    assert redirected_to(conn) == "/"
    assert [event] = events_of_type(ctx.tenant, "auth.signed_out")
    assert event.actor_id == ctx.reviewer.id
  end

  test "self-service account routes are not served; the magic-link routes are" do
    routes = Enum.map(Phoenix.Router.routes(SdrAgentWeb.Router), &{&1.verb, &1.path})

    for {_verb, path} <- routes do
      refute path =~ ~r/register|reset|confirm/, "unexpected route #{path}"
    end

    # Sign-in only (registration is disabled): request a link, open it, sign in.
    magic = for {verb, path} <- routes, path =~ ~r/magic/, do: {verb, path}
    assert Enum.sort(magic) == [{:get, "/magic_link/:token"}]
  end

  describe "magic link" do
    # Each request comes from its own client address (the proxy's
    # X-Forwarded-For), so the per-client request limit never couples tests.
    defp request_link(conn, email) do
      n = System.unique_integer([:positive])

      conn
      |> put_req_header("x-forwarded-for", "198.18.#{rem(n, 250)}.#{rem(div(n, 250), 250) + 1}")
      |> post("/auth/user/magic_link/request", %{"user" => %{"email" => email}})
    end

    test "the sign-in page offers the email-link form next to the password form", %{conn: conn} do
      html = conn |> get("/sign-in") |> html_response(200)

      assert html =~ ~s(action="/auth/user/magic_link/request")
      assert html =~ ~s(action="/auth/user/password/sign_in")
    end

    test "an allowlisted user's link opens a confirmation page and signs in once",
         %{conn: conn} = ctx do
      email = to_string(ctx.reviewer.email)
      System.put_env("SDR_LOGIN_ALLOWLIST", email)

      requested = request_link(conn, email)
      assert redirected_to(requested) == "/sign-in"

      assert_received {:email, %{text_body: body}}
      [_, token] = Regex.run(~r{/magic_link/([A-Za-z0-9._-]+)}, body)
      refute_email_sent()

      page = build_conn() |> get("/magic_link/#{token}") |> html_response(200)
      assert page =~ ~s(action="/auth/user/magic_link")

      signed_in = post(build_conn(), "/auth/user/magic_link", %{"user" => %{"token" => token}})
      assert redirected_to(signed_in) == "/"
      assert get_session(signed_in, "user_token")

      assert [event] = events_of_type(ctx.tenant, "auth.sign_in.succeeded")
      assert {event.actor_id, event.payload["strategy"]} == {ctx.reviewer.id, "magic_link"}

      reused = post(build_conn(), "/auth/user/magic_link", %{"user" => %{"token" => token}})
      assert redirected_to(reused) == "/sign-in"
      refute get_session(reused, "user_token")
    end

    test "a request for an address not on the allowlist answers the same and sends nothing",
         %{conn: conn} = ctx do
      System.put_env("SDR_LOGIN_ALLOWLIST", "someone.else@example.test")

      for email <- [to_string(ctx.reviewer.email), "nobody.here@example.test"] do
        requested = capture_log(fn -> send(self(), {:conn, request_link(conn, email)}) end)
        assert_received {:conn, requested_conn}
        assert redirected_to(requested_conn) == "/sign-in"
        refute requested =~ email
        refute_email_sent()
      end
    end

    test "the confirmation page is not cached, sends no referrer and loads nothing external",
         %{conn: conn} do
      for path <- ["/magic_link/not-a-real-token", "/sign-in"] do
        page = get(build_conn(), path)

        assert html_response(page, 200)
        assert get_resp_header(page, "cache-control") == ["no-store"], path
        assert get_resp_header(page, "referrer-policy") == ["no-referrer"], path
        refute html_response(page, 200) =~ ~r{(src|href)="https?://}, path
      end

      assert conn |> request_link("nobody.else@example.test") |> get_resp_header("cache-control") ==
               ["no-store"]
    end
  end

  describe "enforced allowlist (prod)" do
    setup do
      previous = Application.fetch_env(:sdr_agent, :login_allowlist_enforced)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:sdr_agent, :login_allowlist_enforced, value)
          :error -> Application.delete_env(:sdr_agent, :login_allowlist_enforced)
        end
      end)

      Application.put_env(:sdr_agent, :login_allowlist_enforced, true)
      :ok
    end

    test "a user off the list gets the ordinary failure, no session, and an audited refusal",
         %{conn: conn} = ctx do
      System.put_env("SDR_LOGIN_ALLOWLIST", "someone.else@example.test")

      conn = sign_in(conn, to_string(ctx.reviewer.email), test_password())

      assert redirected_to(conn) == "/sign-in"
      refute get_session(conn, "user_token")
      assert [event] = events_of_type(ctx.tenant, "auth.sign_in.failed")
      assert event.actor_type == :anonymous
    end

    test "a console session ends once its user is off the list", %{conn: conn} = ctx do
      email = to_string(ctx.reviewer.email)
      System.put_env("SDR_LOGIN_ALLOWLIST", email)

      conn = sign_in(conn, email, test_password())
      assert redirected_to(conn) == "/"
      console = conn |> recycle() |> get("/")
      assert html_response(console, 200)

      System.put_env("SDR_LOGIN_ALLOWLIST", "someone.else@example.test")
      refused = console |> recycle() |> get("/")
      assert redirected_to(refused) == "/sign-in"
    end

    test "public answers do not reveal who is on the list", %{conn: conn} = ctx do
      owner = to_string(ctx.reviewer.email)
      other = human(:admin, ctx.tenant)
      System.put_env("SDR_LOGIN_ALLOWLIST", owner)

      answers =
        for email <- [
              owner,
              to_string(other.email),
              "nobody.anywhere@example.test",
              "not an address"
            ] do
          requested = request_link(conn, email)
          {redirected_to(requested), Phoenix.Flash.get(requested.assigns.flash, :info)}
        end

      assert [_one] = Enum.uniq(answers)

      # A listed user with a wrong password and an unlisted one with the right
      # password get the same refusal.
      wrong = sign_in(conn, owner, "wrong-password-0")
      unlisted = sign_in(conn, to_string(other.email), test_password())

      assert {redirected_to(wrong), Phoenix.Flash.get(wrong.assigns.flash, :error)} ==
               {redirected_to(unlisted), Phoenix.Flash.get(unlisted.assigns.flash, :error)}
    end
  end
end
