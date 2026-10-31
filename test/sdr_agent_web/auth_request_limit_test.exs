defmodule SdrAgentWeb.AuthRequestLimitTest do
  @moduledoc """
  Hosted auth hardening plan r1, S3 (entity delta r1 RateLimitBucket, Codex
  m_codex_g4_auth_entity_r1_pass_20261031): unauthenticated credential
  attempts are bounded before the action runs, with no client-address key
  (behind Caddy every peer is the loopback).

    * Password sign-in: one global bucket of 30 per minute, checked first,
      then 5 per 15 minutes per sha256 of the trimmed, downcased email. A
      missing, malformed or nested email counts against the global bucket
      only. Over a bound the answer is the wrong-credential answer (same
      flash and redirect), the sign-in action never runs (no audit event,
      no session) and a correct password is not admitted.
    * Hosted enrollment POST: one global bucket of 10 per 15 minutes; over
      it the answer is the invalid-link answer and the link is not consumed
      (it still works in the next window). The token is never a key.
    * Concurrent attempts never exceed a bound; each window recovers when it
      ends; no limiter key holds an email in clear.
  """
  use SdrAgentWeb.ConnCase, async: false

  import SdrAgent.AuditCase,
    only: [bootstrap!: 0, human: 2, events_of_type: 2, test_password: 0]

  alias SdrAgent.Clock
  alias SdrAgent.HostedOwnerFixtures, as: H
  alias SdrAgent.TestSupport.RateLimits

  setup do
    RateLimits.reset()

    on_exit(fn ->
      RateLimits.reset()
      Clock.unfreeze()
    end)

    Clock.freeze(DateTime.utc_now())
    :ok
  end

  defp limiter_loaded! do
    assert Code.ensure_loaded?(SdrAgent.RateLimiter), "SdrAgent.RateLimiter is not defined"
  end

  defp sign_in(email, password) do
    post(build_conn(), "/auth/user/password/sign_in", %{
      "user" => %{"email" => email, "password" => password}
    })
  end

  defp answer(conn), do: {redirected_to(conn), Phoenix.Flash.get(conn.assigns.flash, :error)}
  defp signed_in?(conn), do: redirected_to(conn) == "/"
  defp unknown, do: "u#{System.unique_integer([:positive])}@example.test"

  describe "password sign-in" do
    setup do
      tenant = bootstrap!()
      reviewer = human(:reviewer, tenant)
      %{tenant: tenant, email: to_string(reviewer.email), t0: Clock.utc_now()}
    end

    test "the sixth attempt for one email in fifteen minutes is refused before the action",
         ctx do
      limiter_loaded!()
      wrong = for n <- 1..5, do: sign_in(ctx.email, "wrong-password-#{n}")
      failed = length(events_of_type(ctx.tenant, "auth.sign_in.failed"))

      limited = sign_in(" " <> String.upcase(ctx.email) <> " ", test_password())

      refute signed_in?(limited)
      assert answer(limited) == answer(hd(wrong))
      assert events_of_type(ctx.tenant, "auth.sign_in.succeeded") == []
      assert length(events_of_type(ctx.tenant, "auth.sign_in.failed")) == failed

      # Another email is unaffected; the next window admits this one again.
      assert answer(sign_in(unknown(), "x")) == answer(hd(wrong))
      Clock.freeze(DateTime.add(ctx.t0, 15, :minute))
      assert signed_in?(sign_in(ctx.email, test_password()))
    end

    test "the thirty-first attempt in a minute is refused for any email", ctx do
      limiter_loaded!()
      for _ <- 1..30, do: sign_in(unknown(), "x")

      limited = sign_in(ctx.email, test_password())
      refute signed_in?(limited)
      assert events_of_type(ctx.tenant, "auth.sign_in.succeeded") == []

      Clock.freeze(DateTime.add(ctx.t0, 1, :minute))
      assert signed_in?(sign_in(ctx.email, test_password()))
    end

    test "the global bucket is checked first: a refused attempt charges no email bucket",
         ctx do
      limiter_loaded!()
      for _ <- 1..30, do: sign_in(unknown(), "x")

      refute signed_in?(sign_in(ctx.email, "wrong-password-0"))

      hash = :crypto.hash(:sha256, String.downcase(String.trim(ctx.email)))
      rows = inspect(:ets.tab2list(SdrAgent.RateLimiter), limit: :infinity)
      refute rows =~ inspect(hash, limit: :infinity)
      refute rows =~ Base.encode16(hash, case: :lower)
      refute rows =~ Base.encode16(hash)

      # After the global window rolls over the email has its full five.
      Clock.freeze(DateTime.add(ctx.t0, 1, :minute))
      before = length(events_of_type(ctx.tenant, "auth.sign_in.failed"))
      for n <- 1..5, do: refute(signed_in?(sign_in(ctx.email, "wrong-password-#{n}")))
      assert length(events_of_type(ctx.tenant, "auth.sign_in.failed")) == before + 5
      refute signed_in?(sign_in(ctx.email, test_password()))
      assert length(events_of_type(ctx.tenant, "auth.sign_in.failed")) == before + 5
    end

    test "missing, malformed and nested emails count globally only", ctx do
      limiter_loaded!()

      shapes = [
        %{"password" => "x"},
        %{"email" => %{"nested" => ctx.email}, "password" => "x"},
        %{"email" => ["a", ctx.email], "password" => "x"},
        %{"email" => "not an address", "password" => "x"}
      ]

      for shape <- shapes, _ <- 1..6 do
        conn = post(build_conn(), "/auth/user/password/sign_in", %{"user" => shape})
        refute signed_in?(conn)
      end

      # 24 global hits so far, and none was charged to the real email.
      assert signed_in?(sign_in(ctx.email, test_password()))
    end

    test "concurrent attempts for one email reach the action at most five times", ctx do
      limiter_loaded!()

      1..12
      |> Task.async_stream(fn n -> sign_in(ctx.email, "wrong-password-#{n}") end,
        max_concurrency: 12
      )
      |> Enum.each(fn {:ok, conn} -> assert redirected_to(conn) == "/sign-in" end)

      assert length(events_of_type(ctx.tenant, "auth.sign_in.failed")) == 5
    end

    test "no limiter key holds an email in clear", ctx do
      limiter_loaded!()
      sign_in(ctx.email, "wrong-password-0")
      rows = :ets.tab2list(SdrAgent.RateLimiter)
      assert rows != []
      refute inspect(rows, limit: :infinity) =~ ctx.email
      refute inspect(rows, limit: :infinity) =~ String.downcase(ctx.email)
    end
  end

  describe "hosted enrollment" do
    test "the eleventh POST in fifteen minutes is refused and does not consume a link" do
      limiter_loaded!()
      t0 = Clock.utc_now()
      ctx = H.activated!()
      %{enrollment_token: link} = H.enrol!(ctx)

      bad =
        for _ <- 1..10,
            do:
              post(build_conn(), "/hosted-enrollment", %{enrollment_token: "synthetic-not-a-jwt"})

      limited = post(build_conn(), "/hosted-enrollment", %{enrollment_token: link})
      assert redirected_to(limited) == redirected_to(hd(bad))

      assert Phoenix.Flash.get(limited.assigns.flash, :error) ==
               Phoenix.Flash.get(hd(bad).assigns.flash, :error)

      rows = :ets.tab2list(SdrAgent.RateLimiter)
      refute inspect(rows, limit: :infinity) =~ link

      Clock.freeze(DateTime.add(t0, 15, :minute))
      admitted = post(build_conn(), "/hosted-enrollment", %{enrollment_token: link})
      assert redirected_to(admitted) == "/"
    end
  end

  describe "no-store and no-referrer (regression guards)" do
    test "sign-in, enrollment and the auth answer are never stored and send no referrer" do
      for conn <- [
            get(build_conn(), "/sign-in"),
            get(build_conn(), "/hosted-enrollment"),
            post(build_conn(), "/hosted-enrollment", %{enrollment_token: "x"}),
            sign_in(unknown(), "x")
          ] do
        assert get_resp_header(conn, "cache-control") == ["no-store"], conn.request_path
        assert get_resp_header(conn, "referrer-policy") == ["no-referrer"], conn.request_path
      end
    end
  end
end
