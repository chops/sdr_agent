defmodule SdrAgent.Agents.LaunchAdmissionRaceTest do
  @moduledoc """
  Real concurrency for C9-03 launch admission (as
  `SdrAgent.Agents.ModelCallAdmissionRaceTest`): every process works on its
  own non-sandboxed connection. Launch admission locks run → invocation →
  the charged grant and allocation `FOR SHARE` → chain head, and only then
  reads the terms, so a revocation racing a launch has exactly one order:
  either it commits first (the launch is refused and failed) or the launch
  commits first (it proceeds; the revocation does not touch it). Two
  admissions of one id launch it once. Committed rows are removed
  afterwards with triggers disabled.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.AuditCase
  alias SdrAgent.Clock
  alias SdrAgent.SDR.StaleRunSweeper

  @tables ~w(audit_accesses audit_events audit_chain_heads model_invocations
             model_call_allocations model_call_grants agent_runs failures operations
             agent_definitions tokens users payloads provenance_snapshots tenants)

  setup do
    :ok = Sandbox.checkout(SdrAgent.Repo, sandbox: false)
    cleanup!()
    on_exit(fn -> with_connection(&cleanup!/0) end)
    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    admin = AuditCase.human(:admin, tenant)
    grant = AgentsFixtures.grant!(tenant, %{}, admin)
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)

    {:ok, invocation} =
      Agents.reserve_model_invocation(run, AgentsFixtures.claude_attrs("race"), actor: agent)

    %{
      tenant: tenant,
      admin: admin,
      grant: grant,
      run: run,
      agent: agent,
      invocation: invocation
    }
  end

  test "a revocation holding the grant while a launch is admitted: the revocation wins", ctx do
    parent = self()

    revoker =
      Task.async(fn ->
        with_connection(fn ->
          Audit.transaction(fn ->
            lock!("SELECT id FROM model_call_grants WHERE id = $1 FOR UPDATE", ctx.grant.id)
            send(parent, :grant_locked)
            receive do: (:go -> :ok)

            {:ok, revoked} =
              Agents.revoke_grant(ctx.grant, %{expected_revision: 1}, actor: ctx.admin)

            revoked
          end)
        end)
      end)

    assert_receive :grant_locked, 10_000
    # The launch has locked the run and the invocation and waits for the grant.
    launch = Task.async(fn -> admit(ctx) end)
    await_lock_waiters(1)
    send(revoker.pid, :go)

    assert {:ok, %{status: :revoked}} = Task.await(revoker, 30_000)
    assert {:error, :grant_ineligible_at_launch} = Task.await(launch, 30_000)

    stored = Ash.get!(ModelInvocation, ctx.invocation.id, authorize?: false)
    assert {stored.status, stored.sent_at} == {:failed, nil}
    assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: auditor(ctx))
  end

  test "a launch holding its share locks while a revoke runs: the launch wins", ctx do
    parent = self()

    # Holds the chain head so the launch stops after its share locks.
    head =
      Task.async(fn ->
        with_connection(fn ->
          SdrAgent.Repo.transaction(fn ->
            {:ok, _} = Audit.Kernel.lock_head(ctx.tenant.id)
            send(parent, :head_held)
            receive do: (:go -> :ok)
          end)
        end)
      end)

    assert_receive :head_held, 10_000
    launch = Task.async(fn -> admit(ctx) end)
    await_lock_waiters(1)

    revoke =
      Task.async(fn ->
        with_connection(fn ->
          Agents.revoke_grant(ctx.grant, %{expected_revision: 1}, actor: ctx.admin)
        end)
      end)

    # The revocation waits for the launch's share lock on the grant.
    await_lock_waiters(2)
    send(head.pid, :go)

    assert {:ok, _} = Task.await(head, 30_000)
    assert {:ok, %{status: :sent}} = Task.await(launch, 30_000)
    assert {:ok, %{status: :revoked}} = Task.await(revoke, 30_000)

    stored = Ash.get!(ModelInvocation, ctx.invocation.id, authorize?: false)
    assert stored.status == :sent
    assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: auditor(ctx))
  end

  test "a run stop holding the run while a launch is admitted: the stop wins", ctx do
    parent = self()

    stopper =
      Task.async(fn ->
        with_connection(fn ->
          Audit.transaction(fn ->
            lock!("SELECT id FROM agent_runs WHERE id = $1 FOR UPDATE", ctx.run.id)
            send(parent, :run_locked)
            receive do: (:go -> :ok)
            {:ok, cancelled} = Agents.cancel_run(ctx.run, actor: ctx.admin)
            cancelled
          end)
        end)
      end)

    assert_receive :run_locked, 10_000
    launch = Task.async(fn -> admit(ctx) end)
    await_lock_waiters(1)
    send(stopper.pid, :go)

    assert {:ok, %{status: :cancelled}} = Task.await(stopper, 30_000)
    assert {:error, :run_not_running_at_launch} = Task.await(launch, 30_000)

    stored = Ash.get!(ModelInvocation, ctx.invocation.id, authorize?: false)
    assert {stored.status, stored.sent_at} == {:failed, nil}
    assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: auditor(ctx))
  end

  test "a launch holding the run while a stop runs: the launch wins", ctx do
    parent = self()

    # Holds the chain head so the launch stops after its run and share locks.
    head =
      Task.async(fn ->
        with_connection(fn ->
          SdrAgent.Repo.transaction(fn ->
            {:ok, _} = Audit.Kernel.lock_head(ctx.tenant.id)
            send(parent, :head_held)
            receive do: (:go -> :ok)
          end)
        end)
      end)

    assert_receive :head_held, 10_000
    launch = Task.async(fn -> admit(ctx) end)
    await_lock_waiters(1)

    stop =
      Task.async(fn ->
        with_connection(fn -> Agents.cancel_run(ctx.run, actor: ctx.admin) end)
      end)

    # The stop waits for the launch's run lock.
    await_lock_waiters(2)
    send(head.pid, :go)

    assert {:ok, _} = Task.await(head, 30_000)
    assert {:ok, %{status: :sent}} = Task.await(launch, 30_000)
    assert {:ok, %{status: :cancelled}} = Task.await(stop, 30_000)

    stored = Ash.get!(ModelInvocation, ctx.invocation.id, authorize?: false)
    assert stored.status == :sent
    assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: auditor(ctx))
  end

  test "two concurrent admissions of one id launch it exactly once", ctx do
    results =
      1..4
      |> Enum.map(fn _ -> Task.async(fn -> admit(ctx) end) end)
      |> Task.await_many(60_000)

    assert Enum.count(results, &match?({:ok, %{status: :sent}}, &1)) == 1, inspect(results)
    assert Enum.count(results, &(&1 == {:error, :invocation_not_reserved})) == 3

    {:ok, events} = Audit.list_events(actor: auditor(ctx))
    assert Enum.count(events, &(&1.event_type == "model.invocation.sent")) == 1
    assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: auditor(ctx))
  end

  describe "reserved recovery racing a launch (C9-03 case (a))" do
    setup ctx do
      Clock.freeze(
        DateTime.add(Clock.utc_now(), StaleRunSweeper.stale_after_seconds() + 60, :second)
      )

      on_exit(&Clock.unfreeze/0)
      ctx
    end

    test "recovery first: the row is failed unlaunched and the launch is refused", ctx do
      parent = self()
      head = Task.async(fn -> with_connection(fn -> hold_head(ctx, parent) end) end)
      assert_receive :head_held, 10_000

      sweep =
        Task.async(fn -> with_connection(fn -> StaleRunSweeper.sweep(ctx.tenant.id) end) end)

      await_lock_waiters(1)
      launch = Task.async(fn -> admit(ctx) end)
      await_lock_waiters(2)
      send(head.pid, :go)

      assert {:ok, _} = Task.await(head, 30_000)
      assert :ok = Task.await(sweep, 30_000)
      assert {:error, :invocation_not_reserved} = Task.await(launch, 30_000)

      stored = Ash.get!(ModelInvocation, ctx.invocation.id, authorize?: false)
      assert {stored.status, stored.sent_at} == {:failed, nil}
      assert stored.error["kind"] == "abandoned_before_launch"
      assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: auditor(ctx))
    end

    test "launch first: the call is sent, and recovery marks it unknown, not failed", ctx do
      parent = self()
      head = Task.async(fn -> with_connection(fn -> hold_head(ctx, parent) end) end)
      assert_receive :head_held, 10_000

      launch = Task.async(fn -> admit(ctx) end)
      await_lock_waiters(1)

      sweep =
        Task.async(fn -> with_connection(fn -> StaleRunSweeper.sweep(ctx.tenant.id) end) end)

      await_lock_waiters(2)
      send(head.pid, :go)

      assert {:ok, _} = Task.await(head, 30_000)
      assert {:ok, %{status: :sent}} = Task.await(launch, 30_000)
      assert :ok = Task.await(sweep, 30_000)

      stored = Ash.get!(ModelInvocation, ctx.invocation.id, authorize?: false)
      assert stored.status == :unknown
      assert stored.sent_at != nil
      assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: auditor(ctx))
    end
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

  # Waits until `count` backends of this database wait on a row or tuple lock.
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
