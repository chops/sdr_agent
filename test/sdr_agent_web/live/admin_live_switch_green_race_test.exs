defmodule SdrAgentWeb.AdminLiveSwitchGreenRaceTest do
  @moduledoc """
  R0-05 GREEN review regression for MF3 (Codex
  `codex-r005-8de4fca-green-review.md`): a LiveView crash while the review
  is `:uncertain` never puts the frozen confirmation in the captured
  `:debug` crash report (the channel's `format_status/2` state), as test 15
  captures logs. An unknown outcome needs a settlement barrier that can't
  be taken, so this module runs the SQL sandbox in `:auto` mode like
  `SdrAgentWeb.AdminLiveSwitchRaceTest` (`AdminSwitchHarness.auto_sandbox!/0`).
  The fake CLI; no model call.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import SdrAgent.Test.AdminSwitchHarness

  alias SdrAgent.Audit
  alias SdrAgent.AuditCase
  alias SdrAgent.Test.ResolveHarness, as: RH
  alias SdrAgent.Test.StatusHarness, as: SH

  @endpoint SdrAgentWeb.Endpoint
  @moduletag :r0_05
  @moduletag :capture_log
  @moduletag timeout: 240_000

  setup do
    auto_sandbox!()
    RH.lease_cleanup!()
    SH.select_claude_cli!()
    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    %{tenant: tenant, admin: AuditCase.new_human(:admin, tenant)}
  end

  test "MF3: a LiveView crash while :uncertain keeps the confirmation out of the debug crash report",
       ctx do
    blocked = RH.dead_holder!(ctx)
    text = confirmation(blocked)
    {:ok, view, _html} = build_conn() |> sign_in_user(ctx.admin) |> live("/admin")
    click!(view, "#resolve-blocked", "MF3 uncertain")

    await_element!(
      view,
      "#resolution-review[data-state='editing']",
      nil,
      10_000,
      "MF3: the review"
    )

    blocker = RH.block_coordinator!()
    {holder, _backend} = RH.hold!(fn -> RH.lock_setting!(ctx.tenant.id) end)
    change_form!(view, "#resolution-form", %{"resolution_confirmation" => text}, "MF3")
    submit_form!(view, "#resolution-form", %{"resolution_confirmation" => text}, "MF3")

    await_element!(
      view,
      "#resolution-review[data-state='uncertain']",
      nil,
      30_000,
      "MF3: the unknown outcome"
    )

    Process.unlink(view.pid)
    previous = Process.flag(:trap_exit, true)

    log =
      try do
        {_result, captured} =
          debug_logs(fn ->
            :sys.terminate(view.pid, :r005_uncertain_crash)
            Process.sleep(100)
          end)

        captured
      after
        Process.flag(:trap_exit, previous)
        RH.release_holder(holder)
        RH.release_coordinator!(blocker)
        RH.drain!()
      end

    assert log =~ "r005_uncertain_crash", "positive control: the crash report was captured"

    assert log =~ "#Confirmation<redacted>",
           "positive control: the frozen review is in the report"

    refute log =~ text, "MF3: the :uncertain crash report disclosed the confirmation"
  end
end
