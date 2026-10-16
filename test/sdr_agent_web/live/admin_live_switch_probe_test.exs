defmodule SdrAgentWeb.AdminLiveSwitchProbeTest do
  @moduledoc """
  R0-05 GREEN review probes, kept permanently with their assertions
  unchanged (Codex `codex-r005-8de4fca-green-review.md`, probe file sha256
  `5ab9317f0050bcae52da7bbbf4b9216c8da501022683d63e8ec77efe59838e91`;
  module renamed, this moduledoc and the `:r0_05` tag added): MF1 (an
  async completion re-validates a demoted admin before any read), MF3 (a
  LiveView crash report never carries the frozen confirmation) and MF2
  (the terminal re-read shows the reviewed switch, never a newer one).
  """
  use SdrAgentWeb.OperatorCase, async: false

  import SdrAgent.Test.AdminSwitchHarness

  alias SdrAgent.Accounts
  alias SdrAgent.AuditCase
  alias SdrAgent.Test.ResolveHarness, as: RH
  alias SdrAgent.Test.StatusHarness, as: SH

  @moduletag :r0_05
  @moduletag :capture_log
  @moduletag timeout: 90_000

  setup do
    RH.lease_cleanup!()
    SH.select_claude_cli!()
    :ok
  end

  test "async completion must revalidate a demoted admin before loading new admin data", ctx do
    blocked = RH.none!(ctx)
    other = AuditCase.new_human(:admin, ctx.tenant)
    {:ok, view, _} = ctx.conn |> sign_in(:admin) |> live("/admin")
    click!(view, "#resolve-blocked", "review probe")
    blocker = RH.block_coordinator!()
    text = confirmation(blocked)
    submit_form!(view, "#resolution-form", %{"resolution_confirmation" => text}, "review probe")
    await_element!(view, "#resolution-review[data-state='submitting']", nil, 5_000, "submitting")

    {:ok, _} = Accounts.change_role(ctx.admin, :reviewer, actor: other)
    fresh = AuditCase.new_human(:reviewer, ctx.tenant)
    RH.release_coordinator!(blocker)
    await_element!(view, "#resolution-result", nil, 10_000, "async finished")
    html = render(view)

    refute html =~ to_string(fresh.email),
           "async completion loaded and disclosed a newly created user's email after demotion"
  end

  test "crash diagnostics must not include a frozen confirmation", ctx do
    blocked = RH.none!(ctx)
    {:ok, view, _} = ctx.conn |> sign_in(:admin) |> live("/admin")
    click!(view, "#resolve-blocked", "crash probe")
    blocker = RH.block_coordinator!()
    text = confirmation(blocked)
    submit_form!(view, "#resolution-form", %{"resolution_confirmation" => text}, "crash probe")
    await_element!(view, "#resolution-review[data-state='submitting']", nil, 5_000, "submitting")
    Process.unlink(view.pid)
    previous = Process.flag(:trap_exit, true)

    log =
      try do
        {_result, captured} =
          debug_logs(fn ->
            :sys.terminate(view.pid, :codex_review_crash)
            Process.sleep(100)
          end)

        captured
      after
        Process.flag(:trap_exit, previous)
        RH.release_coordinator!(blocker)
      end

    assert log =~ "codex_review_crash", "positive control: capture the crash report"
    refute log =~ text, "LiveView crash report disclosed the frozen confirmation"
  end

  test "a terminal reread must show the reviewed switch, not a newer switch", ctx do
    blocked = RH.none!(ctx)
    other = AuditCase.new_human(:admin, ctx.tenant)
    {:ok, view, _} = ctx.conn |> sign_in(:admin) |> live("/admin")
    click!(view, "#resolve-blocked", "target binding probe")
    attestation = RH.attestation(blocked, RH.latest_start!(ctx), :none)
    assert {:ok, _} = RH.resolve(blocked, attestation, other)
    RH.drain!()
    newer = switch_through_coordinator!(%{ctx | admin: other})
    assert newer.id != blocked.id
    assert newer.status == :completed

    submit_form!(
      view,
      "#resolution-form",
      %{"resolution_confirmation" => confirmation(blocked)},
      "target binding probe"
    )

    await_element!(
      view,
      "#resolution-result[data-outcome='switch_not_blocked']",
      nil,
      10_000,
      "terminal refusal"
    )

    assert has_element?(view, "#stored-switch[data-status='failed']"),
           "the reviewed switch is failed, but the card substituted the newer completed switch"
  end
end
