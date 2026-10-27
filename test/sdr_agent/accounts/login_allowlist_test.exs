defmodule SdrAgent.Accounts.LoginAllowlistTest do
  @moduledoc """
  Hosted sign-in allowlist enforcement (`config :sdr_agent,
  :login_allowlist_enforced`, true in prod): when enforced, password
  sign-in, magic-link sign-in, magic-link requests and every session or
  token resolution (`get_by_subject`) admit a user only if their lowercased
  email is on `SDR_LOGIN_ALLOWLIST`, read at call time; an empty, blank or
  unset list admits nobody. A refused sign-in is audited as
  `auth.sign_in.failed` like any other. Not enforced (dev/test default),
  nothing changes.
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
      for {key, value} <- previous_env do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end

      case previous_enforced do
        {:ok, value} -> Application.put_env(:sdr_agent, :login_allowlist_enforced, value)
        :error -> Application.delete_env(:sdr_agent, :login_allowlist_enforced)
      end
    end)

    System.delete_env("SDR_LOGIN_ALLOWLIST")
    System.put_env("SDR_MAIL_FROM", "sign-in@example.test")
    Application.put_env(:sdr_agent, :login_allowlist_enforced, true)

    tenant = bootstrap!()
    reviewer = human(:reviewer, tenant)
    %{tenant: tenant, reviewer: reviewer, email: to_string(reviewer.email)}
  end

  defp allow(value), do: System.put_env("SDR_LOGIN_ALLOWLIST", value)
  defp strategy, do: Info.strategy!(User, :magic_link)
  defp magic_sign_in(token), do: Strategy.action(strategy(), :sign_in, %{"token" => token})

  defp failed(tenant, strategy_name) do
    for event <- events_of_type(tenant, "auth.sign_in.failed"),
        event.payload["strategy"] == strategy_name,
        do: event
  end

  test "the switch is off unless configured, and prod turns it on" do
    Application.delete_env(:sdr_agent, :login_allowlist_enforced)
    refute SdrAgent.Accounts.LoginAllowlist.enforced?()
    Application.put_env(:sdr_agent, :login_allowlist_enforced, true)
    assert SdrAgent.Accounts.LoginAllowlist.enforced?()
  end

  test "a user off the list cannot sign in with the right password; the refusal is audited",
       ctx do
    allow("someone.else@example.test")

    assert {:error, _} = Accounts.sign_in(ctx.email, test_password())
    assert [event] = failed(ctx.tenant, "password")
    assert event.actor_type == :anonymous
    assert events_of_type(ctx.tenant, "auth.sign_in.succeeded") == []
  end

  test "a user off the list cannot sign in with a valid magic-link token; the refusal is audited",
       ctx do
    allow("someone.else@example.test")
    {:ok, token} = MagicLink.request_token_for(strategy(), ctx.reviewer)

    refute match?({:ok, %User{}}, magic_sign_in(token))
    assert [_event] = failed(ctx.tenant, "magic_link")
    assert events_of_type(ctx.tenant, "auth.sign_in.succeeded") == []
  end

  test "a user off the list is sent no link and gets no token", ctx do
    allow("someone.else@example.test")
    tokens = Ash.count!(SdrAgent.Accounts.Token, authorize?: false)

    capture_log(fn ->
      assert :ok = Strategy.action(strategy(), :request, %{"email" => ctx.email})
    end)

    refute_email_sent()
    assert Ash.count!(SdrAgent.Accounts.Token, authorize?: false) == tokens
  end

  test "a session valid when issued is refused once the user is off the list", ctx do
    allow(String.upcase(ctx.email))
    assert {:ok, %User{} = user} = Accounts.sign_in(ctx.email, test_password())
    session = user.__metadata__.token
    assert {:ok, %User{}} = Accounts.current_operator(session)

    assert {:ok, %User{}} =
             AshAuthentication.subject_to_user(AshAuthentication.user_to_subject(user), User)

    allow("someone.else@example.test")
    assert :error = Accounts.current_operator(session)

    assert {:error, _} =
             AshAuthentication.subject_to_user(AshAuthentication.user_to_subject(user), User)
  end

  test "an empty, blank or unset list admits nobody", ctx do
    allow(ctx.email)
    {:ok, user} = Accounts.sign_in(ctx.email, test_password())
    {:ok, token} = MagicLink.request_token_for(strategy(), ctx.reviewer)

    for value <- [nil, "", " , "] do
      if value, do: allow(value), else: System.delete_env("SDR_LOGIN_ALLOWLIST")

      assert {:error, _} = Accounts.sign_in(ctx.email, test_password())
      refute match?({:ok, %User{}}, magic_sign_in(token))
      assert :error = Accounts.current_operator(user.__metadata__.token)
    end
  end

  test "the allowlisted owner signs in by magic link", ctx do
    allow(ctx.email)

    assert :ok = Strategy.action(strategy(), :request, %{"email" => ctx.email})
    assert_received {:email, %{text_body: body}}
    [_, token] = Regex.run(~r{/magic_link/([A-Za-z0-9._-]+)}, body)

    assert {:ok, %User{id: id} = user} = magic_sign_in(token)
    assert id == ctx.reviewer.id
    assert {:ok, %User{}} = Accounts.current_operator(user.__metadata__.token)
  end

  test "not enforced, sign-in and sessions ignore the list (dev and test default)", ctx do
    Application.put_env(:sdr_agent, :login_allowlist_enforced, false)
    allow("someone.else@example.test")

    assert {:ok, %User{} = user} = Accounts.sign_in(ctx.email, test_password())
    assert {:ok, %User{}} = Accounts.current_operator(user.__metadata__.token)
    {:ok, token} = MagicLink.request_token_for(strategy(), ctx.reviewer)
    assert {:ok, %User{}} = magic_sign_in(token)
  end
end
