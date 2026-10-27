defmodule SdrAgent.Accounts.LoginAllowlistTest do
  @moduledoc """
  Hosted owner-only admission (Codex M1). In the declared hosted mode
  (`config :sdr_agent, :login_allowlist_enforced`, true in prod, false in
  dev and test) every way in admits a user only if their lowercased email is
  on `SDR_LOGIN_ALLOWLIST`, read at call time: the magic-link request (no
  token is minted for anyone else), password sign-in, magic-link sign-in,
  and every session or token resolution (`get_by_subject`, so
  `Accounts.current_operator/1` and the console's LiveView hooks). A
  missing, empty, blank or malformed list admits nobody, and so does a
  switch missing or set to anything but `false`. A refused sign-in is audited as
  `auth.sign_in.failed` like any other. With the switch off, nothing
  changes.
  """
  use SdrAgent.AuditCase, async: false

  import ExUnit.CaptureLog
  import Swoosh.TestAssertions

  alias AshAuthentication.Info
  alias AshAuthentication.Strategy
  alias AshAuthentication.Strategy.MagicLink
  alias SdrAgent.Accounts
  alias SdrAgent.Accounts.User

  @env ["SDR_LOGIN_ALLOWLIST", "SDR_MAIL_FROM"]

  setup do
    previous_env = Map.new(@env, &{&1, System.get_env(&1)})
    previous_enforced = Application.fetch_env(:sdr_agent, :login_allowlist_enforced)

    on_exit(fn ->
      SdrAgent.TestSupport.RateLimits.reset()

      for {key, value} <- previous_env do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end

      case previous_enforced do
        {:ok, value} -> Application.put_env(:sdr_agent, :login_allowlist_enforced, value)
        :error -> Application.delete_env(:sdr_agent, :login_allowlist_enforced)
      end
    end)

    SdrAgent.TestSupport.RateLimits.reset()
    System.delete_env("SDR_LOGIN_ALLOWLIST")
    System.put_env("SDR_MAIL_FROM", "sign-in@example.test")
    Application.put_env(:sdr_agent, :login_allowlist_enforced, true)

    tenant = bootstrap!()
    reviewer = human(:reviewer, tenant)

    %{
      tenant: tenant,
      admin: human(:admin, tenant),
      reviewer: reviewer,
      email: to_string(reviewer.email)
    }
  end

  defp allow(value), do: System.put_env("SDR_LOGIN_ALLOWLIST", value)
  defp strategy, do: Info.strategy!(User, :magic_link)
  defp request(email), do: Strategy.action(strategy(), :request, %{"email" => email})
  defp magic_sign_in(token), do: Strategy.action(strategy(), :sign_in, %{"token" => token})
  defp tokens, do: Ash.count!(SdrAgent.Accounts.Token, authorize?: false)
  defp admitted?(result), do: match?({:ok, %User{}}, result)

  defp mailed_token do
    assert_received {:email, %{text_body: body}}
    [_, token] = Regex.run(~r{/magic_link/([A-Za-z0-9._-]+)}, body)
    token
  end

  defp failed(tenant, strategy_name) do
    for event <- events_of_type(tenant, "auth.sign_in.failed"),
        event.payload["strategy"] == strategy_name,
        do: event
  end

  test "the allowlisted owner requests a link and signs in with it", ctx do
    allow(" " <> String.upcase(ctx.email) <> " ")

    assert :ok = request(ctx.email)
    assert {:ok, %User{id: id} = user} = magic_sign_in(mailed_token())
    assert id == ctx.reviewer.id
    assert {:ok, %User{}} = Accounts.current_operator(user.__metadata__.token)
    assert {:ok, %User{}} = Accounts.sign_in(ctx.email, test_password())
  end

  test "a user off the list cannot sign in with a known password; the refusal is audited",
       ctx do
    allow("someone.else@example.test")

    assert {:error, _} = Accounts.sign_in(ctx.email, test_password())
    assert [event] = failed(ctx.tenant, "password")
    assert event.actor_type == :anonymous
    assert events_of_type(ctx.tenant, "auth.sign_in.succeeded") == []
  end

  test "a user off the list is minted no token and sent nothing", ctx do
    allow("someone.else@example.test")
    before = tokens()

    capture_log(fn -> assert :ok = request(ctx.email) end)

    assert tokens() == before
    refute_email_sent()
  end

  test "a link minted while listed no longer signs in once the user is off the list", ctx do
    allow(ctx.email)
    assert :ok = request(ctx.email)
    token = mailed_token()

    allow("someone.else@example.test")
    refute admitted?(magic_sign_in(token))
    assert [_event] = failed(ctx.tenant, "magic_link")

    # Back on the list, the unspent link still works once (it was never consumed).
    allow(ctx.email)
    assert admitted?(magic_sign_in(token))
  end

  test "a token issued by hand to a user off the list does not sign in", ctx do
    allow("someone.else@example.test")
    {:ok, token} = MagicLink.request_token_for(strategy(), ctx.reviewer)

    refute admitted?(magic_sign_in(token))
    assert events_of_type(ctx.tenant, "auth.sign_in.succeeded") == []
  end

  test "a session valid when issued is refused once the user is off the list", ctx do
    allow(ctx.email)
    assert {:ok, %User{} = user} = Accounts.sign_in(ctx.email, test_password())
    session = user.__metadata__.token
    subject = AshAuthentication.user_to_subject(user)
    assert {:ok, %User{}} = Accounts.current_operator(session)
    assert {:ok, %User{}} = AshAuthentication.subject_to_user(subject, User)

    allow("someone.else@example.test")
    assert :error = Accounts.current_operator(session)
    assert {:error, _} = AshAuthentication.subject_to_user(subject, User)
  end

  test "a disabled user stays out even when listed", ctx do
    allow(ctx.email)
    {:ok, user} = Accounts.sign_in(ctx.email, test_password())
    {:ok, token} = MagicLink.request_token_for(strategy(), ctx.reviewer)

    {:ok, _} = Accounts.change_status(ctx.reviewer, :disabled, actor: ctx.admin)

    assert {:error, _} = Accounts.sign_in(ctx.email, test_password())
    refute admitted?(magic_sign_in(token))
    assert :error = Accounts.current_operator(user.__metadata__.token)
    before = tokens()
    assert :ok = request(ctx.email)
    assert tokens() == before
    refute_email_sent()
  end

  test "a missing, empty, blank or malformed list admits nobody", ctx do
    allow(ctx.email)
    {:ok, user} = Accounts.sign_in(ctx.email, test_password())
    {:ok, token} = MagicLink.request_token_for(strategy(), ctx.reviewer)

    for value <- [nil, "", " , ", "not-an-address", ctx.email <> ", owner", ctx.email <> " x"] do
      if value, do: allow(value), else: System.delete_env("SDR_LOGIN_ALLOWLIST")

      assert match?({:error, _}, Accounts.sign_in(ctx.email, test_password())), inspect(value)
      refute admitted?(magic_sign_in(token)), inspect(value)
      assert Accounts.current_operator(user.__metadata__.token) == :error, inspect(value)
    end
  end

  test "a switch missing or set to anything but false enforces the list (fail closed)", ctx do
    allow("someone.else@example.test")

    for value <- [:missing, true, "false", nil, :yes] do
      if value == :missing,
        do: Application.delete_env(:sdr_agent, :login_allowlist_enforced),
        else: Application.put_env(:sdr_agent, :login_allowlist_enforced, value)

      assert match?({:error, _}, Accounts.sign_in(ctx.email, test_password())), inspect(value)
    end
  end

  test "with the switch off, sign-in and sessions ignore the list (dev and test)", ctx do
    Application.put_env(:sdr_agent, :login_allowlist_enforced, false)
    allow("someone.else@example.test")

    assert {:ok, %User{} = user} = Accounts.sign_in(ctx.email, test_password())
    assert {:ok, %User{}} = Accounts.current_operator(user.__metadata__.token)
    {:ok, token} = MagicLink.request_token_for(strategy(), ctx.reviewer)
    assert admitted?(magic_sign_in(token))
  end
end
