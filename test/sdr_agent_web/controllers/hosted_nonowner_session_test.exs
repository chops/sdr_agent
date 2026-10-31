defmodule SdrAgentWeb.HostedNonownerSessionTest do
  @moduledoc """
  K1 reachability RED: a real persisted legacy User can retain historical
  domain semantics without becoming a hosted website principal. Tests use
  real signed/stored sessions and the existing browser password route.
  """
  use SdrAgentWeb.ConnCase, async: false

  import SdrAgent.AuditCase, only: [human: 2, test_password: 0]

  alias SdrAgent.Accounts
  alias SdrAgent.PrototypeFixtures
  alias SdrAgent.PrototypeGateFixtures, as: G
  alias SdrAgentWeb.LiveUserAuth

  setup do
    fx = G.bound!(auditor: true)
    reviewer = human(:reviewer, fx.tenant)
    assert {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(reviewer)
    %{fx: fx, reviewer: reviewer, token: token}
  end

  defp socket(user, token) do
    %Phoenix.LiveView.Socket{
      endpoint: SdrAgentWeb.Endpoint,
      router: SdrAgentWeb.Router,
      assigns: %{__changed__: %{}, current_user: user, flash: %{}},
      private: %{
        live_temp: %{},
        lifecycle: %Phoenix.LiveView.Lifecycle{},
        operator_session: %{"user_token" => token}
      }
    }
  end

  test "a persisted nonowner password login gets no hosted session", ctx do
    assert :ok = PrototypeFixtures.enter_runtime(ctx.fx.snapshot)

    conn =
      post(ctx.conn, "/auth/user/password/sign_in", %{
        "user" => %{"email" => to_string(ctx.reviewer.email), "password" => test_password()}
      })

    assert redirected_to(conn) == "/sign-in"
    assert get_session(conn, "user_token") == nil
  end

  test "a stored nonowner session cannot mount the hosted console", ctx do
    assert {:ok, _} = Accounts.current_operator(ctx.token)
    assert :ok = PrototypeFixtures.enter_runtime(ctx.fx.snapshot)
    # Preserve the pre-existing token-resolution contract; the web boundary
    # is what disallows this principal on the hosted website.
    assert {:ok, _} = Accounts.current_operator(ctx.token)

    assert {:halt, %{redirected: {:redirect, %{to: "/sign-in"}}}} =
             LiveUserAuth.on_mount(
               :operator,
               %{},
               %{"user_token" => ctx.token},
               socket(ctx.reviewer, ctx.token)
             )
  end

  test "a connected legacy session cannot revalidate into the hosted console", ctx do
    assert :ok = PrototypeFixtures.enter_runtime(ctx.fx.snapshot)

    assert {:error, %{redirected: {:redirect, %{to: "/sign-in"}}}} =
             ctx.reviewer
             |> socket(ctx.token)
             |> Phoenix.Component.assign(:current_scope, SdrAgentWeb.Scope.for_user(ctx.reviewer))
             |> LiveUserAuth.revalidate()
  end

  test "ordinary browser login remains available for the same persisted reviewer", ctx do
    conn =
      post(ctx.conn, "/auth/user/password/sign_in", %{
        "user" => %{"email" => to_string(ctx.reviewer.email), "password" => test_password()}
      })

    assert redirected_to(conn) == "/"
    assert is_binary(get_session(conn, "user_token"))
  end

  test "a rejected hosted principal can stay on sign-in without a redirect loop", ctx do
    assert :ok = PrototypeFixtures.enter_runtime(ctx.fx.snapshot)

    assert {:cont, signed_out} =
             LiveUserAuth.on_mount(
               :live_no_user,
               %{},
               %{"user_token" => ctx.token},
               socket(ctx.reviewer, ctx.token)
             )

    assert signed_out.assigns.current_user == nil
  end
end
