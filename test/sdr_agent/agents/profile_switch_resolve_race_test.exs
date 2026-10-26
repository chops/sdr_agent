defmodule SdrAgent.Agents.ProfileSwitchResolveRaceTest do
  @moduledoc """
  C2-02b2β RED (`docs/product/r0/c2-02b2b-interface.md` draft 4, interface
  and entity PASS at `e60943c`; revised for Codex 8a5eb73 MF1–MF4), section
  8 on independent connections: tests 3 (an admin changed between dispatch
  and the locks), 8, 9, 10 (a stored-state fault-injection probe), 12, 13,
  14, 17 (a request expired in a blocked mailbox, a lock wait and a pool
  wait crossing the deadline), 18 (a restart while conflicted), 19 (a death
  during the lock wait), 20 (kills after and before the commit) and 21.

  The whole tree needs independent connections, so this module runs the SQL
  sandbox in `:auto` mode for its own duration (synchronous; restored to
  `:manual` afterwards) and truncates only a test database before and after
  each test; leases, paused processes, holders, blocked coordinators and
  tracing are all cleaned up on exit by `SdrAgent.Test.ResolveHarness`.

  **Settlement (test 12)** is proven against an independent, uncommitted
  "original": a privileged test transaction on its own connection (no
  LedgerCall watchdog, so it really stays open) that takes the write's locks
  in the write's order and writes the resolution row. With the coordinator
  blocked in its mailbox, the caller's call times out and its barrier is
  shown waiting on that exact writer (`pg_locks`, `pg_blocking_pids`) before
  the original commits or rolls back. Short pauses inside the coordinator's
  own LedgerCall (tests 20, 21) stay below its budget plus 250 ms
  connection watchdog; test 13's pause outlives that default bound on
  purpose, under the widened client-side watchdog of its write (#230).

  Test-build-only seams chosen: the coordinator faults `lose_reply:
  [:resolve_blocked]` (b2α's `lose_reply:` key: a committed write's outcome
  is unknown to the coordinator, test 14), `resolve_budget_ms:` (a smaller
  write budget, test 13) and `client_slack_ms:` (a wider client-side
  watchdog for that write, test 13). Definite timeouts are accepted only with
  an acknowledged rollback, a refusal within the deadline, or barrier
  evidence. The fake CLI; no model call.
  """
  use ExUnit.Case, async: false

  import SdrAgent.Test.ResolveHarness

  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Accounts
  alias SdrAgent.Audit
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper
  alias SdrAgent.AI.ModelProvider.Coordinator
  alias SdrAgent.AuditCase
  alias SdrAgent.Repo

  @moduletag :c2_02b2b
  @moduletag timeout: 180_000

  @tables ~w(model_server_starts model_server_counters model_profile_switches
             model_profile_settings audit_accesses audit_events audit_chain_heads
             model_call_allocations model_call_grants failures operations model_invocations
             agent_runs agent_definitions tokens users payloads provenance_snapshots tenants)
  @switch_lock ~r/FROM "model_profile_switches".* FOR UPDATE/s

  setup do
    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      cleanup!()
      Sandbox.mode(Repo, :manual)
    end)

    cleanup!()
    lease_cleanup!()
    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    %{tenant: tenant, admin: AuditCase.new_human(:admin, tenant)}
  end

  ## 3. An admin changed between dispatch and the locks

  for change <- [:demoted, :disabled] do
    test "3. an admin #{change} while the write waits on the setting lock is refused after the locks",
         ctx do
      blocked = dead_holder!(ctx)
      resolver = AuditCase.new_human(:admin, ctx.tenant)
      attestation = attestation(blocked, latest_start!(ctx), :dead_holder)
      {holder, backend} = hold!(fn -> lock_setting!(ctx.tenant.id) end)

      caller = resolve_task(blocked, attestation, resolver)
      await_blocked_by!(backend)
      assert {:ok, _} = change!(unquote(change), resolver, ctx.admin)
      release_holder(holder)
      result = await_task(caller, 25_000)

      assert match?({:error, %Ash.Error.Forbidden{}}, result),
             "C2-02b2β: an admin #{unquote(change)} before the locks is refused after them; " <>
               "got #{inspect(result)}"

      assert raw_status(blocked.id) == "blocked"
      assert resolved_events(ctx) == []
    end
  end

  ## 8. Concurrent same-id callers (R3-2)

  test "8. two same-id callers that both missed: one event, one resolution, one exact replay",
       ctx do
    blocked = none!(ctx)
    latest = latest_start!(ctx)
    attestation = attestation(blocked, latest, :none)
    query_pause!(:read_a, caller_replay_read(:a))
    query_pause!(:read_b, caller_replay_read(:b))

    a = resolve_task(blocked, attestation, ctx.admin, init: fn -> mark_caller(:a) end)
    b = resolve_task(blocked, attestation, ctx.admin, init: fn -> mark_caller(:b) end)
    assert_receive {:read_a, read_a}, 10_000, "caller a's stored replay read was never seen"
    assert_receive {:read_b, read_b}, 10_000, "caller b's stored replay read was never seen"

    # Both callers saw nothing. a completes, and its reconciliation advances
    # the runtime start, before b is dequeued.
    resume(read_a, :read_a)
    first = await_task(a, 25_000)

    assert match?({:ok, %{switch: %{status: :failed}}}, first) and
             not Map.get(elem(first, 1), :replay, false),
           "C2-02b2β: the first caller resolves; got #{inspect(first)}"

    await_status!(&(&1.generation > latest.generation), 20_000)
    resume(read_b, :read_b)
    second = await_task(b, 25_000)

    id = blocked.id

    assert match?({:ok, %{switch: %{id: ^id}, replay: true}}, second),
           "C2-02b2β: the second caller is an exact replay, checked before the mutable " <>
             "state; got #{inspect(second)}"

    assert length(resolved_events(ctx)) == 1, "one event"
    stored = switch!(ctx, blocked.id)
    assert field(stored, :attestation_id) == attestation.attestation_id
    assert field(stored, :resolved_by_id) == ctx.admin.id
  end

  ## 9. Concurrent different ids

  test "9. two different ids at once: exactly one commits, the other is :switch_not_blocked",
       ctx do
    blocked = dead_holder!(ctx)
    latest = latest_start!(ctx)
    query_pause!(:read_a, caller_replay_read(:a))
    query_pause!(:read_b, caller_replay_read(:b))

    a =
      resolve_task(blocked, attestation(blocked, latest, :dead_holder), ctx.admin,
        init: fn -> mark_caller(:a) end
      )

    b =
      resolve_task(blocked, attestation(blocked, latest, :dead_holder), ctx.admin,
        init: fn -> mark_caller(:b) end
      )

    assert_receive {:read_a, read_a}, 10_000, "caller a's stored replay read was never seen"
    assert_receive {:read_b, read_b}, 10_000, "caller b's stored replay read was never seen"
    resume(read_a, :read_a)
    resume(read_b, :read_b)
    results = [await_task(a, 25_000), await_task(b, 25_000)]

    assert Enum.count(results, &match?({:ok, %{switch: %{status: :failed}}}, &1)) == 1 and
             Enum.count(results, &(&1 == {:error, :switch_not_blocked})) == 1,
           "C2-02b2β: exactly one commit, one :switch_not_blocked; got #{inspect(results)}"

    assert length(resolved_events(ctx)) == 1
  end

  ## 10. A stored-state fault-injection probe (Codex 8a5eb73 ruling)
  #
  # Not a supported allocation and no proof of allocator concurrency: while
  # the write waits on the setting lock, a privileged raw insert synthesizes
  # an atomically consistent newer start and counter in this disposable
  # database. It proves only that the resolver re-checks the stored fence
  # after its locks. The real restart/allocation case is test 10 in
  # `ProfileSwitchResolveTest`.

  test "10. probe: a newer start synthesized during the write's lock wait is refused after the locks",
       ctx do
    blocked = dead_holder!(ctx)
    latest = latest_start!(ctx)
    attestation = attestation(blocked, latest, :dead_holder)
    {holder, backend} = hold!(fn -> lock_setting!(ctx.tenant.id) end)

    caller = resolve_task(blocked, attestation, ctx.admin)
    await_blocked_by!(backend, 10_000, "C2-02b2β: the write never waited on the setting lock")
    synthesize_start!(ctx.tenant.id, latest.generation + 1, status().boot_id)
    release_holder(holder)
    result = await_task(caller, 25_000)

    assert result == {:error, :stale_attestation},
           "C2-02b2β: the latest start is re-checked after the locks; got #{inspect(result)}"

    assert raw_status(blocked.id) == "blocked"
    assert resolved_events(ctx) == []
  end

  ## 12. Settlement against a held, uncommitted original (R3-1)
  #
  # The original is an independent test transaction on its own connection
  # (no LedgerCall watchdog), a clearly labelled privileged fixture: it takes
  # the write's locks in the write's order (setting FOR UPDATE, counter FOR
  # SHARE, switch FOR UPDATE) and writes the resolution row, then stays open.
  # The coordinator is blocked in its mailbox, so the caller's call times out
  # and its settlement barrier must wait on that writer.

  test "12. held past the settle bound: :resolve_uncertain, though an independent read sees blocked",
       ctx do
    run = settlement_against_original!(ctx)
    result = await_task(run.caller, 10_000)

    assert result == {:error, :resolve_uncertain},
           "C2-02b2β: no barrier, no answer: :resolve_uncertain; got #{inspect(result)}"

    assert Enum.any?(
             relation_locks(run.writer),
             &(&1 == ["model_profile_switches", "RowExclusiveLock"])
           ),
           "the original was still open when the settlement gave up"

    assert raw_status(run.blocked.id) == "blocked"
    assert status().hold == :held, "nothing acts on an unproven outcome"

    # The original commits; the same attestation then converges to the replay.
    commit_original!(run)
    replay = resolve(run.blocked, run.attestation, ctx.admin)

    assert match?({:ok, %{replay: true}}, replay),
           "after the commit, the same attestation is a replay; got #{inspect(replay)}"

    finish_settlement!(ctx, run)
  end

  test "12. the original commits while the caller's barrier waits: the replay result", ctx do
    run = settlement_against_original!(ctx)
    commit_original!(run)
    result = await_task(run.caller, 10_000)

    assert match?({:ok, %{switch: %{status: :failed}, replay: true}}, result),
           "C2-02b2β: a barrier acquired after the commit, then an exact match: the replay " <>
             "result; got #{inspect(result)}"

    finish_settlement!(ctx, run)
  end

  test "12. the original rolls back while the caller's barrier waits: a definite :resolve_timeout",
       ctx do
    tracer = trace_release!()
    run = settlement_against_original!(ctx)
    rollback_original!(run)
    result = await_task(run.caller, 10_000)

    assert result == {:error, :resolve_timeout},
           "C2-02b2β: a barrier acquired after the rollback, S blocked and no row: a " <>
             "definite :resolve_timeout; got #{inspect(result)}"

    finish_settlement!(ctx, run)
    assert raw_status(run.blocked.id) == "blocked"
    assert status().hold == :held
    assert release_callers(tracer) == []
  end

  test "12. settlement keeps semantic matching: the same id from another admin conflicts", ctx do
    other_admin = AuditCase.new_human(:admin, ctx.tenant)
    run = settlement_against_original!(ctx, other_admin)
    commit_original!(run)
    result = await_task(run.caller, 10_000)

    assert result == {:error, :attestation_conflict},
           "C2-02b2β: after the barrier, a row with this id but another resolver is " <>
             ":attestation_conflict, never a replay; got #{inspect(result)}"

    finish_settlement!(ctx, run)
    assert field(switch!(ctx, run.blocked.id), :resolved_by_id) == ctx.admin.id
  end

  ## 13. LedgerCall's own pre-commit refusal

  test "13. the write's own pre-commit budget refusal is a definite :resolve_timeout, unsettled",
       ctx do
    # Test-only seams: the write's budget is 400 ms and its client-side
    # watchdog is widened to 5 400 ms (`client_slack_ms:`), so a 900 ms pause
    # inside it spends the budget while the connection stays open — past the
    # 650 ms default bound on purpose (a finite margin, not a guarantee; #230).
    blocked = dead_holder!(ctx, faults: [resolve_budget_ms: 400, client_slack_ms: 5_000])
    attestation = attestation(blocked, latest_start!(ctx), :dead_holder)
    coordinator_log = query_log!(&coordinator_query/1)
    caller_log = query_log!(caller_query(:c13))
    query_pause!(:appending, coordinator_event_append())

    caller = resolve_task(blocked, attestation, ctx.admin, init: fn -> mark_caller(:c13) end)
    assert_receive {:appending, coordinator}, 10_000, "the write's event append was never seen"
    Process.sleep(900)
    resume(coordinator, :appending)
    result = await_task(caller, 10_000)

    assert result == {:error, :resolve_timeout},
           "C2-02b2β: LedgerCall's pre-commit refusal is a definite :resolve_timeout; " <>
             "got #{inspect(result)}"

    drain!()
    after_write = coordinator_log |> logged() |> Enum.drop_while(&(not switch_update?(&1)))

    assert {"rollback", :ok} in after_write,
           "the write's own rollback was acknowledged (no connection loss)"

    refute {"commit", :ok} in after_write, "nothing committed"

    after_rollback = Enum.drop_while(after_write, &(&1 != {"rollback", :ok}))

    refute Enum.any?(after_rollback, fn {query, _} -> Regex.match?(@switch_lock, query) end),
           "no settlement barrier after a definite refusal (coordinator)"

    refute Enum.any?(logged(caller_log), fn {query, _} -> String.contains?(query, " FOR ") end),
           "no settlement barrier after a definite refusal (caller)"

    assert raw_status(blocked.id) == "blocked"
    assert resolved_events(ctx) == []
  end

  ## 14. The coordinator after an unknown commit

  test "14. the coordinator settles an unknown commit before any reconciliation; unproven stays held",
       ctx do
    blocked = none!(ctx, faults: [lose_reply: [:resolve_blocked]])
    latest = latest_start!(ctx)
    tracer = trace_release!()
    coordinator_log = query_log!(&coordinator_query/1)
    query_pause!(:committed, coordinator_commit())

    caller = resolve_task(blocked, attestation(blocked, latest, :none), ctx.admin)
    assert_receive {:committed, coordinator}, 10_000, "the resolve commit was never seen"
    assert raw_status(blocked.id) == "failed"

    # The coordinator's settlement can't take its barrier: unproven.
    {holder, backend} = hold!(fn -> lock_setting!(ctx.tenant.id) end)
    resume(coordinator, :committed)

    await_blocked_by!(
      backend,
      10_000,
      "C2-02b2β: the coordinator's settlement barrier never waited after the unknown commit"
    )

    Process.sleep(4_500)

    assert status().hold == :held, "an unproven outcome stays held"
    assert starts!(ctx) |> List.last() |> Map.get(:id) == latest.id, "no reconciliation yet"
    assert await_task(caller, 15_000) == {:error, :resolve_uncertain}

    # The tick retries the same settlement; it converges, then b2α's reconciliation.
    release_holder(holder)
    await_status!(&(&1.hold == :released), 20_000)
    after_commit = coordinator_log |> logged() |> Enum.drop_while(&(&1 != {"commit", :ok}))

    barrier =
      Enum.find_index(after_commit, fn {query, _} -> Regex.match?(@switch_lock, query) end)

    allocation =
      Enum.find_index(after_commit, fn {query, _} ->
        String.starts_with?(query, "INSERT INTO \"model_server_starts\"")
      end)

    assert is_integer(barrier) and is_integer(allocation) and barrier < allocation,
           "C2-02b2β: the settlement barrier precedes any reconciliation allocation"

    assert release_callers(tracer) == []
  end

  ## 17. The deadline

  test "17. a request expired in a blocked mailbox: definite only after the caller's barrier",
       ctx do
    blocked = survivor!(ctx)
    attestation = attestation(blocked, latest_start!(ctx), :survivor)
    assert_held_refusals!("before the resolution (passes by design)")
    blocked_coordinator = block_coordinator!()

    started = System.monotonic_time(:millisecond)
    caller = resolve_task(blocked, attestation, ctx.admin)
    Process.sleep(1_000)
    assert_held_refusals!("while the request waits")
    Process.sleep(max(13_500 - (System.monotonic_time(:millisecond) - started), 0))

    # Contention the caller's settlement barrier must wait through: evidence
    # that a definite answer follows a barrier, never the timeout alone.
    {holder, backend} = hold!(fn -> lock_setting!(ctx.tenant.id) end)

    [[_waiter, query] | _] =
      await_blocked_by!(
        backend,
        10_000,
        "C2-02b2β: the caller's settlement barrier never waited after its timeout"
      )

    assert query =~ ~r/model_profile_settings.*FOR UPDATE/s, "the barrier's setting lock"
    release_holder(holder)
    result = await_task(caller, 10_000)

    assert result == {:error, :resolve_timeout},
           "C2-02b2β: barrier acquired, S blocked and no row: a definite :resolve_timeout; " <>
             "got #{inspect(result)}"

    # Dequeued after its deadline: refused, nothing else.
    release_coordinator!(blocked_coordinator)
    drain!()
    assert raw_status(blocked.id) == "blocked"
    assert resolved_events(ctx) == []
    assert status().hold == :held
    assert_held_refusals!("after the expired request")
  end

  test "17. a write whose lock wait crosses the deadline rolls back, acknowledged, in time",
       ctx do
    blocked = dead_holder!(ctx)
    attestation = attestation(blocked, latest_start!(ctx), :dead_holder)
    blocked_coordinator = block_coordinator!()
    coordinator_log = query_log!(&coordinator_query/1)

    started = System.monotonic_time(:millisecond)
    caller = resolve_task(blocked, attestation, ctx.admin)
    Process.sleep(13_700)
    {holder, _backend} = hold!(fn -> lock_setting!(ctx.tenant.id) end)
    release_coordinator!(blocked_coordinator)
    result = await_task(caller, 10_000)
    elapsed = System.monotonic_time(:millisecond) - started
    release_holder(holder)
    drain!()
    queries = logged(coordinator_log)

    assert result == {:error, :resolve_timeout},
           "C2-02b2β: a lock wait past the deadline rolls back: :resolve_timeout; got #{inspect(result)}"

    assert elapsed < 16_000, "a definite reply within the call's deadline: #{elapsed} ms"

    assert Enum.any?(queries, &(&1 == {"rollback", :ok})) and
             not Enum.any?(queries, &(&1 == {"commit", :ok})),
           "the write's rollback was acknowledged and nothing committed"

    assert raw_status(blocked.id) == "blocked"
    assert resolved_events(ctx) == []
  end

  test "17. a pool wait crossing the deadline commits nothing, even once the pool frees", ctx do
    blocked = dead_holder!(ctx)
    attestation = attestation(blocked, latest_start!(ctx), :dead_holder)
    # Under `:auto` ownership a process keeps its connection: the
    # coordinator gives its own back, so its next use must wait on the pool.
    assert Coordinator.test_run(fn _binding -> Sandbox.checkin(Repo) end, 5_000) in [
             :ok,
             :not_owner
           ]

    blocked_coordinator = block_coordinator!()

    started = System.monotonic_time(:millisecond)
    caller = resolve_task(blocked, attestation, ctx.admin)
    Process.sleep(13_700)
    occupiers = occupy_pool!()
    release_coordinator!(blocked_coordinator)

    # The pool frees just after the 15 s deadline: a write whose budget isn't
    # bound by the deadline would now get its connection and commit.
    Process.sleep(max(15_300 - (System.monotonic_time(:millisecond) - started), 0))
    release_pool!(occupiers)
    result = await_task(caller, 10_000)
    elapsed = System.monotonic_time(:millisecond) - started
    drain!()

    assert raw_status(blocked.id) == "blocked",
           "C2-02b2β: a pool wait past the deadline must never commit; got #{inspect(result)}"

    assert resolved_events(ctx) == []
    assert match?({:error, _}, result), "no commit, no success; got #{inspect(result)}"
    assert elapsed < 25_000
  end

  ## 18. The hard conflict across a restart

  test "18. a restart while conflicted stays held; the operator path, then a fresh start and the release",
       ctx do
    blocked = dead_holder!(ctx)
    latest = latest_start!(ctx)
    tracer = trace_release!()

    assert match?(
             {:ok, %{switch: _}},
             resolve(blocked, attestation(blocked, latest, :dead_holder), ctx.admin)
           ),
           "C2-02b2β: the :dead_holder resolution"

    await_status!(&(&1.stage == :cleanup_unprovable), 10_000)
    drain!()
    before = status()
    kill_coordinator!()
    await_status!(&(&1.boot_id != before.boot_id), 10_000)
    sync()
    Process.sleep(1_500)

    assert %{stage: :cleanup_unprovable} = status()
    assert status().hold != :released

    assert Process.whereis(ClaudeCLI.server()) == nil,
           "no failed live child behind the dead lease"

    refute Enum.any?(starts!(ctx), &(&1.generation > latest.generation and &1.status == :ready)),
           "no readiness behind the dead lease"

    assert release_callers(tracer) == []

    assert :ok = Reaper.release(ClaudeCLI.server())
    released = await_status!(&(&1.hold == :released), 20_000)
    fresh = latest_start!(ctx)

    assert fresh.boot_id == released.boot_id and fresh.status == :ready and
             fresh.ready_evidence == :spawn_preflight and fresh.generation > latest.generation,
           "a fresh allocation and preflight of the current boot"

    assert release_callers(tracer) == [self()]
  end

  ## 19. A survivor's death during the write's lock wait

  test "19. a survivor dying during the write's lock wait leaves the coordinator held", ctx do
    blocked = survivor!(ctx)
    latest = latest_start!(ctx)
    tracer = trace_release!()
    {holder, backend} = hold!(fn -> lock_setting!(ctx.tenant.id) end)

    caller = resolve_task(blocked, attestation(blocked, latest, :survivor), ctx.admin)
    await_blocked_by!(backend)
    server = Process.whereis(ClaudeCLI.server())
    reaper = ClaudeCLI.reaper(server)
    true = :erlang.suspend_process(server)
    true = :erlang.suspend_process(reaper)
    kill!(server)
    kill!(reaper)
    release_holder(holder)
    result = await_task(caller, 25_000)

    assert match?({:ok, _}, result) or match?({:error, _}, result),
           "C2-02b2β: the resolution answers; got #{inspect(result)}"

    Process.sleep(2_000)
    sync()

    if match?({:ok, _}, result) do
      assert match?(%{stage: :cleanup_unprovable}, status()),
             "the current runtime facts (a dead lease), not the attested :survivor"
    end

    assert status().hold != :released
    assert Process.whereis(ClaudeCLI.server()) == nil
    assert Reaper.lease(ClaudeCLI.server()) == {:held, reaper}

    refute Enum.any?(starts!(ctx), &(&1.generation > latest.generation and &1.status == :ready)),
           "the human decision is not cleanup proof"

    assert release_callers(tracer) == []
  end

  ## 20. Crashes around the commit

  test "20. a kill after the commit: the next boot takes b2α's no-open-switch path", ctx do
    blocked = none!(ctx)
    latest = latest_start!(ctx)
    query_pause!(:committed, coordinator_commit())

    caller = resolve_task(blocked, attestation(blocked, latest, :none), ctx.admin)
    assert_receive {:committed, _coordinator}, 10_000, "the resolve commit was never seen"
    before = status()
    kill_coordinator!()
    result = await_task(caller, 25_000)

    assert match?({:ok, %{switch: %{status: :failed}, replay: true}}, result),
           "C2-02b2β: a lost reply is settled to the replay; got #{inspect(result)}"

    released = await_status!(&(&1.boot_id != before.boot_id and &1.hold == :released), 20_000)
    fresh = latest_start!(ctx)

    assert fresh.boot_id == released.boot_id and fresh.reason == :boot and
             fresh.ready_evidence == :spawn_preflight and fresh.generation > latest.generation

    assert raw_status(blocked.id) == "failed"
    assert length(resolved_events(ctx)) == 1
  end

  test "20. a kill before the commit: S blocked and the server held", ctx do
    blocked = survivor!(ctx)
    query_pause!(:precommit, coordinator_precommit())

    caller = resolve_task(blocked, attestation(blocked, latest_start!(ctx), :survivor), ctx.admin)
    assert_receive {:precommit, _coordinator}, 10_000, "the uncommitted write was never seen"
    before = status()
    kill_coordinator!()
    result = await_task(caller, 25_000)

    assert result == {:error, :resolve_timeout},
           "C2-02b2β: a rolled-back write is settled to a definite :resolve_timeout; " <>
             "got #{inspect(result)}"

    await_status!(&(&1.boot_id != before.boot_id and &1.hold == :held), 10_000)
    sync()
    assert raw_status(blocked.id) == "blocked"
    assert resolved_events(ctx) == []
    assert_held_refusals!("after the restart")
  end

  ## 21. Held refusals throughout

  test "21. ordinary, prepared and direct-pid calls are refused while held", ctx do
    blocked = survivor!(ctx)
    assert_held_refusals!("before the resolution (passes by design)")
    query_pause!(:precommit, coordinator_precommit())
    query_pause!(:committed, coordinator_commit())

    caller = resolve_task(blocked, attestation(blocked, latest_start!(ctx), :survivor), ctx.admin)
    assert_receive {:precommit, coordinator}, 10_000, "the uncommitted write was never seen"
    assert_held_refusals!("during the uncommitted write")
    resume(coordinator, :precommit)
    assert_receive {:committed, ^coordinator}, 10_000, "the resolve commit was never seen"
    assert_held_refusals!("committed, before the reconciliation")
    resume(coordinator, :committed)

    result = await_task(caller, 25_000)

    assert match?({:ok, %{switch: %{status: :failed}}}, result),
           "C2-02b2β: the :survivor resolution; got #{inspect(result)}"

    drain!()
  end

  ## Helpers

  # Test 12's fixture: the coordinator blocked, the privileged original
  # open with its locks, the caller's call timed out and its barrier waiting
  # on exactly that writer. `resolver` is the caller's actor.
  defp settlement_against_original!(ctx, resolver \\ nil) do
    require_resolver!()
    blocked = dead_holder!(ctx)
    attestation = attestation(blocked, latest_start!(ctx), :dead_holder)
    starts = starts!(ctx)
    blocked_coordinator = block_coordinator!()
    {original, writer} = original!(blocked, attestation, ctx.admin)

    locks = relation_locks(writer)

    for lock <- [
          ["model_profile_settings", "RowShareLock"],
          ["model_server_counters", "RowShareLock"],
          ["model_profile_switches", "RowExclusiveLock"]
        ],
        do: assert(lock in locks, "the original holds #{inspect(lock)}: #{inspect(locks)}")

    assert raw_status(blocked.id) == "blocked", "an independent read sees S blocked"
    caller = resolve_task(blocked, attestation, resolver || ctx.admin)

    [[_waiter, query]] =
      await_blocked_by!(
        writer,
        25_000,
        "C2-02b2β: the caller's settlement barrier never waited on the open original"
      )

    assert query =~ ~r/model_profile_settings.*FOR UPDATE/s, "the barrier's setting lock"

    assert Enum.any?(
             relation_locks(writer),
             &(&1 == ["model_profile_switches", "RowExclusiveLock"])
           )

    assert starts!(ctx) == starts

    %{
      blocked: blocked,
      attestation: attestation,
      caller: caller,
      original: original,
      writer: writer,
      starts: starts,
      coordinator: blocked_coordinator
    }
  end

  # The privileged original: the write's locks in the write's order, then
  # the resolution row, uncommitted until `commit_original!/1` or
  # `rollback_original!/1`.
  defp original!(switch, attestation, resolver) do
    parent = self()
    tenant = Ecto.UUID.dump!(switch.tenant_id)
    id = Ecto.UUID.dump!(switch.id)

    task =
      Task.async(fn ->
        Repo.transaction(
          fn ->
            [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows

            Repo.query!("SELECT 1 FROM model_profile_settings WHERE tenant_id = $1 FOR UPDATE", [
              tenant
            ])

            Repo.query!("SELECT 1 FROM model_server_counters WHERE tenant_id = $1 FOR SHARE", [
              tenant
            ])

            Repo.query!("SELECT 1 FROM model_profile_switches WHERE id = $1 FOR UPDATE", [id])

            Repo.query!(
              "UPDATE model_profile_switches SET status = 'failed', finished_at = now(), " <>
                "resolved_at = now(), resolution = 'owner_attested', resolved_by_id = $2, " <>
                "attestation_id = $3, attested_start_id = $4, attested_generation = $5, " <>
                "attested_lease_kind = $6, updated_at = now() WHERE id = $1",
              [
                id,
                Ecto.UUID.dump!(resolver.id),
                Ecto.UUID.dump!(attestation.attestation_id),
                Ecto.UUID.dump!(attestation.attested_start_id),
                attestation.attested_generation,
                Atom.to_string(attestation.attested_lease_kind)
              ]
            )

            send(parent, {:original_open, backend})

            receive do
              :commit -> :committed
              :rollback -> Repo.rollback(:fixture_rollback)
            after
              60_000 -> Repo.rollback(:fixture_timeout)
            end
          end,
          timeout: 90_000
        )
      end)

    assert_receive {:original_open, backend}, 10_000
    on_exit(fn -> send(task.pid, :rollback) end)
    {task, backend}
  end

  defp commit_original!(run) do
    send(run.original.pid, :commit)
    assert Task.await(run.original, 10_000) == {:ok, :committed}
    assert raw_status(run.blocked.id) == "failed"
  end

  defp rollback_original!(run) do
    send(run.original.pid, :rollback)
    assert Task.await(run.original, 10_000) == {:error, :fixture_rollback}
    assert raw_status(run.blocked.id) == "blocked"
  end

  # Releases the blocked coordinator (it dequeues the expired request) and
  # joins it: nothing it does may write a resolution or a start.
  defp finish_settlement!(ctx, run) do
    if Process.alive?(run.original.pid), do: commit_original!(run)
    release_coordinator!(run.coordinator)
    drain!()
    assert resolved_events(ctx) == [], "the expired request wrote nothing"
    assert starts!(ctx) == run.starts, "the expired request started nothing"
  end

  defp switch_update?({query, _status}),
    do: String.starts_with?(query, "UPDATE \"model_profile_switches\"")

  # Checks out pool connections (each held by its own unlinked process,
  # `queue: false`) until the next checkout is refused: the pool is then
  # exhausted until `release_pool!/1`.
  defp occupy_pool! do
    occupiers = occupy([], Repo.config()[:pool_size] + 5)
    on_exit(fn -> for pid <- occupiers, do: send(pid, :release) end)
    occupiers
  end

  defp occupy(occupiers, 0), do: flunk("the pool was never exhausted (#{length(occupiers)} held)")

  defp occupy(occupiers, left) do
    parent = self()
    pid = spawn(fn -> hold_connection(parent) end)

    receive do
      {:occupied, ^pid} -> occupy([pid | occupiers], left - 1)
      {:exhausted, ^pid} -> occupiers
    after
      10_000 -> flunk("a pool occupier never answered")
    end
  end

  defp hold_connection(parent) do
    Repo.checkout(fn -> occupied(parent) end, queue: false, timeout: 40_000)
  rescue
    DBConnection.ConnectionError -> send(parent, {:exhausted, self()})
  end

  defp occupied(parent) do
    send(parent, {:occupied, self()})

    receive do
      :release -> :ok
    after
      30_000 -> :ok
    end
  end

  defp release_pool!(occupiers) do
    for pid <- occupiers do
      ref = Process.monitor(pid)
      send(pid, :release)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        10_000 -> flunk("a pool occupier never exited")
      end
    end
  end

  defp change!(:demoted, user, admin), do: Accounts.change_role(user, :reviewer, actor: admin)
  defp change!(:disabled, user, admin), do: Accounts.change_status(user, :disabled, actor: admin)

  # The fault-injection probe's synthesized start: a privileged raw insert
  # (replica role) and counter bump, committed on its own connection while
  # the coordinator's write waits. Never a supported allocation.
  defp synthesize_start!(tenant_id, generation, boot_id) do
    Task.async(fn ->
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL session_replication_role = replica")

        Repo.query!(
          "INSERT INTO model_server_starts (id, tenant_id, generation, boot_id, profile_id, " <>
            "reason, status, inserted_at, updated_at) VALUES ($1, $2, $3, $4, " <>
            "'claude_cli_opus', 'replacement', 'allocated', now(), now())",
          [
            Ecto.UUID.dump!(Ecto.UUID.generate()),
            Ecto.UUID.dump!(tenant_id),
            generation,
            Ecto.UUID.dump!(boot_id)
          ]
        )

        Repo.query!(
          "UPDATE model_server_counters SET last_generation = $1 WHERE tenant_id = $2",
          [generation, Ecto.UUID.dump!(tenant_id)]
        )
      end)
    end)
    |> Task.await(10_000)
  end

  @doc false
  def truncatable?(database) when is_binary(database),
    do: Regex.match?(~r/\Asdr_agent_test[a-z0-9_]*\z/, database)

  def truncatable?(_database), do: false

  defp cleanup! do
    database = Repo.config()[:database]

    unless truncatable?(database) do
      raise "refusing to truncate #{inspect(database)}: not a test database"
    end

    existing =
      Enum.filter(@tables, fn table ->
        Repo.query!("SELECT to_regclass($1) IS NOT NULL", [table]).rows == [[true]]
      end)

    Repo.transaction(fn ->
      Repo.query!("SET LOCAL session_replication_role = replica")
      Repo.query!("TRUNCATE #{Enum.join(existing, ", ")} CASCADE")
    end)
  end
end
