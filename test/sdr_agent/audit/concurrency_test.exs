defmodule SdrAgent.Audit.ConcurrencyTest do
  @moduledoc """
  Real concurrency: every process uses its own non-sandboxed connection and
  transaction, so appends genuinely race for the chain-head row lock. The
  committed rows are removed afterwards with triggers disabled.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Audit

  @tables ~w(anchor_sink_receipts audit_exports audit_anchors audit_signing_keys
             audit_accesses audit_events audit_chain_heads retention_markers
             qualification_evidences qualifications evidence_claims research_artifacts
             campaign_enrollments leads campaigns sequence_steps sequences contacts accounts
             icp_definitions decisions tool_invocations model_invocations agent_runs
             failures operations agent_definitions tokens users payloads
             provenance_snapshots tenants)

  @processes 16
  @appends_per_process 5

  setup do
    :ok = Sandbox.checkout(SdrAgent.Repo, sandbox: false)
    cleanup!()
    on_exit(fn -> with_connection(&cleanup!/0) end)
    :ok
  end

  test "concurrent appends keep a gap-free sequence and a valid chain" do
    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    kernel = struct(SdrAgent.Actor, type: :kernel, tenant_id: tenant.id)

    results =
      1..@processes
      |> Enum.map(fn worker ->
        Task.async(fn -> with_connection(fn -> run_worker(worker, kernel) end) end)
      end)
      |> Task.await_many(60_000)

    committed =
      results
      |> Enum.map(fn
        {:committed, n} -> n
        {:rolled_back, _} -> 0
      end)
      |> Enum.sum()

    rolled_back = Enum.count(results, &match?({:rolled_back, _}, &1))
    assert rolled_back > 0

    aud = struct(SdrAgent.Actor, type: :auditor_cli, tenant_id: tenant.id)
    {:ok, events} = Audit.list_events(actor: aud)
    sequences = Enum.map(events, & &1.sequence)

    assert sequences == Enum.to_list(1..length(events))
    assert length(events) == 2 + committed

    {:ok, report} = Audit.verify_chain(actor: aud)
    assert report.valid?, inspect(report.issues)
    assert report.last_sequence == 2 + committed
  end

  test "concurrent model-call reservations never exceed the run budget" do
    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    agent = struct(SdrAgent.Actor, type: :agent_runtime, tenant_id: tenant.id)
    %{run: run} = SdrAgent.AgentsFixtures.running_run(tenant, max_model_calls: 3)

    results =
      1..12
      |> Enum.map(fn _ ->
        Task.async(fn -> reserve_in_own_connection(run, agent) end)
      end)
      |> Task.await_many(60_000)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 3
    assert Enum.count(results, &match?({:error, %Ash.Error.Invalid{}}, &1)) == 9

    {:ok, reloaded} = SdrAgent.Agents.get_run(run.id, actor: agent)
    assert reloaded.budget.model_calls_reserved == 3

    aud = struct(SdrAgent.Actor, type: :auditor_cli, tenant_id: tenant.id)
    assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: aud)
  end

  test "concurrent reservations across runs never exceed the daily model-call limit" do
    previous = Application.get_env(:sdr_agent, :daily_model_call_limit)
    Application.put_env(:sdr_agent, :daily_model_call_limit, 2)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:sdr_agent, :daily_model_call_limit, previous),
        else: Application.delete_env(:sdr_agent, :daily_model_call_limit)
    end)

    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    agent = struct(SdrAgent.Actor, type: :agent_runtime, tenant_id: tenant.id)
    runs = for _ <- 1..8, do: SdrAgent.AgentsFixtures.running_run(tenant).run

    results =
      runs
      |> Enum.with_index()
      |> Enum.map(fn {run, n} ->
        Task.async(fn ->
          with_connection(fn ->
            SdrAgent.Agents.reserve_model_invocation(
              run,
              SdrAgent.AgentsFixtures.model_attrs("daily-race-#{n}"),
              actor: agent
            )
          end)
        end)
      end)
      |> Task.await_many(60_000)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 2, inspect(results)
    assert Enum.count(results, &match?({:error, {:budget_exhausted, :daily}}, &1)) == 6
    assert SdrAgent.Agents.daily_model_calls(tenant.id) == 2

    aud = struct(SdrAgent.Actor, type: :auditor_cli, tenant_id: tenant.id)
    assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: aud)
  end

  describe "linking an Operation to a Failure being resolved concurrently" do
    setup do
      {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
      agent = struct(SdrAgent.Actor, type: :agent_runtime, tenant_id: tenant.id)

      {:ok, operation} =
        SdrAgent.Operations.create_operation(
          %{
            kind: :research_lead,
            queue: :research,
            subject_resource: "SdrAgent.Sales.Lead",
            subject_id: Ecto.UUID.generate(),
            idempotency_key: "race-#{System.unique_integer([:positive])}",
            correlation_id: Ecto.UUID.generate(),
            max_attempts: 1
          },
          actor: agent
        )

      {:ok, operation} = SdrAgent.Operations.start_operation(operation, actor: agent)

      {:ok, failure} =
        SdrAgent.Operations.open_failure(
          %{
            operation_id: operation.id,
            subject_resource: "SdrAgent.Agents.AgentRun",
            subject_id: Ecto.UUID.generate(),
            class: :crash,
            severity: :critical,
            message: "run crashed"
          },
          actor: agent
        )

      %{tenant: tenant, agent: agent, operation: operation, failure: failure}
    end

    test "a resolution committed first makes the link refuse and roll back", ctx do
      parent = self()

      resolver =
        Task.async(fn ->
          with_connection(fn ->
            Audit.transaction(fn ->
              {:ok, _} =
                SdrAgent.Operations.resolve_failure(ctx.failure, %{resolution_note: "cleared"},
                  actor: ctx.agent
                )

              send(parent, :resolved_uncommitted)
              receive do: (:commit -> :ok)
            end)
          end)
        end)

      assert_receive :resolved_uncommitted, 10_000

      linker =
        Task.async(fn ->
          with_connection(fn ->
            SdrAgent.Operations.fail_operation(ctx.operation, %{failure_id: ctx.failure.id},
              actor: ctx.agent
            )
          end)
        end)

      # Let the link reach its read of the Failure while the resolve is open.
      Process.sleep(300)
      send(resolver.pid, :commit)
      assert {:ok, _} = Task.await(resolver, 30_000)

      assert {:error, %Ash.Error.Invalid{}} = Task.await(linker, 30_000)

      {:ok, operation} = SdrAgent.Operations.get_operation(ctx.operation.id, actor: ctx.agent)
      assert operation.status == :running

      assert operation_events(
               ctx.tenant,
               ~w(operations.operation.failed operations.operation.discarded)
             ) == []
    end

    test "a link committed first is followed by the resolution, in that order", ctx do
      results =
        race(2, fn
          1 ->
            with_connection(fn ->
              SdrAgent.Operations.fail_operation(ctx.operation, %{failure_id: ctx.failure.id},
                actor: ctx.agent
              )
            end)

          2 ->
            with_connection(fn ->
              SdrAgent.Operations.resolve_failure(ctx.failure, %{resolution_note: "cleared"},
                actor: ctx.agent
              )
            end)
        end)

      case results do
        [{:ok, discarded}, {:ok, _resolved}] ->
          assert discarded.last_failure_id == ctx.failure.id

          [failed, resolved] =
            operation_events(
              ctx.tenant,
              ~w(operations.operation.failed operations.failure.resolved)
            )

          assert failed.event_type == "operations.operation.failed"
          assert resolved.event_type == "operations.failure.resolved"

        [{:error, %Ash.Error.Invalid{}}, {:ok, _resolved}] ->
          assert operation_events(ctx.tenant, ~w(operations.operation.failed)) == []
      end
    end
  end

  test "concurrent anchor requests serialize to one contiguous range" do
    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    anchorer = struct(SdrAgent.Actor, type: :anchorer, tenant_id: tenant.id)
    kernel = struct(SdrAgent.Actor, type: :kernel, tenant_id: tenant.id)
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, _} =
      Audit.register_signing_key(%{key_id: "concurrent-key", public_key: public_key},
        actor: kernel
      )

    {:ok, _} = Audit.append(%{event_type: "test.anchorable", category: :system}, actor: anchorer)

    results =
      race(4, fn _ ->
        with_connection(fn ->
          SdrAgent.Audit.Anchoring.anchor(
            trigger: :event_count,
            actor: anchorer,
            private_key: private_key,
            sinks: []
          )
        end)
      end)

    anchors = for {:ok, anchor} <- results, is_struct(anchor), do: anchor
    reuses = for {:ok, {:existing, anchor}} <- results, do: anchor
    assert length(anchors) == 1
    assert length(reuses) == 3
    assert hd(anchors).from_sequence == 1
    assert Enum.all?(reuses, &(&1.id == hd(anchors).id))
  end

  test "two admins demoting each other concurrently leave exactly one active admin" do
    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    seeder = struct(SdrAgent.Actor, type: :seeder, tenant_id: tenant.id)

    [first, second] =
      for n <- 1..2 do
        {:ok, admin} =
          SdrAgent.Accounts.seed_user(
            %{
              id: Ecto.UUID.generate(),
              email: "race-admin-#{n}@example.test",
              display_name: "Race admin #{n}",
              role: :admin,
              password: "race-password-1",
              password_confirmation: "race-password-1"
            },
            actor: seeder
          )

        admin
      end

    for _round <- 1..3 do
      {:ok, _} = restore_admins([first, second], seeder)

      results =
        [{first, second}, {second, first}]
        |> Enum.map(fn {actor, target} ->
          Task.async(fn ->
            with_connection(fn ->
              SdrAgent.Accounts.change_role(target, :reviewer, actor: actor)
            end)
          end)
        end)
        |> Task.await_many(60_000)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1, inspect(results)
      assert Enum.count(results, &match?({:error, %Ash.Error.Invalid{}}, &1)) == 1

      {:ok, users} = SdrAgent.Accounts.list_users(actor: seeder)
      assert Enum.count(users, &(&1.role == :admin and &1.status == :active)) == 1
    end

    aud = struct(SdrAgent.Actor, type: :auditor_cli, tenant_id: tenant.id)
    assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: aud)
  end

  test "concurrent first-admin bootstraps: exactly one wins" do
    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")

    results =
      race(6, fn n ->
        with_connection(fn ->
          password = "boot-password-#{n}-0123456789"

          SdrAgent.Accounts.bootstrap_admin(%{
            email: "boot-#{n}@example.test",
            display_name: "Boot #{n}",
            password: password,
            password_confirmation: password
          })
        end)
      end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1, inspect(results)
    assert Enum.count(results, &match?({:error, %Ash.Error.Invalid{}}, &1)) == 5

    seeder = struct(SdrAgent.Actor, type: :seeder, tenant_id: tenant.id)
    {:ok, users} = SdrAgent.Accounts.list_users(actor: seeder)
    assert [%{role: :admin}] = users
  end

  # Re-promotes whichever of `admins` was demoted, as the remaining admin.
  defp restore_admins(admins, seeder) do
    {:ok, users} = SdrAgent.Accounts.list_users(actor: seeder)
    by_id = Map.new(users, &{&1.id, &1})
    current = Enum.map(admins, &Map.fetch!(by_id, &1.id))

    case Enum.split_with(current, &(&1.role == :admin)) do
      {[_, _], []} -> {:ok, :both_admins}
      {[admin], [demoted]} -> SdrAgent.Accounts.change_role(demoted, :admin, actor: admin)
    end
  end

  describe "concurrent decisions with one idempotency key" do
    setup do
      {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
      %{run: run, agent: agent} = SdrAgent.AgentsFixtures.running_run(tenant)
      %{tenant: tenant, run: run, agent: agent}
    end

    test "identical calls all succeed with one row and one event", ctx do
      attrs = decision_attrs(ctx.run, "clear")

      results = race(8, fn _ -> record_in_own_connection(attrs, ctx.agent) end)

      assert Enum.all?(results, &match?({:ok, _}, &1)), inspect(results)
      assert results |> Enum.map(fn {:ok, d} -> d.id end) |> Enum.uniq() |> length() == 1
      assert decision_events(ctx.tenant) == 1
    end

    test "different decisions: exactly one wins, the rest conflict", ctx do
      results =
        race(8, fn n ->
          record_in_own_connection(decision_attrs(ctx.run, "outcome-#{n}"), ctx.agent)
        end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1, inspect(results)

      conflicts =
        Enum.count(results, fn
          {:error, %Ash.Error.Invalid{errors: errors}} ->
            Enum.any?(
              errors,
              &match?(%{__struct__: SdrAgent.Agents.Errors.IdempotencyConflict}, &1)
            )

          _ ->
            false
        end)

      assert conflicts == 7, inspect(results)
      assert decision_events(ctx.tenant) == 1
    end
  end

  defp decision_attrs(run, outcome) do
    %{
      agent_run_id: run.id,
      kind: :phase_transition,
      mode: :deterministic,
      rule_id: "phase",
      rule_version: "1",
      subject_resource: "SdrAgent.Agents.AgentRun",
      subject_id: run.id,
      inputs: %{"from" => "research"},
      outcome: outcome,
      idempotency_key: "phase:concurrent"
    }
  end

  defp race(n, fun) do
    1..n
    |> Enum.map(fn i -> Task.async(fn -> fun.(i) end) end)
    |> Task.await_many(60_000)
  end

  defp record_in_own_connection(attrs, agent) do
    with_connection(fn -> SdrAgent.Agents.record_decision(attrs, actor: agent) end)
  end

  defp operation_events(tenant, types) do
    aud = struct(SdrAgent.Actor, type: :auditor_cli, tenant_id: tenant.id)
    {:ok, events} = Audit.list_events(actor: aud)
    Enum.filter(events, &(&1.event_type in types))
  end

  defp decision_events(tenant) do
    aud = struct(SdrAgent.Actor, type: :auditor_cli, tenant_id: tenant.id)
    {:ok, events} = Audit.list_events(actor: aud)
    Enum.count(events, &(&1.event_type == "agents.decision.recorded"))
  end

  defp run_worker(worker, kernel) do
    if rem(worker, 4) == 0 do
      {:error, :abandoned} =
        Audit.transaction(fn ->
          append_many(worker, kernel)
          SdrAgent.Repo.rollback(:abandoned)
        end)

      {:rolled_back, worker}
    else
      for _ <- 1..@appends_per_process, do: commit_one(worker, kernel)

      {:committed, @appends_per_process}
    end
  end

  defp commit_one(worker, kernel) do
    {:ok, _} = Audit.transaction(fn -> append_one(worker, kernel) end)
  end

  defp append_many(worker, kernel) do
    for _ <- 1..@appends_per_process, do: append_one(worker, kernel)
  end

  defp append_one(worker, kernel) do
    {:ok, event} =
      Audit.append(
        %{
          event_type: "test.concurrent",
          category: :system,
          subject_resource: "Test",
          subject_id: "worker-#{worker}",
          action: "append",
          payload: %{worker: worker}
        },
        actor: kernel
      )

    event
  end

  defp reserve_in_own_connection(run, agent) do
    with_connection(fn -> SdrAgent.Agents.reserve_model_call(run, actor: agent) end)
  end

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
