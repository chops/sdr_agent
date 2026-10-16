defmodule SdrAgent.Agents.ProfileSwitchResolveRaceTest do
  @moduledoc """
  C2-02b2β RED (`docs/product/r0/c2-02b2b-interface.md` draft 4, interface
  and entity PASS at `e60943c`), section 8 on independent connections: tests
  3 (an admin changed between dispatch and the locks), 8, 9, 10 (a start
  allocated during the write's lock wait), 12, 13, 14, 17 (a lock wait
  crossing the deadline), 18 (a restart while conflicted), 19 (a death during
  the lock wait), 20 (kills after and before the commit) and 21, plus the
  settlement and replay obligations of `codex-c202b2beta-e60943c-interface-pass.md`.

  The whole tree needs independent connections, so this module runs the SQL
  sandbox in `:auto` mode for its own duration (synchronous; restored to
  `:manual` afterwards) and truncates only a test database before and after
  each test; every lease is cleaned up by `ResolveHarness.lease_cleanup!/0`.
  Row-lock holders are raw SQL transactions on their own connections, joined
  on release.

  **The original transaction held uncommitted** (test 12): the coordinator
  is paused by a query telemetry handler in its own process, after its
  resolve transaction's switch update and LedgerCall's last budget step,
  before `COMMIT` (`ResolveHarness.coordinator_precommit/0`). It is then
  committed by resuming it, or rolled back by terminating its backend
  (`pg_terminate_backend`), while the caller's settlement barrier waits on its
  locks. The coordinator is killed only when it is paused on its own
  connection. Test-build-only seam chosen: the coordinator fault `lose_reply:
  [:resolve_blocked]` (b2α's `lose_reply:` key) makes a committed write's
  outcome unknown to the coordinator (test 14). Test 10's concurrent start is
  a raw insert (replica role) on an independent connection, the only way a
  start can appear while the coordinator itself waits. The fake CLI; no
  model call.
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

  ## 10. A start allocated while the write waits on the setting lock

  test "10. a start allocated during the write's setting-lock wait is refused after the locks",
       ctx do
    blocked = dead_holder!(ctx)
    latest = latest_start!(ctx)
    attestation = attestation(blocked, latest, :dead_holder)
    {holder, backend} = hold!(fn -> lock_setting!(ctx.tenant.id) end)

    caller = resolve_task(blocked, attestation, ctx.admin)
    await_blocked_by!(backend)
    insert_start!(ctx.tenant.id, latest.generation + 1, status().boot_id)
    release_holder(holder)
    result = await_task(caller, 25_000)

    assert result == {:error, :stale_attestation},
           "C2-02b2β: the latest start is re-checked after the locks; got #{inspect(result)}"

    assert raw_status(blocked.id) == "blocked"
    assert resolved_events(ctx) == []
  end

  ## 12. Settlement: the original transaction held uncommitted (R3-1)

  test "12. held past the settle bound: :resolve_uncertain, though an independent read sees blocked",
       ctx do
    run = uncommitted_resolution!(ctx)
    result = await_task(run.caller, 10_000)

    assert result == {:error, :resolve_uncertain},
           "C2-02b2β: no barrier, no answer: :resolve_uncertain; got #{inspect(result)}"

    assert raw_status(run.blocked.id) == "blocked"
    assert status().hold == :held, "nothing acts on an unproven outcome"
    assert starts!(ctx) == run.starts

    # The original commits; a later settlement converges to the replay.
    resume(run.coordinator, :precommit)
    await!(fn -> raw_status(run.blocked.id) == "failed" end, 10_000, "the original committed")
    replay = resolve(run.blocked, run.attestation, ctx.admin)

    assert match?({:ok, %{replay: true}}, replay),
           "after the commit, the same attestation is a replay; got #{inspect(replay)}"

    assert length(resolved_events(ctx)) == 1
  end

  test "12. the original commits while the caller's barrier waits: the replay result", ctx do
    run = uncommitted_resolution!(ctx)
    resume(run.coordinator, :precommit)
    result = await_task(run.caller, 10_000)

    assert match?({:ok, %{switch: %{status: :failed}, replay: true}}, result),
           "C2-02b2β: a barrier acquired after the commit, then an exact match: the replay " <>
             "result; got #{inspect(result)}"

    assert length(resolved_events(ctx)) == 1
  end

  test "12. the original rolls back while the caller's barrier waits: a definite :resolve_timeout",
       ctx do
    tracer = trace_release!()
    run = uncommitted_resolution!(ctx)
    assert [[true]] = Repo.query!("SELECT pg_terminate_backend($1)", [run.writer]).rows
    resume(run.coordinator, :precommit)
    result = await_task(run.caller, 10_000)

    assert result == {:error, :resolve_timeout},
           "C2-02b2β: a barrier acquired after the rollback, S blocked and no row: a " <>
             "definite :resolve_timeout; got #{inspect(result)}"

    sync()
    quiet!()
    assert raw_status(run.blocked.id) == "blocked"
    assert resolved_events(ctx) == []
    assert status().hold == :held
    assert starts!(ctx) == run.starts, "nothing acted on the unknown commit"
    assert release_callers(tracer) == []
  end

  test "12. settlement keeps semantic matching: the same id from another admin conflicts", ctx do
    other_admin = AuditCase.new_human(:admin, ctx.tenant)

    run =
      uncommitted_resolution!(
        ctx,
        fn blocked, attestation -> resolve_task(blocked, attestation, other_admin) end,
        2
      )

    resume(run.coordinator, :precommit)
    first = await_task(run.caller, 10_000)
    second = await_task(run.other, 10_000)

    assert match?({:ok, %{replay: true}}, first),
           "C2-02b2β: the original's caller settles to the replay; got #{inspect(first)}"

    assert second == {:error, :attestation_conflict},
           "C2-02b2β: after the barrier, a row with this id but another resolver is " <>
             ":attestation_conflict, never a replay; got #{inspect(second)}"

    sync()
    assert length(resolved_events(ctx)) == 1
    assert field(switch!(ctx, run.blocked.id), :resolved_by_id) == ctx.admin.id
  end

  ## 13. LedgerCall's own pre-commit refusal

  test "13. the write's own pre-commit budget refusal is a definite :resolve_timeout, unsettled",
       ctx do
    blocked = dead_holder!(ctx)
    attestation = attestation(blocked, latest_start!(ctx), :dead_holder)
    coordinator_log = query_log!(&coordinator_query/1)
    caller_log = query_log!(caller_query(:c13))
    query_pause!(:appending, coordinator_event_append())

    caller = resolve_task(blocked, attestation, ctx.admin, init: fn -> mark_caller(:c13) end)
    assert_receive {:appending, coordinator}, 10_000, "the write's event append was never seen"
    # Past the write's 2 s budget, inside its transaction: its last step refuses the commit.
    Process.sleep(2_300)
    resume(coordinator, :appending)
    result = await_task(caller, 10_000)

    assert result == {:error, :resolve_timeout},
           "C2-02b2β: LedgerCall's pre-commit refusal is a definite :resolve_timeout; " <>
             "got #{inspect(result)}"

    sync()
    after_rollback = coordinator_log |> logged() |> Enum.drop_while(&(&1 != "rollback"))
    assert after_rollback != [], "the write rolled back"

    refute Enum.any?(after_rollback, &Regex.match?(@switch_lock, &1)),
           "no settlement barrier after a definite refusal (coordinator)"

    refute Enum.any?(logged(caller_log), &String.contains?(&1, " FOR ")),
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
    await_blocked_by!(backend)
    Process.sleep(4_500)

    assert status().hold == :held, "an unproven outcome stays held"
    assert starts!(ctx) |> List.last() |> Map.get(:id) == latest.id, "no reconciliation yet"
    assert await_task(caller, 15_000) == {:error, :resolve_uncertain}

    # The tick retries the same settlement; it converges, then b2α's reconciliation.
    release_holder(holder)
    await_status!(&(&1.hold == :released), 20_000)
    queries = logged(coordinator_log)
    after_commit = Enum.drop_while(queries, &(&1 != "commit"))
    barrier = Enum.find_index(after_commit, &Regex.match?(@switch_lock, &1))

    allocation =
      Enum.find_index(
        after_commit,
        &String.starts_with?(&1, "INSERT INTO \"model_server_starts\"")
      )

    assert is_integer(barrier) and is_integer(allocation) and barrier < allocation,
           "C2-02b2β: the settlement barrier precedes any reconciliation allocation"

    assert release_callers(tracer) == []
  end

  ## 17. A lock wait crossing the deadline

  test "17. a write whose lock wait crosses the deadline doesn't commit", ctx do
    blocked = dead_holder!(ctx)
    attestation = attestation(blocked, latest_start!(ctx), :dead_holder)
    parent = self()

    blocker =
      Task.async(fn ->
        Coordinator.test_run(
          fn _binding ->
            send(parent, {:coordinator_blocked, self()})

            receive do
              :go -> :ok
            after
              40_000 -> :ok
            end
          end,
          45_000
        )
      end)

    assert_receive {:coordinator_blocked, coordinator}, 5_000
    started = System.monotonic_time(:millisecond)
    caller = resolve_task(blocked, attestation, ctx.admin)
    Process.sleep(13_700)
    {holder, _backend} = hold!(fn -> lock_setting!(ctx.tenant.id) end)
    send(coordinator, :go)
    Task.await(blocker, 10_000)
    result = await_task(caller, 10_000)
    elapsed = System.monotonic_time(:millisecond) - started
    release_holder(holder)

    assert result == {:error, :resolve_timeout},
           "C2-02b2β: a lock wait past the deadline rolls back: :resolve_timeout; got #{inspect(result)}"

    assert elapsed < 17_000, "bounded by the deadline: #{elapsed} ms"
    sync()
    quiet!()
    assert raw_status(blocked.id) == "blocked"
    assert resolved_events(ctx) == []
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
    quiet!()
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

    quiet!()
  end

  ## Helpers

  # The coordinator paused with its resolve transaction uncommitted; the
  # caller's call has timed out and its settlement barrier waits on it.
  # `also.(blocked, attestation)` may start more callers first; `waiters`
  # barriers are awaited.
  defp uncommitted_resolution!(ctx, also \\ fn _blocked, _attestation -> nil end, waiters \\ 1) do
    blocked = dead_holder!(ctx)
    attestation = attestation(blocked, latest_start!(ctx), :dead_holder)
    query_pause!(:precommit, coordinator_precommit())

    caller = resolve_task(blocked, attestation, ctx.admin)
    assert_receive {:precommit, coordinator}, 10_000, "the uncommitted write was never seen"
    other = also.(blocked, attestation)
    writer = switch_writer()
    assert is_integer(writer), "the original transaction holds its row locks, uncommitted"
    assert raw_status(blocked.id) == "blocked", "an independent read sees S blocked"
    starts = starts!(ctx)

    # The callers' 15 s calls time out; their barriers then wait on the original.
    await!(
      fn -> waiting_on(writer) >= waiters end,
      25_000,
      "the settlement barriers never waited"
    )

    assert status().hold == :held
    assert starts!(ctx) == starts

    %{
      blocked: blocked,
      attestation: attestation,
      caller: caller,
      other: other,
      coordinator: coordinator,
      writer: writer,
      starts: starts
    }
  end

  defp waiting_on(backend) do
    [[count]] =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid))",
        [backend]
      ).rows

    count
  end

  defp change!(:demoted, user, admin), do: Accounts.change_role(user, :reviewer, actor: admin)
  defp change!(:disabled, user, admin), do: Accounts.change_status(user, :disabled, actor: admin)

  # A start the coordinator didn't allocate, committed on its own connection
  # while the coordinator's write waits (replica role: a raw simulation).
  defp insert_start!(tenant_id, generation, boot_id) do
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
