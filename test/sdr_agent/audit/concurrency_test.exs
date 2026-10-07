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

  @tables ~w(audit_accesses audit_events audit_chain_heads retention_markers decisions
             tool_invocations model_invocations agent_runs agent_definitions payloads
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

    admin = %SdrAgent.Test.Human{id: Ecto.UUID.generate(), role: :admin, tenant_id: tenant.id}
    {:ok, events} = Audit.list_events(actor: admin)
    sequences = Enum.map(events, & &1.sequence)

    assert sequences == Enum.to_list(1..length(events))
    assert length(events) == 2 + committed

    {:ok, report} = Audit.verify_chain(actor: admin)
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

    admin = %SdrAgent.Test.Human{id: Ecto.UUID.generate(), role: :admin, tenant_id: tenant.id}
    assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: admin)
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
