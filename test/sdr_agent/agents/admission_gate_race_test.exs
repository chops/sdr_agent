defmodule SdrAgent.Agents.AdmissionGateRaceTest do
  @moduledoc """
  R0-07 slice B with real connections (packet rows B4', B5'; entity PASS at
  3600fcf). Every process reserves on its own non-sandboxed connection.

    * **Store trust is observation-time trust (B5').** A configured root
      changed while the reservation waits on a held run lock is refused
      (`:store_changed`); a same-path filesystem change after the pre-lock
      observation is not refused at that step (the documented residual) and
      is caught by the launch's fresh observation before any spend.
    * **Calibration order (B4').** Two concurrent calibration reservations
      serialise on the chain head: exactly one is admitted and the other is
      refused `:calibration_evidence_pending`.

  Committed rows are removed afterwards with triggers disabled.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit

  @tables ~w(audit_accesses audit_events audit_chain_heads model_invocations
             model_call_allocations model_call_grants agent_runs failures operations
             agent_definitions tokens users payloads provenance_snapshots tenants)

  setup do
    admitted = AdmissionFixtures.admit_tuples!()
    :ok = Sandbox.checkout(SdrAgent.Repo, sandbox: false)
    cleanup!()
    on_exit(fn -> with_connection(&cleanup!/0) end)
    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")

    AgentsFixtures.grant!(tenant, %{
      total_attempts: 10,
      allocations: [
        %{key: :b1, applies_to: [:b1], attempts: 5},
        %{key: :proof, applies_to: [:proof], attempts: 4}
      ]
    })

    %{tenant: tenant, root: admitted.root}
  end

  # Holds the run row FOR UPDATE on its own connection until :go.
  defp hold_run!(run) do
    parent = self()
    holder = Task.async(fn -> with_connection(fn -> hold(run, parent) end) end)
    assert_receive :run_held, 10_000
    holder
  end

  defp hold(run, parent) do
    SdrAgent.Repo.transaction(fn ->
      SQL.query!(SdrAgent.Repo, "SELECT id FROM agent_runs WHERE id = $1 FOR UPDATE", [
        Ecto.UUID.dump!(run.id)
      ])

      send(parent, :run_held)
      receive do: (:go -> :ok)
    end)
  end

  defp reserve_async(run, agent, key, opts \\ []) do
    Task.async(fn ->
      with_connection(fn ->
        Agents.reserve_model_invocation(
          run,
          key |> AgentsFixtures.claude_attrs() |> Map.put(:request, ~s({"k":"#{key}"})),
          [actor: agent] ++ opts
        )
      end)
    end)
  end

  test "a configured root changed while the reservation waits is refused", ctx do
    %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
    holder = hold_run!(run)

    reservation = reserve_async(run, agent, "changed")
    await_lock_waiters(1)

    # After the pre-lock observation, before the locks are granted.
    other = SdrAgent.Test.WitnessRoot.mkdir!("other-#{System.os_time()}")
    on_exit(fn -> File.rm_rf(other) end)
    AdmissionFixtures.put_root!(other)
    send(holder.pid, :go)
    Task.await(holder, 30_000)

    assert {:error, %Refused{reason: :witness_store_untrusted, check: :store_changed}} =
             Task.await(reservation, 30_000)

    assert Agents.ModelInvocation
           |> Ash.Query.filter(agent_run_id == ^run.id)
           |> Ash.count!(authorize?: false) == 0
  end

  test "a same-path filesystem change after the observation is caught at launch", ctx do
    %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
    holder = hold_run!(run)

    reservation = reserve_async(run, agent, "same-path")
    await_lock_waiters(1)

    # The documented residual: pure path equality under the locks cannot see
    # a permission change of the same root after the observation.
    File.chmod!(ctx.root, 0o770)
    send(holder.pid, :go)
    Task.await(holder, 30_000)
    assert {:ok, invocation} = Task.await(reservation, 30_000)

    # The launch observes the root afresh, before its locks, and refuses.
    assert {:error, %Refused{stage: :launch, reason: :witness_store_untrusted}} =
             Agents.admit_launch(invocation.id, :claude_cli_opus, actor: agent)

    stored = Ash.get!(Agents.ModelInvocation, invocation.id, authorize?: false)
    assert {stored.status, stored.sent_at} == {:failed, nil}
  end

  test "concurrent calibration reservations: exactly one is admitted", ctx do
    runs = for _ <- 1..4, do: AgentsFixtures.running_run(ctx.tenant, usage_origin: :proof)

    results =
      runs
      |> Enum.with_index()
      |> Enum.map(fn {%{run: run, agent: agent}, n} ->
        reserve_async(run, agent, "cal-#{n}", calibration: AdmissionFixtures.calibration())
      end)
      |> Task.await_many(60_000)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1, inspect(results)

    assert Enum.count(
             results,
             &match?({:error, %Refused{reason: :calibration_evidence_pending}}, &1)
           ) == 3,
           inspect(results)

    assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: auditor(ctx))
  end

  defp await_lock_waiters(count, attempts \\ 200) do
    %{rows: [[waiting]]} =
      SQL.query!(
        SdrAgent.Repo,
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() " <>
          "AND wait_event_type = 'Lock'",
        []
      )

    cond do
      waiting >= count ->
        :ok

      attempts == 0 ->
        flunk("expected #{count} lock waiters, saw #{waiting}")

      true ->
        Process.sleep(25)
        await_lock_waiters(count, attempts - 1)
    end
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
