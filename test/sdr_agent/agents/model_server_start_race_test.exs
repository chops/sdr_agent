defmodule SdrAgent.Agents.ModelServerStartRaceTest do
  @moduledoc """
  C2-02b2α RED on independent connections (interface and entity PASS at
  `c00ed69`, sections 1a and 1b; binding obligations 2 and 3).

    * **R2, the lock order.** The allocator takes the counter `FOR UPDATE`
      before its insert's FK `KEY SHARE` on S; finalizers take setting →
      counter `FOR SHARE` → switch. Neither order can deadlock, and a
      waiter re-reads the latest start after its lock.
    * **D3-1, a call's authority lasts exactly the call.** A coordinator
      ledger call is bounded end to end by its budget (consecutive locks
      included), commits nothing past it, and a coordinator killed
      mid-call never commits; the next boot's first allocation proceeds
      within the bound.
    * **The first counter row and the allocation conflict** roll back
      whole.

  The coordinator runs in the test build's `manual: true` mode, and
  `Coordinator.test_run/2` runs each ledger call in the coordinator
  process, which checks out its own non-sandboxed connection. Competing
  transactions are raw SQL holders on their own connections (the
  coordinator is the only b2 writer by design, so a holder stands for a
  finalizer or allocator mid-transaction, or a killed coordinator's
  backend). Every task is joined before cleanup, which runs only against a
  test database. Presence-guarded: on the b1 head each test fails on an
  explicit assertion after its fixtures.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents
  alias SdrAgent.Audit
  alias SdrAgent.Repo

  @coordinator SdrAgent.AI.ModelProvider.Coordinator
  @profile_supervisor SdrAgent.AI.ModelProvider.ProfileSupervisor
  @tables ~w(model_server_starts model_server_counters model_profile_switches
             model_profile_settings audit_accesses audit_events audit_chain_heads
             model_call_allocations model_call_grants failures operations model_invocations
             agent_runs agent_definitions tokens users payloads provenance_snapshots tenants)

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    cleanup!()
    on_exit(fn -> with_connection(&cleanup!/0) end)

    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")

    %{
      tenant: tenant,
      admin: SdrAgent.AuditCase.new_human(:admin, tenant),
      runtime: struct(SdrAgent.Actor, type: :model_runtime, tenant_id: tenant.id)
    }
  end

  ## R2

  describe "R2: the lock order" do
    # MF3 (Codex 5f57e6ac): each holder first takes only its FIRST lock;
    # the contender is shown waiting; only then does the holder take its
    # SECOND lock. With the approved order the second lock is free; with
    # the inversion it is held by the contender and the step deadlocks or
    # times out. "the interleaving harness tells the orders apart" proves
    # that sensitivity with raw-SQL contenders in both orders.
    test "an allocation waiting on the counter holds no switch lock", ctx do
      race(fn ->
        binding = coordinator!()
        switch = switched!(ctx, binding)

        # A finalizer mid-transaction: setting, counter FOR SHARE; next, the switch.
        {holder, holder_pid} =
          hold(fn ->
            lock_setting!(ctx)
            lock_counter!(ctx, "FOR SHARE")
          end)

        allocation =
          coordinator_call(:allocator, fn ->
            call(:allocate_server_start, [
              %{
                boot_id: binding.boot_id,
                profile_id: :claude_cli_sonnet,
                reason: :activation,
                switch_id: switch.id
              },
              [actor: ctx.runtime]
            ])
          end)

        await_blocked_by!(pid_of(:allocator), holder_pid)

        assert {:ok, waited} = step(holder, fn -> lock_switch!(switch, "FOR UPDATE") end),
               "the waiting allocator holds the switch: it took the FK before the counter"

        assert waited < 500
        release(holder)
        join(holder)

        assert {:ok, %{reason: :activation}} = join(allocation)
      end)
    end

    test "a finalizer waiting on the counter holds no switch lock, then re-reads latest", ctx do
      race(fn ->
        binding = coordinator!()
        switch = switched!(ctx, binding)
        candidate = ready_activation!(ctx, binding, switch)

        # An allocation mid-transaction: counter FOR UPDATE; next, the FK's
        # KEY SHARE on S and a newer latest start.
        {holder, holder_pid} = hold(fn -> lock_counter!(ctx, "FOR UPDATE") end)

        finalizer =
          coordinator_call(:finalizer, fn -> complete(ctx, binding, switch, candidate) end)

        await_blocked_by!(pid_of(:finalizer), holder_pid)

        assert {:ok, waited} =
                 step(holder, fn ->
                   lock_switch!(switch, "FOR KEY SHARE")
                   insert_newer_start!(ctx, binding)
                 end),
               "the waiting finalizer holds the switch: it locked S before the counter"

        assert waited < 500
        release(holder)
        join(holder)

        assert {:error, _} = join(finalizer), "the waiter re-read latest: the candidate is stale"
        assert switch_status(switch) == "pending"
      end)
    end

    test "the interleaving harness tells the approved order from the inversion" do
      race(fn ->
        harness_tables!()

        for {side, order, expected} <- [
              {:allocator, :approved, :ok},
              {:allocator, :inverted, :error},
              {:finalizer, :approved, :ok},
              {:finalizer, :inverted, :error}
            ] do
          {holder, holder_pid} = hold(holder_first(side))
          contender = raw_contender(side, order)
          await_blocked_by!(pid_of(:contender), holder_pid)

          # Only a free second lock passes: a deadlock may abort the
          # contender instead, and the holder then waits ~deadlock_timeout.
          result = step(holder, holder_second(side))
          outcome = if match?({:ok, ms} when ms < 500, result), do: :ok, else: :error
          assert outcome == expected, "#{side} #{order}: #{inspect(result)}"

          release(holder)
          join(holder)
          join(contender)
        end
      end)
    end

    test "the first counter row: a waiter proceeds after the first row commits or rolls back",
         ctx do
      for outcome <- [:commit, :rollback] do
        race(fn ->
          cleanup_ledger!()
          binding = coordinator!(outcome)

          {holder, holder_pid} = hold(fn -> insert_counter!(ctx) end, outcome)

          first =
            coordinator_call(:first, fn ->
              call(:allocate_server_start, [
                %{boot_id: binding.boot_id, profile_id: :claude_cli_opus, reason: :boot},
                [actor: ctx.runtime]
              ])
            end)

          await_blocked_by!(pid_of(:first), holder_pid)
          release(holder)
          join(holder)

          assert {:ok, %{generation: 1}} = join(first), "after #{outcome}"
        end)
      end
    end

    test "an allocation conflict rolls the whole transaction back", ctx do
      race(fn ->
        binding = coordinator!()
        booted = booted!(ctx, binding)
        insert_conflicting_start!(ctx, booted.generation + 1)
        before = {counter(ctx), events(ctx, "model.server.start_allocated")}

        result =
          in_coordinator(fn _ ->
            with_connection(fn ->
              call(:allocate_server_start, [
                %{boot_id: binding.boot_id, profile_id: :claude_cli_opus, reason: :replacement},
                [actor: ctx.runtime]
              ])
            end)
          end)

        assert {:error, :allocation_conflict} = result
        assert {counter(ctx), events(ctx, "model.server.start_allocated")} == before
      end)
    end
  end

  ## D3-1

  describe "D3-1: a call's bound and authority" do
    test "consecutive lock waits share one budget; nothing commits past it", ctx do
      race(fn ->
        binding = coordinator!()
        switch = switched!(ctx, binding)
        candidate = ready_activation!(ctx, binding, switch)

        {setting_holder, setting_pid} = hold(fn -> lock_setting!(ctx) end)
        {counter_holder, _counter_pid} = hold(fn -> lock_counter!(ctx, "FOR UPDATE") end)

        started = System.monotonic_time(:millisecond)

        finalizer =
          coordinator_call(:finalizer, fn ->
            result = complete(ctx, binding, switch, candidate, budget_ms: 500)
            {result, System.monotonic_time(:millisecond)}
          end)

        await_blocked_by!(pid_of(:finalizer), setting_pid)
        Process.sleep(300)
        release(setting_holder)
        join(setting_holder)
        Process.sleep(350)
        release(counter_holder)
        join(counter_holder)

        {result, returned_at} = join(finalizer)
        assert {:error, :ledger_timeout} = result
        assert returned_at - started < 650, "500 ms budget took #{returned_at - started} ms"
        assert switch_status(switch) == "pending"
        assert events(ctx, "model.profile.switch_completed") == 0
      end)
    end

    test "a coordinator killed mid-call never commits; the next boot proceeds within the bound",
         ctx do
      race(fn ->
        binding = coordinator!()
        switch = switched!(ctx, binding)
        candidate = ready_activation!(ctx, binding, switch)
        {holder, holder_pid} = hold(fn -> lock_switch!(switch, "FOR UPDATE") end)

        _doomed =
          coordinator_call(:doomed, fn ->
            complete(ctx, binding, switch, candidate, budget_ms: 1_500)
          end)

        await_blocked_by!(pid_of(:doomed), holder_pid)
        kill_coordinator!()

        next = await_new_boot!(binding.boot_id)
        started = System.monotonic_time(:millisecond)

        claim =
          coordinator_call(:claim, fn ->
            call(:allocate_server_start, [
              %{boot_id: next.boot_id, profile_id: :claude_cli_opus, reason: :replacement},
              [actor: ctx.runtime]
            ])
          end)

        assert {:ok, %{boot_id: boot}} = join(claim)
        assert boot == next.boot_id
        assert System.monotonic_time(:millisecond) - started < 2_500

        release(holder)
        join(holder)
        assert switch_status(switch) == "pending"
        assert events(ctx, "model.profile.switch_completed") == 0
      end)
    end
  end

  ## Helpers

  defp call(fun, args) do
    assert function_exported?(Agents, fun, length(args)),
           "C2-02b2α: SdrAgent.Agents.#{fun}/#{length(args)} is not implemented"

    apply(Agents, fun, args)
  end

  defp coordinator!(id \\ :profile_tree) do
    for module <- [@profile_supervisor, @coordinator] do
      assert Code.ensure_loaded?(module), "C2-02b2α: #{inspect(module)} is not implemented"
    end

    assert function_exported?(@coordinator, :test_run, 2),
           "C2-02b2α: the test-build Coordinator.test_run/2 seam is missing"

    start_supervised!({@profile_supervisor, manual: true}, id: id)
    in_coordinator(& &1)
  end

  defp in_coordinator(fun, timeout \\ 10_000), do: apply(@coordinator, :test_run, [fun, timeout])

  # Runs `fun` in the coordinator, on its own connection, from a tracked
  # task; reports the coordinator's backend pid under `tag`.
  defp coordinator_call(tag, fun) do
    parent = self()

    task = Task.async(fn -> coordinator_run(fn _binding -> reported(parent, tag, fun) end) end)

    Process.put(:race_tasks, [task | Process.get(:race_tasks, [])])
    task
  end

  defp reported(parent, tag, fun) do
    with_connection(fn ->
      [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
      send(parent, {tag, pid})
      fun.()
    end)
  end

  # A killed coordinator ends its caller's call with an exit; reported as
  # a value so the tracked task doesn't take the test process down.
  defp coordinator_run(fun) do
    in_coordinator(fun, 20_000)
  catch
    :exit, reason -> {:coordinator_exit, reason}
  end

  defp booted!(ctx, binding) do
    in_coordinator(fn _ ->
      with_connection(fn ->
        {:ok, start} =
          call(:allocate_server_start, [
            %{boot_id: binding.boot_id, profile_id: :claude_cli_opus, reason: :boot},
            [actor: ctx.runtime]
          ])

        ready(ctx, binding, start)
      end)
    end)
  end

  defp ready(ctx, binding, start) do
    reaper = spawn(fn -> :ok end)

    {:ok, start} =
      call(:mark_server_start, [
        start,
        :started,
        %{boot_id: binding.boot_id, pid: self(), node: node(), reaper_pid: reaper},
        [actor: ctx.runtime]
      ])

    {:ok, start} =
      call(:mark_server_start, [
        start,
        :ready,
        %{boot_id: binding.boot_id, pid: self(), ready_evidence: :spawn_preflight},
        [actor: ctx.runtime]
      ])

    start
  end

  defp switched!(ctx, binding) do
    booted = booted!(ctx, binding)

    {:ok, switch} =
      with_connection(fn ->
        call(:request_profile_switch, [
          %{
            to_profile_id: :claude_cli_sonnet,
            expected_revision: 1,
            server_generation: booted.generation
          },
          [actor: ctx.admin]
        ])
      end)

    switch
  end

  defp ready_activation!(ctx, binding, switch) do
    in_coordinator(fn _ ->
      with_connection(fn ->
        {:ok, start} =
          call(:allocate_server_start, [
            %{
              boot_id: binding.boot_id,
              profile_id: :claude_cli_sonnet,
              reason: :activation,
              switch_id: switch.id
            },
            [actor: ctx.runtime]
          ])

        ready(ctx, binding, start)
      end)
    end)
  end

  defp complete(ctx, binding, switch, start, opts \\ []) do
    call(:complete_profile_switch, [
      switch,
      %{
        server_generation: switch.server_generation,
        boot_id: binding.boot_id,
        start_id: start.id
      },
      [actor: ctx.runtime] ++ opts
    ])
  end

  defp kill_coordinator! do
    coordinator = Process.whereis(@coordinator)
    ref = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^ref, :process, ^coordinator, _}, 5_000
  end

  defp await_new_boot!(old_boot) do
    Enum.find_value(1..250, fn _ ->
      Process.sleep(20)
      new_boot(old_boot)
    end) || flunk("no new coordinator boot")
  end

  defp new_boot(old_boot) do
    with pid when is_pid(pid) <- Process.whereis(@coordinator),
         %{boot_id: boot_id} = binding when boot_id != old_boot <- in_coordinator(& &1),
         do: binding,
         else: (_ -> nil)
  end

  ## Raw holders (each on its own connection, in a transaction)

  defp lock_setting!(ctx),
    do:
      Repo.query!("SELECT 1 FROM model_profile_settings WHERE tenant_id = $1 FOR UPDATE", [
        uuid(ctx.tenant.id)
      ])

  defp lock_counter!(ctx, mode),
    do:
      Repo.query!("SELECT 1 FROM model_server_counters WHERE tenant_id = $1 #{mode}", [
        uuid(ctx.tenant.id)
      ])

  defp lock_switch!(switch, mode),
    do:
      Repo.query!("SELECT 1 FROM model_profile_switches WHERE id = $1 #{mode}", [uuid(switch.id)])

  defp insert_counter!(ctx) do
    Repo.query!("SET LOCAL session_replication_role = replica")

    Repo.query!(
      "INSERT INTO model_server_counters (id, tenant_id, last_generation, inserted_at, updated_at) " <>
        "VALUES (gen_random_uuid(), $1, 0, now(), now())",
      [uuid(ctx.tenant.id)]
    )
  end

  defp insert_newer_start!(ctx, binding) do
    Repo.query!("SET LOCAL session_replication_role = replica")

    Repo.query!(
      "INSERT INTO model_server_starts (id, tenant_id, generation, boot_id, profile_id, reason, " <>
        "status, inserted_at, updated_at) SELECT gen_random_uuid(), $1, last_generation + 1, $2, " <>
        "'claude_cli_opus', 'replacement', 'allocated', now(), now() FROM model_server_counters " <>
        "WHERE tenant_id = $1",
      [uuid(ctx.tenant.id), uuid(binding.boot_id)]
    )

    Repo.query!(
      "UPDATE model_server_counters SET last_generation = last_generation + 1 WHERE tenant_id = $1",
      [uuid(ctx.tenant.id)]
    )
  end

  defp insert_conflicting_start!(ctx, generation) do
    with_connection(fn ->
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL session_replication_role = replica")

        Repo.query!(
          "INSERT INTO model_server_starts (id, tenant_id, generation, boot_id, profile_id, reason, " <>
            "status, inserted_at, updated_at) VALUES (gen_random_uuid(), $1, $2, gen_random_uuid(), " <>
            "'claude_cli_opus', 'replacement', 'allocated', now(), now())",
          [uuid(ctx.tenant.id), generation]
        )
      end)
    end)
  end

  defp counter(ctx) do
    with_connection(fn ->
      Repo.query!("SELECT last_generation FROM model_server_counters WHERE tenant_id = $1", [
        uuid(ctx.tenant.id)
      ]).rows
    end)
  end

  defp events(ctx, type) do
    with_connection(fn ->
      [[count]] =
        Repo.query!(
          "SELECT count(*) FROM audit_events WHERE tenant_id = $1 AND event_type = $2",
          [uuid(ctx.tenant.id), type]
        ).rows

      count
    end)
  end

  defp switch_status(switch) do
    with_connection(fn ->
      [[status]] =
        Repo.query!("SELECT status FROM model_profile_switches WHERE id = $1", [uuid(switch.id)]).rows

      status
    end)
  end

  defp uuid(id), do: Ecto.UUID.dump!(id)

  defp hold(fun, outcome \\ :commit) do
    parent = self()
    task = Task.async(fn -> reported(parent, :holder, holding(parent, fun, outcome)) end)
    Process.put(:race_tasks, [task | Process.get(:race_tasks, [])])
    pid = pid_of(:holder)
    assert_receive {:held, _}, 10_000
    {task, pid}
  end

  defp holding(parent, fun, outcome),
    do: fn -> Repo.transaction(fn -> held(parent, fun, outcome) end) end

  defp held(parent, fun, outcome) do
    result = fun.()
    send(parent, {:held, self()})
    await_release(parent)
    if outcome == :rollback, do: Repo.rollback(:test_rollback), else: result
  end

  # A holder takes further steps on request until it is released.
  defp await_release(parent) do
    receive do
      {:step, fun} ->
        send(parent, {:stepped, timed_step(fun)})
        await_release(parent)

      :release ->
        :ok
    after
      30_000 -> :timeout
    end
  end

  # One step under a savepoint and a 1.5 s lock timeout: {:ok, waited_ms}
  # or {:error, reason} (a lock timeout or a deadlock), the holder's
  # transaction left usable.
  defp timed_step(fun) do
    Repo.query!("SAVEPOINT step")
    Repo.query!("SET LOCAL lock_timeout = '1500ms'")
    started = System.monotonic_time(:millisecond)

    try do
      fun.()
      {:ok, System.monotonic_time(:millisecond) - started}
    rescue
      error ->
        Repo.query!("ROLLBACK TO SAVEPOINT step")
        {:error, Exception.message(error)}
    end
  end

  defp step(%Task{} = holder, fun) do
    send(holder.pid, {:step, fun})
    assert_receive {:stepped, result}, 10_000
    result
  end

  # The harness self-check runs on three bare one-row tables of its own
  # (created and dropped here), standing for the setting, the counter and
  # the switch; no ledger code or ledger table is involved.
  @harness %{
    setting: "c202b2a_harness_setting",
    counter: "c202b2a_harness_counter",
    switch: "c202b2a_harness_switch"
  }

  defp harness_tables! do
    for {_role, table} <- @harness do
      Repo.query!("DROP TABLE IF EXISTS #{table}")
      Repo.query!("CREATE TABLE #{table} (id integer PRIMARY KEY)")
      Repo.query!("INSERT INTO #{table} (id) VALUES (1)")
    end

    on_exit(fn -> with_connection(&drop_harness_tables/0) end)
  end

  defp drop_harness_tables,
    do: for({_role, table} <- @harness, do: Repo.query!("DROP TABLE IF EXISTS #{table}"))

  defp harness_lock(role, mode),
    do: fn -> Repo.query!("SELECT 1 FROM #{Map.fetch!(@harness, role)} WHERE id = 1 #{mode}") end

  # Holder: a finalizer (setting, counter share; then the switch) or an
  # allocator (counter; then the switch's key share).
  defp holder_first(:allocator) do
    fn ->
      harness_lock(:setting, "FOR UPDATE").()
      harness_lock(:counter, "FOR SHARE").()
    end
  end

  defp holder_first(:finalizer), do: harness_lock(:counter, "FOR UPDATE")
  defp holder_second(:allocator), do: harness_lock(:switch, "FOR UPDATE")
  defp holder_second(:finalizer), do: harness_lock(:switch, "FOR KEY SHARE")

  # A raw contender on its own connection, in the approved or the inverted
  # order.
  defp raw_contender(side, order) do
    statements = contender_statements(side, order)
    parent = self()

    task = Task.async(fn -> reported(parent, :contender, contending(statements)) end)

    Process.put(:race_tasks, [task | Process.get(:race_tasks, [])])
    task
  end

  defp contending(statements) do
    fn ->
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '3s'")
        Enum.each(statements, &safe_run/1)
      end)
    end
  end

  defp safe_run(fun) do
    fun.()
  rescue
    _error -> :aborted
  end

  defp contender_statements(:allocator, :approved),
    do: [harness_lock(:counter, "FOR UPDATE"), harness_lock(:switch, "FOR KEY SHARE")]

  defp contender_statements(:allocator, :inverted),
    do: [harness_lock(:switch, "FOR KEY SHARE"), harness_lock(:counter, "FOR UPDATE")]

  defp contender_statements(:finalizer, :approved),
    do: [harness_lock(:counter, "FOR SHARE"), harness_lock(:switch, "FOR UPDATE")]

  defp contender_statements(:finalizer, :inverted),
    do: [harness_lock(:switch, "FOR UPDATE"), harness_lock(:counter, "FOR SHARE")]

  defp release(%Task{} = task), do: send(task.pid, :release)
  defp join(%Task{} = task, timeout \\ 20_000), do: Task.await(task, timeout)

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

  defp blocked_by?(waiter, holder) do
    case Repo.query!("SELECT pg_blocking_pids($1)", [waiter]).rows do
      [[pids]] -> if holder in pids, do: true
      _ -> nil
    end
  end

  defp race(fun) do
    fun.()
  after
    for task <- Process.get(:race_tasks, []), do: Task.shutdown(task, 5_000)
    Process.delete(:race_tasks)

    for id <- [:profile_tree, :commit, :rollback] do
      _ = stop_supervised(id)
    end
  end

  # MF1 (Codex 5f57e6ac): a process that already owns its non-sandboxed
  # connection (the test process, after setup) reuses it and never checks
  # it in; a process without one checks one out for `fun` only. An
  # allowed (borrowed) connection is not an independent one: it raises.
  defp with_connection(fun) do
    case Sandbox.checkout(Repo, sandbox: false) do
      :ok ->
        try do
          fun.()
        after
          Sandbox.checkin(Repo)
        end

      {:already, :owner} ->
        fun.()
    end
  end

  defp cleanup_ledger! do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL session_replication_role = replica")

      for table <- ~w(model_server_starts model_server_counters),
          Repo.query!("SELECT to_regclass($1) IS NOT NULL", [table]).rows == [[true]],
          do: Repo.query!("TRUNCATE #{table} CASCADE")
    end)
  end

  @doc false
  def truncatable?(database) when is_binary(database),
    do: Regex.match?(~r/\Asdr_agent_test[a-z0-9_]*\z/, database)

  def truncatable?(_database), do: false

  test "with_connection reuses an owned connection and keeps tasks independent" do
    outer = backend_pid()
    assert with_connection(&backend_pid/0) == outer
    assert with_connection(fn -> with_connection(&backend_pid/0) end) == outer
    assert backend_pid() == outer, "the owned connection survived the nested calls"

    other = Task.async(fn -> with_connection(&backend_pid/0) end) |> Task.await(10_000)
    refute other == outer
  end

  defp backend_pid, do: hd(hd(Repo.query!("SELECT pg_backend_pid()").rows))

  test "the cleanup guard refuses anything but a test database" do
    for name <- ["sdr_agent_dev", "sdr_agent_calibration", "postgres", nil, ""],
        do: refute(truncatable?(name))

    assert truncatable?("sdr_agent_test_c202b2a")
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
