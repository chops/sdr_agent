defmodule SdrAgent.Agents.LaunchAdmissionOperatedRaceTest do
  @moduledoc """
  R0-07 slice B (row B1), code review of #145: launch admission under real
  concurrency for a run that has an Operation. The launch locks run →
  Operation `FOR SHARE` → invocation → grant and allocation `FOR SHARE` →
  chain head. An Operation writer (`FOR UPDATE` on the Operation) meets
  that order in one direction only, so the two never deadlock and each
  race has a single outcome. Every process uses its own non-sandboxed
  connection; committed rows are removed afterwards with triggers disabled.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.AuditCase

  @tables ~w(audit_accesses audit_events audit_chain_heads model_invocations
             model_call_allocations model_call_grants agent_runs failures operations
             oban_jobs agent_definitions tokens users payloads provenance_snapshots tenants)

  setup do
    SdrAgent.AdmissionFixtures.admit_tuples!()
    :ok = Sandbox.checkout(SdrAgent.Repo, sandbox: false)
    cleanup!()
    on_exit(fn -> with_connection(&cleanup!/0) end)
    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    admin = AuditCase.human(:admin, tenant)
    AgentsFixtures.grant!(tenant, %{}, admin)
    %{run: run, agent: agent, operation: operation} = AgentsFixtures.operated_run(tenant)

    {:ok, invocation} =
      Agents.reserve_model_invocation(run, AgentsFixtures.claude_attrs("operated-race"),
        actor: agent
      )

    %{tenant: tenant, run: run, agent: agent, operation: operation, invocation: invocation}
  end

  test "an Operation writer holding its row while a launch is admitted: the launch waits", ctx do
    parent = self()

    writer =
      Task.async(fn ->
        with_connection(fn ->
          SdrAgent.Repo.transaction(fn ->
            lock!("SELECT id FROM operations WHERE id = $1 FOR UPDATE", ctx.operation.id)
            send(parent, :operation_locked)
            receive do: (:go -> :ok)
          end)
        end)
      end)

    assert_receive :operation_locked, 10_000
    launch = Task.async(fn -> admit(ctx) end)
    # The launch waits for the Operation share lock, after its run lock.
    await_lock_waiters(1)
    send(writer.pid, :go)

    assert {:ok, _} = Task.await(writer, 30_000)
    assert {:ok, %{status: :sent}} = Task.await(launch, 30_000)
    assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: auditor(ctx))
  end

  test "a launch holding its share locks while an Operation writer runs: the launch wins", ctx do
    parent = self()
    head = Task.async(fn -> with_connection(fn -> hold_head(ctx, parent) end) end)
    assert_receive :head_held, 10_000

    # The launch now holds run, Operation (share) and invocation, and waits
    # for the head.
    launch = Task.async(fn -> admit(ctx) end)
    await_lock_waiters(1)

    writer =
      Task.async(fn ->
        with_connection(fn ->
          SdrAgent.Repo.transaction(fn ->
            lock!("SELECT id FROM operations WHERE id = $1 FOR UPDATE", ctx.operation.id)
            :written
          end)
        end)
      end)

    await_lock_waiters(2)
    send(head.pid, :go)

    assert {:ok, _} = Task.await(head, 30_000)
    assert {:ok, %{status: :sent}} = Task.await(launch, 30_000)
    assert {:ok, :written} = Task.await(writer, 30_000)
  end

  defp hold_head(ctx, parent) do
    SdrAgent.Repo.transaction(fn ->
      {:ok, _} = Audit.Kernel.lock_head(ctx.tenant.id)
      send(parent, :head_held)
      receive do: (:go -> :ok)
    end)
  end

  defp admit(ctx) do
    with_connection(fn ->
      Agents.admit_launch(ctx.invocation.id, :claude_cli_opus, actor: ctx.agent)
    end)
  end

  defp lock!(sql, id), do: SQL.query!(SdrAgent.Repo, sql, [Ecto.UUID.dump!(id)])

  defp await_lock_waiters(count, attempts \\ 200) do
    %{rows: [[waiting]]} =
      SQL.query!(
        SdrAgent.Repo,
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() " <>
          "AND wait_event_type = 'Lock'",
        []
      )

    cond do
      waiting >= count -> :ok
      attempts == 0 -> flunk("expected #{count} lock waiters, saw #{waiting}")
      true -> retry_waiters(count, attempts)
    end
  end

  defp retry_waiters(count, attempts) do
    Process.sleep(25)
    await_lock_waiters(count, attempts - 1)
  end

  defp auditor(ctx), do: struct(SdrAgent.Actor, type: :auditor_cli, tenant_id: ctx.tenant.id)

  defp with_connection(fun) do
    :ok = Sandbox.checkout(SdrAgent.Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(SdrAgent.Repo)
    end
  end

  defp cleanup! do
    SdrAgent.Repo.transaction(fn ->
      SQL.query!(SdrAgent.Repo, "SET LOCAL session_replication_role = replica", [])
      SQL.query!(SdrAgent.Repo, "TRUNCATE #{Enum.join(@tables, ", ")} CASCADE", [])
    end)
  end
end
