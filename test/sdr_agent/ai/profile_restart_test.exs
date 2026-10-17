defmodule SdrAgent.AI.ProfileRestartTest do
  @moduledoc """
  C2-02c RED, restart (`docs/product/r0/c2-02c-interface.md` draft 3,
  interface and entity PASS at `401df6f`; section 1 and section 4 tests
  1–7; binding interpretations 1, 2 and 6).

  The three restart forms are separate (`SdrAgent.Test.StatusHarness`):
  **A** a coordinator-only restart (`:rest_for_one`), **B** a profile-tree
  stop and start with any retained lease untouched, and **C** B plus a
  **simulated** loss of VM-local state: only after every fixture-owned
  server, reaper, worker and supervisor is stopped and joined, and only for
  this test's own lease. C is not a BEAM restart and not evidence of OS
  cleanup (OQ-2).

  Each test first pins the restart behaviour b2α and b2β already have (the
  ledger, the hold, the server, the lease), then asserts the c status
  observation of that outcome (section 2): the RED failure is the status
  contract, except where noted. Test 5 needs b2β's resolver and fails at its
  presence guard until b2β lands. Tests 3B and 3A' (a pending switch behind
  a retained dead lease) pin section 0's "every pending switch at a
  coordinator start stays blocked": b2α's boot does not block a pending
  switch when its first start fails the preflight, so they fail at that pin.

  Shared SQL sandbox; the fake CLI under the test launcher; zero model calls.
  """
  use SdrAgent.AuditCase, async: false

  import SdrAgent.Test.StatusHarness

  alias SdrAgent.Agents
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper
  alias SdrAgent.AI.ModelProvider.Coordinator
  alias SdrAgent.AI.ModelProvider.Runtime
  alias SdrAgent.Test.ResolveHarness, as: RH

  @moduletag :c2_02c
  @moduletag timeout: 180_000

  @opus :claude_cli_opus
  @sonnet :claude_cli_sonnet
  @history [
    :id,
    :from_profile_id,
    :to_profile_id,
    :server_generation,
    :requested_at,
    :inserted_at
  ]

  setup do
    tenant = bootstrap!()
    RH.lease_cleanup!()
    select_claude_cli!()
    %{tenant: tenant, admin: human(:admin, tenant)}
  end

  ## 1. The current setting (Sonnet), no open switch

  for form <- [:A, :B, :C] do
    test "1#{form}. setting Sonnet with no open switch: the restart ends released at Sonnet",
         ctx do
      form = unquote(form)
      switch = sonnet!(ctx)
      boot = Coordinator.status().boot_id
      history = switches(ctx)

      restart!(form, fn -> tree!() end)
      released = await_boot!(boot, &(&1.hold == :released))
      RH.drain!()
      latest = RH.latest_start!(ctx)
      server = Process.whereis(ClaudeCLI.server())

      assert {latest.profile_id, latest.status, latest.boot_id} ==
               {@sonnet, :ready, released.boot_id}

      assert ClaudeCLI.profile(server) == @sonnet

      assert_restart_evidence!(form, latest)

      assert switches(ctx) == history, "terminal history unchanged"
      assert RH.switch!(ctx, switch.id).status == :completed

      status = status_now!()
      assert_status!(status, released_row(@sonnet, confirmed(@sonnet, :setting)), "1#{form}")
      assert_ledger_is_row!(status, "1#{form}")
    end
  end

  ## 2. Setting absent; setting read fails

  test "2. setting absent: the default at a cold start and after a coordinator restart; no setting is created",
       ctx do
    tree!()
    cold = RH.await_status!(&(&1.hold == :released))
    RH.drain!()
    assert {:ok, nil} = Agents.get_profile_setting(actor: ctx.admin)
    assert RH.latest_start!(ctx).profile_id == @opus
    cold_status = status_now!()

    kill_coordinator!()
    await_boot!(cold.boot_id, &(&1.hold == :released))
    RH.drain!()
    assert RH.latest_start!(ctx).ready_evidence == :adopted

    assert {:ok, nil} = Agents.get_profile_setting(actor: ctx.admin),
           "status never initializes it"

    restarted = status_now!()

    for {label, status} <- [{"2 cold", cold_status}, {"2A", restarted}] do
      assert_status!(status, released_row(@opus, confirmed(@opus, :default)), label)
    end

    assert_ledger_is_row!(restarted, "2A")
  end

  test "2A. setting read fails at a coordinator restart: no start, held, retried, never the default; recovered",
       ctx do
    sonnet!(ctx)
    %{boot_id: boot} = Coordinator.status()
    starts = RH.starts!(ctx)
    server = Process.whereis(ClaudeCLI.server())
    log = RH.query_log!(&RH.coordinator_query/1)

    break_table!("model_profile_settings")
    kill_coordinator!()
    await_boot!(boot, &(&1.hold == :held))
    await_failed_read!(log, "model_profile_settings")
    # At least one more boot attempt (retried every second), still failing.
    RH.await!(fn -> failed_reads(log, "model_profile_settings") >= 2 end, 5_000, "never retried")
    failing = status_now!()

    assert RH.starts!(ctx) == starts, "no start while the setting is unreadable"
    assert Process.whereis(ClaudeCLI.server()) == server and ClaudeCLI.held?(server)
    assert Runtime.resolve(provider: ClaudeCLI) == {:error, :provider_held}

    restore_table!("model_profile_settings")
    recovered = await_boot!(boot, &(&1.hold == :released))
    RH.drain!()
    assert %{profile_id: @sonnet, ready_evidence: :adopted} = RH.latest_start!(ctx)
    assert recovered.profile_id == @sonnet

    assert_status!(
      failing,
      [
        ledger_observation: :valid,
        runtime_observation: :consistent,
        desired_profile: :unknown,
        switch: none_switch(),
        observed_profile: @sonnet,
        hold: :held,
        effective_profile: nil,
        effective: nil,
        refusal: :provider_held,
        profile_id: @sonnet,
        model_alias: "sonnet"
      ],
      "2A unreadable setting (never the default)"
    )

    assert_status!(
      status_now!(),
      released_row(@sonnet, confirmed(@sonnet, :setting)),
      "2A recovered"
    )
  end

  test "2C. setting read fails after a simulated VM-local loss: no start, no server, never the default; recovered",
       ctx do
    sonnet!(ctx)
    starts = RH.starts!(ctx)
    owned = stop_tree!()
    simulate_vm_local_loss!(owned)
    log = RH.query_log!(&RH.coordinator_query/1)

    break_table!("model_profile_settings")
    tree!()
    await_failed_read!(log, "model_profile_settings")
    RH.await!(fn -> failed_reads(log, "model_profile_settings") >= 2 end, 5_000, "never retried")
    failing = status_now!()

    assert RH.starts!(ctx) == starts, "no start while the setting is unreadable"
    assert Process.whereis(ClaudeCLI.server()) == nil
    assert Runtime.resolve(provider: ClaudeCLI) == {:error, :provider_not_running}

    restore_table!("model_profile_settings")
    RH.await_status!(&(&1.hold == :released), 20_000)
    RH.drain!()

    assert %{profile_id: @sonnet, reason: :boot, ready_evidence: :spawn_preflight} =
             RH.latest_start!(ctx)

    assert_status!(
      failing,
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
      "2C unreadable setting, no server (never the default)"
    )

    assert_status!(
      status_now!(),
      released_row(@sonnet, confirmed(@sonnet, :setting)),
      "2C recovered"
    )
  end

  ## 3. A pending switch at a start → blocked (coordinator_restarted)

  test "3A. a pending switch at a coordinator restart (live survivor) is blocked and held; history unchanged",
       ctx do
    {switch, boot, _worker} = pending_drained!(ctx)
    requested = RH.switch!(ctx, switch.id)

    kill_coordinator!()
    blocked = await_blocked!(ctx, switch, "3A")
    await_boot!(boot, &(&1.hold == :held))
    RH.drain!()

    assert_pending_blocked!(ctx, requested, blocked)

    assert_status!(
      status_now!(),
      held_row(
        @opus,
        confirmed(@opus, :setting),
        open_switch(switch, :blocked, "coordinator_restarted")
      ),
      "3A"
    )
  end

  for form <- [:A, :B] do
    test "3#{form}'. a pending switch behind a retained dead lease (form #{form}) is blocked and held",
         ctx do
      {switch, dead} = pending_dead_lease!(ctx)
      requested = RH.switch!(ctx, switch.id)
      boot = Coordinator.status().boot_id

      restart!(unquote(form), fn -> RH.tree!() end, [dead])
      await_boot!(boot, &(&1.hold == :held))
      assert Reaper.lease(ClaudeCLI.server()) == {:held, dead}, "the retained lease is untouched"

      # Section 0: every pending switch at a coordinator start stays blocked.
      blocked = await_blocked!(ctx, switch, "3#{unquote(form)}' (retained dead lease)")
      RH.drain!()
      assert_pending_blocked!(ctx, requested, blocked)

      # Codex 5503795b: b2β's dead-lease boot allocates only its fence and
      # starts no server, so nothing is observed (the desired profile stays
      # Opus); every blocked, provenance, hold and lease assertion is kept.
      assert_status!(
        status_now!(),
        Keyword.merge(
          held_row(
            @opus,
            confirmed(@opus, :setting),
            open_switch(switch, :blocked, "coordinator_restarted")
          ),
          observed_profile: :none,
          refusal: :provider_not_running
        ),
        "3#{unquote(form)}'"
      )
    end
  end

  test "3C. a pending switch after a simulated VM-local loss is blocked: the lost lease proves nothing",
       ctx do
    {switch, dead} = pending_dead_lease!(ctx)
    requested = RH.switch!(ctx, switch.id)
    boot = Coordinator.status().boot_id

    restart!(:C, fn -> RH.tree!() end, [dead])
    blocked = await_blocked!(ctx, switch, "3C")
    await_boot!(boot, &(&1.hold == :held))
    RH.drain!()

    assert Reaper.lease(ClaudeCLI.server()) != nil, "a fresh start's own lease"
    assert_pending_blocked!(ctx, requested, blocked)

    assert_status!(
      status_now!(),
      held_row(
        @opus,
        confirmed(@opus, :setting),
        open_switch(switch, :blocked, "coordinator_restarted")
      ),
      "3C"
    )
  end

  ## 4. A blocked switch stays blocked and held

  test "4A. a blocked switch with its survivor stays blocked and held at a coordinator restart",
       ctx do
    blocked = RH.survivor!(ctx)
    boot = Coordinator.status().boot_id

    kill_coordinator!()
    await_boot!(boot, &(&1.hold == :held))
    RH.drain!()
    Process.sleep(300)

    assert_still_blocked!(ctx, blocked, :provider_held)

    assert_status!(
      status_now!(),
      held_row(
        @opus,
        confirmed(@opus, :setting),
        open_switch(blocked, :blocked, "coordinator_restarted")
      ),
      "4A"
    )
  end

  for form <- [:B, :C] do
    test "4#{form}. a blocked switch behind a dead lease stays blocked and held (form #{form})",
         ctx do
      form = unquote(form)
      blocked = RH.dead_holder!(ctx)
      {:held, dead} = Reaper.lease(ClaudeCLI.server())
      boot = Coordinator.status().boot_id

      restart!(form, fn -> RH.tree!() end, [dead])
      await_boot!(boot, &(&1.hold == :held))
      RH.drain!()
      Process.sleep(300)

      assert_lease_after!(form, dead)

      assert_still_blocked!(ctx, blocked, blocked_refusal(form))

      assert_status!(
        status_now!(),
        Keyword.merge(
          held_row(
            @opus,
            confirmed(@opus, :setting),
            open_switch(blocked, :blocked, "old_cleanup_unconfirmed")
          ),
          blocked_runtime(form)
        ),
        "4#{form}"
      )
    end
  end

  ## 5. Resolved (b2β) with a dead lease

  for form <- [:A, :B] do
    test "5#{form}. resolved with a dead lease (form #{form}): held at :cleanup_unprovable, no release",
         ctx do
      {blocked, dead, tracer} = resolved_dead_lease!(ctx)
      resolved = RH.switch!(ctx, blocked.id)
      prior = RH.starts!(ctx)
      boot = Coordinator.status().boot_id

      restart!(unquote(form), fn -> RH.tree!() end, [dead])

      %{boot_id: new_boot} =
        await_boot!(boot, &(&1.stage == :cleanup_unprovable and &1.hold == :held), 10_000)

      RH.drain!()
      conflicted = RH.starts!(ctx)
      Process.sleep(1_000)
      RH.drain!()

      # The new boot's own fencing allocation is an intent only (b2α 1a, 2):
      # permitted and required; no launch, readiness or release over the lease.
      assert_conflicted_boot!(prior, conflicted, RH.starts!(ctx), new_boot)
      assert Process.whereis(ClaudeCLI.server()) == nil, "no failed live child behind it"
      assert server_children() == [], "no server launched over the retained dead lease"
      assert %{hold: :held, stage: :cleanup_unprovable} = Coordinator.status(), "never released"
      assert Reaper.lease(ClaudeCLI.server()) == {:held, dead}, "the dead lease is unchanged"
      assert RH.release_callers(tracer) == [], "nothing calls Reaper.release/1"

      assert RH.switch!(ctx, blocked.id) == resolved,
             "the resolved switch's provenance is unchanged"

      assert_status!(
        status_now!(),
        [
          ledger_observation: :valid,
          runtime_observation: :consistent,
          desired_profile: confirmed(@opus, :setting),
          switch: none_switch(),
          observed_profile: :none,
          hold: :held,
          stage: :cleanup_unprovable,
          effective_profile: nil,
          effective: nil,
          refusal: :provider_not_running,
          published_at: timestamp()
        ],
        "5#{unquote(form)}"
      )
    end
  end

  test "5C. resolved with a dead lease, then a simulated VM-local loss: a fresh start, preflight, then the release",
       ctx do
    {blocked, dead, tracer} = resolved_dead_lease!(ctx)
    latest = RH.latest_start!(ctx)
    boot = Coordinator.status().boot_id

    restart!(:C, fn -> RH.tree!() end, [dead])
    released = await_boot!(boot, &(&1.hold == :released))
    RH.drain!()
    fresh = RH.latest_start!(ctx)

    assert fresh.generation > latest.generation and fresh.status == :ready and
             fresh.ready_evidence == :spawn_preflight and fresh.boot_id == released.boot_id and
             fresh.profile_id == current_profile(ctx),
           "a fresh allocation at the current setting, preflighted"

    assert RH.release_callers(tracer) == [], "the simulated loss is not a Reaper.release/1 call"
    assert RH.switch!(ctx, blocked.id).status == :failed

    assert_status!(status_now!(), released_row(@opus, confirmed(@opus, :setting)), "5C")
  end

  ## 6. The current setting, not the switch history

  test "6. after Opus → Sonnet → Opus, B and then A start the current setting (Opus); history unchanged",
       ctx do
    tree!()
    RH.await_status!(&(&1.hold == :released))
    complete_switch!(ctx, @sonnet)
    complete_switch!(ctx, @opus)
    history = switches(ctx)
    assert Enum.map(history, & &1.status) == [:completed, :completed]
    boot = Coordinator.status().boot_id

    restart!(:B, fn -> tree!() end)
    b = await_boot!(boot, &(&1.hold == :released))
    RH.drain!()

    assert %{profile_id: @opus, reason: :boot, ready_evidence: :spawn_preflight} =
             RH.latest_start!(ctx)

    assert switches(ctx) == history
    after_b = status_now!()

    kill_coordinator!()
    await_boot!(b.boot_id, &(&1.hold == :released))
    RH.drain!()
    assert %{profile_id: @opus, ready_evidence: :adopted} = RH.latest_start!(ctx)
    assert switches(ctx) == history

    after_a = status_now!()

    for {label, status} <- [{"6B", after_b}, {"6A", after_a}] do
      assert_status!(status, released_row(@opus, confirmed(@opus, :setting)), label)
    end

    assert_ledger_is_row!(after_a, "6A")
  end

  ## 7. Old-boot replies

  test "7. replies and DOWNs from an old boot's server or worker cannot reopen the new hold",
       ctx do
    {switch, boot, worker} = pending_drained!(ctx)
    server = Process.whereis(ClaudeCLI.server())

    kill_coordinator!()
    blocked = await_blocked!(ctx, switch, "7")
    await_boot!(boot, &(&1.hold == :held))
    RH.drain!()
    starts = RH.starts!(ctx)
    refute Process.alive?(worker), "the old boot's worker went with its OperationSupervisor"
    current = Process.whereis(Coordinator)

    # The old boot's late messages (its worker's results, its monitors'
    # DOWNs, its reaper receipt, its hold replies), forged with old refs.
    for message <- [
          {:op, make_ref(), {:drained, {:ok, %{}}}},
          {:op, make_ref(), {:preflighted, :ok}},
          {:DOWN, make_ref(), :process, worker, :normal},
          {:DOWN, make_ref(), :process, server, :normal},
          {:reaper_cleanup_confirmed, make_ref(), %{name: ClaudeCLI.server(), tracked: 0}},
          {make_ref(), {:held, make_ref()}},
          {make_ref(), :ok},
          {:reconcile, :boot},
          {:reconcile, {:switch, switch.id, :completed}},
          :replace
        ],
        do: send(current, message)

    RH.drain!()
    Process.sleep(500)
    RH.drain!()

    assert Process.whereis(Coordinator) == current
    assert %{hold: :held} = Coordinator.status()
    RH.assert_held_refusals!("after the old boot's messages")
    assert RH.switch!(ctx, switch.id) == blocked
    assert RH.starts!(ctx) == starts

    assert_status!(
      status_now!(),
      held_row(
        @opus,
        confirmed(@opus, :setting),
        open_switch(switch, :blocked, "coordinator_restarted")
      ),
      "7"
    )
  end

  ## Fixtures and helpers

  # A completed Opus → Sonnet switch, released at Sonnet, coordinator idle.
  defp sonnet!(ctx) do
    tree!()
    RH.await_status!(&(&1.hold == :released))
    complete_switch!(ctx, @sonnet)
  end

  defp complete_switch!(ctx, to) do
    switch = RH.request_switch!(ctx)
    assert switch.to_profile_id == to
    RH.await_switch!(ctx, switch.id, :completed)
    RH.await_status!(&(&1.hold == :released and &1.profile_id == to), 20_000)
    RH.drain!()
    RH.switch!(ctx, switch.id)
  end

  # A pending switch whose worker is paused after its drain (the server
  # survives, held for the switch). Returns the switch, the boot and the
  # paused worker.
  defp pending_drained!(ctx) do
    tree!()
    %{boot_id: boot} = RH.await_status!(&(&1.hold == :released))
    pause = RH.pause_stage!(:drained)
    switch = RH.request_switch!(ctx)
    assert_receive {:stage_paused, :drained, worker}, 20_000
    :telemetry.detach(pause)
    {switch, boot, worker}
  end

  # A pending switch paused at :old_stopping whose old server and reaper
  # were suspended, then killed (no receipt): the lease is held by the dead
  # reaper, no named server is left, and the coordinator is still paused.
  defp pending_dead_lease!(ctx) do
    tree!()
    RH.await_status!(&(&1.hold == :released))
    pause = RH.pause_stage!(:old_stopping)
    switch = RH.request_switch!(ctx)
    assert_receive {:stage_paused, :old_stopping, _coordinator}, 20_000
    :telemetry.detach(pause)

    server = Process.whereis(ClaudeCLI.server())
    reaper = ClaudeCLI.reaper(server)
    true = :erlang.suspend_process(server)
    true = :erlang.suspend_process(reaper)
    RH.kill!(server)
    RH.kill!(reaper)
    assert Reaper.lease(ClaudeCLI.server()) == {:held, reaper}, "fixture: a dead holder"
    assert RH.switch!(ctx, switch.id).status == :pending
    {switch, reaper}
  end

  # A dead-holder blocked switch, resolved (b2β) to :failed: the coordinator
  # holds at :cleanup_unprovable. Fails at b2β's presence guard until it lands.
  defp resolved_dead_lease!(ctx) do
    blocked = RH.dead_holder!(ctx)
    latest = RH.latest_start!(ctx)
    {:held, dead} = Reaper.lease(ClaudeCLI.server())
    tracer = RH.trace_release!()

    result = RH.resolve(blocked, RH.attestation(blocked, latest, :dead_holder), ctx.admin)

    assert match?({:ok, %{switch: %{status: :failed}}}, result),
           "C2-02b2β: the :dead_holder resolution; got #{inspect(result)}"

    RH.await_status!(&(&1.stage == :cleanup_unprovable and &1.hold == :held), 10_000)
    RH.drain!()
    {blocked, dead, tracer}
  end

  defp await_blocked!(ctx, switch, label) do
    RH.await!(
      fn -> RH.switch!(ctx, switch.id).status == :blocked end,
      10_000,
      fn ->
        "C2-02c #{label}: a pending switch at a coordinator start must be blocked " <>
          "(coordinator_restarted); still #{inspect(RH.switch!(ctx, switch.id).status)}"
      end
    )

    RH.switch!(ctx, switch.id)
  end

  # Blocked for the restart; the request history is unchanged; never
  # completed, continued (no candidate) or failed; the server held.
  defp assert_pending_blocked!(ctx, requested, blocked) do
    assert blocked.failure_reason =~ "coordinator_restarted"

    assert Map.take(blocked, @history) == Map.take(requested, @history),
           "request history unchanged"

    assert [%{id: id}] = switches(ctx)
    assert id == requested.id

    refute Enum.any?(
             RH.starts!(ctx),
             &(&1.switch_id == requested.id and &1.reason == :activation)
           ),
           "never continued: no candidate start"

    Process.sleep(500)
    assert RH.switch!(ctx, requested.id) == blocked, "never completed, continued or failed"
    assert %{hold: :held} = Coordinator.status()

    assert Runtime.resolve(provider: ClaudeCLI) in [
             {:error, :provider_held},
             {:error, :provider_not_running}
           ]
  end

  defp assert_still_blocked!(ctx, blocked, refusal) do
    assert RH.switch!(ctx, blocked.id) == blocked, "still blocked, unchanged"
    assert %{hold: :held} = Coordinator.status()
    assert Runtime.resolve(provider: ClaudeCLI) == {:error, refusal}
  end

  # Codex 5503795b, per form (runtime clauses): B keeps the dead lease, so
  # b2β's boot allocates only its fence and no server runs (nothing
  # observed, not running); C lost the lease with the simulated VM, so a
  # fresh server runs, held (observed Opus, held).
  defp blocked_refusal(:B), do: :provider_not_running
  defp blocked_refusal(:C), do: :provider_held

  defp blocked_runtime(:B), do: [observed_profile: :none, refusal: :provider_not_running]
  defp blocked_runtime(:C), do: [observed_profile: @opus, refusal: :provider_held]

  # Form-specific restart evidence (runtime clauses, so each generated test
  # keeps its assertion without an unreachable branch).
  defp assert_restart_evidence!(:A, latest),
    do: assert(latest.ready_evidence == :adopted, "A adopts the survivor")

  defp assert_restart_evidence!(:B, latest),
    do: assert(latest.ready_evidence in [:adopted, :spawn_preflight], "B adopts or starts fresh")

  defp assert_restart_evidence!(:C, latest),
    do:
      assert(
        {latest.reason, latest.ready_evidence} == {:boot, :spawn_preflight},
        "C starts fresh"
      )

  defp assert_lease_after!(:B, dead),
    do: assert(Reaper.lease(ClaudeCLI.server()) == {:held, dead}, "B retains the lease")

  defp assert_lease_after!(:C, dead),
    do: refute(Reaper.lease(ClaudeCLI.server()) == {:held, dead}, "C lost it with the VM")

  # Prior starts are immutable; the new boot allocated its own fencing
  # start(s) above every earlier generation, each only allocated or failed
  # with no recorded server identity (never started or ready); its latest
  # start is the current one; nothing more is allocated while conflicted.
  defp assert_conflicted_boot!(prior, conflicted, later, new_boot) do
    assert Enum.take(conflicted, length(prior)) == prior, "prior start history unchanged"
    assert Enum.take(later, length(prior)) == prior, "prior start history unchanged (later)"
    fresh = Enum.drop(conflicted, length(prior))
    top = prior |> Enum.map(& &1.generation) |> Enum.max(fn -> 0 end)

    assert fresh != [], "the new boot allocates its own fencing start (b2α section 2, step 3)"

    for start <- fresh do
      assert start.boot_id == new_boot and start.generation > top,
             "a fenced allocation of the new boot: #{inspect(Map.take(start, [:boot_id, :generation]))}"

      assert start.status in [:allocated, :failed] and is_nil(start.pid),
             "an intent only, never a launched server: #{inspect(Map.take(start, [:status, :pid]))}"
    end

    assert List.last(later).boot_id == new_boot, "the new boot's start is the latest"
    assert later == conflicted, "no repeated allocation or spawning while conflicted"
  end

  defp server_children do
    SdrAgent.AI.ModelProvider.ServerSupervisor
    |> DynamicSupervisor.which_children()
  catch
    :exit, _ -> []
  end

  defp switches(ctx) do
    {:ok, switches} = Agents.list_profile_switches(actor: ctx.admin)
    Enum.sort_by(switches, &{&1.requested_at, &1.id})
  end

  defp current_profile(ctx) do
    case Agents.get_profile_setting(actor: ctx.admin) do
      {:ok, %{desired_profile_id: profile}} -> profile
      {:ok, nil} -> @opus
    end
  end
end
