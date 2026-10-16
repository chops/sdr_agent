defmodule SdrAgent.AI.ProfileCoordinatorResolveTest do
  @moduledoc """
  C2-02b2β RED (`docs/product/r0/c2-02b2b-interface.md` draft 4, interface
  and entity PASS at `e60943c`; revised for Codex 8a5eb73 MF1–MF4), section
  8 "Coordinator and runtime": tests 15, 16, 18, 19 (a death after the
  commit) and 20 (a forced failure before the commit), plus the binding
  obligations on the hard conflict, current runtime facts, failed lookups
  and `Reaper.release/1`. Test 17 is in the race file (it needs barrier
  evidence on independent connections).

  Every switch is blocked by the real b2α coordinator
  (`SdrAgent.Test.ResolveHarness`). Test-build-only seams chosen: the
  coordinator faults `observe:` (the lease and hold observation),
  `replay_read:` (the coordinator's stored replay read) and
  `locked_replay_read:` (the replay check after the locks), each `fn ->
  :read | :unavailable end`, and the caller option `faults: [replay_read:
  fn -> ... end]` (the caller's first stored read). An unacknowledged hold
  and a busy coordinator are set on b2α's own state fields (`hold_state`,
  `op`, `reconcile`) with `:sys.replace_state/2`: defensive guard tests, not
  an API precedent. The operator path (`Reaper.release/1`) is always run by
  the test; a trace with a positive and a negative control proves the
  coordinator never calls it. Shared SQL sandbox; the fake CLI; no model
  call.

  Passes by design: the release-trace control test, and the held refusals
  before a resolution (b2α's hold) inside tests that fail on b2β behavior.
  """
  use SdrAgent.AuditCase, async: false

  import SdrAgent.Test.ResolveHarness

  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper
  alias SdrAgent.AI.ModelProvider.Coordinator

  @moduletag :c2_02b2b
  @moduletag timeout: 120_000

  setup do
    tenant = bootstrap!()
    lease_cleanup!()
    %{tenant: tenant, admin: human(:admin, tenant)}
  end

  ## 15. The observed lease kind

  describe "15. lease kinds" do
    test "a live lease holder with no server is :live_work_observed, whatever is attested",
         ctx do
      blocked = dead_holder!(ctx)
      latest = latest_start!(ctx)
      {:held, dead} = Reaper.lease(ClaudeCLI.server())
      live = live_dummy!()
      :persistent_term.put({Reaper, ClaudeCLI.server()}, {:held, live})

      for kind <- [:dead_holder, :none] do
        result = resolve(blocked, attestation(blocked, latest, kind), ctx.admin)

        assert result == {:error, :live_work_observed},
               "C2-02b2β: a live holder with no server (attested #{kind}) must be " <>
                 ":live_work_observed; got #{inspect(result)}"
      end

      assert switch!(ctx, blocked.id) == blocked
      :persistent_term.put({Reaper, ClaudeCLI.server()}, {:held, dead})
      assert ok?(resolve(blocked, attestation(blocked, latest, :dead_holder), ctx.admin))
    end

    test "a lease holder that isn't the server's own reaper is :live_work_observed", ctx do
      blocked = survivor!(ctx)
      latest = latest_start!(ctx)
      own = Reaper.lease(ClaudeCLI.server())
      :persistent_term.put({Reaper, ClaudeCLI.server()}, {:held, live_dummy!()})

      result = resolve(blocked, attestation(blocked, latest, :survivor), ctx.admin)
      :persistent_term.put({Reaper, ClaudeCLI.server()}, own)

      assert result == {:error, :live_work_observed},
             "C2-02b2β: a foreign lease holder must be :live_work_observed; got #{inspect(result)}"

      assert switch!(ctx, blocked.id) == blocked
      assert ok?(resolve(blocked, attestation(blocked, latest, :survivor), ctx.admin))
    end

    test "a held server with blocked admission is :live_work_observed, confirmation present",
         ctx do
      blocked = admission_blocked!(ctx)
      attestation = attestation(blocked, latest_start!(ctx), :survivor)
      assert attestation.confirmation == "STOPPED " <> blocked.id

      result = resolve(blocked, attestation, ctx.admin)

      assert result == {:error, :live_work_observed},
             "C2-02b2β: blocked admission must be :live_work_observed; got #{inspect(result)}"

      assert switch!(ctx, blocked.id) == blocked
      assert resolved_events(ctx) == []
    end

    for {kind, wrong} <- [
          survivor: [:none, :dead_holder],
          dead_holder: [:survivor, :none],
          none: [:dead_holder, :survivor]
        ] do
      test "#{kind} attested as another kind is :stale_attestation", ctx do
        blocked = blocked!(ctx, unquote(kind))
        latest = latest_start!(ctx)

        for wrong <- unquote(wrong) do
          result = resolve(blocked, attestation(blocked, latest, wrong), ctx.admin)

          assert result == {:error, :stale_attestation},
                 "C2-02b2β: observed #{unquote(kind)}, attested #{wrong}, must be " <>
                   ":stale_attestation; got #{inspect(result)}"
        end

        assert switch!(ctx, blocked.id) == blocked
        assert ok?(resolve(blocked, attestation(blocked, latest, unquote(kind)), ctx.admin))
      end
    end

    test "a failed observation is :observation_unknown for the facts and the resolution", ctx do
      {:ok, gate} = Agent.start_link(fn -> :read end)
      blocked = dead_holder!(ctx, faults: [observe: fn -> Agent.get(gate, & &1) end])
      attestation = attestation(blocked, latest_start!(ctx), :dead_holder)
      Agent.update(gate, fn _ -> :unavailable end)

      assert facts(blocked, ctx.admin) == {:error, :observation_unknown},
             "C2-02b2β: a failed observation in the facts is :observation_unknown"

      assert resolve(blocked, attestation, ctx.admin) == {:error, :observation_unknown}
      assert switch!(ctx, blocked.id) == blocked

      # An observation only refuses; once it reads again, the same attestation resolves.
      Agent.update(gate, fn _ -> :read end)
      assert ok?(resolve(blocked, attestation, ctx.admin))
    end

    test "an unacknowledged hold is :observation_unknown", ctx do
      blocked = survivor!(ctx)
      attestation = attestation(blocked, latest_start!(ctx), :survivor)

      :sys.replace_state(Coordinator, &%{&1 | hold_state: :pending})
      result = resolve(blocked, attestation, ctx.admin)
      :sys.replace_state(Coordinator, &%{&1 | hold_state: :held})

      assert result == {:error, :observation_unknown},
             "C2-02b2β: an unacknowledged hold must be :observation_unknown; got #{inspect(result)}"

      assert switch!(ctx, blocked.id) == blocked
      assert ok?(resolve(blocked, attestation, ctx.admin))
    end

    test "a failed caller replay read refuses before dispatch (test-only caller seam)", ctx do
      blocked = dead_holder!(ctx)
      attestation = attestation(blocked, latest_start!(ctx), :dead_holder)

      result =
        resolve(blocked, attestation, ctx.admin, faults: [replay_read: fn -> :unavailable end])

      assert match?({:error, _}, result) and result != {:error, :switch_not_blocked},
             "C2-02b2β: a failed caller lookup is never absence; got #{inspect(result)}"

      assert switch!(ctx, blocked.id) == blocked
      assert resolved_events(ctx) == []
      assert ok?(resolve(blocked, attestation, ctx.admin)), "the allow side, once it reads"
    end

    test "a failed coordinator replay read refuses: never absent, never resolved", ctx do
      {:ok, gate} = Agent.start_link(fn -> :read end)
      blocked = dead_holder!(ctx, faults: [replay_read: fn -> Agent.get(gate, & &1) end])
      attestation = attestation(blocked, latest_start!(ctx), :dead_holder)

      # Never resolved: a failed coordinator lookup must not proceed as absent.
      Agent.update(gate, fn _ -> :unavailable end)
      first = resolve(blocked, attestation, ctx.admin)

      assert match?({:error, _}, first) and first != {:error, :switch_not_blocked},
             "C2-02b2β: a failed coordinator lookup must refuse; got #{inspect(first)}"

      assert switch!(ctx, blocked.id) == blocked
      assert resolved_events(ctx) == []

      # Historical: caller x misses before y's resolution commits (barriered
      # after its own read), so x reaches the coordinator's lookup, which fails.
      Agent.update(gate, fn _ -> :read end)
      query_pause!(:read_x, caller_replay_read(:x))
      x = resolve_task(blocked, attestation, ctx.admin, init: fn -> mark_caller(:x) end)
      assert_receive {:read_x, read_x}, 10_000, "caller x's stored replay read was never seen"
      assert ok?(resolve(blocked, attestation, ctx.admin)), "caller y resolves"
      Agent.update(gate, fn _ -> :unavailable end)
      resume(read_x, :read_x)
      again = await_task(x, 25_000)

      refute match?({:ok, _}, again) or again == {:error, :switch_not_blocked},
             "a failed coordinator lookup is never a replay or a resolved refusal; got #{inspect(again)}"

      assert length(resolved_events(ctx)) == 1
    end

    test "a failed post-lock replay read rolls back: never absent", ctx do
      blocked =
        dead_holder!(ctx, faults: [locked_replay_read: fn -> :unavailable end])

      attestation = attestation(blocked, latest_start!(ctx), :dead_holder)
      result = resolve(blocked, attestation, ctx.admin)

      assert match?({:error, _}, result) and result != {:error, :switch_not_blocked},
             "C2-02b2β: a failed lookup after the locks must refuse; got #{inspect(result)}"

      drain!()
      assert switch!(ctx, blocked.id) == blocked
      assert resolved_events(ctx) == []
    end
  end

  ## 16. Busy
  #
  # Coverage qualification (Codex 8a5eb73 ruling): busy during a block retry
  # is omitted. It is unreachable with a blocked S: α's `{:retry_block, id,
  # reason}` re-reads the target, a pending S is refused (:switch_not_blocked)
  # before the busy branch, and a stored blocked S ends the retry. If β adds
  # retained block-retry or settlement state, its reachable busy path must be
  # covered then. These `:sys.replace_state/2` cases are defensive guard tests
  # on b2α's own fields, not a natural runtime sequence.

  test "16. during a worker or a reconciliation the coordinator is busy; nothing is queued",
       ctx do
    blocked = survivor!(ctx)
    attestation = attestation(blocked, latest_start!(ctx), :survivor)
    worker = live_dummy!()

    busy_states = [
      {"a switch worker",
       &%{
         &1
         | op: %{
             switch: blocked,
             token: make_ref(),
             worker: worker,
             worker_ref: make_ref(),
             stage: :draining,
             from: blocked.from_profile_id,
             to: blocked.to_profile_id,
             continue: nil,
             receipt: nil
           }
       }},
      {"a reconciliation in flight", &%{&1 | reconcile: :boot}}
    ]

    for {label, busy} <- busy_states do
      :sys.replace_state(Coordinator, busy)
      result = resolve(blocked, attestation, ctx.admin)
      :sys.replace_state(Coordinator, &%{&1 | op: nil, reconcile: nil})

      assert result == {:error, :coordinator_busy},
             "C2-02b2β: during #{label} the reply is :coordinator_busy; got #{inspect(result)}"
    end

    drain!()
    assert switch!(ctx, blocked.id) == blocked, "nothing was queued"
    assert resolved_events(ctx) == []
    assert ok?(resolve(blocked, attestation, ctx.admin))
  end

  ## 17. The deadline: in the race file (it needs barrier evidence on
  ## independent connections).

  ## 18. After the commit

  describe "18. after the commit" do
    test ":none → a fresh held start at from, the no-call preflight, ready, then the release",
         ctx do
      blocked = none!(ctx)
      latest = latest_start!(ctx)
      tracer = trace_release!()
      flush_launches()

      assert ok?(resolve(blocked, attestation(blocked, latest, :none), ctx.admin)),
             "C2-02b2β: the :none resolution"

      released = await_status!(&(&1.hold == :released), 20_000)
      fresh = latest_start!(ctx)

      assert fresh.generation > latest.generation and fresh.reason == :replacement and
               fresh.status == :ready and fresh.ready_evidence == :spawn_preflight and
               fresh.profile_id == blocked.from_profile_id and fresh.boot_id == released.boot_id,
             "a fresh held replacement at from, preflighted: #{inspect(Map.take(fresh, [:generation, :reason, :status, :ready_evidence, :profile_id]))}"

      assert_reconciled_ready!(fresh, released, blocked)
      refute_received {:launch_admission, _, _, _}, "zero launches"
      assert release_callers(tracer) == [], "the coordinator never calls Reaper.release/1"
    end

    test ":survivor → adopted (or stopped with a fresh receipt and replaced), then released",
         ctx do
      blocked = survivor!(ctx)
      latest = latest_start!(ctx)
      server = Process.whereis(ClaudeCLI.server())
      tracer = trace_release!()
      flush_launches()

      assert ok?(resolve(blocked, attestation(blocked, latest, :survivor), ctx.admin)),
             "C2-02b2β: the :survivor resolution"

      released = await_status!(&(&1.hold == :released), 20_000)
      current = Process.whereis(ClaudeCLI.server())
      fresh = latest_start!(ctx)

      # The chosen path, then its reconciled readiness: adoption keeps the
      # survivor; a replacement is a fresh preflighted start.
      if current == server do
        assert fresh.ready_evidence in [:adopted, :spawn_preflight]
      else
        assert fresh.generation > latest.generation and fresh.ready_evidence == :spawn_preflight,
               "replaced by a fresh preflighted start"
      end

      assert_reconciled_ready!(fresh, released, blocked)
      refute_received {:launch_admission, _, _, _}, "zero launches"
      assert release_callers(tracer) == [], "the coordinator never calls Reaper.release/1"
    end

    test ":dead_holder → held at :cleanup_unprovable; the operator path, then ready and released",
         ctx do
      blocked = dead_holder!(ctx)
      latest = latest_start!(ctx)
      {:held, dead} = Reaper.lease(ClaudeCLI.server())
      tracer = trace_release!()
      flush_launches()

      assert ok?(resolve(blocked, attestation(blocked, latest, :dead_holder), ctx.admin)),
             "C2-02b2β: the :dead_holder resolution"

      await_status!(&(&1.stage == :cleanup_unprovable and &1.hold == :held), 10_000)
      starts = starts!(ctx)
      Process.sleep(1_000)

      assert starts!(ctx) == starts, "no start behind a known dead lease"

      assert Process.whereis(ClaudeCLI.server()) == nil,
             "no failed live child behind the dead lease"

      assert Reaper.lease(ClaudeCLI.server()) == {:held, dead}, "b2β releases nothing"
      assert %{stage: :cleanup_unprovable, hold: :held} = status()
      assert release_callers(tracer) == []

      # The existing operator path, run by the test.
      assert :ok = Reaper.release(ClaudeCLI.server())
      released = await_status!(&(&1.hold == :released), 20_000)
      fresh = latest_start!(ctx)

      assert fresh.generation > latest.generation and fresh.status == :ready and
               fresh.ready_evidence == :spawn_preflight and fresh.boot_id == released.boot_id and
               fresh.profile_id == blocked.from_profile_id,
             "a fresh allocation and preflight, not adopted or failed readiness"

      assert_reconciled_ready!(fresh, released, blocked)

      refute_received {:launch_admission, _, _, _}, "zero launches"
      assert release_callers(tracer) == [self()], "only the test-side operator released the lease"
    end
  end

  ## 19. No authority from absence or death (after the commit)

  test "19. a survivor whose server and reaper die without a receipt leaves the coordinator held",
       ctx do
    blocked = survivor!(ctx)
    tracer = trace_release!()

    assert ok?(resolve(blocked, attestation(blocked, latest_start!(ctx), :survivor), ctx.admin)),
           "C2-02b2β: the :survivor resolution"

    await_status!(&(&1.hold == :released), 20_000)
    drain!()
    server = Process.whereis(ClaudeCLI.server())
    reaper = ClaudeCLI.reaper(server)
    true = :erlang.suspend_process(server)
    true = :erlang.suspend_process(reaper)
    kill!(server)
    kill!(reaper)

    await_status!(&(&1.stage == :cleanup_unprovable and &1.hold == :held), 10_000)
    starts = starts!(ctx)
    Process.sleep(1_500)

    assert %{hold: :held} = status()
    assert starts!(ctx) == starts

    assert Process.whereis(ClaudeCLI.server()) == nil,
           "no failed live child behind the dead lease"

    assert Reaper.lease(ClaudeCLI.server()) == {:held, reaper}
    assert release_callers(tracer) == [], "the coordinator never calls Reaper.release/1"
  end

  ## 20. A forced failure before the commit

  test "20. a forced failure at the pre-commit step leaves S blocked and the server held", ctx do
    blocked = survivor!(ctx)
    attestation = attestation(blocked, latest_start!(ctx), :survivor)
    fail_resolved_event!()

    result = resolve(blocked, attestation, ctx.admin)

    assert result == {:error, :resolve_timeout},
           "C2-02b2β: a failed write is settled to a definite :resolve_timeout; got #{inspect(result)}"

    sync()
    assert switch!(ctx, blocked.id) == blocked
    assert resolved_events(ctx) == []
    assert status().hold == :held
    assert_held_refusals!("after the failed write")
  end

  ## The release trace (harness control)

  test "the release trace detects a coordinator Reaper.release/1 call (control, passes by design)",
       _ctx do
    tree!()
    await_status!(&is_integer(&1.generation))
    tracer = trace_release!()

    coordinator =
      Coordinator.test_run(
        fn _binding ->
          :ok = Reaper.release(:c202b2b_coordinator_control)
          self()
        end,
        5_000
      )

    assert release_callers(tracer, :c202b2b_coordinator_control) == [coordinator],
           "a forbidden coordinator release would be detected"
  end

  ## Helpers

  # The released server: the latest ready start of this boot, at the desired
  # (from) profile, on the live named server's recorded pid, with that
  # server's own live reaper holding the lease.
  defp assert_reconciled_ready!(latest, released, blocked) do
    server = Process.whereis(ClaudeCLI.server())
    assert is_pid(server), "a live named server"
    reaper = ClaudeCLI.reaper(server)

    assert latest.status == :ready and latest.boot_id == released.boot_id and
             latest.profile_id == blocked.from_profile_id and latest.pid == inspect(server),
           "the latest start is this boot's ready start of the live server at from"

    assert ClaudeCLI.profile(server) == blocked.from_profile_id
    assert is_pid(reaper) and Process.alive?(reaper)
    assert Reaper.lease(ClaudeCLI.server()) == {:held, reaper}, "its own live reaper's lease"
  end

  defp ok?(result), do: match?({:ok, %{switch: %{status: :failed}}}, result)

  defp live_dummy! do
    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp flush_launches do
    receive do
      {:launch_admission, _, _, _} -> flush_launches()
    after
      0 -> :ok
    end
  end

  # The resolution's event append fails inside its transaction.
  defp fail_resolved_event! do
    SdrAgent.Repo.query!("""
    CREATE FUNCTION sdr_test_fail_resolved_event() RETURNS trigger
    LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected resolved event failure'; END $$
    """)

    SdrAgent.Repo.query!(
      "CREATE TRIGGER fail_resolved_event BEFORE INSERT ON audit_events FOR EACH ROW " <>
        "WHEN (NEW.event_type = 'model.profile.switch_resolved') " <>
        "EXECUTE FUNCTION sdr_test_fail_resolved_event()"
    )
  end
end
