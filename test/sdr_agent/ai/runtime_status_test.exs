defmodule SdrAgent.AI.RuntimeStatusTest do
  @moduledoc """
  C2-02c RED, status (`docs/product/r0/c2-02c-interface.md` draft 3,
  interface and entity PASS at `401df6f`; sections 2, 2a and 2b; section 4
  tests 8–15; binding interpretations 1–5).

  Status is the coordinator's last confirmed ledger observations plus one
  bracketed runtime sample (C1, S1, eligibility, S2, C2; at most three
  attempts), never authority, with no observation effects.

  **Seam chosen for GREEN** (test builds only, `@test_seams`, as the other
  test seams): `Runtime.status/0` emits `[:sdr_agent, :runtime_status,
  :sample]` with `%{point: :c1 | :s1 | :eligibility | :s2 | :c2, attempt:
  n}` in the caller right after each step, every point once per attempt.
  The bracket tests (9) pause the subject there (`StatusHarness`); a missing
  seam fails as the guard after the fixture.

  **Test-only faults:** a table renamed inside the shared sandbox
  transaction (`StatusHarness.break_table!/1`) makes the coordinator's real
  read fail (a failed read, never a missing seam); a blocked coordinator is
  b2α's `test_run/2`; a coordinator paused in a ledger read is b2β's
  `query_pause!/2`; a forged coordinator table is a test process's own
  named table. A test-side hold on the server changes its hold without the
  coordinator.

  **Effects (test 11):** every status read in 8–10 goes through
  `StatusHarness.status!/0`, scoped to the subject call (interpretation 5):
  repo-query telemetry of that task only, and a trace of its sends and of
  the forbidden calls (delivered, then acknowledged). Each test ends with
  `assert_no_status_effects!/0`; test 11 adds the quiescent counts and the
  positive controls.

  Passes by design: the observation controls (11). The Fake rows (8, 13)
  are shape pins that also hold today only where noted in their message.
  Shared SQL sandbox; the fake CLI under the test launcher; zero model
  calls.
  """
  use SdrAgent.AuditCase, async: false

  import SdrAgent.Test.StatusHarness

  alias SdrAgent.Agents
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.Coordinator
  alias SdrAgent.AI.ModelProvider.Fake
  alias SdrAgent.AI.ModelProvider.Runtime
  alias SdrAgent.Repo
  alias SdrAgent.Test.PinnedCLI
  alias SdrAgent.Test.ResolveHarness, as: RH

  @moduletag :c2_02c
  @moduletag timeout: 180_000

  @opus :claude_cli_opus
  @sonnet :claude_cli_sonnet

  setup do
    tenant = bootstrap!()
    RH.lease_cleanup!()
    select_claude_cli!()
    %{tenant: tenant, admin: human(:admin, tenant)}
  end

  ## 8. Every row of the 2b table

  describe "8. the 2b rows" do
    test "Fake: every ClaudeCLI field :not_applicable, even with a running tree and a stored Sonnet setting",
         ctx do
      sonnet!(ctx)
      select_fake!()

      assert_status!(
        status!(),
        [
          ledger_observation: :not_applicable,
          runtime_observation: :not_applicable,
          desired_profile: :not_applicable,
          switch: :not_applicable,
          observed_profile: :not_applicable,
          hold: :not_applicable,
          stage: :not_applicable,
          effective_profile: nil,
          effective: Fake,
          refusal: nil,
          published_at: nil,
          profile_id: :fake
        ],
        "8 Fake"
      )

      # The Fake's effective provider is "as today": its resolve/1 is a
      # pass-through (2a's no-resolve rule binds the ClaudeCLI bracket).
      assert_no_status_effects!(allow: [{Runtime, :resolve, 1}])
    end

    test "ClaudeCLI with no coordinator: :unavailable and :unknown; a named server alone is still unknown" do
      assert_status!(status!(), unavailable_row(), "8 no coordinator")

      # Interpretation 2: a process holding the name, with no coordinator
      # binding, is never its profile and never eligible.
      start_bare_server!(@sonnet)
      assert_status!(status!(), unavailable_row(), "8 no coordinator, a named server")
      stop_bare_server!()
      assert_no_status_effects!()
    end

    test "an invalid coordinator row (an unregistered owner, a stale binding, no row) is :unavailable" do
      tree!()
      RH.await_status!(&(&1.hold == :released))
      RH.drain!()
      rows = :ets.tab2list(Coordinator)
      stop_tree!()

      for {label, register?, rows} <- [
            {"unregistered table owner", false, rows},
            {"registered owner, the row's coordinator is another (stale binding)", true, rows},
            {"registered owner, no row", true, []}
          ] do
        forger = forge_coordinator_table!(rows, register?)
        assert_status!(status!(), unavailable_row(), "8 invalid coordinator: #{label}")
        stop_forger!(forger)
      end

      assert_no_status_effects!()
    end

    test "a valid coordinator with no bound server (a known failed start): :none, Sonnet confirmed",
         ctx do
      gate = start_gate()
      sonnet!(ctx, fail_start: gate)
      stop_tree!()
      :atomics.put(gate, 1, 1)
      log = RH.query_log!(&RH.coordinator_query/1)
      tree!(fail_start: gate)
      RH.await!(fn -> failed_start?(ctx) end, 10_000, "fixture: no known failed start")
      # Blocked between its boot retries, so its row is stable while read.
      blocker = RH.block_coordinator!()
      assert Process.whereis(ClaudeCLI.server()) == nil
      assert Enum.all?(RH.logged(log), &match?({_, :ok}, &1)), "fixture: every read succeeded"

      assert_status!(
        status!(),
        [
          ledger_observation: :valid,
          runtime_observation: :consistent,
          desired_profile: confirmed(@sonnet, :setting),
          switch: none_switch(),
          observed_profile: :none,
          hold: row(:hold),
          stage: row(:stage),
          effective_profile: nil,
          effective: nil,
          refusal: :provider_not_running,
          published_at: row_published_at(),
          profile_id: @sonnet,
          model_alias: "sonnet"
        ],
        "8 no bound server (known failed start)"
      )

      # Interpretation 2: :none needs no process holding the name.
      start_bare_server!(@sonnet)

      assert_status!(
        status!(),
        [
          ledger_observation: :valid,
          runtime_observation: :unavailable,
          desired_profile: confirmed(@sonnet, :setting),
          observed_profile: :unknown,
          hold: :unknown,
          stage: :unknown,
          effective_profile: nil,
          effective: nil,
          refusal: :status_unavailable,
          published_at: row_published_at()
        ],
        "8 no bound server, a named process holds the name"
      )

      stop_bare_server!()
      RH.release_coordinator!(blocker)
      assert_no_status_effects!()
    end

    test "a valid coordinator whose bound server is missing or unbound: runtime :unavailable, never :none",
         _ctx do
      tree!()
      RH.await_status!(&(&1.hold == :released))
      RH.drain!()
      blocker = RH.block_coordinator!()
      server = Process.whereis(ClaudeCLI.server())
      reaper = ClaudeCLI.reaper(server)
      RH.kill!(server)
      join!(reaper, "the killed server's reaper did not exit")

      missing = [
        ledger_observation: :valid,
        runtime_observation: :unavailable,
        desired_profile: confirmed(@opus, :default),
        switch: none_switch(),
        observed_profile: :unknown,
        hold: :unknown,
        stage: :unknown,
        effective_profile: nil,
        effective: nil,
        refusal: :status_unavailable,
        published_at: row_published_at(),
        profile_id: @opus,
        model_alias: "opus"
      ]

      assert_status!(status!(), missing, "8 bound server missing")

      # The name is now held by an unbound server at another profile.
      start_bare_server!(@sonnet)
      assert_status!(status!(), missing, "8 bound server replaced by an unbound one")
      stop_bare_server!()

      RH.release_coordinator!(blocker)
      RH.await_status!(&(&1.hold == :released), 20_000)
      RH.drain!()
      assert_no_status_effects!()
    end

    test "consistent, hold :held (a blocked switch's survivor): :provider_held", ctx do
      blocked = RH.survivor!(ctx)

      assert_status!(
        status!(),
        held_row(
          @opus,
          confirmed(@opus, :setting),
          open_switch(blocked, :blocked, "coordinator_restarted")
        ) ++
          [stage: row(:stage)],
        "8 held"
      )

      assert_ledger_is_row!(status!(), "8 held")
      assert_no_status_effects!()
    end

    test "consistent, hold :pending (an unacknowledged re-hold): :provider_held, a pending hold counts as held" do
      tree!()
      first = RH.await_status!(&(&1.hold == :released))
      RH.drain!()
      server = Process.whereis(ClaudeCLI.server())
      true = :erlang.suspend_process(server)
      on_exit(fn -> resume(server) end)

      kill_coordinator!()
      await_boot!(first.boot_id, &(&1.hold == :pending))
      # The new coordinator publishes its survivor binding before it waits
      # for the acknowledgement; it then retries the hold for up to 15 s.
      Process.sleep(300)
      assert %{hold: :pending} = Coordinator.status()
      pending = status!()
      resume(server)

      assert_status!(
        pending,
        [
          ledger_observation: :valid,
          runtime_observation: :consistent,
          desired_profile: unknown_or_confirmed(),
          switch: unknown_or_confirmed(),
          observed_profile: @opus,
          hold: :pending,
          effective_profile: nil,
          effective: nil,
          refusal: :provider_held,
          published_at: timestamp(),
          profile_id: @opus
        ],
        "8 pending"
      )

      await_boot!(first.boot_id, &(&1.hold == :released))
      RH.drain!()
      assert_no_status_effects!()
    end

    test "consistent, released, eligible: effective ClaudeCLI at the observed profile" do
      tree!()
      RH.await_status!(&(&1.hold == :released))
      RH.drain!()
      server = Process.whereis(ClaudeCLI.server())
      status = status!()

      assert_status!(
        status,
        released_row(@opus, confirmed(@opus, :default)) ++
          [
            stage: row(:stage),
            model_id: "claude-opus-5-5",
            reviewed_version: "2.1.294",
            attestation: ClaudeCLI.attestation(server)
          ],
        "8 released, eligible"
      )

      assert_ledger_is_row!(status, "8 released, eligible")
      assert_no_status_effects!()
    end

    test "consistent, released, eligibility refuses: the pin, version and admission reasons" do
      mismatched = PinnedCLI.inject_identity!(nil, version: "0.0.0")

      for {label, opts, reason} <- [
            {"pin missing", [server: [executable: PinnedCLI.missing_store_path()]],
             :pinned_cli_unavailable},
            # L2 E3 (deliberate change; was "staged", :real_model_staged): a
            # reviewed pin whose identity names another CLI version.
            {"version mismatch", [server: [test_launcher: false, executable: mismatched]],
             :pinned_cli_version_mismatch},
            {"admission blocked", [unidentified: @opus], :provider_not_quiescent}
          ] do
        tree!(opts)
        RH.await_status!(&(&1.hold == :released))
        RH.drain!()
        if reason == :provider_not_quiescent, do: block_admission!()

        assert_status!(
          status!(),
          [
            ledger_observation: :valid,
            runtime_observation: :consistent,
            desired_profile: confirmed(@opus, :default),
            switch: none_switch(),
            observed_profile: @opus,
            hold: :released,
            effective_profile: nil,
            effective: nil,
            refusal: reason,
            published_at: row_published_at(),
            profile_id: @opus
          ],
          "8 released, refused (#{label})"
        )

        stop_tree!()
      end

      assert_no_status_effects!()
    end
  end

  ## 9. The bracket

  describe "9. the bracket" do
    test "after S1: a same-profile replacement, then a hold change → no positive eligibility from mixed samples",
         _ctx do
      %{generation: generation} = released_tree!()
      old = Process.whereis(ClaudeCLI.server())
      h = start_observation(fn -> Runtime.status() end, pause: [{:s1, 1}])
      await_pause!(h, :s1, 1)

      new = replace_server!(old, generation)
      ref = make_ref()
      assert ClaudeCLI.hold(new, ref) == {:held, ref}, "fixture: the test-side hold"
      attestation = ClaudeCLI.attestation(new)
      continue!(h)
      {status, effects} = finish(h)
      assert ClaudeCLI.release_hold(new, ref) == :ok

      assert_status!(
        status,
        [
          ledger_observation: :valid,
          runtime_observation: :consistent,
          observed_profile: @opus,
          effective_profile: nil,
          effective: nil,
          refusal: :provider_held,
          attestation: attestation
        ],
        "9 mixed (replacement, then a hold): every runtime value from the later instance"
      )

      assert retried?(effects), "C2-02c 2a: the changed attempt was not retried"
      assert_no_effects!(effects, "9 mixed")
    end

    test "after S1: a same-profile replacement → a later wholly consistent attempt succeeds" do
      %{generation: generation} = released_tree!()
      old = Process.whereis(ClaudeCLI.server())
      h = start_observation(fn -> Runtime.status() end, pause: [{:s1, 1}])
      await_pause!(h, :s1, 1)

      new = replace_server!(old, generation)
      attestation = ClaudeCLI.attestation(new)
      continue!(h)
      {status, effects} = finish(h)

      assert_status!(
        status,
        released_row(@opus, confirmed(@opus, :default)) ++
          [attestation: attestation, published_at: row_published_at()],
        "9 a later consistent attempt (the replacement's own sample)"
      )

      assert retried?(effects), "C2-02c 2a: the changed attempt was not retried"
      assert_no_effects!(effects, "9 later consistent")
    end

    test "a coordinator restart between C1 and C2 → retried; the ledger is the new coordinator's" do
      first = released_tree!()
      h = start_observation(fn -> Runtime.status() end, pause: [{:s1, 1}])
      await_pause!(h, :s1, 1)
      old_published_at = Map.get(Coordinator.status(), :published_at)

      kill_coordinator!()
      await_boot!(first.boot_id, &(&1.hold == :released))
      RH.drain!()
      continue!(h)
      {status, effects} = finish(h)

      assert retried?(effects),
             "C2-02c 2a: an attempt across a coordinator restart was not retried"

      assert_status!(
        status,
        released_row(@opus, confirmed(@opus, :default)) ++
          [published_at: row_published_at(), published_at: other_than(old_published_at)],
        "9 coordinator restart between C1 and C2"
      )

      assert_no_effects!(effects, "9 coordinator restart")
    end

    test "the server table deleted and recreated between C1 and S1 → retried, then consistent" do
      %{generation: generation} = released_tree!()
      old = Process.whereis(ClaudeCLI.server())
      h = start_observation(fn -> Runtime.status() end, pause: [{:c1, 1}])
      await_pause!(h, :c1, 1)

      new = replace_server!(old, generation)
      attestation = ClaudeCLI.attestation(new)
      continue!(h)
      {status, effects} = finish(h)

      assert retried?(effects),
             "C2-02c 2a: a server table not bound by C1 (recreated by name) was not retried"

      assert_status!(
        status,
        released_row(@opus, confirmed(@opus, :default)) ++
          [attestation: attestation, published_at: row_published_at()],
        "9 server table recreated mid-attempt"
      )

      assert_no_effects!(effects, "9 table recreated")
    end

    test "three changing server samples → :inconsistent, the ledger still :valid (interpretation 1)" do
      released_tree!()
      server = Process.whereis(ClaudeCLI.server())
      pause = for attempt <- 1..3, do: {:s1, attempt}
      h = start_observation(fn -> Runtime.status() end, pause: pause)
      ref = make_ref()

      for attempt <- 1..3 do
        await_pause!(h, :s1, attempt)
        toggle_hold!(server, ref, attempt)
        continue!(h)
      end

      {status, effects} = finish(h)
      _ = ClaudeCLI.release_hold(server, ref)

      assert_status!(
        status,
        [
          ledger_observation: :valid,
          runtime_observation: :inconsistent,
          desired_profile: confirmed(@opus, :default),
          switch: none_switch(),
          observed_profile: :unknown,
          hold: :unknown,
          stage: :unknown,
          effective_profile: nil,
          effective: nil,
          refusal: :status_inconsistent,
          published_at: row_published_at(),
          profile_id: @opus
        ],
        "9 three changing server samples (2b: both valid, but changing)"
      )

      assert attempts(effects) == 3, "C2-02c 2a: at most three attempts; got #{attempts(effects)}"
      assert_no_effects!(effects, "9 three server changes")
    end

    test "three changing coordinator rows → :unavailable; no ledger kept from another attempt" do
      first = released_tree!()
      pause = for attempt <- 1..3, do: {:s1, attempt}
      h = start_observation(fn -> Runtime.status() end, pause: pause)

      Enum.reduce(1..3, first.boot_id, fn attempt, boot ->
        await_pause!(h, :s1, attempt)
        kill_coordinator!()
        %{boot_id: next} = await_boot!(boot, &(&1.hold == :released))
        RH.drain!()
        continue!(h)
        next
      end)

      {status, effects} = finish(h)
      assert_status!(status, unavailable_row(), "9 three changing coordinator rows")
      assert attempts(effects) == 3, "C2-02c 2a: at most three attempts; got #{attempts(effects)}"
      assert_no_effects!(effects, "9 three coordinator changes")
    end
  end

  ## 10. The lag intervals

  describe "10. lag" do
    test "a committed caller request shows the older confirmed none until the coordinator publishes",
         ctx do
      released_tree!()
      before = status!()
      assert_status!(before, [switch: none_switch()], "10 baseline")
      baseline = Map.fetch!(before, :switch)

      blocker = RH.block_coordinator!()
      switch = RH.request_switch!(ctx)
      assert RH.raw_status(switch.id) == "pending", "fixture: the caller committed the request"
      during = status!()

      pause = RH.pause_stage!(:drained)
      RH.release_coordinator!(blocker)
      assert_receive {:stage_paused, :drained, worker}, 20_000
      :telemetry.detach(pause)
      published = status!()
      send(worker, :continue)

      RH.await_switch!(ctx, switch.id, :completed)
      RH.await_status!(&(&1.hold == :released and &1.profile_id == @sonnet), 20_000)
      RH.drain!()
      settled = status!()

      assert_status!(
        during,
        [ledger_observation: :valid, switch: baseline, effective: ClaudeCLI],
        "10 committed, not yet published: the older confirmed none"
      )

      assert_status!(
        published,
        [switch: open_switch(switch, :pending, nil), hold: :held, refusal: :provider_held],
        "10 published: the open pending switch"
      )

      assert_status!(
        settled,
        released_row(@sonnet, confirmed(@sonnet, :setting)) ++ [switch: other_than(baseline)],
        "10 settled: a newer confirmed none"
      )

      assert_no_status_effects!()
    end

    test "an uncertain finalization shows :unknown until it is settled", ctx do
      {:ok, gate} = Agent.start_link(fn -> :unavailable end)
      tree!(faults: [lose_reply: [:complete], reconcile: fn -> Agent.get(gate, & &1) end])
      RH.await_status!(&(&1.hold == :released))
      switch = RH.request_switch!(ctx)
      RH.await_switch!(ctx, switch.id, :completed)
      RH.await_status!(&(&1.hold == :held and is_nil(&1.switch_id)), 20_000)
      RH.drain!()
      uncertain = status!()

      Agent.update(gate, fn _ -> :read end)
      RH.await_status!(&(&1.hold == :released), 20_000)
      RH.drain!()
      settled = status!()

      assert_status!(
        uncertain,
        [
          ledger_observation: :valid,
          runtime_observation: :consistent,
          desired_profile: :unknown,
          switch: :unknown,
          hold: :held,
          effective_profile: nil,
          effective: nil,
          refusal: :provider_held
        ],
        "10 uncertain finalization"
      )

      assert_status!(settled, released_row(@sonnet, confirmed(@sonnet, :setting)), "10 settled")
      assert_no_status_effects!()
    end

    test "a failed read shows :unknown, with eligibility still following the consistent runtime",
         ctx do
      released_tree!()
      before = status!()
      assert_status!(before, [desired_profile: confirmed(@opus, :default)], "10 baseline")
      log = RH.query_log!(&RH.coordinator_query/1)
      blocker = RH.block_coordinator!()
      RH.request_switch!(ctx)
      break_table!("model_profile_switches")
      RH.release_coordinator!(blocker)
      await_failed_read!(log, "model_profile_switches")
      RH.drain!()
      failed = status!()
      restore_table!("model_profile_switches")

      assert_status!(
        failed,
        [
          ledger_observation: :valid,
          runtime_observation: :consistent,
          desired_profile: Map.fetch!(before, :desired_profile),
          switch: :unknown,
          observed_profile: @opus,
          hold: :released,
          effective_profile: @opus,
          effective: ClaudeCLI,
          refusal: nil
        ],
        "10 a failed switch read (interpretation 3: not evidence no switch is pending)"
      )

      assert_no_status_effects!()
    end
  end

  ## 11. No observation effects

  describe "11. no side effects" do
    test "a quiescent observation: no query, message, write, launch, reservation, resolve or CLI run" do
      bin = PinnedCLI.inject_identity!()
      tree!(server: [executable: bin])
      RH.await_status!(&(&1.hold == :released))
      RH.drain!()
      flush_launches()
      counts = counts!()
      row = Coordinator.status()

      {status, effects} = observe(fn -> Runtime.status() end)
      RH.drain!()

      assert_no_effects!(effects, "quiescent")
      assert counts!() == counts, "no write: events, starts, switches, settings, reservations"
      refute_received {:launch_admission, _, _, _}, "no launch"
      assert Coordinator.status() == row, "no publication or hold change"
      assert_status!(status, [ledger_observation: :valid, effective: ClaudeCLI], "11 quiescent")
    end

    test "during a switch paused at :finalizing: the same zero effects, scoped to the status call",
         ctx do
      released_tree!()
      pause = RH.pause_stage!(:finalizing)
      switch = RH.request_switch!(ctx)
      assert_receive {:stage_paused, :finalizing, coordinator}, 20_000
      flush_launches()
      counts = counts!()

      {status, effects} = observe(fn -> Runtime.status() end)
      counts_after = counts!()
      :telemetry.detach(pause)
      send(coordinator, :continue)
      RH.await_switch!(ctx, switch.id, :completed)
      RH.await_status!(&(&1.hold == :released), 20_000)
      RH.drain!()

      assert_no_effects!(effects, "mid-switch")
      assert counts_after == counts, "no write attributable to the status call"
      refute_received {:launch_admission, _, _, _}, "no launch"

      assert_status!(
        status,
        [ledger_observation: :valid, hold: :held, refusal: :provider_held],
        "11 mid-switch"
      )
    end

    test "control: the observation sees a query, a coordinator message and a resolve call (passes by design)" do
      released_tree!()
      coordinator = Process.whereis(Coordinator)
      server = Process.whereis(ClaudeCLI.server())

      {_, query} = observe(fn -> Repo.query!("SELECT 1") end)
      assert query.queries >= 1, "control: a subject query is counted"

      {_, message} = observe(fn -> send(coordinator, :c202c_probe) end)
      assert coordinator in forbidden_sends(message), "control: a coordinator message is seen"

      {_, resolve} = observe(fn -> Runtime.resolve([]) end)
      assert {Runtime, :resolve, 1} in forbidden_calls(resolve), "control: a resolve call is seen"

      {_, release} = observe(fn -> ClaudeCLI.release_hold(server, make_ref()) end)
      assert server in forbidden_sends(release), "control: a server message is seen"
      assert {ClaudeCLI, :release_hold, 2} in forbidden_calls(release)
      RH.drain!()
    end
  end

  ## 12. No default on unknown

  test "12. no bound server and an unknown desired profile: profile_id and the model fields are nil" do
    log = RH.query_log!(&RH.coordinator_query/1)
    break_table!("model_profile_settings")
    tree!()
    await_failed_read!(log, "model_profile_settings")
    unknown = status!()
    restore_table!("model_profile_settings")
    RH.await_status!(&(&1.hold == :released), 20_000)
    RH.drain!()

    assert_status!(
      unknown,
      [
        ledger_observation: :valid,
        runtime_observation: :consistent,
        desired_profile: :unknown,
        switch: none_switch(),
        observed_profile: :none,
        effective_profile: nil,
        effective: nil,
        refusal: :provider_not_running,
        profile_id: nil,
        model_alias: nil,
        model_id: nil,
        reviewed_version: nil
      ],
      "12 (never the registry default)"
    )

    assert_status!(status!(), released_row(@opus, confirmed(@opus, :default)), "12 recovered")
    assert_no_status_effects!()
  end

  ## 13. desired_profile/0

  describe "13. desired_profile/0" do
    test "the Fake is :not_applicable, even with a stored Sonnet setting", ctx do
      sonnet!(ctx)
      assert {:ok, %{desired_profile_id: @sonnet}} = Agents.get_profile_setting(actor: ctx.admin)
      select_fake!()

      assert RH.bounded(fn -> Runtime.desired_profile() end, 5_000) == :not_applicable,
             "C2-02c 13: the Fake has no real profile configured; never the stored setting"
    end

    test "a valid, confirmed observation is {:ok, the coordinator's confirmed desired profile}",
         ctx do
      sonnet!(ctx)
      result = RH.bounded(fn -> Runtime.desired_profile() end, 5_000)

      assert match?(
               {:ok, %{profile_id: @sonnet, source: :setting, confirmed_at: %DateTime{}}},
               result
             ),
             "C2-02c 13: got #{inspect(result)}"

      assert result == {:ok, Map.get(Coordinator.status(), :desired)},
             "C2-02c 13: the coordinator's last confirmed observation, not a fresh read"
    end

    test "otherwise {:error, :unknown}: no coordinator, a failed setting read, an invalid row" do
      desired = fn -> RH.bounded(fn -> Runtime.desired_profile() end, 5_000) end
      assert desired.() == {:error, :unknown}, "no coordinator"

      log = RH.query_log!(&RH.coordinator_query/1)
      break_table!("model_profile_settings")
      tree!()
      await_failed_read!(log, "model_profile_settings")
      unreadable = desired.()
      restore_table!("model_profile_settings")
      RH.await_status!(&(&1.hold == :released), 20_000)
      RH.drain!()
      assert unreadable == {:error, :unknown}, "a failed setting read is never the default"

      rows = :ets.tab2list(Coordinator)
      stop_tree!()
      forger = forge_coordinator_table!(rows, true)
      assert desired.() == {:error, :unknown}, "an invalid (stale) coordinator row"
      stop_forger!(forger)
    end
  end

  ## 14. Sanitized

  test "14. neither Coordinator.status/0 nor Runtime.status/0 returns a pid, a ref or the private binding",
       ctx do
    released_tree!()
    check_sanitized!(ctx, "released")

    pause = RH.pause_stage!(:drained)
    RH.request_switch!(ctx)
    assert_receive {:stage_paused, :drained, worker}, 20_000
    :telemetry.detach(pause)
    check_sanitized!(ctx, "mid-switch")
    send(worker, :continue)
    RH.await_status!(&(&1.hold == :released and &1.profile_id == @sonnet), 20_000)
    RH.drain!()
    check_sanitized!(ctx, "after the switch")
  end

  ## 15. The regression budget

  test "15. status returns within 50 ms, with the last confirmed observation, while the coordinator waits in a ledger call",
       ctx do
    released_tree!()
    before = status!()
    RH.query_pause!(:c202c_ledger, &RH.coordinator_query/1)
    RH.request_switch!(ctx)
    assert_receive {:c202c_ledger, coordinator}, 10_000

    started = System.monotonic_time(:microsecond)
    status = RH.bounded(fn -> Runtime.status() end, 5_000)
    elapsed = System.monotonic_time(:microsecond) - started
    RH.resume(coordinator, :c202c_ledger)
    RH.await_status!(&(&1.hold == :released and &1.profile_id == @sonnet), 20_000)
    RH.drain!()

    assert elapsed < 50_000,
           "C2-02c 15: status took #{div(elapsed, 1000)} ms while the coordinator waited"

    assert_status!(
      status,
      [
        ledger_observation: :valid,
        switch: Map.get(before, :switch, :__missing__),
        published_at: Map.get(before, :published_at, :__missing__),
        published_at: timestamp()
      ],
      "15 the last confirmed observation, not a timeout sentinel"
    )
  end

  ## Fixtures and helpers

  defp released_tree!(opts \\ []) do
    tree!(opts)
    RH.await_status!(&(&1.hold == :released))
    RH.drain!()
    Coordinator.status()
  end

  defp sonnet!(ctx, opts \\ []) do
    released_tree!(opts)
    switch = RH.request_switch!(ctx)
    RH.await_switch!(ctx, switch.id, :completed)
    RH.await_status!(&(&1.hold == :released and &1.profile_id == @sonnet), 20_000)
    RH.drain!()
  end

  # The coordinator replaces a killed server (held, preflighted, released)
  # at the same profile; its table is recreated under the same name.
  defp replace_server!(old, generation) do
    track_pids!([old])
    RH.kill!(old)
    RH.await_status!(&(&1.hold == :released and &1.generation == generation + 1), 20_000)
    RH.drain!()
    new = Process.whereis(ClaudeCLI.server())

    assert is_pid(new) and new != old and ClaudeCLI.profile(new) == @opus,
           "fixture: a replacement"

    new
  end

  # A test-side hold change (no coordinator involvement).
  defp toggle_hold!(server, ref, attempt) when rem(attempt, 2) == 1,
    do: assert(ClaudeCLI.hold(server, ref) == {:held, ref})

  defp toggle_hold!(server, ref, _attempt), do: assert(ClaudeCLI.release_hold(server, ref) == :ok)

  # An unidentified fake launch (no model) leaves admission blocked while
  # the hold is released.
  defp block_admission! do
    assert {:unknown, _} = ClaudeCLI.complete(RH.request_map(), [])
    assert %{admission: :blocked} = ClaudeCLI.admission()
    RH.drain!()
  end

  defp failed_start?(ctx) do
    boot = Coordinator.status().boot_id

    Enum.any?(
      RH.starts!(ctx),
      &(&1.boot_id == boot and &1.status == :failed and &1.reason == :boot)
    )
  end

  defp resume(pid) do
    :erlang.resume_process(pid)
  rescue
    ArgumentError -> :ok
  end

  defp flush_launches do
    receive do
      {:launch_admission, _, _, _} -> flush_launches()
    after
      0 -> :ok
    end
  end

  defp check_sanitized!(ctx, label) do
    public = Coordinator.status()
    status = status!()
    latest = RH.latest_start!(ctx)

    for key <- [:desired, :switch, :published_at] do
      assert Map.has_key?(public, key),
             "C2-02c 14 (#{label}): Coordinator.status/0 lacks its public #{key}: #{inspect(public)}"
    end

    for {name, term} <- [{"Coordinator.status/0", public}, {"Runtime.status/0", status}] do
      refute raw?(term),
             "C2-02c 14 (#{label}): #{name} holds a pid, ref, port or fun: #{inspect(term)}"

      refute inspect(term) =~ latest.id, "C2-02c 14 (#{label}): #{name} exposes the start id"

      refute inspect(term) =~ inspect(Process.whereis(Coordinator)),
             "C2-02c 14 (#{label}): #{name} exposes the coordinator pid"
    end

    assert_no_status_effects!()
  end
end
