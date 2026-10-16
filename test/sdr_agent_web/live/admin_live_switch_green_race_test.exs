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

  **Draft 4 amendment (D-141; Codex d0c80ff, permitted amendments 4 and
  5):** the MF3 positive control is the tagged channel's fixed diagnostic
  (the crash reason and `#Confirmation<redacted>` are no longer in the
  report), and test 15b's crash while frozen in `:uncertain`, through the
  `crash_on_event!/3` seam on a real `refresh_status` click, at `:debug`
  and at `:warning`.
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

  # The review in :uncertain: an attempt whose caller's call times out
  # against the blocked coordinator and whose settlement barrier can't take
  # the setting lock. Returns `{view, text, release}`.
  defp uncertain!(ctx, label) do
    blocked = RH.dead_holder!(ctx)
    text = confirmation(blocked)
    {:ok, view, _html} = build_conn() |> sign_in_user(ctx.admin) |> live("/admin")
    click!(view, "#resolve-blocked", label)

    await_element!(
      view,
      "#resolution-review[data-state='editing']",
      nil,
      10_000,
      "#{label}: the review"
    )

    blocker = RH.block_coordinator!()
    {holder, _backend} = RH.hold!(fn -> RH.lock_setting!(ctx.tenant.id) end)
    change_form!(view, "#resolution-form", %{"resolution_confirmation" => text}, label)
    submit_form!(view, "#resolution-form", %{"resolution_confirmation" => text}, label)

    await_element!(
      view,
      "#resolution-review[data-state='uncertain']",
      nil,
      30_000,
      "#{label}: the unknown outcome"
    )

    release = fn ->
      RH.release_holder(holder)
      RH.release_coordinator!(blocker)
      RH.drain!()
    end

    {view, text, release}
  end

  test "MF3: a LiveView crash while :uncertain keeps the confirmation out of the debug crash report",
       ctx do
    {view, text, release} = uncertain!(ctx, "MF3 uncertain")

    # Amendment (draft 4, D-141; ADR-0005 R0-05 amendment; Codex d0c80ff,
    # permitted amendment 4): the tagged channel's report is the fixed
    # diagnostic, so the crash reason and #Confirmation<redacted> are no
    # longer in it. The positive control is the diagnostic itself, at its
    # level with the safe metadata; the wrapper's own redaction is tested
    # directly in SdrAgentWeb.AdminLiveSwitchGreenTest.
    {_reason, log, events} =
      try do
        log_events(:debug, fn ->
          crash!(view, fn -> :sys.terminate(view.pid, :r005_uncertain_crash) end)
        end)
      after
        release.()
      end

    assert_withheld!(events, view.pid, "MF3 :uncertain crash report")
    assert log =~ withheld(), "R0-05 MF3: the captured text shows the diagnostic"

    refute Enum.any?(events_of(events, view.pid), &canary_in?(&1, text)),
           "MF3: the :uncertain crash report disclosed the confirmation"

    refute log =~ text, "MF3: the :uncertain crash report disclosed the confirmation"
  end

  for level <- [:debug, :warning] do
    test "15b. a channel crash while frozen in :uncertain reports only the fixed diagnostic, at #{level}",
         ctx do
      level = unquote(level)
      label = "15b :uncertain at #{level}"
      {view, text, release} = uncertain!(ctx, label)
      crash_on_event!(view, "refresh_status")

      {reason, log, events} =
        try do
          log_events(level, fn ->
            crash!(view, fn -> click!(view, "#refresh-status", label) end)
          end)
        after
          release.()
        end

      assert seam_crash?(reason), "fixture: the seam crash; got #{inspect(reason, limit: 5)}"
      assert_withheld!(events, view.pid, label)
      assert log =~ withheld(), "R0-05 #{label}: the captured text shows the diagnostic"

      # The valid phrase was dispatched: downstream diagnostic copies are
      # D-141's accepted residual; the channel's own reports are checked.
      refute Enum.any?(events_of(events, view.pid), &canary_in?(&1, text)),
             "R0-05 #{label}: the channel's own events carry the confirmation"

      assert exception_filter!(label)
    end
  end
end
