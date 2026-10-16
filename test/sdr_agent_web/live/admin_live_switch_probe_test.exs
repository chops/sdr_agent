defmodule SdrAgentWeb.AdminLiveSwitchProbeTest do
  @moduledoc """
  R0-05 GREEN review probes, kept permanently with their assertions
  unchanged (Codex `codex-r005-8de4fca-green-review.md`, probe file sha256
  `5ab9317f0050bcae52da7bbbf4b9216c8da501022683d63e8ec77efe59838e91`;
  module renamed, this moduledoc and the `:r0_05` tag added): MF1 (an
  async completion re-validates a demoted admin before any read), MF3 (a
  LiveView crash report never carries the frozen confirmation) and MF2
  (the terminal re-read shows the reviewed switch, never a newer one).

  **Amendment (probe 1 only; Codex ruling 1 in
  `codex-r005-379e701-rulings.md`, PASS):** MF1's fix clears the review and
  ends the restricted view with the existing redirect, so the original wait
  for `#resolution-result` (and the render after it) is replaced by
  `assert_redirect(view, "/", ...)`. The no-fresh-email intent is kept by:
  the new user is still created after the demotion; the last page rendered
  before the completion doesn't show its email; the page's own (view and
  task) `Accounts.list_users/1` and `Agents.list_profile_switches/1` calls
  are counted before the held coordinator is released, and none follows
  the completion (trace delivered and acknowledged by the collector). A
  stopped proxy is never rendered. The redirect is no proof of what the
  dispatched attempt did.
  """
  use SdrAgentWeb.OperatorCase, async: false

  import SdrAgent.Test.AdminSwitchHarness

  alias SdrAgent.Accounts
  alias SdrAgent.Agents
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
    # Amendment: the page's own data reads (the test process's are excluded).
    tracer = trace_calls!([{Accounts, :list_users, 1}, {Agents, :list_profile_switches, 1}])
    {:ok, view, _} = ctx.conn |> sign_in(:admin) |> live("/admin")
    click!(view, "#resolve-blocked", "review probe")
    blocker = RH.block_coordinator!()
    text = confirmation(blocked)
    submit_form!(view, "#resolution-form", %{"resolution_confirmation" => text}, "review probe")
    await_element!(view, "#resolution-review[data-state='submitting']", nil, 5_000, "submitting")

    {:ok, _} = Accounts.change_role(ctx.admin, :reviewer, actor: other)
    fresh = AuditCase.new_human(:reviewer, ctx.tenant)
    # Amendment: the last page rendered before the completion, and the
    # page's read count, both taken before the coordinator is released.
    html = render(view)
    reads = page_reads(tracer)

    refute html =~ to_string(fresh.email),
           "async completion loaded and disclosed a newly created user's email after demotion"

    RH.release_coordinator!(blocker)
    # Amendment: the redirect replaces the wait for #resolution-result.
    assert_redirect(view, "/", 10_000)

    assert page_reads(tracer) == reads,
           "async completion read admin data for a demoted operator: " <>
             inspect(Enum.map(page_reads(tracer) -- reads, & &1.mfa))
  end

  # The page's own reads; `calls/1` delivers every trace message
  # (`:erlang.trace_delivered/1`) and waits for the collector's answer.
  defp page_reads(tracer) do
    tracer
    |> calls()
    |> Enum.filter(&(&1.pid != self()))
    |> Enum.map(&Map.take(&1, [:pid, :mfa, :args]))
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
