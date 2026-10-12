defmodule SdrAgent.Agents.ModelCallAdmissionRaceTest do
  @moduledoc """
  Real concurrency for C9 admission (as `SdrAgent.Audit.ConcurrencyTest`):
  every process reserves on its own non-sandboxed connection, so the
  reservations genuinely race for the run and chain-head locks. The last
  unit of an allocation is charged exactly once, and concurrent refusals of
  the same key open exactly one Failure. Held-lock regressions: a
  reservation never waits on a grant, allocation or Operation row while it
  holds the chain head, so it neither deadlocks with a grant editor nor with
  an Operation lifecycle writer; exactly one order wins. Committed rows are
  removed afterwards with triggers disabled.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.AuditCase
  alias SdrAgent.Operations
  alias SdrAgent.Operations.Failure

  @tables ~w(audit_accesses audit_events audit_chain_heads model_invocations
             model_call_allocations model_call_grants agent_runs failures operations
             agent_definitions tokens users payloads provenance_snapshots tenants)

  setup do
    :ok = Sandbox.checkout(SdrAgent.Repo, sandbox: false)
    cleanup!()
    on_exit(fn -> with_connection(&cleanup!/0) end)
    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    %{tenant: tenant}
  end

  test "concurrent reservations for the last unit: exactly one wins", ctx do
    grant =
      AgentsFixtures.grant!(ctx.tenant, %{
        total_attempts: 1,
        allocations: [%{key: :b1, applies_to: [:b1], attempts: 1}]
      })

    runs = for _ <- 1..6, do: AgentsFixtures.running_run(ctx.tenant)

    results =
      runs
      |> Enum.with_index()
      |> Enum.map(fn {%{run: run, agent: agent}, n} ->
        Task.async(fn ->
          with_connection(fn ->
            Agents.reserve_model_invocation(run, AgentsFixtures.claude_attrs("last-#{n}"),
              actor: agent
            )
          end)
        end)
      end)
      |> Task.await_many(60_000)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1, inspect(results)

    assert Enum.count(results, &(&1 == {:error, {:budget_exhausted, :grant}})) == 5,
           inspect(results)

    charged =
      Agents.ModelInvocation
      |> Ash.Query.filter(grant_id == ^grant.id)
      |> Ash.count!(authorize?: false)

    assert charged == 1
    assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: auditor(ctx))
  end

  test "concurrent refusals of the same key open one Failure", ctx do
    %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)

    results =
      1..6
      |> Enum.map(fn n ->
        Task.async(fn ->
          with_connection(fn ->
            Agents.reserve_model_invocation(run, AgentsFixtures.claude_attrs("refused-#{n}"),
              actor: agent
            )
          end)
        end)
      end)
      |> Task.await_many(60_000)

    assert Enum.all?(results, &(&1 == {:error, :no_eligible_grant})), inspect(results)

    failures =
      Failure
      |> Ash.Query.filter(class == :budget_exhausted and subject_id == ^run.id)
      |> Ash.read!(Audit.Kernel.opts(ctx.tenant.id))

    assert length(failures) == 1

    {:ok, events} = Audit.list_events(actor: auditor(ctx))
    assert Enum.count(events, &(&1.event_type == "model.reservation.refused")) == 6
    assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: auditor(ctx))
  end

  describe "held locks (no deadlock with grant editors or Operation writers)" do
    test "a grant edit holding the grant while a reservation runs: the edit wins", ctx do
      admin = AuditCase.human(:admin, ctx.tenant)
      grant = AgentsFixtures.grant!(ctx.tenant, %{}, admin)
      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
      parent = self()

      editor =
        Task.async(fn ->
          with_connection(fn ->
            Audit.transaction(fn ->
              lock!("SELECT id FROM model_call_grants WHERE id = $1 FOR UPDATE", grant.id)
              send(parent, :editor_locked)
              receive do: (:go -> :ok)
              {:ok, revoked} = Agents.revoke_grant(grant, %{expected_revision: 1}, actor: admin)
              revoked
            end)
          end)
        end)

      assert_receive :editor_locked, 10_000
      reservation = Task.async(fn -> reserve(run, agent, "held-edit") end)
      await_lock_waiters(1)
      send(editor.pid, :go)

      assert {:ok, %{status: :revoked}} = Task.await(editor, 30_000)
      assert Task.await(reservation, 30_000) == {:error, :no_eligible_grant}
      assert charged(grant) == 0
      assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: auditor(ctx))
    end

    test "a reservation holding its share locks while a revoke runs: the reservation wins",
         ctx do
      admin = AuditCase.human(:admin, ctx.tenant)
      grant = AgentsFixtures.grant!(ctx.tenant, %{}, admin)
      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
      parent = self()

      # Holds the chain head so the reservation stops after its share locks.
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
      reservation = Task.async(fn -> reserve(run, agent, "held-share") end)
      await_lock_waiters(1)

      revoke =
        Task.async(fn ->
          with_connection(fn ->
            Agents.revoke_grant(grant, %{expected_revision: 1}, actor: admin)
          end)
        end)

      await_lock_waiters(2)
      send(head.pid, :go)

      assert {:ok, _} = Task.await(head, 30_000)
      assert {:ok, invocation} = Task.await(reservation, 30_000)
      assert invocation.grant_id == grant.id
      assert {:ok, %{status: :revoked}} = Task.await(revoke, 30_000)
      assert charged(grant) == 1
      assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: auditor(ctx))
    end

    test "a refusal of a run with an Operation waits for its lifecycle writer", ctx do
      %{run: run, agent: agent} = run_with_operation!(ctx)
      parent = self()

      writer =
        Task.async(fn ->
          with_connection(fn ->
            Audit.transaction(fn ->
              lock!("SELECT id FROM operations WHERE id = $1 FOR UPDATE", run.operation_id)
              send(parent, :operation_locked)
              receive do: (:go -> :ok)
              {:ok, operation} = Operations.get_operation(run.operation_id, actor: agent)
              {:ok, started} = Operations.start_operation(operation, actor: agent)
              started
            end)
          end)
        end)

      assert_receive :operation_locked, 10_000
      reservation = Task.async(fn -> reserve(run, agent, "held-operation") end)
      await_lock_waiters(1)
      send(writer.pid, :go)

      assert {:ok, %{status: :running}} = Task.await(writer, 30_000)
      assert Task.await(reservation, 30_000) == {:error, :no_eligible_grant}

      assert [failure] = refusal_failures(ctx, run)
      assert failure.operation_id == run.operation_id
      assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: auditor(ctx))
    end
  end

  defp reserve(run, agent, key) do
    with_connection(fn ->
      Agents.reserve_model_invocation(run, AgentsFixtures.claude_attrs(key), actor: agent)
    end)
  end

  defp charged(grant) do
    Agents.ModelInvocation
    |> Ash.Query.filter(grant_id == ^grant.id)
    |> Ash.count!(authorize?: false)
  end

  defp refusal_failures(ctx, run) do
    Failure
    |> Ash.Query.filter(class == :budget_exhausted and subject_id == ^run.id)
    |> Ash.read!(Audit.Kernel.opts(ctx.tenant.id))
  end

  defp run_with_operation!(ctx) do
    agent = struct(SdrAgent.Actor, type: :agent_runtime, tenant_id: ctx.tenant.id)
    definition = AgentsFixtures.definition!(ctx.tenant)
    lead_id = Ecto.UUID.generate()

    {:ok, operation} =
      Operations.create_operation(
        %{
          kind: :research_lead,
          queue: :research,
          subject_resource: "SdrAgent.Sales.Lead",
          subject_id: lead_id,
          idempotency_key: "held-lock:#{lead_id}",
          correlation_id: Ecto.UUID.generate(),
          max_attempts: 1
        },
        actor: agent
      )

    attrs =
      definition
      |> AgentsFixtures.run_attrs()
      |> Map.merge(%{lead_id: lead_id, operation_id: operation.id})

    {:ok, run} = Agents.create_run(attrs, actor: agent)
    {:ok, run} = Agents.start_run(run, actor: agent)
    %{run: run, agent: agent}
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
