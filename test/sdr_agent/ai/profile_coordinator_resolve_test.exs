defmodule SdrAgent.AI.ProfileCoordinatorResolveTest do
  @moduledoc """
  C2-02b2β RED (`docs/product/r0/c2-02b2b-interface.md` draft 4, interface
  and entity PASS at `e60943c`), section 8 "Coordinator and runtime": tests
  15, 16, 17 (a request expired in a blocked mailbox), 18, 19 (a death after
  the commit), 20 (a forced failure before the commit) and 21, plus the
  binding obligations on the hard conflict, current runtime facts, failed
  lookups and `Reaper.release/1` (`codex-c202b2beta-e60943c-interface-pass.md`).

  Every switch is blocked by the real b2α coordinator
  (`SdrAgent.Test.ResolveHarness`). Test-build-only seams chosen for the
  cases the contract leaves to a seam: the coordinator faults `observe: fn
  -> :read | :unavailable end` (the lease and hold observation) and
  `replay_read: fn -> :read | :unavailable end` (the coordinator's stored
  replay read); an unacknowledged hold and a busy coordinator are set on
  b2α's own state fields (`hold_state`, `op`, `reconcile`) with
  `:sys.replace_state/2`. The operator path (`Reaper.release/1`) is always
  run by the test; a trace proves the coordinator never calls it. Shared SQL
  sandbox; the fake CLI; no model call.

  Passes by design: the held refusals before a resolution (test 21's first
  step, b2α's hold) are asserted inside tests that fail on b2β behavior.
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

    test "a failed coordinator replay read never counts as absent or resolved", ctx do
      {:ok, gate} = Agent.start_link(fn -> :read end)
      blocked = dead_holder!(ctx, faults: [replay_read: fn -> Agent.get(gate, & &1) end])
      attestation = attestation(blocked, latest_start!(ctx), :dead_holder)

      Agent.update(gate, fn _ -> :unavailable end)
      before = resolve(blocked, attestation, ctx.admin)

      assert match?({:error, _}, before) and before != {:error, :switch_not_blocked},
             "C2-02b2β: a failed replay read must refuse, never proceed as absent; got #{inspect(before)}"

      assert switch!(ctx, blocked.id) == blocked
      assert resolved_events(ctx) == []

      Agent.update(gate, fn _ -> :read end)
      assert ok?(resolve(blocked, attestation, ctx.admin))
      quiet!()

      Agent.update(gate, fn _ -> :unavailable end)
      again = resolve(blocked, attestation, ctx.admin)

      refute match?({:ok, _}, again) or again == {:error, :switch_not_blocked},
             "a failed replay read is never a replay or a resolved refusal; got #{inspect(again)}"

      assert length(resolved_events(ctx)) == 1
    end
  end

  ## 16. Busy

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

    sync()
    quiet!()
    assert switch!(ctx, blocked.id) == blocked, "nothing was queued"
    assert resolved_events(ctx) == []
    assert ok?(resolve(blocked, attestation, ctx.admin))
  end

  ## 17. The deadline (a request expired in a blocked mailbox)

  test "17. a request expired in a blocked mailbox does nothing; held calls are refused", ctx do
    blocked = survivor!(ctx)
    attestation = attestation(blocked, latest_start!(ctx), :survivor)
    assert_held_refusals!("before the resolution (passes by design)")
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
    Process.sleep(1_000)
    assert_held_refusals!("while the request waits")
    result = await_task(caller, 25_000)
    elapsed = System.monotonic_time(:millisecond) - started
    send(coordinator, :go)
    Task.await(blocker, 10_000)

    assert result == {:error, :resolve_timeout},
           "C2-02b2β: a request never dequeued before its deadline is a definite " <>
             ":resolve_timeout; got #{inspect(result)}"

    assert elapsed >= 14_500 and elapsed < 19_000,
           "the 15 s deadline, then settlement: #{elapsed} ms"

    # Dequeued after its deadline: refused, nothing else.
    sync()
    quiet!()
    assert switch!(ctx, blocked.id) == blocked
    assert resolved_events(ctx) == []
    assert status().hold == :held
    assert_held_refusals!("after the expired request")
  end

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

      assert ClaudeCLI.profile(Process.whereis(ClaudeCLI.server())) == blocked.from_profile_id
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

      await_status!(&(&1.hold == :released), 20_000)
      current = Process.whereis(ClaudeCLI.server())
      fresh = latest_start!(ctx)

      assert current == server or
               (fresh.generation > latest.generation and fresh.ready_evidence == :spawn_preflight),
             "adopted, or replaced by a fresh preflighted start"

      assert ClaudeCLI.profile(current) == blocked.from_profile_id
      refute_received {:launch_admission, _, _, _}, "zero launches"
      assert release_callers(tracer) == []
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
    quiet!()
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

  ## Helpers

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
