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
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.AuditCase
  alias SdrAgent.Clock
  alias SdrAgent.Operations
  alias SdrAgent.Operations.Failure

  @tables ~w(audit_accesses audit_events audit_chain_heads model_invocations
             model_call_allocations model_call_grants agent_runs failures operations
             agent_definitions tokens users payloads provenance_snapshots tenants)

  setup do
    # R0-07 slice B: real calls are admitted only with a promoted tuple and
    # a trusted store (`SdrAgent.AdmissionFixtures`).
    SdrAgent.AdmissionFixtures.admit_tuples!()
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

    assert Enum.count(
             results,
             &match?({:error, %Refused{reason: {:budget_exhausted, :grant}}}, &1)
           ) == 5,
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

    assert Enum.all?(results, &match?({:error, %Refused{reason: :no_eligible_grant}}, &1)),
           inspect(results)

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
      assert {:error, %Refused{reason: :no_eligible_grant}} = Task.await(reservation, 30_000)
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
      assert {:error, %Refused{reason: :no_eligible_grant}} = Task.await(reservation, 30_000)

      assert [failure] = refusal_failures(ctx, run)
      assert failure.operation_id == run.operation_id
      assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: auditor(ctx))
    end
  end

  describe "the admission instant is read after every lock" do
    setup do
      on_exit(&Clock.unfreeze/0)
    end

    # Holds the chain head while the clock moves; the reservation (a task of
    # this process, so it reads this process's frozen clock) waits for it.
    defp reserve_while_time_moves(ctx, run, agent, key, from, to) do
      Clock.freeze(from)
      parent = self()

      head = Task.async(fn -> with_connection(fn -> hold_head(ctx, parent) end) end)
      assert_receive :head_held, 10_000
      reservation = Task.async(fn -> reserve(run, agent, key) end)
      await_lock_waiters(1)
      Clock.freeze(to)
      send(head.pid, :go)
      {:ok, _} = Task.await(head, 30_000)
      Task.await(reservation, 30_000)
    end

    defp unchanged!(run, agent, key) do
      {:ok, reloaded} = Agents.get_run(run.id, actor: agent)
      assert reloaded.budget.model_calls_reserved == 0
      {:ok, []} = Agents.list_model_invocations(run.id, actor: agent)

      {:ok, payloads} = Audit.list_payloads(actor: auditor_cli(agent))
      request = Map.fetch!(AgentsFixtures.claude_attrs(key), :request)
      refute Enum.any?(payloads, &(&1.sha256 == :crypto.hash(:sha256, request)))
    end

    test "a call that starts before expires_at but is admitted after it is refused", ctx do
      expires = ~U[2026-10-20 12:00:00.000000Z]
      Clock.freeze(~U[2026-10-20 11:00:00.000000Z])

      grant =
        AgentsFixtures.grant!(ctx.tenant, %{
          starts_at: ~U[2026-10-12 00:00:00.000000Z],
          expires_at: expires
        })

      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
      from = DateTime.add(expires, -1, :second)

      assert {:error, %Refused{reason: :no_eligible_grant}} =
               reserve_while_time_moves(ctx, run, agent, "expiring", from, expires)

      assert charged(grant) == 0
      unchanged!(run, agent, "expiring")
    end

    test "an allocation window that closes while the call waits refuses it", ctx do
      until = ~U[2026-10-20 12:00:00.000000Z]
      Clock.freeze(~U[2026-10-20 11:00:00.000000Z])

      grant =
        AgentsFixtures.grant!(ctx.tenant, %{
          allocations: [
            %{key: :rehearsal, applies_to: [:b1], attempts: 5, available_until: until}
          ]
        })

      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
      from = DateTime.add(until, -1, :second)

      assert {:error, %Refused{reason: :no_allocation}} =
               reserve_while_time_moves(ctx, run, agent, "closing", from, until)

      assert charged(grant) == 0
      unchanged!(run, agent, "closing")
    end

    test "across UTC midnight the day cap is counted for the day recorded on the row", ctx do
      Clock.freeze(~U[2026-10-20 23:59:58.000000Z])
      grant = AgentsFixtures.grant!(ctx.tenant, %{per_utc_day_attempts: 1})
      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
      assert {:ok, first} = reserve_here(run, agent, "day-1")
      assert first.reserved_at == ~U[2026-10-20 23:59:58.000000Z]

      admitted_at = ~U[2026-10-21 00:00:00.500000Z]

      assert {:ok, second} =
               reserve_while_time_moves(
                 ctx,
                 run,
                 agent,
                 "day-2",
                 ~U[2026-10-20 23:59:59.500000Z],
                 admitted_at
               )

      assert second.reserved_at == admitted_at
      assert charged(grant) == 2

      # The next call that day is over the day cap of the day it is recorded in.
      assert {:error, %Refused{reason: {:budget_exhausted, :grant_day}}} =
               reserve_here(run, agent, "day-2-again")
    end
  end

  defp reserve(run, agent, key) do
    with_connection(fn ->
      Agents.reserve_model_invocation(run, AgentsFixtures.claude_attrs(key), actor: agent)
    end)
  end

  # Holds the tenant's chain head until told to go.
  defp hold_head(ctx, parent) do
    SdrAgent.Repo.transaction(fn ->
      {:ok, _} = Audit.Kernel.lock_head(ctx.tenant.id)
      send(parent, :head_held)
      receive do: (:go -> :ok)
    end)
  end

  # On this test process's own (already checked out) connection.
  defp reserve_here(run, agent, key),
    do: Agents.reserve_model_invocation(run, AgentsFixtures.claude_attrs(key), actor: agent)

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

  defp auditor_cli(agent),
    do: struct(SdrAgent.Actor, type: :auditor_cli, tenant_id: agent.tenant_id)

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
