defmodule SdrAgent.Agents.ProfileSwitchFenceRaceTest do
  @moduledoc """
  C2-02b1 (#52, slice b1) on independent connections
  (`docs/product/r0/c2-02b1-interface.md`, "The ordering" and "The drain",
  PASS at cda8ee5).
  - **The chain head orders a switch request against every reservation
    and launch.** A fence read is a fresh statement after the head, and it
    never locks the switch row.
  - **The drain revalidates the named switch** in every destructive
    transaction and in its final observation, and holds no lock while it
    waits.

  Every process uses its own non-sandboxed connection. Every task is
  tracked and joined before cleanup, which runs only against a test
  database, as in `SdrAgent.Agents.ModelProfileSwitchRaceTest`.

  RED: the fence and `drain_profile_switch/3` don't exist on the base.
  Assertions name the missing piece after the fixtures.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.AuditCase
  alias SdrAgent.Repo

  @tables ~w(model_profile_switches model_profile_settings audit_accesses audit_events
             audit_chain_heads model_invocations model_call_allocations model_call_grants
             agent_runs failures operations agent_definitions tokens users payloads
             provenance_snapshots tenants)

  setup do
    SdrAgent.AdmissionFixtures.admit_tuples!()
    :ok = Sandbox.checkout(Repo, sandbox: false)
    cleanup!()
    on_exit(fn -> with_connection(&cleanup!/0) end)
    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    admin = AuditCase.human(:admin, tenant)
    grant = AgentsFixtures.grant!(tenant, %{}, admin)
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)

    %{
      tenant: tenant,
      admin: admin,
      grant: grant,
      run: run,
      agent: agent,
      runtime: struct(SdrAgent.Actor, type: :model_runtime, tenant_id: tenant.id)
    }
  end

  ## Presence

  defp fence! do
    assert function_exported?(Admission, :fence_reasons, 0),
           "C2-02b1: Admission.fence_reasons/0 is not implemented"
  end

  defp drain(ctx, switch, timeout_ms \\ 10_000) do
    assert function_exported?(Agents, :drain_profile_switch, 3),
           "C2-02b1: Agents.drain_profile_switch/3 is not implemented"

    Agents.drain_profile_switch(
      switch,
      %{server_generation: switch.server_generation, timeout_ms: timeout_ms},
      actor: ctx.agent
    )
  end

  ## Domain calls

  defp reserve(ctx, key, run \\ nil),
    do:
      Agents.reserve_model_invocation(
        run || ctx.run,
        key |> AgentsFixtures.claude_attrs() |> Map.put(:request, ~s({"k":"#{key}"})),
        actor: ctx.agent
      )

  defp request(ctx, generation \\ 1, to \\ :claude_cli_sonnet, revision \\ 1),
    do:
      Agents.request_profile_switch(
        %{to_profile_id: to, expected_revision: revision, server_generation: generation},
        actor: ctx.admin
      )

  defp fail_switch(ctx, switch),
    do:
      Agents.fail_profile_switch(
        switch,
        %{server_generation: switch.server_generation, failure_reason: "race"},
        actor: ctx.runtime
      )

  defp admit(ctx, id), do: Agents.admit_launch(id, :claude_cli_opus, actor: ctx.agent)
  defp stored(id), do: Ash.get!(ModelInvocation, id, authorize?: false)

  ## 1. Ordering by the chain head

  describe "the chain head orders the request against reservation and launch" do
    test "a request holding the head: the waiting reservation is refused", ctx do
      race(fn ->
        fence!()
        {holder, holder_pid} = hold(fn -> request(ctx) end)
        reserver = on_own_connection(:reserver, fn -> reserve(ctx, "after-request") end)
        reserver_pid = pid_of(:reserver)
        await_blocked_by!(reserver_pid, holder_pid)

        release(holder)
        assert {:ok, {:ok, %{status: :pending}}} = join(holder)

        assert {:error, %Refused{stage: :reservation, reason: :profile_switch_fenced}} =
                 join(reserver)
      end)
    end

    test "a reservation holding the head: the request waits, then the drain sees the row", ctx do
      race(fn ->
        fence!()
        {holder, holder_pid} = hold(fn -> reserve(ctx, "before-request") end)
        requester = on_own_connection(:requester, fn -> request(ctx) end)
        await_blocked_by!(pid_of(:requester), holder_pid)

        release(holder)
        assert {:ok, {:ok, invocation}} = join(holder)
        assert {:ok, switch} = join(requester)
        assert stored(invocation.id).status == :reserved
        assert {:ok, %{refused: 1}} = drain(ctx, switch)
      end)
    end

    test "a request holding the head: the waiting launch is refused", ctx do
      race(fn ->
        fence!()
        assert {:ok, invocation} = reserve(ctx, "launch-after")
        {holder, holder_pid} = hold(fn -> request(ctx) end)
        launcher = on_own_connection(:launcher, fn -> admit(ctx, invocation.id) end)
        await_blocked_by!(pid_of(:launcher), holder_pid)

        release(holder)
        assert {:ok, {:ok, _switch}} = join(holder)

        assert {:error, %Refused{stage: :launch, check: :switch_pending}} = join(launcher)
        assert %{status: :failed, sent_at: nil} = stored(invocation.id)
      end)
    end

    test "a launch holding the head: it is sent, then the request commits", ctx do
      race(fn ->
        fence!()
        assert {:ok, invocation} = reserve(ctx, "launch-before")
        {holder, holder_pid} = hold(fn -> admit(ctx, invocation.id) end)
        requester = on_own_connection(:requester, fn -> request(ctx) end)
        await_blocked_by!(pid_of(:requester), holder_pid)

        release(holder)
        assert {:ok, {:ok, %{status: :sent}}} = join(holder)
        assert {:ok, %{status: :pending}} = join(requester)
      end)
    end

    test "a request that rolls back leaves no fence", ctx do
      race(fn ->
        fence!()
        {holder, holder_pid} = hold(fn -> request(ctx) end, :rollback)
        reserver = on_own_connection(:reserver, fn -> reserve(ctx, "after-rollback") end)
        await_blocked_by!(pid_of(:reserver), holder_pid)

        release(holder)
        join(holder)
        assert {:ok, %{status: :reserved}} = join(reserver)
        assert [[0]] = Repo.query!("SELECT count(*) FROM model_profile_switches").rows
      end)
    end

    test "the fence never locks the switch row", ctx do
      race(fn ->
        fence!()
        assert {:ok, switch} = request(ctx)

        {holder, _pid} =
          hold(fn ->
            Repo.query!("SELECT 1 FROM model_profile_switches WHERE id = $1 FOR UPDATE", [
              Ecto.UUID.dump!(switch.id)
            ])
          end)

        reserver = on_own_connection(:reserver, fn -> reserve(ctx, "switch-row-held") end)

        result = join(reserver, 5_000)

        assert match?({:error, %Refused{reason: :profile_switch_fenced}}, result),
               "the reservation waited on the switch row: #{inspect(result)}"

        release(holder)
        join(holder)
      end)
    end
  end

  ## 6. The drain revalidates the named switch

  describe "the drain revalidates the named switch" do
    for {label, close} <- [failed: :fail, completed: :complete] do
      test "S #{label} while the drain waits: nothing written, later work untouched", ctx do
        race(fn ->
          fence!()
          assert {:ok, row} = reserve(ctx, "pre-s")
          assert {:ok, switch} = request(ctx)
          %{run: run2} = AgentsFixtures.running_run(ctx.tenant)

          {holder, holder_pid} = hold_run(ctx.run)
          drainer = on_own_connection(:drainer, fn -> drain(ctx, switch) end)
          await_blocked_by!(pid_of(:drainer), holder_pid)

          assert {:ok, _} =
                   if(unquote(close) == :fail,
                     do: fail_switch(ctx, switch),
                     else:
                       Agents.complete_profile_switch(switch, %{server_generation: 1},
                         actor: ctx.runtime
                       )
                   )

          assert {:ok, later} = reserve(ctx, "post-s", run2)

          release(holder)
          join(holder)
          assert {:error, :switch_not_open} = join(drainer)
          assert stored(row.id).status == :reserved
          assert stored(later.id).status == :reserved
        end)
      end
    end

    test "a newer pending switch: the drain of S still refuses nothing", ctx do
      race(fn ->
        fence!()
        assert {:ok, row} = reserve(ctx, "pre-s")
        assert {:ok, switch} = request(ctx)

        {holder, holder_pid} = hold_run(ctx.run)
        drainer = on_own_connection(:drainer, fn -> drain(ctx, switch) end)
        await_blocked_by!(pid_of(:drainer), holder_pid)

        assert {:ok, _} = fail_switch(ctx, switch)
        assert {:ok, %{status: :pending}} = request(ctx, 2)

        release(holder)
        join(holder)
        assert {:error, :switch_not_open} = join(drainer)
        assert stored(row.id).status == :reserved
      end)
    end

    # The barrier is the drain's own stage event: it has validated S as
    # pending and is polling the sent row, so only the final observation
    # can see S change.
    test "S changes before the final observation: no success", ctx do
      race(fn ->
        fence!()
        assert {:ok, row} = reserve(ctx, "in-flight")
        assert {:ok, sent} = admit(ctx, row.id)
        assert {:ok, switch} = request(ctx)
        observe_drain!()

        drainer = on_own_connection(:drainer, fn -> drain(ctx, switch) end)
        _ = pid_of(:drainer)
        assert_receive {:drain_stage, :validated}, 10_000
        assert_receive {:drain_stage, :polling}, 10_000
        assert {:ok, _} = fail_switch(ctx, switch)

        assert {:ok, _} =
                 Agents.complete_model_invocation(sent, AgentsFixtures.completion(),
                   actor: ctx.agent
                 )

        assert {:error, :switch_not_open} = join(drainer)
      end)
    end

    # The drain is paused inside its own :polling stage, which it emits
    # outside any transaction between polls.
    test "while it waits for a sent row, the drain holds no lock and no transaction", ctx do
      race(fn ->
        fence!()
        assert {:ok, row} = reserve(ctx, "held-open")
        assert {:ok, sent} = admit(ctx, row.id)
        assert {:ok, switch} = request(ctx)
        pause_drain_at!(:polling)

        drainer = on_own_connection(:drainer, fn -> drain(ctx, switch) end)
        drainer_pid = pid_of(:drainer)
        assert_receive {:drain_paused, :polling, drain_process}, 10_000

        assert idle_without_locks?(drainer_pid),
               "the drain waited inside a transaction or holding a lock"

        assert {:ok, _} =
                 Agents.complete_model_invocation(sent, AgentsFixtures.completion(),
                   actor: ctx.agent
                 )

        # Every later pause (one per poll) is released.
        release_pauses(drain_process)
        assert {:ok, %{refused: 0}} = join(drainer)
      end)
    end

    # Deadline 1000 ms; one of two sent rows settles halfway (progress).
    # Unreset, the drain ends near 1000 ms; reset by progress, near 1500 ms.
    test "progress doesn't reset the deadline", ctx do
      race(fn ->
        fence!()
        assert {:ok, first} = reserve(ctx, "progress-1")
        assert {:ok, second} = reserve(ctx, "progress-2")
        assert {:ok, sent} = admit(ctx, first.id)
        assert {:ok, _sent} = admit(ctx, second.id)
        assert {:ok, switch} = request(ctx)
        observe_drain!()

        drainer = on_own_connection(:drainer, fn -> drain(ctx, switch, 1_000) end)
        _ = pid_of(:drainer)
        assert_receive {:drain_stage, :validated}, 10_000
        started = System.monotonic_time(:millisecond)
        assert_receive {:drain_stage, :polling}, 10_000
        Process.sleep(500)

        assert {:ok, _} =
                 Agents.complete_model_invocation(sent, AgentsFixtures.completion(),
                   actor: ctx.agent
                 )

        assert {:error, :drain_timeout, %{reserved: 0, sent: 1}} = join(drainer)
        elapsed = System.monotonic_time(:millisecond) - started
        assert elapsed < 1_300, "the deadline was reset by progress (#{elapsed} ms)"
      end)
    end

    test "a failed observation is drain_observation_failed, never zero work", ctx do
      race(fn ->
        fence!()
        assert {:ok, row} = reserve(ctx, "observed")
        assert {:ok, _sent} = admit(ctx, row.id)
        assert {:ok, switch} = request(ctx)
        observe_drain!()

        drainer = on_own_connection(:drainer, fn -> drain(ctx, switch) end)
        assert_receive {:drain_stage, :polling}, 10_000

        try do
          # The drain's next count query fails (disposable test DB only).
          Repo.query!("ALTER TABLE model_invocations RENAME COLUMN status TO status_hidden")
          assert {:error, :drain_observation_failed} = join(drainer)
        after
          Repo.query!("ALTER TABLE model_invocations RENAME COLUMN status_hidden TO status")
        end

        assert {:ok, [%{status: :pending}]} = Agents.list_profile_switches(actor: ctx.admin)
      end)
    end
  end

  describe "the drain against a live launch of the same row" do
    test "the launch first: it is refused by the fence; the drain then refuses nothing", ctx do
      race(fn ->
        fence!()
        assert {:ok, row} = reserve(ctx, "contended")
        assert {:ok, switch} = request(ctx)

        {holder, holder_pid} = hold(fn -> admit(ctx, row.id) end)
        drainer = on_own_connection(:drainer, fn -> drain(ctx, switch) end)
        await_blocked_by!(pid_of(:drainer), holder_pid)

        release(holder)
        assert {:ok, {:error, %Refused{stage: :launch, check: :switch_pending}}} = join(holder)
        assert {:ok, %{refused: 0}} = join(drainer)
        assert %{status: :failed, sent_at: nil} = stored(row.id)
      end)
    end

    # The drain takes the run, the invocation and then waits on the head
    # (held here), so a launch of the same row waits on the drain's run
    # lock; after the drain commits, the launch finds the row refused.
    test "the drain first: the launch waits on the drain, then is refused as not reserved",
         ctx do
      race(fn ->
        fence!()
        assert {:ok, row} = reserve(ctx, "drain-first")
        assert {:ok, switch} = request(ctx)

        {holder, holder_pid} = hold(fn -> lock_head!(ctx) end)
        drainer = on_own_connection(:drainer, fn -> drain(ctx, switch) end)
        drainer_pid = pid_of(:drainer)
        await_blocked_by!(drainer_pid, holder_pid)

        launcher = on_own_connection(:launcher, fn -> admit(ctx, row.id) end)
        await_blocked_by!(pid_of(:launcher), drainer_pid)

        release(holder)
        join(holder)
        assert {:ok, %{refused: 1}} = join(drainer)
        assert {:error, :invocation_not_reserved} = join(launcher)
        assert %{status: :failed, sent_at: nil} = stored(row.id)
        assert [[0]] = sent_events(row)
        assert [[1]] = run_failures(ctx.run)
      end)
    end
  end

  ## Operation settlement contention (MF2 of the interface; RED review MF3)

  describe "the drain and a worker settling the same Operation" do
    for resolved? <- [false, true] do
      test "held contention: one terminal outcome, one cause, one live item (resolved: #{resolved?})",
           ctx do
        race(fn ->
          fence!()
          %{run: run, operation: operation} = AgentsFixtures.operated_run(ctx.tenant)
          assert {:ok, _row} = reserve(ctx, "settle-race", run)
          assert {:ok, switch} = request(ctx)

          # The drain pauses after its refusal transaction has committed and
          # released its locks (stage :refused), before the Operation's own
          # transaction. Only then does the holder take the Operation, so
          # the drain's settlement and the worker contend on it.
          pause_drain_at!(:refused)
          drainer = on_own_connection(:drainer, fn -> drain(ctx, switch) end)
          drainer_pid = pid_of(:drainer)
          assert_receive {:drain_paused, :refused, drain_process}, 10_000

          {:ok, stopped} = Agents.get_run(run.id, actor: ctx.agent)
          assert {stopped.status, stopped.status_reason} == {:failed, :model_not_admitted}

          {holder, holder_pid} = hold(fn -> lock_operation!(operation) end)
          send(drain_process, :continue)
          await_blocked_by!(drainer_pid, holder_pid)

          worker =
            on_own_connection(:worker, fn ->
              SdrAgent.SDR.AgentWorker.fail_operation(operation, stopped, ctx.agent)
            end)

          # Row-lock waiters queue: the worker waits behind the holder or
          # behind the drain already queued on the same Operation row.
          await_blocked_by_any!(pid_of(:worker), [holder_pid, drainer_pid])
          if unquote(resolved?), do: resolve!(ctx, stopped.attention_failure_id)

          release(holder)
          join(holder)
          assert {:ok, %{refused: 1}} = join(drainer)
          assert :ok = join(worker)

          {:ok, settled} = SdrAgent.Operations.get_operation(operation.id, actor: ctx.admin)
          assert settled.status in [:failed, :discarded]
          # max_attempts 1: one fail writes failed, then discarded.
          assert operation_events(operation) == %{failed: 1, discarded: 1}
          assert live_items(ctx) == 1

          if unquote(resolved?),
            do: refute(settled.last_failure_id == stopped.attention_failure_id),
            else: assert(settled.last_failure_id == stopped.attention_failure_id)
        end)
      end
    end
  end

  ## The end-to-end deadline (GREEN review MF1, Codex a1071e0e)

  describe "the drain's one deadline" do
    # Held run lock for ~300 ms, then the head until ~650 ms, against a
    # 500 ms drain: each wait alone fits the original allowance, the sum
    # doesn't. The refusal must not commit after the deadline.
    test "waits across several locks never commit work after the deadline", ctx do
      race(fn ->
        fence!()
        assert {:ok, row} = reserve(ctx, "multi-lock")
        assert {:ok, switch} = request(ctx)

        {run_holder, run_holder_pid} = hold_tagged(:run_holder, fn -> hold_run_lock!(ctx.run) end)
        {head_holder, _} = hold_tagged(:head_holder, fn -> lock_head!(ctx) end)

        started = System.monotonic_time(:millisecond)

        # The drain's own return time, not the test's join (the test keeps
        # the head held past the deadline).
        drainer =
          on_own_connection(:drainer, fn ->
            {drain(ctx, switch, 500), System.monotonic_time(:millisecond)}
          end)

        await_blocked_by!(pid_of(:drainer), run_holder_pid)
        Process.sleep(300)
        release(run_holder)
        join(run_holder)
        Process.sleep(350)
        release(head_holder)
        join(head_holder)

        {result, returned_at} = join(drainer)
        elapsed = returned_at - started

        assert stored(row.id).status == :reserved, "a refusal committed after the deadline"
        assert match?({:error, :drain_timeout, _}, result), inspect(result)
        assert elapsed < 600, "the drain returned after its deadline (#{elapsed} ms)"
      end)
    end

    test "a blocked observation at the deadline is not waited for", ctx do
      race(fn ->
        fence!()
        assert {:ok, _row} = reserve(ctx, "blocked-observation")
        assert {:ok, switch} = request(ctx)

        {holder, _pid} =
          hold_tagged(:table_holder, fn ->
            Repo.query!("LOCK TABLE model_invocations IN ACCESS EXCLUSIVE MODE")
          end)

        started = System.monotonic_time(:millisecond)
        drainer = on_own_connection(:drainer, fn -> drain(ctx, switch, 200) end)
        _ = pid_of(:drainer)
        result = Task.yield(drainer, 1_500)
        elapsed = System.monotonic_time(:millisecond) - started
        release(holder)
        join(holder)

        assert match?({:ok, {:error, :drain_timeout, _}}, result),
               "the drain still waited at #{elapsed} ms: #{inspect(result)}"

        assert elapsed < 700
        # Counts never observed within the deadline are reported as unknown.
        {:ok, {:error, :drain_timeout, counts}} = result
        assert counts == %{reserved: nil, sent: nil}
      end)
    end

    test "a final observation after the deadline is a timeout, not success", ctx do
      race(fn ->
        fence!()
        assert {:ok, row} = reserve(ctx, "late-final")
        assert {:ok, sent} = admit(ctx, row.id)
        assert {:ok, switch} = request(ctx)
        pause_drain_at!(:polling)

        drainer = on_own_connection(:drainer, fn -> drain(ctx, switch, 400) end)
        assert_receive {:drain_paused, :polling, drain_process}, 10_000

        assert {:ok, _} =
                 Agents.complete_model_invocation(sent, AgentsFixtures.completion(),
                   actor: ctx.agent
                 )

        Process.sleep(500)
        release_pauses(drain_process)
        assert {:error, :drain_timeout, _counts} = join(drainer)
      end)
    end
  end

  ## Pool acquisition inside the deadline (GREEN re-review MF1, Codex 992eaec6)

  describe "the drain's deadline includes connection checkout" do
    # A separate, production-shaped pool (DBConnection.ConnectionPool, one
    # connection, default queue settings) against this disposable test DB,
    # with its only connection held. The domain call itself is timed.
    test "a saturated regular pool: the drain still returns at its deadline", ctx do
      race(fn ->
        fence!()
        assert {:ok, switch} = request(ctx)

        {:ok, pool} =
          Repo.start_link(name: nil, pool: DBConnection.ConnectionPool, pool_size: 1)

        parent = self()

        try do
          holder =
            Task.async(fn ->
              Repo.put_dynamic_repo(pool)

              Repo.transaction(fn ->
                Repo.query!("SELECT 1")
                send(parent, :pool_held)

                receive do
                  :release -> :ok
                after
                  5_000 -> :timeout
                end
              end)
            end)

          Process.put(:race_tasks, [holder | Process.get(:race_tasks, [])])
          assert_receive :pool_held, 5_000

          drainer =
            Task.async(fn ->
              Repo.put_dynamic_repo(pool)
              started = System.monotonic_time(:millisecond)
              result = drain(ctx, switch, 200)
              {result, System.monotonic_time(:millisecond) - started}
            end)

          Process.put(:race_tasks, [drainer | Process.get(:race_tasks, [])])
          at_600 = Task.yield(drainer, 600)
          send(holder.pid, :release)
          Task.await(holder, 5_000)

          assert match?({:ok, {_result, _elapsed}}, at_600),
                 "the drain still waited for a pool connection at 600 ms"

          {:ok, {result, elapsed}} = at_600
          assert match?({:error, :drain_timeout, _}, result), inspect(result)
          assert elapsed < 400, "the drain returned after its deadline (#{elapsed} ms)"
        after
          stop_tasks!()
          Supervisor.stop(pool)
        end
      end)
    end
  end

  ## Settlement revalidates the named switch (GREEN review MF2)

  describe "the drain's Operation settlement revalidates S" do
    test "a retried drain doesn't settle after S closed", ctx do
      race(fn ->
        fence!()
        %{run: run, operation: operation} = AgentsFixtures.operated_run(ctx.tenant)
        assert {:ok, row} = reserve(ctx, "retry-stale", run)
        assert {:ok, switch} = request(ctx)

        # The documented crash gap: the row refused and its run stopped,
        # its Operation not yet settled.
        assert {:ok, {:refused, _}} =
                 Agents.refuse_reserved_for_switch(row.id, switch.id, 1, ctx.agent)

        pause_drain_at!(:validated)
        drainer = on_own_connection(:drainer, fn -> drain(ctx, switch) end)
        assert_receive {:drain_paused, :validated, drain_process}, 10_000
        assert {:ok, _} = fail_switch(ctx, switch)
        release_pauses(drain_process)

        assert {:error, :switch_not_open} = join(drainer)
        assert operation_status(operation) == :running
      end)
    end

    test "S closing between the refusal and its settlement: nothing settled", ctx do
      race(fn ->
        fence!()
        %{run: run, operation: operation} = AgentsFixtures.operated_run(ctx.tenant)
        assert {:ok, _row} = reserve(ctx, "refused-then-stale", run)
        assert {:ok, switch} = request(ctx)

        pause_drain_at!(:refused)
        drainer = on_own_connection(:drainer, fn -> drain(ctx, switch) end)
        assert_receive {:drain_paused, :refused, drain_process}, 10_000
        assert {:ok, _} = fail_switch(ctx, switch)
        release_pauses(drain_process)

        assert {:error, :switch_not_open} = join(drainer)
        assert operation_status(operation) == :running
      end)
    end
  end

  ## Drain observation, probes and queries

  # The drain's stage events (metadata only), sent to this test process.
  defp observe_drain! do
    id = "c202b1-drain-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        id,
        [:sdr_agent, :profile_switch, :drain],
        fn _event, _measurements, %{stage: stage}, _config ->
          send(parent, {:drain_stage, stage})
        end,
        nil
      )

    Process.put(:telemetry_handlers, [id | Process.get(:telemetry_handlers, [])])
  end

  # Blocks the drain's process inside its own stage event `stage` until this
  # test sends `:continue` (the handler runs in the drain's process; it
  # observes a lifecycle point, it authorizes nothing).
  defp pause_drain_at!(stage) do
    id = "c202b1-pause-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        id,
        [:sdr_agent, :profile_switch, :drain],
        fn _event, _measurements, meta, _config -> pause(meta, stage, parent) end,
        nil
      )

    Process.put(:telemetry_handlers, [id | Process.get(:telemetry_handlers, [])])
  end

  defp pause(%{stage: stage}, stage, parent) do
    send(parent, {:drain_paused, stage, self()})

    receive do
      :continue -> :ok
    after
      30_000 -> :ok
    end
  end

  defp pause(_meta, _stage, _parent), do: :ok

  # Keeps answering the drain's pauses until it stops pausing.
  defp release_pauses(drain_process) do
    send(drain_process, :continue)

    receive do
      {:drain_paused, _stage, ^drain_process} -> release_pauses(drain_process)
    after
      500 -> :ok
    end
  end

  defp operation_status(operation) do
    [[status]] =
      Repo.query!("SELECT status FROM operations WHERE id = $1", [Ecto.UUID.dump!(operation.id)]).rows

    String.to_existing_atom(status)
  end

  # As `hold/2`, under its own tag, so one test can hold several locks.
  defp hold_tagged(tag, fun) do
    task =
      on_own_connection(tag, fn ->
        Audit.transaction(fn -> held(fun, :commit) end)
      end)

    pid = pid_of(tag)
    assert_receive {:held, _}, 10_000
    {task, pid}
  end

  defp hold_run_lock!(run) do
    Repo.query!("SELECT 1 FROM agent_runs WHERE id = $1 FOR UPDATE", [Ecto.UUID.dump!(run.id)])
  end

  defp lock_head!(ctx) do
    Repo.query!("SELECT 1 FROM audit_chain_heads WHERE tenant_id = $1 FOR UPDATE", [
      Ecto.UUID.dump!(ctx.tenant.id)
    ])
  end

  defp lock_operation!(operation) do
    Repo.query!("SELECT 1 FROM operations WHERE id = $1 FOR UPDATE", [
      Ecto.UUID.dump!(operation.id)
    ])
  end

  defp resolve!(ctx, failure_id) do
    {:ok, failure} = SdrAgent.Operations.get_failure(failure_id, actor: ctx.admin)

    {:ok, _} =
      SdrAgent.Operations.resolve_failure(failure, %{resolution_note: "seen"}, actor: ctx.admin)
  end

  defp live_items(ctx) do
    {:ok, items} = SdrAgent.Operations.list_attention(actor: ctx.admin)
    length(items)
  end

  defp sent_events(row) do
    Repo.query!(
      "SELECT count(*) FROM audit_events WHERE event_type = 'model.invocation.sent' " <>
        "AND model_invocation_id = $1",
      [Ecto.UUID.dump!(row.id)]
    ).rows
  end

  defp run_failures(run) do
    Repo.query!("SELECT count(*) FROM failures WHERE subject_id::text = $1", [run.id]).rows
  end

  defp operation_events(operation) do
    for type <- [:failed, :discarded], into: %{} do
      [[count]] =
        Repo.query!(
          "SELECT count(*) FROM audit_events WHERE subject_id = $1 AND event_type = $2",
          [operation.id, "operations.operation.#{type}"]
        ).rows

      {type, count}
    end
  end

  ## Connections, holds and cleanup

  # Runs `fun` in a transaction on its own connection and holds it open
  # until `release/1`; then commits, or rolls back with `:rollback`.
  # Returns the task and its backend pid.
  defp hold(fun, outcome \\ :commit) do
    task =
      on_own_connection(:holder, fn ->
        Audit.transaction(fn -> held(fun, outcome) end)
      end)

    pid = pid_of(:holder)
    assert_receive {:held, _}, 10_000
    {task, pid}
  end

  defp held(fun, outcome) do
    result = fun.()
    send(holder_parent(), {:held, self()})

    receive do
      :release -> :ok
    after
      30_000 -> :timeout
    end

    if outcome == :rollback, do: Repo.rollback(:test_rollback), else: result
  end

  defp hold_run(run) do
    hold(fn ->
      Repo.query!("SELECT 1 FROM agent_runs WHERE id = $1 FOR UPDATE", [Ecto.UUID.dump!(run.id)])
    end)
  end

  defp holder_parent, do: Process.get(:test_parent)

  # `hold/2` returns `{task, backend_pid}`; callers pass the task.
  defp release(%Task{} = task), do: send(task.pid, :release)

  defp join(task_or_hold, timeout \\ 15_000)
  defp join({task, _pid}, timeout), do: Task.await(task, timeout)
  defp join(%Task{} = task, timeout), do: Task.await(task, timeout)

  defp on_own_connection(tag, fun) do
    parent = self()

    task =
      Task.async(fn ->
        Process.put(:test_parent, parent)

        with_connection(fn ->
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {tag, pid})
          fun.()
        end)
      end)

    Process.put(:race_tasks, [task | Process.get(:race_tasks, [])])
    task
  end

  defp pid_of(tag) do
    assert_receive {^tag, pid}, 10_000
    pid
  end

  defp await_blocked_by!(waiter, holder) do
    blocked =
      Enum.find_value(1..250, fn _ ->
        Process.sleep(20)
        blocked_by?(waiter, holder)
      end)

    assert blocked, "backend #{waiter} was never blocked by #{holder}"
  end

  defp await_blocked_by_any!(waiter, holders) do
    blocked =
      Enum.find_value(1..250, fn _ ->
        Process.sleep(20)
        Enum.any?(holders, &blocked_by?(waiter, &1)) || nil
      end)

    assert blocked, "backend #{waiter} was never blocked by any of #{inspect(holders)}"
  end

  defp blocked_by?(waiter, holder) do
    case Repo.query!("SELECT pg_blocking_pids($1)", [waiter]).rows do
      [[pids]] -> if holder in pids, do: true
      _ -> nil
    end
  end

  defp idle_without_locks?(pid) do
    [[state]] =
      Repo.query!("SELECT state FROM pg_stat_activity WHERE pid = $1", [pid]).rows

    [[locks]] =
      Repo.query!(
        "SELECT count(*) FROM pg_locks l JOIN pg_class c ON c.oid = l.relation " <>
          "WHERE l.pid = $1 AND l.granted AND c.relname IN " <>
          "('audit_chain_heads', 'model_invocations', 'agent_runs', 'model_profile_switches', " <>
          "'model_profile_settings', 'operations', 'failures')",
        [pid]
      ).rows

    state in ["idle", "active"] and state != "idle in transaction" and locks == 0
  end

  # Cleanup runs only against a test database (`sdr_agent_test` or a
  # partition copy), checked inside `cleanup!/0` before its first SQL.
  @doc false
  def truncatable?(database) when is_binary(database),
    do: Regex.match?(~r/\Asdr_agent_test[a-z0-9_]*\z/, database)

  def truncatable?(_database), do: false

  test "the cleanup guard refuses anything but a test database" do
    for name <- ["sdr_agent_dev", "sdr_agent_calibration", "postgres", nil, ""],
        do: refute(truncatable?(name))

    assert truncatable?("sdr_agent_test_c202b1")
  end

  # Every test body runs here: its tasks (holder, reserver, requester,
  # launcher, drainer) are stopped and joined before the test ends, pass or
  # fail, so none holds a connection or lock when on_exit truncates.
  defp race(fun) do
    fun.()
  after
    stop_tasks!()
    for id <- Process.delete(:telemetry_handlers) || [], do: :telemetry.detach(id)
  end

  defp stop_tasks! do
    for task <- Process.get(:race_tasks, []), do: Task.shutdown(task, 5_000)
    Process.delete(:race_tasks)
  end

  defp with_connection(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(Repo)
    end
  end

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
