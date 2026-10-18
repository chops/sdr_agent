defmodule SdrAgentWeb.AdminLiveSwitchTest do
  @moduledoc """
  R0-05 RED (`docs/product/r0/r0-05-interface.md` draft 3, interface PASS
  at `fbc3203`, Codex `232bd20d`): the admin model card, the switch request
  and the blocked-switch resolver, Tests 1–9 and 11–17. Tests 10 and 10a,
  and the retry refusals of section 3, need independent connections and are
  in `SdrAgentWeb.AdminLiveSwitchRaceTest`.

  Every coordinator state is real (`SdrAgent.Test.ResolveHarness`,
  `SdrAgent.Test.StatusHarness`): the fake CLI under the test launcher,
  launches reported to the test process, zero model calls. Shared SQL
  sandbox (the seeded console data of `SdrAgentWeb.OperatorCase`); an audit
  commit is delivered with `audit_refresh!/1`, since the sandbox never
  commits. Test-only faults, all b2β/C2-02c seams: the coordinator faults
  `observe:`, `lose_reply:` and `reconcile:`, a table renamed inside the
  sandbox transaction, a test-side lease holder, `:sys.replace_state/2` on
  b2α's `reconcile` field for a busy coordinator, a blocked coordinator
  (`test_run/2`), and the C2-02c sample seam paused in the page's own
  status read.

  **Chosen ids, events and params** (where the contract is silent):

    * card lines: `#desired-profile` (`data-profile`, `data-source`; absent
      for the Fake), `#running-profile` (`data-profile`; marked "sampled"),
      `#accepting-calls` (`data-accepting` yes/no, `data-refusal`),
      `#provider-hold` (`data-hold`, `data-stage`), `#open-switch`
      (`data-state` none/pending/blocked/unknown, `data-switch-id`),
      `#status-published-at`, the `#cleanup-unprovable` banner and the
      `#refresh-status` button (`refresh_status`); the last check stays
      `#model-attestation`;
    * the switch: `#change-profile` (`open_switch`), `#switch-status-unknown`,
      `#switch-form` (`review_switch`, select `switch[to_profile_id]`,
      `#switch-target`), `#switch-review` (`data-from`, `data-to`,
      `data-revision`), `#confirm-switch` (`confirm_switch`),
      `#cancel-switch` (`cancel_switch`), `#switch-result`, `#switch-error`,
      `#switch-stale` with `#reload-switch` (`reload_switch`);
    * the resolver: `#resolve-blocked` (`open_resolution`: reads the facts
      and enters `:editing`), `#resolution-review` (`data-state`
      facts/editing/submitting/uncertain/terminal, `data-attestation-id`),
      `#resolution-facts` (the facts: `#resolution-switch` (`data-switch-id`),
      `#covered-start-<generation>`
      (`data-start-id`) and `#resolution-lease-kind` (`data-kind`)),
      `#resolution-statement`, `#resolution-form` (`change_resolution`,
      `confirm_resolution`; input `resolution_confirmation`, id
      `#resolution-confirmation`), `#confirm-resolution` (enabled
      throughout `:editing`, whatever the text; draft 5), `#resolution-facts-changed`, `#resolution-error`,
      `#resolution-result` (`data-outcome` recorded/uncertain/not_recorded
      or the refusal tag), `#check-again` (`check_again`) and
      `#stored-switch` (`data-status`: the stored switch re-read as the
      actor);
    * the resolution runs off the view process (as `start_async/3`), so
      `:submitting` is observable and the page stays responsive.

  Passes by design: none. Each test's guard names its missing element.

  **Draft 4 amendment (option B, D-141; ADR-0005 R0-05 amendment; Codex
  `codex-r005-d0c80ff-contract-pass.md`, permitted test amendments 1, 2 and
  5).** Test 9: a forced wrong or malformed submit is refused by the page
  (`#resolution-mismatch`: no dispatch, still `:editing` with the same id,
  the input cleared, the button still enabled: draft 5), in
  place of the server's `:attestation_invalid`. Test 12: the terminal
  result is b2β's `:stale_attestation` for the exact text. Test 15: its
  wrong-text refusal is now the page's. New: 15a (minimization, traced with
  a positive control), 15b (the tagged channel's own crash reports, through
  the `crash_on_event!/3` seam and a `:logger` handler after the primary
  filters; with controls) and 15c (the accepted supervisor-report residual,
  shown, with SASL translation on for that test only).
  """
  use SdrAgentWeb.OperatorCase, async: false

  import SdrAgent.Test.AdminSwitchHarness

  require Logger

  alias SdrAgent.Accounts
  alias SdrAgent.Agents
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper
  alias SdrAgent.AI.ModelProvider.Coordinator
  alias SdrAgent.AI.ModelProvider.Fake
  alias SdrAgent.AI.ModelProvider.Runtime
  alias SdrAgent.AuditCase
  alias SdrAgent.Repo
  alias SdrAgent.Test.ResolveHarness, as: RH
  alias SdrAgent.Test.StatusHarness, as: SH

  @moduletag :r0_05
  @moduletag :capture_log
  @moduletag timeout: 180_000
  # The sandbox owner must outlive the test timeout: test 15 held its
  # connection past the default 120 s under CI load (run 39068733145, #177).
  @moduletag ownership_timeout: 200_000

  @opus :claude_cli_opus
  @sonnet :claude_cli_sonnet
  @request {Coordinator, :request_switch, 2}
  @setting {Agents, :get_profile_setting, 1}
  @facts {Agents, :blocked_switch_facts, 2}
  @resolve {Agents, :resolve_blocked_switch, 3}
  @switches {Agents, :list_profile_switches, 1}
  @mismatch "That text doesn't match. Type STOPPED, a space and the switch id shown above."
  @model_calls [
    {ClaudeCLI, :complete, 2},
    {Fake, :complete, 2},
    {Agents, :reserve_model_invocation, 3},
    {Agents, :admit_launch, 3}
  ]

  setup do
    RH.lease_cleanup!()
    SH.select_claude_cli!()
    :ok
  end

  ## Page steps

  defp admin_view(conn) do
    {:ok, view, _html} = conn |> sign_in(:admin) |> live(~p"/admin")
    view
  end

  defp user_view(user) do
    {:ok, view, _html} = build_conn() |> sign_in_user(user) |> live(~p"/admin")
    view
  end

  defp open_switch!(view, label) do
    click!(view, "#change-profile", label)
  end

  defp review_switch!(view, to, label) do
    assert has_element?(view, "#switch-target option[value='#{to}']"),
           "R0-05 #{label}: the choices (the reviewed real profiles except the setting's from) " <>
             "must offer #{to}; got #{inspect(text_of(view, "#switch-target"))}"

    submit_form!(view, "#switch-form", %{"switch" => %{"to_profile_id" => to}}, label)

    assert has_element?(view, "#switch-review"),
           "R0-05 #{label}: choosing #{to} shows no #switch-review"
  end

  defp open_resolution!(view, label) do
    click!(view, "#resolve-blocked", label)

    await_element!(
      view,
      "#resolution-review[data-state='editing']",
      nil,
      10_000,
      "#{label}: opening the resolver never reached :editing with the facts"
    )

    id = attr_of(view, "#resolution-review", "data-attestation-id")

    assert is_binary(id) and match?({:ok, _}, Ecto.UUID.cast(id)),
           "R0-05 #{label}: the :editing review carries no attestation id; got #{inspect(id)}"

    id
  end

  defp type!(view, text, label),
    do: change_form!(view, "#resolution-form", %{"resolution_confirmation" => text}, label)

  defp confirm_resolution!(view, text, label),
    do: submit_form!(view, "#resolution-form", %{"resolution_confirmation" => text}, label)

  defp review_state(view), do: attr_of(view, "#resolution-review", "data-state")

  defp review_id(view), do: attr_of(view, "#resolution-review", "data-attestation-id")

  defp await_outcome!(view, outcome, timeout, label) do
    await_element!(
      view,
      "#resolution-result[data-outcome='#{outcome}']",
      nil,
      timeout,
      "#{label}: the result #{outcome} was never shown"
    )

    text_of(view, "#resolution-result")
  end

  defp resolve_calls(tracer), do: page_calls(tracer, @resolve)

  defp assert_terminal!(view, label) do
    assert review_state(view) == "terminal",
           "R0-05 #{label}: the review must be :terminal; got #{inspect(review_state(view))}"

    refute has_element?(view, "#check-again"),
           "R0-05 #{label}: a terminal review offers no Check again"
  end

  defp refute_ready!(view, label) do
    text = text_of(view, "#resolution-result") || ""

    refute text =~ ~r/\bready\b/i,
           "R0-05 #{label}: a resolution never says ready; got #{inspect(text)}"
  end

  defp stored_status!(ctx, switch), do: RH.switch!(ctx, switch.id).status

  defp other_admin!(ctx), do: AuditCase.new_human(:admin, ctx.tenant)

  ## 1. The card

  describe "1. the card renders each C2-02c shape" do
    test "the Fake hides the desired profile; ClaudeCLI with no coordinator is unknown, never the default",
         %{conn: conn} do
      SH.select_fake!()
      view = admin_view(conn)

      refute has_element?(view, "#desired-profile"),
             "R0-05 1 (Fake): the desired-profile line is hidden for the Fake"

      refute has_element?(view, "#change-profile")
      refute has_element?(view, "#resolve-blocked")

      SH.select_claude_cli!()
      status = Runtime.status()
      assert status.ledger_observation == :unavailable, "fixture: no coordinator"
      assert_card!(admin_view(conn), status, "ClaudeCLI, no coordinator")
    end

    test "a valid coordinator with no bound server: running none, the confirmed default, refused",
         %{conn: conn} do
      no_server!()
      blocker = RH.block_coordinator!()
      status = Runtime.status()
      assert status.observed_profile == :none, "fixture: no bound server"
      assert_card!(admin_view(conn), status, "no bound server")
      RH.release_coordinator!(blocker)
    end

    test "held (a blocked switch's survivor): held, not accepting, the switch blocked", ctx do
      RH.survivor!(ctx)
      status = Runtime.status()
      assert %{hold: :held, switch: %{status: :blocked}} = status
      assert_card!(admin_view(ctx.conn), status, "held")
    end

    test "a pending hold counts as held and never reads as accepting calls", %{conn: conn} do
      pending_hold!()
      status = Runtime.status()
      assert status.hold == :pending, "fixture: the re-hold is pending"
      assert_card!(admin_view(conn), status, "pending hold")
    end

    test "released and eligible: accepting calls on the observed profile", %{conn: conn} do
      released!()
      status = Runtime.status()
      assert status.effective_profile == @opus, "fixture: released and eligible"
      assert_card!(admin_view(conn), status, "released, eligible")
    end

    test "released and refused (the pin): no, with the refusal in words", %{conn: conn} do
      refused_pin!()
      status = Runtime.status()
      assert %{hold: :released, effective_profile: nil} = status
      assert_card!(admin_view(conn), status, "released, refused")
    end

    test ":cleanup_unprovable gets its banner and promises no automatic restart", ctx do
      cleanup_unprovable!(ctx)
      status = Runtime.status()
      assert status.stage == :cleanup_unprovable, "fixture: the hard conflict"
      view = admin_view(ctx.conn)

      assert has_element?(view, "#cleanup-unprovable"),
             "R0-05 1 (:cleanup_unprovable): the card has no #cleanup-unprovable banner"

      banner = text_of(view, "#cleanup-unprovable")

      for words <- [
            "A model server's cleanup can't be confirmed.",
            "Calls stay paused.",
            "An operator must check the machine and release the old reaper's lease from a console.",
            "Normal reconciliation then checks readiness again."
          ] do
        assert banner =~ words, "R0-05 1: the banner must say #{inspect(words)}; got #{banner}"
      end

      refute banner =~ ~r/restart/i, "R0-05 1: no unconditional automatic restart is promised"
      assert_card!(view, status, ":cleanup_unprovable")
    end

    test "an unknown ledger (an uncertain finalization) shows unknown, never a default", ctx do
      gate = uncertain_ledger!(ctx)
      status = Runtime.status()
      assert_card!(admin_view(ctx.conn), status, "unknown ledger")
      settle_ledger!(gate)
    end

    test "an inconsistent runtime sample is unknown, never the default", ctx do
      released!()
      view = admin_view(ctx.conn)
      server = Process.whereis(ClaudeCLI.server())
      ref = make_ref()
      pause_view_samples!(view.pid, for(attempt <- 1..3, do: {:s1, attempt}))
      audit_refresh!(ctx.tenant.id)

      for attempt <- 1..3 do
        assert_receive {:r005_sample, :s1, ^attempt, pid},
                       5_000,
                       "R0-05 1: the page's audit refresh never reached C2-02c sample (s1, #{attempt})"

        if rem(attempt, 2) == 1,
          do: assert(ClaudeCLI.hold(server, ref) == {:held, ref}),
          else: assert(ClaudeCLI.release_hold(server, ref) == :ok)

        send(pid, {:r005_continue, :s1, attempt})
      end

      expected = %{
        Runtime.status()
        | observed_profile: :unknown,
          hold: :unknown,
          stage: :unknown,
          effective_profile: nil,
          refusal: :status_inconsistent
      }

      await_element!(
        view,
        "#accepting-calls[data-refusal='status_inconsistent']",
        nil,
        5_000,
        "1 (inconsistent): the refreshed card never showed the inconsistent sample"
      )

      _ = ClaudeCLI.release_hold(server, ref)
      assert_card!(view, expected, "inconsistent")
    end
  end

  ## 2. No model call

  test "2. no model call across mount, refresh, a resolution and a switch (launches traced: zero)",
       ctx do
    blocked = RH.dead_holder!(ctx)
    flush_launches()
    invocations = invocations!()
    tracer = trace_calls!(@model_calls)

    view = admin_view(ctx.conn)
    click!(view, "#refresh-status", "2 refresh")
    audit_refresh!(ctx.tenant.id)

    open_resolution!(view, "2 resolve")
    confirm_resolution!(view, confirmation(blocked), "2 resolve")
    await_outcome!(view, "recorded", 20_000, "2 resolve")

    RH.await_status!(&(&1.stage == :cleanup_unprovable), 15_000)
    # The test-side operator path (never the page's).
    assert :ok = Reaper.release(ClaudeCLI.server())
    RH.await_status!(&(&1.hold == :released), 20_000)
    RH.drain!()

    click!(view, "#refresh-status", "2 refresh after the release")
    await_element!(view, "#accepting-calls[data-accepting='yes']", nil, 5_000, "2 released")
    open_switch!(view, "2 switch")
    review_switch!(view, "claude_cli_sonnet", "2 switch")
    click!(view, "#confirm-switch", "2 switch")
    await_element!(view, "#switch-result", "Switch requested", 10_000, "2 switch requested")
    RH.await_status!(&(&1.hold == :released and &1.profile_id == @sonnet), 20_000)
    RH.drain!()
    click!(view, "#refresh-status", "2 refresh after the switch")

    refute_received {:launch_admission, _, _, _}, "R0-05 2: a model call was admitted"
    model_calls = Enum.reject(calls(tracer), &(&1.pid == self()))

    assert model_calls == [],
           "R0-05 2: no model call, reservation or launch admission; got " <>
             inspect(Enum.map(model_calls, &{&1.pid, &1.mfa}))

    assert invocations!() == invocations, "R0-05 2: no model invocation was reserved"
  end

  ## 3. Refresh

  test "3. an audit commit re-renders the card, Refresh status re-reads it, and nothing polls",
       ctx do
    released!()
    view = admin_view(ctx.conn)

    assert has_element?(view, "#running-profile[data-profile='claude_cli_opus']"),
           "R0-05 3: the card shows the running profile"

    switch_through_coordinator!(ctx)
    Process.sleep(1_500)

    assert attr_of(view, "#running-profile", "data-profile") == "claude_cli_opus",
           "R0-05 3: no timer and no polling: the card changes only on an audit event or a click"

    audit_refresh!(ctx.tenant.id)

    await_element!(
      view,
      "#running-profile[data-profile='claude_cli_sonnet']",
      nil,
      5_000,
      "3: an audit commit re-reads Runtime.status/0"
    )

    assert_card!(view, Runtime.status(), "3 after the audit refresh")

    switch_through_coordinator!(ctx)
    Process.sleep(1_000)
    assert attr_of(view, "#running-profile", "data-profile") == "claude_cli_sonnet"

    click!(view, "#refresh-status", "3 manual refresh")

    await_element!(
      view,
      "#running-profile[data-profile='claude_cli_opus']",
      nil,
      5_000,
      "3: Refresh status re-reads Runtime.status/0"
    )

    assert_card!(view, Runtime.status(), "3 after Refresh status")
  end

  ## 4. The control

  describe "4. Change model profile shows only for ClaudeCLI, a confirmed desired profile and no open switch" do
    test "shown when released with no switch; hidden for the Fake and with no coordinator",
         %{conn: conn} do
      released!()

      assert has_element?(admin_view(conn), "#change-profile"),
             "R0-05 4: ClaudeCLI, a confirmed desired profile and no open switch show the control"

      SH.select_fake!()
      refute has_element?(admin_view(conn), "#change-profile"), "R0-05 4: hidden for the Fake"

      SH.select_claude_cli!()
      SH.stop_tree!()
      view = admin_view(conn)
      refute has_element?(view, "#change-profile"), "R0-05 4: hidden while the status is unknown"

      assert has_element?(view, "#switch-status-unknown", "status unknown; refresh"),
             "R0-05 4: an unknown status says \"status unknown; refresh\""
    end

    test "hidden while a switch is pending", ctx do
      released!()
      pause = RH.pause_stage!(:drained)
      RH.request_switch!(ctx)
      assert_receive {:stage_paused, :drained, worker}, 20_000
      :telemetry.detach(pause)
      RH.await_status!(&match?(%{switch: %{status: :pending}}, &1), 10_000)
      assert %{switch: %{status: :pending}} = Runtime.status()
      view = admin_view(ctx.conn)

      assert has_element?(view, "#open-switch[data-state='pending']"),
             "R0-05 4: the card shows the pending switch"

      refute has_element?(view, "#change-profile"), "R0-05 4: hidden while a switch is open"
      refute has_element?(view, "#resolve-blocked"), "R0-05 4: a pending switch is not blocked"
      send(worker, :continue)
    end

    test "hidden while a switch is blocked (the resolver shows instead)", ctx do
      RH.survivor!(ctx)
      view = admin_view(ctx.conn)

      assert has_element?(view, "#resolve-blocked"),
             "R0-05 4: a blocked switch shows Resolve blocked switch"

      refute has_element?(view, "#change-profile"), "R0-05 4: hidden while a switch is blocked"
    end

    test "hidden while the ledger is unknown", ctx do
      gate = uncertain_ledger!(ctx)
      view = admin_view(ctx.conn)

      assert has_element?(view, "#switch-status-unknown", "status unknown; refresh"),
             "R0-05 4: an unknown ledger says \"status unknown; refresh\""

      refute has_element?(view, "#change-profile"), "R0-05 4: hidden while the ledger is unknown"
      settle_ledger!(gate)
    end
  end

  ## 5. The setting read

  describe "5. the review's from and revision come from the setting itself" do
    test "absent: the default and revision 1; present: its from and its revision", ctx do
      released!()
      assert match?({:ok, nil}, Agents.get_profile_setting(actor: ctx.admin)), "fixture: absent"
      view = admin_view(ctx.conn)

      open_switch!(view, "5 absent")

      assert has_element?(view, "#switch-target option[value='claude_cli_sonnet']"),
             "R0-05 5: the choices are the reviewed real profiles except from"

      refute has_element?(view, "#switch-target option[value='claude_cli_opus']")
      refute has_element?(view, "#switch-target option[value='fake']")
      review_switch!(view, "claude_cli_sonnet", "5 absent")

      assert attr_of(view, "#switch-review", "data-from") == "claude_cli_opus" and
               attr_of(view, "#switch-review", "data-revision") == "1",
             "R0-05 5 (absent): from the registry default at revision 1; got " <>
               inspect(text_of(view, "#switch-review"))

      assert has_element?(
               view,
               "#switch-review",
               "Switch from claude_cli_opus to claude_cli_sonnet."
             )

      assert has_element?(view, "#switch-review", "Calls in progress finish first.")
      click!(view, "#cancel-switch", "5 cancel")

      switch_through_coordinator!(ctx)
      {:ok, setting} = Agents.get_profile_setting(actor: ctx.admin)
      assert setting.desired_profile_id == @sonnet and setting.revision > 1, "fixture: present"

      open_switch!(view, "5 present")
      review_switch!(view, "claude_cli_opus", "5 present")

      assert attr_of(view, "#switch-review", "data-from") == "claude_cli_sonnet" and
               attr_of(view, "#switch-review", "data-revision") == to_string(setting.revision),
             "R0-05 5 (present): from #{setting.desired_profile_id} at revision " <>
               "#{setting.revision}; got #{inspect(text_of(view, "#switch-review"))}"

      assert has_element?(view, "#switch-review", "revision #{setting.revision}")
    end

    test "a failed read shows a message and no review; it is never treated as absent", ctx do
      released!()
      view = admin_view(ctx.conn)
      SH.break_table!("model_profile_settings")

      try do
        open_switch!(view, "5 failed read")
      after
        SH.restore_table!("model_profile_settings")
      end

      assert Process.alive?(view.pid), "R0-05 5: a failed read never crashes the page"

      assert has_element?(view, "#switch-error", "the setting can't be read; try again"),
             "R0-05 5: a failed setting read says so; got #{inspect(text_of(view, "#switch-error"))}"

      refute has_element?(view, "#switch-form"), "R0-05 5: a failed read opens no choice"
      refute has_element?(view, "#switch-review"), "R0-05 5: a failed read is never absent"
    end

    test "changed between review and confirm: the stale refusal and a reload prompt, never a rewritten review",
         ctx do
      released!()
      tracer = trace_calls!([@request])
      view = admin_view(ctx.conn)
      open_switch!(view, "5 stale")
      review_switch!(view, "claude_cli_sonnet", "5 stale")

      done = switch_through_coordinator!(ctx)
      click!(view, "#confirm-switch", "5 stale")

      assert has_element?(view, "#switch-stale"),
             "R0-05 5: a changed setting shows the stale reload prompt; got " <>
               inspect(text_of(view, "#switch-error") || render(view))

      assert has_element?(view, "#reload-switch"), "R0-05 5: the stale prompt offers a reload"

      if has_element?(view, "#switch-review") do
        assert attr_of(view, "#switch-review", "data-revision") == "1" and
                 attr_of(view, "#switch-review", "data-from") == "claude_cli_opus",
               "R0-05 5: the review the admin saw is never rewritten"
      end

      call = one!(page_calls(tracer, @request), "R0-05 5: one request, nothing retried by itself")
      assert [%{to_profile_id: @sonnet, expected_revision: 1}, _opts] = call.args

      assert Enum.map(switches!(ctx.admin), & &1.id) == [done.id],
             "R0-05 5: no switch was written by the page"

      refute has_element?(view, "#switch-result", "Switch requested")
      refute_raw_terms!(view, "5 stale")
    end
  end

  ## 6. Confirm sends the stored review only

  test "6. confirm sends the stored review; browser values are ignored; a forged confirm does nothing",
       ctx do
    released!()
    tracer = trace_calls!([@request])
    view = admin_view(ctx.conn)
    forged = %{"to_profile_id" => "claude_cli_opus", "expected_revision" => "9"}

    render_click(view, "confirm_switch", Map.put(forged, "switch", forged))

    assert page_calls(tracer, @request) == [],
           "R0-05 6: a forged confirm_switch with no review sends nothing"

    open_switch!(view, "6")

    for target <- ["claude_cli_opus", "fake", "nope", ""] do
      render_submit(view, "review_switch", %{"switch" => %{"to_profile_id" => target}})

      refute has_element?(view, "#switch-review"),
             "R0-05 6: #{inspect(target)} is not a reviewed real profile other than from"
    end

    review_switch!(view, "claude_cli_sonnet", "6")
    render_click(view, "confirm_switch", Map.put(forged, "switch", forged))

    call = one!(page_calls(tracer, @request), "R0-05 6: exactly one request")

    assert match?([%{to_profile_id: @sonnet, expected_revision: 1}, _opts], call.args) and
             map_size(hd(call.args)) == 2,
           "R0-05 6: the stored review (claude_cli_sonnet at revision 1), never browser values; " <>
             "got #{inspect(call.args)}"

    assert actor_of(call).id == ctx.admin.id, "R0-05 6: the request runs as the signed-in admin"
    await_element!(view, "#switch-result", "Switch requested", 5_000, "6 requested")
    assert [%{to_profile_id: @sonnet}] = switches!(ctx.admin)
  end

  ## 7. Results

  describe "7. request results come from the operator-safe mapping" do
    test "{:error, :switch_open}: its message, then a re-read of the status", ctx do
      released!()
      view = admin_view(ctx.conn)
      open_switch!(view, "7 open")
      review_switch!(view, "claude_cli_sonnet", "7 open")

      pause = RH.pause_stage!(:drained)

      assert {:ok, _other} =
               Coordinator.request_switch(%{to_profile_id: @sonnet, expected_revision: 1},
                 actor: other_admin!(ctx)
               )

      assert_receive {:stage_paused, :drained, worker}, 20_000
      :telemetry.detach(pause)
      RH.await_status!(&match?(%{switch: %{status: :pending}}, &1), 10_000)

      click!(view, "#confirm-switch", "7 open")

      assert has_element?(view, "#switch-error", "Another switch is open"),
             "R0-05 7: :switch_open says \"Another switch is open\"; got " <>
               inspect(text_of(view, "#switch-error"))

      await_element!(
        view,
        "#open-switch[data-state='pending']",
        nil,
        5_000,
        "7: :switch_open is followed by a re-read of the status"
      )

      refute_raw_terms!(view, "7 :switch_open")
      send(worker, :continue)
    end

    test ":coordinator_not_ready: its message; nothing is written", ctx do
      released!()
      view = admin_view(ctx.conn)
      open_switch!(view, "7 not ready")
      review_switch!(view, "claude_cli_sonnet", "7 not ready")
      SH.stop_tree!()
      click!(view, "#confirm-switch", "7 not ready")

      assert has_element?(
               view,
               "#switch-error",
               "The model server isn't ready to switch; try again shortly"
             ),
             "R0-05 7: :coordinator_not_ready has its message; got " <>
               inspect(text_of(view, "#switch-error"))

      assert switches!(ctx.admin) == []
      refute_raw_terms!(view, "7 :coordinator_not_ready")
    end
  end

  ## 8. The facts

  describe "8. the facts" do
    test "every covered start with its recorded identity (nil shows not recorded), and the lease kind",
         ctx do
      blocked = RH.partial!(ctx)
      assert {:ok, facts} = RH.facts(blocked, ctx.admin)

      assert Enum.any?(facts.covered_starts, &is_nil(&1.pid)),
             "fixture: a start with no recorded identity"

      view = admin_view(ctx.conn)
      open_resolution!(view, "8")

      assert has_element?(view, "#resolution-switch[data-switch-id='#{blocked.id}']"),
             "R0-05 8: the facts name the switch"

      switch_text = text_of(view, "#resolution-switch")

      for words <- [
            to_string(blocked.from_profile_id),
            to_string(blocked.to_profile_id),
            ctx.admin.display_name
          ] do
        assert switch_text =~ words,
               "R0-05 8: the switch shows #{inspect(words)}; got #{switch_text}"
      end

      for start <- facts.covered_starts do
        selector = "#covered-start-#{start.generation}"
        assert has_element?(view, selector), "R0-05 8: covered start #{start.generation} is shown"
        text = text_of(view, selector)

        for words <- [start.generation, start.reason, start.profile_id, start.status] do
          assert text =~ to_string(words),
                 "R0-05 8: start #{start.generation} shows #{words}; got #{text}"
        end

        for value <- [start.pid, start.node, start.reaper_pid] do
          words = value || "not recorded"
          assert text =~ words, "R0-05 8: start #{start.generation} shows #{words}; got #{text}"
        end
      end

      assert has_element?(view, "#resolution-lease-kind[data-kind='survivor']"),
             "R0-05 8: the lease kind in words; got #{inspect(text_of(view, "#resolution-lease-kind"))}"

      assert has_element?(view, "#resolution-statement", statement())
      refute_raw_terms!(view, "8 facts")
    end

    test ":observation_unknown shows its message and no statement or input", ctx do
      {:ok, gate} = Agent.start_link(fn -> :read end)
      RH.dead_holder!(ctx, faults: [observe: fn -> Agent.get(gate, & &1) end])
      view = admin_view(ctx.conn)
      Agent.update(gate, fn _ -> :unavailable end)
      click!(view, "#resolve-blocked", "8 observation unknown")

      await_element!(
        view,
        "#resolution-error",
        "The server's state can't be read right now; try again",
        5_000,
        "8: {:error, :observation_unknown} has its message"
      )

      refute has_element?(view, "#resolution-statement"), "R0-05 8: no statement without facts"
      refute has_element?(view, "#resolution-confirmation"), "R0-05 8: no input without facts"
      refute_raw_terms!(view, "8 observation unknown")
      Agent.update(gate, fn _ -> :read end)
      open_resolution!(view, "8 after the observation recovers")
    end
  end

  ## 9. The typed confirmation

  # The page's local refusal of a text that doesn't match (draft 4, section
  # 3 step 2): no dispatch, #resolution-mismatch without the text, still
  # :editing with the same id, the input cleared and the button still
  # enabled (draft 5: a browser cannot submit through a disabled button), and
  # no raw value kept in the socket.
  defp assert_mismatch!(view, tracer, blocked, id, wrong, label) do
    sent = resolution_dispatches(tracer)

    assert sent == [],
           "R0-05 #{label}: a text that doesn't match is refused by the page, with no task, " <>
             "domain or coordinator resolution call; got #{inspect(Enum.map(sent, & &1.mfa))}"

    assert has_element?(view, "#resolution-mismatch"),
           "R0-05 #{label}: the page's refusal shows #resolution-mismatch; got " <>
             inspect(text_of(view, "#resolution-result") || review_state(view))

    shown = text_of(view, "#resolution-mismatch")

    assert shown =~ @mismatch,
           "R0-05 #{label}: #resolution-mismatch says #{inspect(@mismatch)}; got #{inspect(shown)}"

    refute shown =~ blocked.id, "R0-05 #{label}: the refusal never repeats the text"

    assert review_state(view) == "editing" and review_id(view) == id,
           "R0-05 #{label}: the review stays :editing with the same attestation id; got " <>
             "#{inspect(review_state(view))} #{inspect(review_id(view))}"

    refute has_element?(view, "#resolution-result"),
           "R0-05 #{label}: a local refusal claims no recorded or refused attempt"

    refute has_element?(view, "#confirm-resolution[disabled]"),
           "R0-05 #{label}: the button stays enabled in :editing (draft 5), so the next " <>
             "entry can be submitted from a browser"

    assert attr_of(view, "#resolution-confirmation", "value") in [nil, ""],
           "R0-05 #{label}: the input is cleared"

    if is_binary(wrong) and wrong not in ["", "STOPPED"] do
      refute holds?(:sys.get_state(view.pid), wrong),
             "R0-05 #{label}: the mismatched text is kept nowhere in the socket"

      unless String.contains?(wrong, confirmation(blocked)) do
        refute render(view) =~ wrong, "R0-05 #{label}: the page never shows the text"
      end
    end
  end

  test "9. the button stays enabled for every text; a wrong or malformed submit is refused by the page and stays :editing",
       ctx do
    blocked = RH.none!(ctx)
    tracer = trace_calls!(resolution_path_mfas())
    view = admin_view(ctx.conn)
    id = open_resolution!(view, "9")
    exact = confirmation(blocked)

    wrongs = [
      "stopped " <> blocked.id,
      " " <> exact,
      exact <> " ",
      "STOPPED  " <> blocked.id,
      "STOPPED " <> Ecto.UUID.generate(),
      "STOPPED",
      ""
    ]

    for wrong <- wrongs do
      type!(view, wrong, "9")

      refute has_element?(view, "#confirm-resolution[disabled]"),
             "R0-05 9: the button stays enabled for #{inspect(wrong)} (draft 5), so a " <>
               "browser can submit it to the page's own check"
    end

    type!(view, exact, "9")

    refute has_element?(view, "#confirm-resolution[disabled]"),
           "R0-05 9: the button is enabled for exactly STOPPED <switch id>"

    # A submit of a wrong text: the page checks the submitted bytes itself.
    for wrong <- wrongs do
      label = "9 forced #{inspect(wrong)}"
      type!(view, exact, label)
      confirm_resolution!(view, wrong, label)
      assert_mismatch!(view, tracer, blocked, id, wrong, label)
    end

    # Malformed input (absent, a list, a map) takes the same local route.
    for {params, what} <- [
          {%{}, "absent"},
          {%{"resolution_confirmation" => [exact]}, "a list"},
          {%{"resolution_confirmation" => %{"text" => exact}}, "a map"}
        ] do
      label = "9 malformed (#{what})"
      type!(view, exact, label)
      render_submit(view, "confirm_resolution", params)
      assert_mismatch!(view, tracer, blocked, id, nil, label)
    end

    type!(view, exact, "9 a fresh exact entry")

    refute has_element?(view, "#confirm-resolution[disabled]"),
           "R0-05 9: the button is enabled for a fresh exact entry"

    confirm_resolution!(view, exact, "9 exact")
    await_outcome!(view, "recorded", 20_000, "9 exact")
    refute_raw_terms!(view, "9")

    call = one!(resolve_calls(tracer), "R0-05 9: one resolution, of the exact text only")
    sent = attestation_of(call)

    assert sent.confirmation === exact and sent.attestation_id == id,
           "R0-05 9: the operator's own bytes are sent, under the same review id; got " <>
             inspect(Map.take(sent, [:attestation_id, :confirmation]))

    assert stored_status!(ctx, blocked) == :failed
    assert length(RH.resolved_events(ctx)) == 1
  end

  ## 11. Stale facts while editing

  test "11. in :editing, an unchanged refresh keeps the input; changed facts clear it and need a new review",
       ctx do
    blocked = RH.dead_holder!(ctx)
    tracer = trace_calls!([@resolve])
    view = admin_view(ctx.conn)
    first = open_resolution!(view, "11")
    type!(view, confirmation(blocked), "11")

    audit_refresh!(ctx.tenant.id)
    click!(view, "#refresh-status", "11 manual refresh")
    render(view)

    assert review_state(view) == "editing" and review_id(view) == first,
           "R0-05 11: an unchanged refresh keeps the review"

    refute has_element?(view, "#confirm-resolution[disabled]"),
           "R0-05 11: an unchanged refresh keeps the typed confirmation"

    # The facts change: the operator path removes the dead lease (kind :none).
    assert :ok = Reaper.release(ClaudeCLI.server())
    click!(view, "#refresh-status", "11 refresh after the change")

    await_element!(
      view,
      "#resolution-facts-changed",
      "the facts changed; review again",
      5_000,
      "11: changed facts ask for a new review"
    )

    assert has_element?(view, "#confirm-resolution[disabled]") or
             not has_element?(view, "#confirm-resolution"),
           "R0-05 11: changed facts clear the input"

    render_submit(view, "confirm_resolution", %{
      "resolution_confirmation" => confirmation(blocked)
    })

    assert resolve_calls(tracer) == [],
           "R0-05 11: nothing is sent on the stale facts without a new review"

    second = open_resolution!(view, "11 review again")
    assert second != first, "R0-05 11: a new review has a new attestation id"
    assert has_element?(view, "#resolution-lease-kind[data-kind='none']")
    type!(view, confirmation(blocked), "11 review again")
    confirm_resolution!(view, confirmation(blocked), "11 review again")
    await_outcome!(view, "recorded", 20_000, "11 the new review")

    call = one!(resolve_calls(tracer), "R0-05 11: one resolution, from the new review")

    assert match?(%{attestation_id: ^second, attested_lease_kind: :none}, attestation_of(call)),
           "R0-05 11: the new review's id and facts; got #{inspect(attestation_of(call))}"
  end

  ## 12. Forged and terminal

  test "12. a forged confirm does nothing; after a domain refusal of the exact text a new review needs a new id and text",
       ctx do
    blocked = RH.dead_holder!(ctx)
    tracer = trace_calls!([@resolve])
    view = admin_view(ctx.conn)
    exact = confirmation(blocked)
    forged = %{"resolution_confirmation" => exact, "attestation_id" => Ecto.UUID.generate()}

    render_submit(view, "confirm_resolution", forged)
    render_click(view, "check_again", forged)

    assert resolve_calls(tracer) == [],
           "R0-05 12: a forged confirm_resolution or check_again with no review sends nothing"

    first = open_resolution!(view, "12")
    type!(view, exact, "12")
    # Draft 4 (D-141): the terminal result is a real domain refusal of the
    # exact text. The facts change under the review (the operator path
    # removes the dead lease), so b2β refuses it as stale.
    assert :ok = Reaper.release(ClaudeCLI.server())
    confirm_resolution!(view, exact, "12 stale")
    await_outcome!(view, "stale_attestation", 20_000, "12 a domain refusal of the exact text")
    assert_terminal!(view, "12")

    refused = one!(resolve_calls(tracer), "R0-05 12: the exact text was sent once")
    assert refused.result == {:error, :stale_attestation}, "fixture: b2β's typed refusal"

    assert match?(%{attestation_id: ^first, confirmation: ^exact}, attestation_of(refused)),
           "R0-05 12: the refused attempt carried the review's id and the operator's text"

    sent = length(resolve_calls(tracer))

    render_submit(view, "confirm_resolution", forged)
    render_click(view, "check_again", forged)

    assert length(resolve_calls(tracer)) == sent,
           "R0-05 12: a terminal review is discarded; a forged confirm sends nothing"

    second = open_resolution!(view, "12 new review")
    assert second != first, "R0-05 12: a new resolution has a new attestation id"

    assert attr_of(view, "#resolution-confirmation", "value") in [nil, ""],
           "R0-05 12: a new resolution needs a new typed confirmation (its input is empty)"

    # The earlier text is never carried over: a submit without one sends
    # nothing and keeps the new review.
    render_submit(view, "confirm_resolution", %{})

    assert length(resolve_calls(tracer)) == sent,
           "R0-05 12: the new review needs a new typed text; a submit without one sends nothing"

    assert review_state(view) == "editing" and review_id(view) == second,
           "R0-05 12: the new review stays :editing with its own id; got " <>
             "#{inspect(review_state(view))} #{inspect(review_id(view))}"

    type!(view, exact, "12 new review")
    confirm_resolution!(view, exact, "12 new review")
    await_outcome!(view, "recorded", 20_000, "12 new review")

    last = List.last(resolve_calls(tracer))

    assert match?(%{attestation_id: ^second, confirmation: ^exact}, attestation_of(last)),
           "R0-05 12: the new review's id and the operator's text; got " <>
             inspect(attestation_of(last))

    assert stored_status!(ctx, blocked) == :failed
  end

  ## 13. Results

  describe "13. resolution results" do
    test "recorded: the exact message, terminal, never ready; the dead lease then shows the banner",
         ctx do
      blocked = RH.dead_holder!(ctx)
      view = admin_view(ctx.conn)
      open_resolution!(view, "13 recorded")
      confirm_resolution!(view, confirmation(blocked), "13 recorded")
      text = await_outcome!(view, "recorded", 20_000, "13 recorded")

      assert text =~ recorded_message(),
             "R0-05 13: the recorded message, word for word; got #{inspect(text)}"

      assert_terminal!(view, "13 recorded")
      refute_ready!(view, "13 recorded")

      RH.await_status!(&(&1.stage == :cleanup_unprovable), 15_000)
      click!(view, "#refresh-status", "13 refresh")
      await_element!(view, "#cleanup-unprovable", nil, 5_000, "13: the hard conflict's banner")
      refute_ready!(view, "13 after the refresh")
    end

    test "a first-attempt :resolve_timeout is Not recorded and terminal; Check again is not offered",
         ctx do
      blocked = RH.dead_holder!(ctx)
      tracer = trace_calls!([@resolve])
      view = admin_view(ctx.conn)
      open_resolution!(view, "13 timeout")
      blocker = RH.block_coordinator!()
      confirm_resolution!(view, confirmation(blocked), "13 timeout")

      assert review_state(view) == "submitting", "R0-05 13: a confirm enters :submitting"
      render_click(view, "check_again", %{})
      text = await_outcome!(view, "not_recorded", 30_000, "13 a definite first timeout")

      call =
        one!(
          resolve_calls(tracer),
          "R0-05 13: one attempt; a forged check_again while :submitting sends nothing"
        )

      assert call.result == {:error, :resolve_timeout}, "fixture: b2β's definite timeout"
      assert text =~ "Not recorded. Start a new review."
      assert_terminal!(view, "13 timeout")
      render_click(view, "check_again", %{})
      assert length(resolve_calls(tracer)) == 1, "R0-05 13: a terminal review has no Check again"

      RH.release_coordinator!(blocker)
      RH.drain!()
      assert stored_status!(ctx, blocked) == :blocked
    end

    test "typed refusals: busy, observation unknown, live work, stale and not blocked, each terminal in words",
         ctx do
      {:ok, gate} = Agent.start_link(fn -> :read end)
      blocked = RH.dead_holder!(ctx, faults: [observe: fn -> Agent.get(gate, & &1) end])
      {:held, dead} = Reaper.lease(ClaudeCLI.server())
      view = admin_view(ctx.conn)

      refusals = [
        coordinator_busy: {
          fn -> :sys.replace_state(Coordinator, &%{&1 | reconcile: :boot}) end,
          fn -> :sys.replace_state(Coordinator, &%{&1 | reconcile: nil}) end
        },
        observation_unknown: {
          fn -> Agent.update(gate, fn _ -> :unavailable end) end,
          fn -> Agent.update(gate, fn _ -> :read end) end
        },
        live_work_observed: {
          fn -> :persistent_term.put({Reaper, ClaudeCLI.server()}, {:held, live_dummy!()}) end,
          fn -> :persistent_term.put({Reaper, ClaudeCLI.server()}, {:held, dead}) end
        },
        stale_attestation:
          {fn -> assert :ok = Reaper.release(ClaudeCLI.server()) end, fn -> :ok end},
        switch_not_blocked: {
          fn ->
            attestation = RH.attestation(blocked, RH.latest_start!(ctx), :none)
            assert match?({:ok, _}, RH.resolve(blocked, attestation, other_admin!(ctx)))
          end,
          fn -> :ok end
        }
      ]

      for {tag, {fault, restore}} <- refusals do
        open_resolution!(view, "13 #{tag}")
        type!(view, confirmation(blocked), "13 #{tag}")
        fault.()
        confirm_resolution!(view, confirmation(blocked), "13 #{tag}")
        text = await_outcome!(view, tag, 20_000, "13 #{tag}")
        restore.()

        assert text != "" and not (text =~ "Not recorded") and not (text =~ recorded_message()),
               "R0-05 13: #{tag} is a refusal in words; got #{inspect(text)}"

        assert_terminal!(view, "13 #{tag}")
        refute_ready!(view, "13 #{tag}")
        refute_raw_terms!(view, "13 #{tag}")
      end

      assert stored_status!(ctx, blocked) == :failed
      assert length(RH.resolved_events(ctx)) == 1, "only the other admin's resolution"
    end

    test ":attestation_conflict on a first attempt: a refusal in words, terminal", ctx do
      blocked = RH.none!(ctx)
      view = admin_view(ctx.conn)
      id = open_resolution!(view, "13 conflict")
      type!(view, confirmation(blocked), "13 conflict")

      # Another admin resolves under the page's own attestation id.
      attestation = RH.attestation(blocked, RH.latest_start!(ctx), :none, %{attestation_id: id})
      assert match?({:ok, _}, RH.resolve(blocked, attestation, other_admin!(ctx)))

      confirm_resolution!(view, confirmation(blocked), "13 conflict")
      text = await_outcome!(view, "attestation_conflict", 20_000, "13 conflict")
      assert text != "" and not (text =~ recorded_message())
      assert_terminal!(view, "13 conflict")
      refute_raw_terms!(view, "13 conflict")
    end
  end

  ## 14. Reconnect

  test "14. a remount re-reads the stored switch as the actor; no attestation is invented or submitted",
       ctx do
    blocked = RH.dead_holder!(ctx)
    tracer = trace_calls!([@resolve, @switches])
    first = admin_view(ctx.conn)
    id = open_resolution!(first, "14")
    type!(first, confirmation(blocked), "14")

    earlier = length(page_calls(tracer, @switches))
    second = admin_view(ctx.conn)

    refute has_element?(second, "#resolution-review"),
           "R0-05 14: a reload loses the socket-only review"

    refute render(second) =~ id, "R0-05 14: the lost attestation id is never reused"

    reads = tracer |> page_calls(@switches) |> Enum.drop(earlier)

    assert Enum.any?(reads, &(actor_of(&1) && actor_of(&1).id == ctx.admin.id)),
           "R0-05 14: the remount re-reads the stored switch with an actor-authorized domain read"

    assert has_element?(second, "#stored-switch[data-status='blocked']"),
           "R0-05 14: the stored switch is still blocked"

    assert has_element?(second, "#resolve-blocked")

    attestation = RH.attestation(blocked, RH.latest_start!(ctx), :dead_holder)
    assert match?({:ok, _}, RH.resolve(blocked, attestation, other_admin!(ctx)))
    RH.drain!()
    third = admin_view(ctx.conn)

    assert has_element?(third, "#stored-switch[data-status='failed']"),
           "R0-05 14: a remount shows the resolved stored switch"

    refute has_element?(third, "#resolve-blocked")
    by_page = Enum.filter(page_calls(tracer, @resolve), &(actor_of(&1).id == ctx.admin.id))
    assert by_page == [], "R0-05 14: no page invented or submitted an attestation"
  end

  ## 15. Never logged

  test "15. the confirmation text is absent from logs, URLs, stored rows and telemetry", ctx do
    blocked = RH.none!(ctx)
    exact = confirmation(blocked)
    wrong = "stopped " <> blocked.id
    recorder = capture_telemetry!()

    {{refusal, html}, log} =
      debug_logs(fn ->
        view = admin_view(ctx.conn)
        render_click(view, "open_resolution", %{})
        render_change(view, "change_resolution", %{"resolution_confirmation" => wrong})
        render_submit(view, "confirm_resolution", %{"resolution_confirmation" => wrong})
        # Draft 4 (D-141): the page refuses the wrong text itself and the
        # review stays :editing, so the exact text follows on the same review.
        wait_until(fn -> has_element?(view, "#resolution-mismatch") end, 5_000)
        refusal = text_of(view, "#resolution-mismatch")
        render_click(view, "open_resolution", %{})
        render_change(view, "change_resolution", %{"resolution_confirmation" => exact})
        render_submit(view, "confirm_resolution", %{"resolution_confirmation" => exact})

        wait_until(
          fn -> has_element?(view, "#resolution-result[data-outcome='recorded']") end,
          20_000
        )

        {refusal, render(view)}
      end)

    for text <- [exact, wrong] do
      refute log =~ text,
             "R0-05 15: the confirmation text appears in the captured :debug logs " <>
               "(filter the resolution_confirmation parameter)"
    end

    assert log =~ "change_resolution" and log =~ "confirm_resolution",
           "control: the LiveView events were logged at :debug"

    assert log =~ "[FILTERED]", "control: the parameter is filtered, not dropped"

    assert refusal != nil and not (refusal =~ exact) and not (refusal =~ wrong),
           "R0-05 15: the page's refusal (#resolution-mismatch) is shown, without the text; " <>
             "got #{inspect(refusal)}"

    assert html =~ "data-outcome=\"recorded\"",
           "R0-05 15: the flow ran to the recorded result"

    records = telemetry_records(recorder)

    for {kind, entry} <- records, text <- [exact, wrong] do
      refute entry =~ text, "R0-05 15: the confirmation text appears in a #{kind} record"
    end

    assert Enum.any?(records, &match?({:url, _}, &1)), "control: URLs were recorded"
    assert tables_containing(exact) == [] and tables_containing(wrong) == []
    refute spans_containing?(exact) or spans_containing?(wrong)
    assert stored_status!(ctx, blocked) == :failed
  end

  ## 15a. Minimization (D-141, option B)

  test "15a. a mismatched canary never reaches the review, a task, Agents, ProfileSwitches or the coordinator; the exact text does",
       ctx do
    blocked = RH.none!(ctx)
    exact = confirmation(blocked)
    canary = mismatch_canary()
    tracer = trace_calls!(resolution_path_mfas())
    view = admin_view(ctx.conn)
    id = open_resolution!(view, "15a")

    type!(view, canary, "15a typed")

    refute holds?(:sys.get_state(view.pid), canary),
           "R0-05 15a: change_resolution keeps only whether the text matches, never the text"

    confirm_resolution!(view, canary, "15a forced")
    wait_until(fn -> has_element?(view, "#resolution-mismatch") end, 5_000)

    passed = Enum.filter(calls(tracer), &(&1.pid != self() and holds?(&1.args, canary)))

    assert passed == [],
           "R0-05 15a: the mismatched canary was passed to " <>
             inspect(passed |> Enum.map(&{&1.pid, &1.mfa}) |> Enum.uniq())

    refute holds?(:sys.get_state(view.pid), canary),
           "R0-05 15a: the mismatched canary is kept in the socket's assigns or review"

    refute render(view) =~ canary, "R0-05 15a: the page never shows the mismatched text"

    # Positive control: the exact text is passed, so an empty trace can't pass.
    type!(view, exact, "15a exact")
    confirm_resolution!(view, exact, "15a exact")
    await_outcome!(view, "recorded", 20_000, "15a exact")

    reached =
      tracer
      |> calls()
      |> Enum.filter(&(&1.pid != self() and holds?(&1.args, exact)))
      |> Enum.map(& &1.mfa)
      |> Enum.uniq()

    for mfa <- [
          {Phoenix.LiveView.Async, :start_async, 4},
          {Agents, :resolve_blocked_switch, 3},
          {SdrAgent.Agents.ProfileSwitches, :resolve_blocked, 3},
          {Coordinator, :resolve_blocked, 2}
        ] do
      assert mfa in reached,
             "R0-05 15a positive control: the exact text reaches #{inspect(mfa)}; " <>
               "reached #{inspect(reached)}"
    end

    assert attestation_of(one!(resolve_calls(tracer), "R0-05 15a: one resolution")).attestation_id ==
             id,
           "R0-05 15a: the exact attempt keeps the review's id"
  end

  ## 15b. The tagged channel's own crash reports (ADR-0005 R0-05 amendment)

  for event <- ["change_resolution", "confirm_resolution"] do
    test "15b. a channel crash while handling #{event} (form-encoded; valid and mismatched canaries) reports only the fixed diagnostic, at :debug and :warning",
         ctx do
      blocked = RH.none!(ctx)
      event = unquote(event)

      for level <- [:debug, :warning],
          {kind, canary} <- [valid: confirmation(blocked), mismatched: mismatch_canary()] do
        label = "15b #{event}, #{kind}, at #{level}"
        view = admin_view(ctx.conn)
        open_resolution!(view, label)
        crash_on_event!(view, event)
        params = %{"resolution_confirmation" => canary}

        {reason, text, events} =
          log_events(level, fn ->
            crash!(view, fn ->
              form = form(view, "#resolution-form", params)
              if event == "change_resolution", do: render_change(form), else: render_submit(form)
            end)
          end)

        assert seam_crash?(reason),
               "fixture: the channel crashed in the seam while handling #{event}; got " <>
                 inspect(reason, limit: 5)

        assert_withheld!(events, view.pid, label)
        assert text =~ withheld(), "R0-05 #{label}: the captured text shows the diagnostic"
        # Nothing was dispatched (the seam runs before the page's handler).
        refute_canary!(events, text, canary, label)
      end

      assert exception_filter!("15b #{event}")
    end
  end

  for level <- [:debug, :warning] do
    test "15b. a channel crash while frozen in :submitting reports only the fixed diagnostic, at #{level}",
         ctx do
      level = unquote(level)
      label = "15b :submitting at #{level}"
      blocked = RH.none!(ctx)
      text = confirmation(blocked)
      view = admin_view(ctx.conn)
      open_resolution!(view, label)
      blocker = RH.block_coordinator!()
      type!(view, text, label)
      confirm_resolution!(view, text, label)
      await_element!(view, "#resolution-review[data-state='submitting']", nil, 5_000, label)
      crash_on_event!(view, "refresh_status")

      {reason, log, events} =
        try do
          log_events(level, fn ->
            crash!(view, fn -> click!(view, "#refresh-status", label) end)
          end)
        after
          RH.release_coordinator!(blocker)
          RH.drain!()
        end

      assert seam_crash?(reason), "fixture: the seam crash; got #{inspect(reason, limit: 5)}"
      own = assert_withheld!(events, view.pid, label)

      # The valid phrase has been dispatched: downstream diagnostic copies
      # are D-141's accepted residual, so only the channel's own reports are
      # checked here.
      refute Enum.any?(events_of(events, view.pid), &canary_in?(&1, text)),
             "R0-05 #{label}: the channel's own events carry the confirmation"

      assert own != [] and log =~ withheld()
      assert exception_filter!(label)
    end
  end

  test "15b controls: untagged and C4 database crashes keep their reports, a tagged :info event is unchanged; a tagged error is replaced",
       _ctx do
    marker = "r005control" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    canary = mismatch_canary()
    tagged_canary = mismatch_canary()

    {pids, _text, events} =
      log_events(:debug, fn ->
        %{
          untagged: run_task!(fn -> raise "r005 untagged control " <> marker end),
          database:
            run_task!(fn ->
              Repo.transaction(fn ->
                Ecto.Adapters.SQL.query!(Repo, "SELECT $1::text::integer", [canary])
              end)
            end),
          info:
            run_task!(fn ->
              tag_process!()
              Logger.info("r005 tagged info " <> marker)
            end),
          error:
            run_task!(fn ->
              tag_process!()
              Logger.error("r005 tagged error " <> tagged_canary)
            end),
          tagged_database:
            run_task!(fn ->
              tag_process!()

              Repo.transaction(fn ->
                Ecto.Adapters.SQL.query!(Repo, "SELECT $1::text::integer", [tagged_canary])
              end)
            end)
        }
      end)

    # Controls: unchanged by the tag.
    untagged = events_of(events, pids.untagged)

    assert Enum.any?(untagged, &(event_text(&1) =~ marker)) and
             not Enum.any?(untagged, &(&1.msg == {:string, withheld()})),
           "R0-05 15b control: an untagged crash keeps its report"

    database = events_of(events, pids.database)

    assert Enum.any?(database, &(event_text(&1) =~ "Postgrex.Error")) and
             not Enum.any?(database, &canary_in?(&1, canary)),
           "R0-05 15b control: the C4 database-error path is unchanged (summarized, no canary)"

    assert Enum.any?(
             events_of(events, pids.info),
             &(&1.level == :info and event_text(&1) =~ marker and &1.meta[:sdr_sensitive_input])
           ),
           "R0-05 15b control: a tagged :info event is unchanged"

    # A tagged error, and a tagged database crash (the tag check is made
    # before the C4 scan), become the fixed diagnostic.
    assert_withheld!(events, pids.error, "15b a tagged Logger.error")
    # A Task's crash report carries no mfa.
    assert_withheld!(events, pids.tagged_database, "15b a tagged database crash", mfa: false)
    refute_canary!(events, "", tagged_canary, "15b tagged")
    assert exception_filter!("15b controls")
  end

  test "15b controls: a failed classification of a tagged event is replaced and the filter stays attached" do
    {fun, opts} = exception_filter!("15b classification")
    canary = mismatch_canary()
    meta = %{sdr_sensitive_input: true, pid: self(), note: canary}
    deep = Enum.reduce(1..60_000, canary, fn _, acc -> {acc} end)

    for {event, what} <- [
          {%{msg: {:string, "r005 " <> canary}, meta: meta}, "no level"},
          {%{level: :not_a_level, msg: {:string, "r005 " <> canary}, meta: meta},
           "an invalid level"},
          {%{level: :error, msg: {:string, "r005 " <> canary}, meta: Map.to_list(meta)},
           "list metadata"},
          # The tag check precedes the C4 scan: never C4's scan_limit event.
          {%{level: :error, msg: {:report, %{data: deep}}, meta: meta}, "an unscannable report"},
          {%{level: :error, msg: {:string, "r005"}, meta: Map.put(meta, :big, deep)},
           "unscannable metadata"}
        ] do
      result = fun.(event, opts)

      assert is_map(result) and result[:msg] == {:string, withheld()},
             "R0-05 15b: a tagged event whose classification fails (#{what}) is replaced by the " <>
               "fixed diagnostic, never returned unchanged; got #{inspect(result[:msg], limit: 5)}"

      refute holds?(result, canary), "R0-05 15b: the replaced event (#{what}) keeps the canary"
      assert Map.keys(result.meta) -- [:pid, :sdr_sensitive_input] == []
    end

    assert exception_filter!("15b classification")
  end

  ## 15c. The accepted limit, shown (D-141)

  test "15c. a supervisor's report about the tagged channel is not classified; the channel's own report is",
       ctx do
    sasl_reports!()
    RH.none!(ctx)
    canary = mismatch_canary()
    view = admin_view(ctx.conn)
    open_resolution!(view, "15c")
    crash_on_event!(view, "change_resolution", :params)
    {:ok, supervisor} = ExUnit.fetch_test_supervisor()

    {reason, _text, events} =
      log_events(:debug, fn ->
        crash!(view, fn ->
          view
          |> form("#resolution-form", %{"resolution_confirmation" => canary})
          |> render_change()
        end)
      end)

    assert match?({%MatchError{}, _stack}, reason),
           "fixture: the seam's MatchError on the params; got #{inspect(reason, limit: 3)}"

    # The control, in the same run: the channel's own reports are replaced.
    assert_withheld!(events, view.pid, "15c the channel's own report")

    refute Enum.any?(events_of(events, view.pid), &canary_in?(&1, canary)),
           "R0-05 15c: the channel's own events carry the canary"

    # The residual, shown (never an absence assertion): the supervisor's
    # report about the channel is the supervisor's own event, untagged and
    # unclassified, and it carries the crash reason with the input.
    reports =
      events |> events_of(supervisor) |> Enum.filter(&(event_text(&1) =~ inspect(view.pid)))

    assert reports != [],
           "R0-05 15c: with SASL translation on, the supervisor reports the channel's exit"

    for report <- reports do
      refute report.meta[:sdr_sensitive_input], "R0-05 15c: the supervisor's report is not tagged"
      refute report.msg == {:string, withheld()}, "R0-05 15c: it is not classified"
    end

    assert Enum.any?(reports, &canary_in?(&1, canary)),
           "R0-05 15c: the accepted residual: the supervisor's report carries the crash reason"

    assert exception_filter!("15c")
  end

  ## 16. The lag

  test "16. an audit commit before the coordinator publishes shows the earlier observation; Refresh shows the newer",
       ctx do
    released!()
    view = admin_view(ctx.conn)

    assert has_element?(view, "#open-switch[data-state='none']") and
             has_element?(view, "#accepting-calls[data-accepting='yes']"),
           "R0-05 16: the card shows the released baseline"

    before = attr_of(view, "#status-published-at", "data-published-at")

    blocker = RH.block_coordinator!()
    switch = RH.request_switch!(ctx)
    assert RH.raw_status(switch.id) == "pending", "fixture: the request committed"
    audit_refresh!(ctx.tenant.id)
    render(view)

    assert has_element?(view, "#open-switch[data-state='none']"),
           "R0-05 16: an audit commit before the coordinator publishes shows the earlier " <>
             "observation; got #{inspect(text_of(view, "#open-switch"))}"

    assert has_element?(view, "#accepting-calls[data-accepting='yes']")

    assert before != nil and attr_of(view, "#status-published-at", "data-published-at") == before,
           "R0-05 16: the card discloses the earlier publication time"

    pause = RH.pause_stage!(:drained)
    RH.release_coordinator!(blocker)
    assert_receive {:stage_paused, :drained, worker}, 20_000
    :telemetry.detach(pause)
    RH.await_status!(&match?(%{switch: %{status: :pending}}, &1), 10_000)
    Process.sleep(600)

    assert has_element?(view, "#open-switch[data-state='none']"),
           "R0-05 16: no coordinator PubSub and no polling: still the earlier observation"

    click!(view, "#refresh-status", "16 manual refresh")

    await_element!(
      view,
      "#open-switch[data-state='pending']",
      "claude_cli_opus → claude_cli_sonnet, pending",
      5_000,
      "16: a manual refresh shows the newer state"
    )

    assert has_element?(view, "#provider-hold[data-hold='held']")
    send(worker, :continue)
    RH.await_switch!(ctx, switch.id, :completed)
    RH.drain!()
  end

  ## 17. Access

  describe "17. access" do
    test "reviewers, auditors and a signed-out user are redirected; the admin's events reach the domain",
         ctx do
      released!()
      tracer = trace_calls!([@setting, @request, @facts, @resolve])

      for role <- [:reviewer, :auditor] do
        result = ctx.conn |> sign_in(role) |> live(~p"/admin")

        assert match?({:error, {:redirect, %{to: "/"}}}, result),
               "R0-05 17: #{role} is redirected; got #{inspect(result, limit: 3)}"
      end

      result = live(build_conn(), ~p"/admin")

      assert match?({:error, {:redirect, %{to: "/sign-in"}}}, result),
             "R0-05 17: a signed-out user is redirected to sign in"

      assert Enum.reject(calls(tracer), &(&1.pid == self())) == [],
             "R0-05 17: no event of a refused user reached the domain"

      # The allow pair: the admin's same event reaches the domain, as the admin.
      view = admin_view(ctx.conn)
      open_switch!(view, "17 allow")

      read =
        one!(page_calls(tracer, @setting), "R0-05 17: the admin's open_switch reads the setting")

      assert actor_of(read).id == ctx.admin.id
    end

    test "a demoted admin is redirected before confirm_switch reaches the domain; an active admin's confirm does",
         ctx do
      released!()
      tracer = trace_calls!([@request])
      view = admin_view(ctx.conn)
      open_switch!(view, "17 demoted")
      review_switch!(view, "claude_cli_sonnet", "17 demoted")

      other = other_admin!(ctx)
      {:ok, _demoted} = Accounts.change_role(ctx.admin, :reviewer, actor: other)
      result = render_click(view, "confirm_switch", %{})

      assert match?({:error, {:redirect, %{to: "/"}}}, result),
             "R0-05 17: a demoted admin is redirected; got #{inspect(result, limit: 3)}"

      assert page_calls(tracer, @request) == [], "R0-05 17: no request reached the domain"
      assert switches!(other) == []

      allowed = user_view(other)
      open_switch!(allowed, "17 allow")
      review_switch!(allowed, "claude_cli_sonnet", "17 allow")
      click!(allowed, "#confirm-switch", "17 allow")

      call = one!(page_calls(tracer, @request), "R0-05 17: the active admin's request")
      assert actor_of(call).id == other.id
    end

    test "a demoted and a disabled admin are redirected before confirm_resolution reaches the domain",
         ctx do
      blocked = RH.none!(ctx)
      tracer = trace_calls!([@resolve])
      exact = confirmation(blocked)
      second = other_admin!(ctx)
      third = other_admin!(ctx)

      demoted = admin_view(ctx.conn)
      disabled = user_view(second)

      for view <- [demoted, disabled] do
        open_resolution!(view, "17 resolver")
        type!(view, exact, "17 resolver")
      end

      {:ok, _} = Accounts.change_role(ctx.admin, :reviewer, actor: third)
      {:ok, _} = Accounts.change_status(second, :disabled, actor: third)

      for {view, to} <- [{demoted, "/"}, {disabled, "/sign-in"}] do
        result = render_submit(view, "confirm_resolution", %{"resolution_confirmation" => exact})

        assert match?({:error, {:redirect, %{to: ^to}}}, result),
               "R0-05 17: redirected to #{to}; got #{inspect(result, limit: 3)}"
      end

      assert resolve_calls(tracer) == [], "R0-05 17: no resolution reached the domain"
      assert stored_status!(%{ctx | admin: third}, blocked) == :blocked

      allowed = user_view(third)
      open_resolution!(allowed, "17 allow")
      confirm_resolution!(allowed, exact, "17 allow")
      await_outcome!(allowed, "recorded", 20_000, "17 allow")
      call = one!(resolve_calls(tracer), "R0-05 17: the active admin's resolution")
      assert actor_of(call).id == third.id
    end
  end
end
