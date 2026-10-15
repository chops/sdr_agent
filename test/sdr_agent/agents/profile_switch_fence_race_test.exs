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

        assert {:error, %Refused{reason: :profile_switch_fenced}} = join(reserver, 5_000),
               "the reservation waited on the switch row"

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

    test "S changes before the final observation: no success", ctx do
      race(fn ->
        fence!()
        assert {:ok, row} = reserve(ctx, "in-flight")
        assert {:ok, sent} = admit(ctx, row.id)
        assert {:ok, switch} = request(ctx)

        drainer = on_own_connection(:drainer, fn -> drain(ctx, switch) end)
        _ = pid_of(:drainer)
        assert {:ok, _} = fail_switch(ctx, switch)

        assert {:ok, _} =
                 Agents.complete_model_invocation(sent, AgentsFixtures.completion(),
                   actor: ctx.agent
                 )

        assert {:error, :switch_not_open} = join(drainer)
      end)
    end

    test "while it waits for a sent row, the drain holds no lock and no transaction", ctx do
      race(fn ->
        fence!()
        assert {:ok, row} = reserve(ctx, "held-open")
        assert {:ok, sent} = admit(ctx, row.id)
        assert {:ok, switch} = request(ctx)

        drainer = on_own_connection(:drainer, fn -> drain(ctx, switch) end)
        drainer_pid = pid_of(:drainer)
        Process.sleep(300)

        assert idle_without_locks?(drainer_pid),
               "the drain waited inside a transaction or holding a lock"

        assert {:ok, _} =
                 Agents.complete_model_invocation(sent, AgentsFixtures.completion(),
                   actor: ctx.agent
                 )

        assert {:ok, %{refused: 0}} = join(drainer)
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

  defp release({task, _pid}), do: send(task.pid, :release)
  defp release(task), do: send(task.pid, :release)

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
