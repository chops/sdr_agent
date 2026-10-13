defmodule SdrAgent.Agents.FinishCalibrationRaceTest do
  @moduledoc """
  R0-07 slice E, row R11-2: the guarded calibration finish under real
  concurrency. It locks run `FOR UPDATE` first, so a concurrent writer of
  the run, or a second finish, waits behind it and then sees its result: the
  same hash replays the one latch, a different hash is
  `:calibration_evidence_conflict`. Every process uses its own
  non-sandboxed connection; committed rows are removed afterwards with
  triggers disabled.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.AuditCase

  @tables ~w(audit_accesses audit_events audit_chain_heads model_result_releases
             wire_witness_links model_invocations model_call_allocations model_call_grants
             agent_runs failures operations oban_jobs agent_definitions tokens users
             payloads provenance_snapshots tenants)

  setup do
    AdmissionFixtures.admit_tuples!()
    :ok = Sandbox.checkout(SdrAgent.Repo, sandbox: false)
    cleanup!()
    on_exit(fn -> with_connection(&cleanup!/0) end)
    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    admin = AuditCase.human(:admin, tenant)

    AgentsFixtures.grant!(
      tenant,
      %{
        total_attempts: 4,
        allocations: [%{key: :proof, applies_to: [:proof], attempts: 4}]
      },
      admin
    )

    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant, usage_origin: :proof)

    {:ok, reserved} =
      AdmissionFixtures.admitting(fn ->
        Agents.reserve_model_invocation(run, AgentsFixtures.claude_attrs("cal-race"),
          actor: agent,
          calibration: AdmissionFixtures.calibration()
        )
      end)

    {:ok, sent} = Agents.mark_model_invocation_sent(reserved, actor: agent)

    {:ok, invocation} =
      Agents.fail_model_invocation(sent, %{error: %{"kind" => "provider_error"}}, actor: agent)

    %{tenant: tenant, run: run, agent: agent, invocation: invocation}
  end

  # Checked by assertion in the test process before any task or held lock
  # starts, so a missing implementation fails as an assertion.
  setup do
    Code.ensure_loaded!(Agents)

    assert function_exported?(Agents, :finish_calibration, 3),
           "Agents.finish_calibration/3 is not defined"

    :ok
  end

  test "a writer holding the run: the finish waits, then latches", ctx do
    parent = self()

    writer =
      Task.async(fn ->
        with_connection(fn ->
          SdrAgent.Repo.transaction(fn ->
            lock!("SELECT id FROM agent_runs WHERE id = $1 FOR UPDATE", ctx.run.id)
            send(parent, :run_locked)
            receive do: (:go -> :ok)
          end)
        end)
      end)

    assert_receive :run_locked, 10_000
    finish = Task.async(fn -> finish(ctx, sha("held")) end)
    await_lock_waiters(1)
    send(writer.pid, :go)

    assert {:ok, _} = Task.await(writer, 30_000)
    assert {:ok, %{release: latch, run: run}} = Task.await(finish, 30_000)
    assert latch.evidence_sha256 == sha("held")
    assert {run.status, run.status_reason} == {:succeeded, :calibration_latched}
    assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: auditor(ctx))
  end

  test "two finishes with the same hash converge on one latch", ctx do
    [a, b] = race(ctx, [sha("same"), sha("same")])

    assert {:ok, %{release: first}} = a
    assert {:ok, %{release: second}} = b
    assert first.id == second.id
    assert length(events(ctx, "model.result.calibration")) == 1
    assert length(events(ctx, "agents.run.calibration_latched")) == 1
    assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: auditor(ctx))
  end

  test "two finishes with different hashes: one latches, the other conflicts", ctx do
    results = race(ctx, [sha("one"), sha("two")])

    assert [{:ok, %{release: latch}}] = Enum.filter(results, &match?({:ok, _}, &1))

    assert [{:error, :calibration_evidence_conflict}] =
             Enum.reject(results, &match?({:ok, _}, &1))

    assert latch.evidence_sha256 in [sha("one"), sha("two")]
    assert length(events(ctx, "model.result.calibration")) == 1
    assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: auditor(ctx))
  end

  # Both finishes start while the chain head is held, so each has taken (or
  # waits for) the run lock before either can decide.
  defp race(ctx, hashes) do
    parent = self()
    head = Task.async(fn -> with_connection(fn -> hold_head(ctx, parent) end) end)
    assert_receive :head_held, 10_000

    tasks =
      hashes
      |> Enum.with_index(1)
      |> Enum.map(fn {hash, waiters} ->
        task = Task.async(fn -> finish(ctx, hash) end)
        await_lock_waiters(waiters)
        task
      end)

    send(head.pid, :go)
    assert {:ok, _} = Task.await(head, 30_000)
    Enum.map(tasks, &Task.await(&1, 30_000))
  end

  defp finish(ctx, hash) do
    with_connection(fn ->
      apply(Agents, :finish_calibration, [ctx.invocation, %{sha256: hash}, [actor: ctx.agent]])
    end)
  end

  defp hold_head(ctx, parent) do
    SdrAgent.Repo.transaction(fn ->
      {:ok, _} = Audit.Kernel.lock_head(ctx.tenant.id)
      send(parent, :head_held)
      receive do: (:go -> :ok)
    end)
  end

  defp events(ctx, type) do
    with_connection(fn -> AuditCase.events_of_type(ctx.tenant, type) end)
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

  defp sha(label), do: :crypto.hash(:sha256, label) |> Base.encode16(case: :lower)

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
