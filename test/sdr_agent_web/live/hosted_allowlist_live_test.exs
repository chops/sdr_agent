defmodule SdrAgentWeb.HostedAllowlistLiveTest do
  @moduledoc """
  Hosted owner-only admission in the operator console (Codex M1): with the
  allowlist enforced, a console opened while the operator was on
  `SDR_LOGIN_ALLOWLIST` signs them out at their next event or navigation
  once they are off it (the `:operator` hook re-validates through
  `get_by_subject`), and a new mount is refused.
  """
  use SdrAgentWeb.OperatorCase, async: false

  alias SdrAgent.Demo.Fixtures

  setup do
    previous_list = System.get_env("SDR_LOGIN_ALLOWLIST")
    previous_enforced = Application.fetch_env(:sdr_agent, :login_allowlist_enforced)

    on_exit(fn ->
      if previous_list,
        do: System.put_env("SDR_LOGIN_ALLOWLIST", previous_list),
        else: System.delete_env("SDR_LOGIN_ALLOWLIST")

      case previous_enforced do
        {:ok, value} -> Application.put_env(:sdr_agent, :login_allowlist_enforced, value)
        :error -> Application.delete_env(:sdr_agent, :login_allowlist_enforced)
      end
    end)

    admin = Enum.find(Fixtures.users(), &(&1.role == :admin))
    System.put_env("SDR_LOGIN_ALLOWLIST", admin.email)
    Application.put_env(:sdr_agent, :login_allowlist_enforced, true)
    :ok
  end

  test "a connected console signs its operator out at the next event once off the list",
       %{conn: conn} do
    conn = sign_in(conn, :admin)
    {:ok, view, _html} = live(conn, ~p"/audit")

    System.put_env("SDR_LOGIN_ALLOWLIST", "someone.else@example.test")

    assert {:error, {:redirect, %{to: "/sign-in"}}} = render_hook(view, "verify_chain", %{})
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/audit")
  end

  test "a connected console signs its operator out at the next navigation once off the list",
       %{conn: conn} do
    conn = sign_in(conn, :admin)
    {:ok, view, _html} = live(conn, ~p"/leads")

    System.put_env("SDR_LOGIN_ALLOWLIST", "")

    assert {:error, {:redirect, %{to: "/sign-in"}}} = render_patch(view, ~p"/leads?status=new")
  end
end
