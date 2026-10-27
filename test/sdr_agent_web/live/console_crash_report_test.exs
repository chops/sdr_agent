defmodule SdrAgentWeb.ConsoleCrashReportTest do
  @moduledoc """
  A credential-owning process outside the auth paths (Codex R1): an
  operator console LiveView channel holds the decoded session token (its
  `:operator` hook keeps it for revalidation). When it crashes, its
  termination report — state included, at :debug — must be emitted and
  carry neither the JWT nor the session cookie, in message or metadata.
  """
  use SdrAgentWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SdrAgent.AuditCase, only: [bootstrap!: 0, human: 2, test_password: 0]

  alias SdrAgent.TestSupport.RawLog

  setup do
    previous = Logger.level()
    on_exit(fn -> Logger.configure(level: previous) end)
    # :debug, so a terminating process's report includes its state.
    Logger.configure(level: :debug)
    :ok
  end

  test "a console view's crash report carries no session token", %{conn: conn} do
    tenant = bootstrap!()
    admin = human(:admin, tenant)
    {:ok, user} = SdrAgent.Accounts.sign_in(to_string(admin.email), test_password())
    jwt = user.__metadata__.token

    conn = conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)
    {:ok, view, _html} = live(conn, "/")

    ref = RawLog.start()
    Process.flag(:trap_exit, true)
    monitor = Process.monitor(view.pid)

    # The dashboard handles no events: an unknown one crashes its channel.
    catch_exit(render_hook(view, "no-such-event", %{}))
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}, 2_000

    event = RawLog.report_of(ref, view.pid)
    refute RawLog.withheld?(event)
    RawLog.assert_absent(ref, [jwt])
  end
end
