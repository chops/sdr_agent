defmodule SdrAgent.Accounts.MagicLinkTest do
  @moduledoc """
  Passwordless sign-in for existing operators (hosted deployment): the
  AshAuthentication magic-link strategy with registration disabled, whose
  sender mails a link through `SdrAgent.Mailer` only to an active user whose
  lowercased email is on `SDR_LOGIN_ALLOWLIST` (comma-separated, read at
  run time; empty or unset means nobody). A refusal sends nothing and logs
  neither the address nor the token. The link signs the user in once; the
  password strategy is unchanged.
  """
  use SdrAgent.AuditCase, async: false

  import ExUnit.CaptureLog
  import Swoosh.TestAssertions

  alias AshAuthentication.Info
  alias AshAuthentication.Strategy
  alias SdrAgent.Accounts
  alias SdrAgent.Accounts.User
  alias SdrAgent.Audit.Kernel

  @env ["SDR_LOGIN_ALLOWLIST", "SDR_MAIL_FROM"]

  setup do
    previous = Map.new(@env, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    System.delete_env("SDR_LOGIN_ALLOWLIST")
    System.put_env("SDR_MAIL_FROM", "SDR Agent <sign-in@example.test>")
    tenant = bootstrap!()
    reviewer = human(:reviewer, tenant)

    %{
      tenant: tenant,
      admin: human(:admin, tenant),
      reviewer: reviewer,
      email: to_string(reviewer.email)
    }
  end

  defp strategy, do: Info.strategy!(User, :magic_link)
  defp request(email), do: Strategy.action(strategy(), :request, %{"email" => email})
  defp sign_in(token), do: Strategy.action(strategy(), :sign_in, %{"token" => token})
  defp allow(value), do: System.put_env("SDR_LOGIN_ALLOWLIST", value)

  defp capture_token do
    receive do
      {:email, email} ->
        [_, token] = Regex.run(~r{/magic_link/([A-Za-z0-9._-]+)}, email.text_body)
        {email, token}
    after
      0 -> flunk("no email was sent")
    end
  end

  test "the strategy exists without registration and needs an interaction" do
    s = strategy()
    refute s.registration_enabled?
    assert s.require_interaction?
    assert Ash.Resource.Info.action(User, s.sign_in_action_name).type == :read
    assert Ash.Resource.Info.action(User, s.request_action_name).type == :read
    # The password strategy is untouched.
    refute Info.strategy!(User, :password).registration_enabled?
  end

  test "an allowlisted user gets exactly one email whose link signs them in once", ctx do
    allow("someone.else@example.test, " <> String.upcase(ctx.email) <> " ,")

    assert :ok = request(ctx.email)
    {email, token} = capture_token()
    refute_email_sent()

    assert email.to == [{"", ctx.email}]
    assert email.from == {"", "SDR Agent <sign-in@example.test>"}
    assert email.html_body =~ "/magic_link/#{token}"

    assert {:ok, %User{} = user} = sign_in(token)
    assert user.id == ctx.reviewer.id
    assert is_binary(user.__metadata__.token)
    assert {:ok, %User{id: id}} = Accounts.current_operator(user.__metadata__.token)
    assert id == ctx.reviewer.id

    assert [event] = events_of_type(ctx.tenant, "auth.sign_in.succeeded")
    assert {event.actor_id, event.payload["strategy"]} == {ctx.reviewer.id, "magic_link"}

    # Single use.
    refute match?({:ok, %User{}}, sign_in(token))
  end

  test "a user not on the allowlist gets no email; the refusal log omits address and token",
       ctx do
    allow("someone.else@example.test")

    log = capture_log(fn -> assert :ok = request(ctx.email) end)

    refute_email_sent()
    assert log =~ "magic link refused"
    refute String.downcase(log) =~ String.downcase(ctx.email)
    refute log =~ "eyJ"
  end

  test "an empty or unset allowlist sends no mail to anyone", ctx do
    for value <- [nil, "", " , "] do
      if value, do: allow(value), else: System.delete_env("SDR_LOGIN_ALLOWLIST")
      capture_log(fn -> assert :ok = request(ctx.email) end)
      refute_email_sent()
    end
  end

  test "an unknown email gets no email and registers nobody", ctx do
    allow("nobody.here@example.test")
    {:ok, before} = Ash.read(User, Kernel.opts(ctx.tenant.id))

    capture_log(fn -> assert :ok = request("nobody.here@example.test") end)

    refute_email_sent()
    {:ok, after_request} = Ash.read(User, Kernel.opts(ctx.tenant.id))
    assert length(after_request) == length(before)
    refute Enum.any?(after_request, &(to_string(&1.email) == "nobody.here@example.test"))
  end

  test "a disabled user gets no link, and an earlier link no longer signs in", ctx do
    allow(ctx.email)
    assert :ok = request(ctx.email)
    {_email, token} = capture_token()

    {:ok, _} = Accounts.change_status(ctx.reviewer, :disabled, actor: ctx.admin)

    capture_log(fn -> assert :ok = request(ctx.email) end)
    refute_email_sent()
    refute match?({:ok, %User{}}, sign_in(token))
  end

  test "one address gets at most three links per fifteen minutes; the refusal omits it", ctx do
    allow(ctx.email)
    t0 = DateTime.utc_now()
    SdrAgent.Clock.freeze(t0)

    for _ <- 1..3 do
      assert :ok = request(ctx.email)
      capture_token()
    end

    log = capture_log(fn -> assert :ok = request(ctx.email) end)
    refute_email_sent()
    assert log =~ "magic link refused"
    refute String.downcase(log) =~ String.downcase(ctx.email)

    SdrAgent.Clock.freeze(DateTime.add(t0, 15, :minute))
    assert :ok = request(ctx.email)
    capture_token()
  end

  test "the password strategy still signs in", ctx do
    allow(ctx.email)
    assert {:ok, %User{id: id}} = Accounts.sign_in(ctx.email, test_password())
    assert id == ctx.reviewer.id
  end
end
