defmodule SdrAgent.Agents.ModelProfileSwitchRaceTest do
  @moduledoc """
  C2-02a (#52, slice a), on independent connections: the first-row
  upsert race and the lock order of a switch request
  (`docs/product/r0/c2-02a-interface.md`, "The first setting row"; the
  probe evidence is recorded there). Every process uses its own
  non-sandboxed connection. Committed rows are removed afterwards with
  triggers disabled, as in `SdrAgent.Audit.ConcurrencyTest`.

  Deterministic: a winner holds its transaction while the loser's wait is
  proven, then commits or rolls back; each runtime action is shown waiting
  on a held setting row without holding the chain head.

  RED: the functions don't exist on main; calls are presence-guarded.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents
  alias SdrAgent.Audit
  alias SdrAgent.Repo

  @tables ~w(model_profile_switches model_profile_settings audit_accesses audit_events
             audit_chain_heads model_call_allocations model_call_grants failures operations
             model_invocations agent_runs agent_definitions tokens users payloads
             provenance_snapshots tenants)

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    cleanup!()
    on_exit(fn -> with_connection(&cleanup!/0) end)

    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    admins = for _ <- 1..2, do: SdrAgent.AuditCase.new_human(:admin, tenant)

    %{
      tenant: tenant,
      admins: admins,
      runtime: struct(SdrAgent.Actor, type: :model_runtime, tenant_id: tenant.id)
    }
  end

  defp call(fun, args) do
    assert function_exported?(Agents, fun, length(args)),
           "C2-02a: SdrAgent.Agents.#{fun}/#{length(args)} is not implemented"

    apply(Agents, fun, args)
  end

  defp request(admin, generation),
    do:
      call(:request_profile_switch, [
        %{to_profile_id: :claude_cli_sonnet, expected_revision: 1, server_generation: generation},
        [actor: admin]
      ])

  defp events(tenant, type) do
    Repo.query!(
      "SELECT count(*) FROM audit_events WHERE tenant_id = $1 AND event_type = $2",
      [Ecto.UUID.dump!(tenant.id), type]
    ).rows
  end

  # These tests commit rows and truncate them afterwards, so cleanup runs
  # only against a test database: `sdr_agent_test` (CI's throwaway cluster
  # and bin/verify) or a `sdr_agent_test<partition>` copy, as for the other
  # race tests. Never the demo, dev or calibration database. The check runs
  # inside `cleanup!/0`, before its first SQL, in setup and on_exit alike.
  @doc false
  def truncatable?(database) when is_binary(database),
    do: Regex.match?(~r/\Asdr_agent_test[a-z0-9_]*\z/, database)

  def truncatable?(_database), do: false

  test "the cleanup guard refuses anything but a test database (no SQL runs)" do
    for name <- ["sdr_agent_dev", "sdr_agent_calibration", "postgres", "sdr_agent", nil, ""] do
      refute truncatable?(name), "#{inspect(name)} must not be truncatable"
    end

    for name <- ["sdr_agent_test", "sdr_agent_test2", "sdr_agent_test_c202a"] do
      assert truncatable?(name)
    end
  end

  # Waits until `pid`'s backend is blocked on a lock; bounded.
  defp await_lock_wait!(pid) do
    waiting =
      Enum.find_value(1..250, fn _ ->
        Process.sleep(20)

        case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [pid]).rows do
          [["Lock"]] -> true
          _ -> nil
        end
      end)

    assert waiting, "backend #{pid} never waited on a lock"
  end

  defp holds_head?(pid) do
    Repo.query!(
      "SELECT count(*) FROM pg_locks l JOIN pg_class c ON c.oid = l.relation " <>
        "WHERE l.pid = $1 AND l.granted AND c.relname = 'audit_chain_heads' " <>
        "AND l.mode IN ('RowShareLock', 'RowExclusiveLock')",
      [pid]
    ).rows != [[0]]
  end

  # Runs `fun` on its own connection, reporting its backend pid first. The
  # task is tracked so `stop_tasks!/0` can stop and join it before cleanup.
  defp on_own_connection(parent, tag, fun) do
    task = spawn_on_connection(parent, tag, fun)
    Process.put(:race_tasks, [task | Process.get(:race_tasks, [])])
    task
  end

  # Stops and joins every tracked task (holder, waiter, winner, loser), so
  # none can still hold a connection or lock when on_exit truncates.
  defp stop_tasks! do
    for task <- Process.get(:race_tasks, []), do: Task.shutdown(task, 5_000)
    Process.delete(:race_tasks)
  end

  defp spawn_on_connection(parent, tag, fun) do
    Task.async(fn ->
      with_connection(fn ->
        [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
        send(parent, {tag, pid})
        fun.()
      end)
    end)
  end

  for outcome <- [:commit, :rollback] do
    test "first-row race with the winner held, then #{outcome}", ctx do
      assert function_exported?(Agents, :request_profile_switch, 2),
             "C2-02a: SdrAgent.Agents.request_profile_switch/2 is not implemented"

      [winner_admin, loser_admin] = ctx.admins
      parent = self()

      winner =
        on_own_connection(parent, :winner, fn ->
          Repo.transaction(fn ->
            result = request(winner_admin, 1)
            send(parent, {:winner_requested, result})

            receive do
              :finish -> :ok
            after
              30_000 -> :timeout
            end

            if unquote(outcome) == :rollback, do: Repo.rollback(:test_rollback), else: result
          end)
        end)

      try do
        assert_receive {:winner_requested, {:ok, %{status: :pending}}}, 10_000
        loser = on_own_connection(parent, :loser, fn -> request(loser_admin, 2) end)
        assert_receive {:winner, winner_pid}, 10_000
        assert_receive {:loser, loser_pid}, 10_000
        await_lock_wait!(loser_pid)

        # The loser is blocked by the winner's transaction (the initializing
        # conflict), holding no chain head.
        assert [[[^winner_pid]]] = Repo.query!("SELECT pg_blocking_pids($1)", [loser_pid]).rows

        refute holds_head?(loser_pid)
        send(winner.pid, :finish)
        Task.await(winner, 15_000)
        loser_result = Task.await(loser, 15_000)

        settings =
          Repo.query!("SELECT revision, desired_profile_id FROM model_profile_settings").rows

        assert settings == [[1, "claude_cli_opus"]]
        assert events(ctx.tenant, "model.profile.setting_initialized") == [[1]]
        assert events(ctx.tenant, "model.profile.switch_requested") == [[1]]
        assert [[1]] = Repo.query!("SELECT count(*) FROM model_profile_switches").rows

        if unquote(outcome) == :commit do
          assert {:error, _} = loser_result
          assert [[1]] = Repo.query!("SELECT server_generation FROM model_profile_switches").rows
        else
          assert {:ok, %{status: :pending, server_generation: 2}} = loser_result
        end
      after
        send(winner.pid, :finish)
        stop_tasks!()
      end
    end
  end

  test "a request waits on the setting row before taking the chain head", ctx do
    [admin, _] = ctx.admins
    assert {:ok, first} = request(admin, 1)
    assert {:ok, _} = runtime(:fail_profile_switch, first, 1, ctx)

    held_setting(fn -> request(admin, 2) end, fn result ->
      assert {:ok, %{status: :pending}} = result
    end)
  end

  for {action, expected} <- [
        complete_profile_switch: :completed,
        fail_profile_switch: :failed,
        block_profile_switch: :blocked
      ] do
    test "#{action} waits on the setting row before taking the chain head", ctx do
      [admin, _] = ctx.admins
      assert {:ok, switch} = request(admin, 1)

      held_setting(
        fn -> runtime(unquote(action), switch, 1, ctx) end,
        fn result -> assert {:ok, %{status: unquote(expected)}} = result end,
        switch.id
      )
    end
  end

  defp runtime(:complete_profile_switch, switch, generation, ctx),
    do:
      call(:complete_profile_switch, [
        switch,
        %{server_generation: generation},
        [actor: ctx.runtime]
      ])

  defp runtime(action, switch, generation, ctx),
    do:
      call(action, [
        switch,
        %{server_generation: generation, failure_reason: "test"},
        [actor: ctx.runtime]
      ])

  # Holds the setting row FOR UPDATE on one connection, runs `fun` on
  # another, proves it waits on a lock without holding the chain head, then
  # releases and checks the result. The hold is always released.
  defp held_setting(fun, check, switch_id \\ nil) do
    parent = self()

    holder =
      on_own_connection(parent, :holder, fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT 1 FROM model_profile_settings FOR UPDATE")
          send(parent, :holding)

          receive do
            :release -> :ok
          after
            30_000 -> :timeout
          end
        end)
      end)

    try do
      assert_receive :holding, 10_000
      waiter = on_own_connection(parent, :waiter, fun)
      assert_receive {:waiter, waiter_pid}, 10_000
      await_lock_wait!(waiter_pid)
      refute holds_head?(waiter_pid), "it held the chain head while waiting on the setting"

      if switch_id,
        do: refute(switch_locked?(switch_id), "it locked the switch before the setting")

      send(holder.pid, :release)
      Task.await(holder, 15_000)
      check.(Task.await(waiter, 15_000))
    after
      send(holder.pid, :release)
      stop_tasks!()
    end
  end

  # From a third connection: can the switch row be locked right now?
  defp switch_locked?(switch_id) do
    fn -> probe_lock(switch_id) end
    |> Task.async()
    |> Task.await(10_000)
    |> case do
      {:ok, {:ok, _}} -> false
      {:ok, {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}}} -> true
      other -> flunk("switch lock probe failed: #{inspect(other)}")
    end
  end

  defp probe_lock(switch_id),
    do: with_connection(fn -> Repo.transaction(fn -> lock_nowait(switch_id) end) end)

  defp lock_nowait(switch_id) do
    Repo.query(
      "SELECT 1 FROM model_profile_switches WHERE id = $1 FOR UPDATE NOWAIT",
      [Ecto.UUID.dump!(switch_id)]
    )
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
