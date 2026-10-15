defmodule SdrAgent.AI.ProfileCoordinatorRaceTest do
  @moduledoc """
  C2-02b2α RED (interface PASS `c00ed69`, section 1a "The permit's
  lifetime"; Codex 5f57e6ac important item 1): messages that arrive while
  a coordinator ledger call waits on a **real** lock.

    * **A worker `DOWN` while `complete` waits:** the coordinator handles
      it only after the call returns. The call commits on the stored fence,
      and the later `DOWN` doesn't block the completed switch; the
      reconciled read then releases the candidate.
    * **The call's bound passing while it waits:** the call ends with a
      rollback, nothing commits, and only then does the coordinator block
      the switch, keeping the candidate held.

  The whole tree (coordinator, worker, servers) needs independent
  connections, so this module runs the SQL Sandbox in `:auto` mode for its
  own duration (it is synchronous, so no async test shares it) and
  restores `:manual` afterwards. Cleanup truncates only a test database.
  The holder is a raw SQL transaction on its own connection. The fake CLI
  runs under the test launcher; no model call.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Audit
  alias SdrAgent.Repo
  alias SdrAgent.Test.LaunchAdmission

  @coordinator SdrAgent.AI.ModelProvider.Coordinator
  @profile_supervisor SdrAgent.AI.ModelProvider.ProfileSupervisor
  @stage [:sdr_agent, :model_coordinator, :stage]
  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)
  @tables ~w(model_server_starts model_server_counters model_profile_switches
             model_profile_settings audit_accesses audit_events audit_chain_heads
             model_call_allocations model_call_grants failures operations model_invocations
             agent_runs agent_definitions tokens users payloads provenance_snapshots tenants)

  setup do
    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      cleanup!()
      Sandbox.mode(Repo, :manual)
      ClaudeCLI.Reaper.release(ClaudeCLI.server())
    end)

    cleanup!()
    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    %{tenant: tenant, admin: SdrAgent.AuditCase.new_human(:admin, tenant)}
  end

  test "a worker DOWN while complete waits on a lock is handled after the call", ctx do
    tree!()
    await_status!(&(&1.hold == :released))
    pause_at!(:preflighted)
    assert {:ok, switch} = request(ctx)
    assert_receive {:stage_paused, :preflighted, worker}, 20_000

    {holder, holder_pid} = hold(fn -> lock_setting!(ctx) end)
    send(worker, :continue)
    await_blocked!(holder_pid)

    # The worker is alive once the coordinator's wait is established; its
    # death is observed, and its DOWN is shown queued in the (blocked)
    # coordinator's mailbox before the lock is released.
    assert Process.alive?(worker)
    coordinator = Process.whereis(@coordinator)
    watch = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^watch, :process, ^worker, :killed}, 5_000
    await_until!(fn -> down_queued?(coordinator, worker) end, 5_000)
    await_blocked!(holder_pid)

    assert switch_status(switch) == "pending"
    assert events(ctx, "model.profile.switch_blocked") == 0, "DOWN was acted on mid-call"

    release(holder)
    Task.await(holder, 10_000)

    await_status!(&(&1.hold == :released and &1.profile_id == :claude_cli_sonnet), 20_000)
    assert switch_status(switch) == "completed"
    assert events(ctx, "model.profile.switch_completed") == 1
    assert events(ctx, "model.profile.switch_blocked") == 0
  end

  test "a call whose bound passes while it waits commits nothing, then blocks", ctx do
    tree!()
    await_status!(&(&1.hold == :released))
    pause_at!(:preflighted)
    assert {:ok, switch} = request(ctx)
    assert_receive {:stage_paused, :preflighted, worker}, 20_000

    {holder, holder_pid} = hold(fn -> lock_setting!(ctx) end)
    send(worker, :continue)
    await_blocked!(holder_pid)

    # Past the 2 s per-call bound.
    Process.sleep(2_600)
    assert events(ctx, "model.profile.switch_completed") == 0
    release(holder)
    Task.await(holder, 10_000)

    await_until!(fn -> switch_status(switch) == "blocked" end, 20_000)
    assert events(ctx, "model.profile.switch_completed") == 0
    assert %{hold: :held} = apply(@coordinator, :status, [])
  end

  ## Helpers

  defp tree! do
    for module <- [@profile_supervisor, @coordinator] do
      assert Code.ensure_loaded?(module), "C2-02b2α: #{inspect(module)} is not implemented"
    end

    parent = self()

    server = fn _profile_id ->
      [
        command: System.find_executable("elixir"),
        test_launcher: true,
        launch_admission: LaunchAdmission.recording(parent),
        command_args: [@fake, "ready"]
      ]
    end

    start_supervised!({@profile_supervisor, server: server})
  end

  defp request(ctx) do
    apply(@coordinator, :request_switch, [
      %{to_profile_id: :claude_cli_sonnet, expected_revision: 1},
      [actor: ctx.admin]
    ])
  end

  defp await_status!(predicate, timeout \\ 10_000) do
    await_until!(
      fn ->
        status = apply(@coordinator, :status, [])
        is_map(status) and predicate.(status)
      end,
      timeout
    )
  end

  defp await_until!(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition never held")

      true ->
        Process.sleep(20)
        poll(fun, deadline)
    end
  end

  defp pause_at!(stage) do
    id = "c202b2a-race-pause-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        id,
        @stage,
        fn _event, _measurements, meta, _config -> pause(meta, stage, parent) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp pause(%{stage: stage}, stage, parent) do
    send(parent, {:stage_paused, stage, self()})

    receive do
      :continue -> :ok
    after
      30_000 -> :ok
    end
  end

  defp pause(_meta, _stage, _parent), do: :ok

  defp lock_setting!(ctx),
    do:
      Repo.query!("SELECT 1 FROM model_profile_settings WHERE tenant_id = $1 FOR UPDATE", [
        Ecto.UUID.dump!(ctx.tenant.id)
      ])

  defp hold(fun) do
    parent = self()

    task =
      Task.async(fn ->
        [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
        send(parent, {:holder, pid})
        Repo.transaction(fn -> held(parent, fun) end)
      end)

    assert_receive {:holder, pid}, 10_000
    assert_receive {:held, _}, 10_000
    {task, pid}
  end

  defp held(parent, fun) do
    fun.()
    send(parent, {:held, self()})

    receive do
      :release -> :ok
    after
      30_000 -> :ok
    end
  end

  defp release(%Task{} = task), do: send(task.pid, :release)

  # Some backend (the coordinator's) waits on the holder.
  defp await_blocked!(holder_pid) do
    await_until!(
      fn ->
        Repo.query!(
          "SELECT count(*) FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid))",
          [holder_pid]
        ).rows == [[1]]
      end,
      10_000
    )
  end

  defp down_queued?(coordinator, worker) do
    {:messages, messages} = Process.info(coordinator, :messages)
    Enum.any?(messages, &match?({:DOWN, _ref, :process, ^worker, _reason}, &1))
  end

  defp switch_status(switch) do
    [[status]] =
      Repo.query!("SELECT status FROM model_profile_switches WHERE id = $1", [
        Ecto.UUID.dump!(switch.id)
      ]).rows

    status
  end

  defp events(ctx, type) do
    [[count]] =
      Repo.query!(
        "SELECT count(*) FROM audit_events WHERE tenant_id = $1 AND event_type = $2",
        [Ecto.UUID.dump!(ctx.tenant.id), type]
      ).rows

    count
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
