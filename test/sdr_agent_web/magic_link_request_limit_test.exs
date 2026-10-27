defmodule SdrAgentWeb.MagicLinkRequestLimitTest do
  @moduledoc """
  Unauthenticated magic-link requests are bounded before anything is minted
  or sent (Codex M3): per client address 5 per 10 minutes (before the
  request action), and per destination address 3 per 15 minutes and 30 in
  total per 10 minutes (before the request preparation mints). Over a bound
  the answer is the same flash and redirect, no token is minted and no mail
  sent, whether the address is listed, unknown or malformed; concurrent
  requests never exceed a bound; each window recovers when it ends. The
  client address is the last X-Forwarded-For entry only from a loopback
  peer (the proxy on this host), else the peer itself.
  """
  use SdrAgentWeb.ConnCase, async: false

  import SdrAgent.AuditCase, only: [bootstrap!: 0, human: 2]

  alias SdrAgent.Clock

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
    tenant = bootstrap!()
    reviewer = human(:reviewer, tenant)
    System.put_env("SDR_LOGIN_ALLOWLIST", to_string(reviewer.email))
    System.put_env("SDR_MAIL_FROM", "sign-in@example.test")
    Clock.freeze(DateTime.utc_now())
    %{email: to_string(reviewer.email), t0: Clock.utc_now()}
  end

  defp request(email, ip, peer \\ {127, 0, 0, 1}) do
    %{build_conn() | remote_ip: peer}
    |> put_req_header("x-forwarded-for", ip)
    |> post("/auth/user/magic_link/request", %{"user" => %{"email" => email}})
  end

  defp unknown, do: "u#{System.unique_integer([:positive])}@example.test"
  defp tokens, do: Ash.count!(SdrAgent.Accounts.Token, authorize?: false)
  defp flash(conn), do: {redirected_to(conn), Phoenix.Flash.get(conn.assigns.flash, :info)}

  defp sent do
    receive do
      {:email, _} -> 1 + sent()
    after
      0 -> 0
    end
  end

  test "a client's sixth request in ten minutes reaches nothing; another client and the next window do",
       ctx do
    admitted = for _ <- 1..5, do: request(unknown(), "203.0.113.7")
    before = tokens()

    limited = request(ctx.email, "203.0.113.7")

    assert flash(limited) == flash(hd(admitted))
    assert {tokens(), sent()} == {before, 0}

    request(ctx.email, "203.0.113.8")
    assert {tokens(), sent()} == {before + 1, 1}

    Clock.freeze(DateTime.add(ctx.t0, 10, :minute))
    request(ctx.email, "203.0.113.7")
    assert {tokens(), sent()} == {before + 2, 1}
  end

  test "X-Forwarded-For names the client only from a loopback peer, by its last entry", ctx do
    # From the proxy (loopback): the last entry is the client, earlier ones are ignored.
    for n <- 1..5, do: request(unknown(), "198.51.100.#{n}, 203.0.113.50")
    before = tokens()
    request(ctx.email, "198.51.100.99, 203.0.113.50")
    assert {tokens(), sent()} == {before, 0}

    # From any other peer the header is ignored: the peer is the client.
    for n <- 1..5, do: request(unknown(), "203.0.113.#{100 + n}", {192, 0, 2, 1})
    request(ctx.email, "203.0.113.200", {192, 0, 2, 1})
    assert {tokens(), sent()} == {before, 0}

    # A malformed header falls back to the loopback peer, a client of its own.
    request(ctx.email, "not-an-address")
    assert {tokens(), sent()} == {before + 1, 1}
  end

  test "one destination gets at most three links per fifteen minutes, minted or not", ctx do
    before = tokens()
    first = for n <- 1..3, do: request(String.upcase(ctx.email), "198.18.1.#{n}")
    assert {tokens(), sent()} == {before + 3, 3}

    over = request(" " <> ctx.email <> " ", "198.18.1.4")
    assert flash(over) == flash(hd(first))
    assert {tokens(), sent()} == {before + 3, 0}

    # Unknown and malformed destinations are bounded the same way and answered the same.
    for email <- ["nobody.listed@example.test", "not an address"] do
      answers = for n <- 1..4, do: flash(request(email, "198.18.2.#{n}"))
      assert Enum.uniq(answers) == [flash(hd(first))]
    end

    Clock.freeze(DateTime.add(ctx.t0, 15, :minute))
    request(ctx.email, "198.18.1.5")
    assert {tokens(), sent()} == {before + 4, 1}
  end

  test "concurrent requests for one destination mint and send exactly three", ctx do
    before = tokens()

    1..8
    |> Task.async_stream(fn n -> request(ctx.email, "198.18.3.#{n}") end, max_concurrency: 8)
    |> Enum.each(fn {:ok, conn} -> assert redirected_to(conn) == "/sign-in" end)

    assert {tokens(), sent()} == {before + 3, 3}
  end

  test "the thirty-first request in ten minutes reaches nothing, from any client", ctx do
    for n <- 1..30, do: request(unknown(), "198.51.100.#{n}")
    before = tokens()

    limited = request(ctx.email, "198.51.100.200")

    assert redirected_to(limited) == "/sign-in"
    assert {tokens(), sent()} == {before, 0}

    Clock.freeze(DateTime.add(ctx.t0, 10, :minute))
    request(ctx.email, "198.51.100.201")
    assert {tokens(), sent()} == {before + 1, 1}
  end
end
