defmodule SdrAgentWeb.MagicLinkRequestLimitTest do
  @moduledoc """
  Unauthenticated magic-link requests are bounded before the request action
  runs (`SdrAgentWeb.MagicLinkRequestLimit` on `POST
  /auth/user/magic_link/request`): 5 per client address and 30 in total per
  10 minutes. Over the limit the answer is the same flash and redirect,
  and no token is minted and no mail sent; the next window admits again.
  The client address is X-Forwarded-For only from a loopback peer (the
  proxy on the same host), else the peer itself.
  """
  use SdrAgentWeb.ConnCase, async: false

  import Swoosh.TestAssertions
  import SdrAgent.AuditCase, only: [bootstrap!: 0, human: 2]

  alias SdrAgent.Clock
  alias SdrAgent.RateLimiter
  alias SdrAgentWeb.MagicLinkRequestLimit

  @env ["SDR_LOGIN_ALLOWLIST", "SDR_MAIL_FROM"]
  @unknown "nobody.here@example.test"

  setup do
    previous = Map.new(@env, &{&1, System.get_env(&1)})

    on_exit(fn ->
      RateLimiter.reset()

      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    RateLimiter.reset()
    tenant = bootstrap!()
    reviewer = human(:reviewer, tenant)
    System.put_env("SDR_LOGIN_ALLOWLIST", to_string(reviewer.email))
    System.put_env("SDR_MAIL_FROM", "sign-in@example.test")
    %{email: to_string(reviewer.email)}
  end

  defp request(ip, email) do
    build_conn()
    |> put_req_header("x-forwarded-for", ip)
    |> post("/auth/user/magic_link/request", %{"user" => %{"email" => email}})
  end

  defp tokens, do: Ash.count!(SdrAgent.Accounts.Token, authorize?: false)
  defp flash(conn), do: Phoenix.Flash.get(conn.assigns.flash, :info)

  test "a client's sixth request in ten minutes mints no token and sends nothing", ctx do
    t0 = DateTime.utc_now()
    Clock.freeze(t0)

    admitted = for _ <- 1..5, do: request("203.0.113.7", @unknown)
    assert Enum.all?(admitted, &(redirected_to(&1) == "/sign-in"))

    before = tokens()
    limited = request("203.0.113.7", ctx.email)

    assert redirected_to(limited) == "/sign-in"
    assert flash(limited) == flash(hd(admitted))
    assert tokens() == before
    refute_email_sent()

    # Another client is unaffected; the same client is admitted in the next window.
    request("203.0.113.8", ctx.email)
    assert tokens() == before + 1
    assert_received {:email, _}

    Clock.freeze(DateTime.add(t0, 10, :minute))
    request("203.0.113.7", ctx.email)
    assert tokens() == before + 2
    assert_received {:email, _}
  end

  test "the thirty-first request in ten minutes is refused from any client", ctx do
    for n <- 1..30, do: request("198.51.100.#{n}", @unknown)

    before = tokens()
    limited = request("198.51.100.200", ctx.email)

    assert redirected_to(limited) == "/sign-in"
    assert tokens() == before
    refute_email_sent()
  end

  test "X-Forwarded-For counts only from a loopback peer; its last valid entry is the client" do
    xff = fn peer, value ->
      %Plug.Conn{
        remote_ip: peer,
        req_headers: if(value, do: [{"x-forwarded-for", value}], else: [])
      }
    end

    assert MagicLinkRequestLimit.client_ip(xff.({127, 0, 0, 1}, "203.0.113.9")) ==
             {203, 0, 113, 9}

    assert MagicLinkRequestLimit.client_ip(xff.({127, 0, 0, 1}, "198.51.100.1, 203.0.113.9")) ==
             {203, 0, 113, 9}

    assert MagicLinkRequestLimit.client_ip(xff.({0, 0, 0, 0, 0, 0, 0, 1}, "2001:db8::1")) ==
             {8193, 3512, 0, 0, 0, 0, 0, 1}

    assert MagicLinkRequestLimit.client_ip(xff.({127, 0, 0, 1}, "not-an-address")) ==
             {127, 0, 0, 1}

    assert MagicLinkRequestLimit.client_ip(xff.({127, 0, 0, 1}, nil)) == {127, 0, 0, 1}
    assert MagicLinkRequestLimit.client_ip(xff.({192, 0, 2, 1}, "203.0.113.9")) == {192, 0, 2, 1}
  end
end
