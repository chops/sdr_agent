defmodule SdrAgent.Agents.RecoverCalibrationRaceTest do
  @moduledoc """
  R0-07 slice E4c-c2 (Codex 01a135d9): the calibration recovery under real
  concurrency. Two identical attested recoveries of one `sent` invocation
  start while the chain head is held; they serialize on the run lock, so
  exactly one `calibration.owner_attested` event and one transition to
  `unknown` are written and both return the recovered invocation. Every
  process uses its own non-sandboxed connection; committed rows are removed
  afterwards with triggers disabled.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Checks.CalibrationAdmission
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
      %{total_attempts: 4, allocations: [%{key: :proof, applies_to: [:proof], attempts: 4}]},
      admin
    )

    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant, usage_origin: :proof)
    claim = Ash.UUIDv7.generate()

    {:ok, reserved} =
      AdmissionFixtures.admitting(fn ->
        Agents.reserve_model_invocation(run, AgentsFixtures.claude_attrs("recover-race"),
          actor: agent,
          calibration:
            CalibrationAdmission.context(:claude_cli_opus, AdmissionFixtures.entry(),
              claim: claim
            )
        )
      end)

    {:ok, sent} = Agents.mark_model_invocation_sent(reserved, actor: agent)
    %{tenant: tenant, agent: agent, invocation: sent, claim: claim}
  end

  # Checked by assertion before any task or held lock starts.
  setup do
    Code.ensure_loaded!(Agents)

    assert function_exported?(Agents, :recover_calibration, 3),
           "Agents.recover_calibration/3 is not defined"

    :ok
  end

  test "two identical attested recoveries write one event and one transition", ctx do
    attestation = %{
      schema: "r0-calibration-attestation/1",
      attestation_id: Ash.UUIDv7.generate(),
      instance_id: ctx.claim,
      invocation_id: ctx.invocation.id,
      ticket_id: Ash.UUIDv7.generate(),
      observation: %{state: "launch_pending", root_pid: nil, process_group_id: nil},
      confirmed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
    }

    parent = self()
    head = Task.async(fn -> with_connection(fn -> hold_head(ctx, parent) end) end)
    assert_receive :head_held, 10_000

    tasks =
      Enum.map(1..2, fn waiters ->
        task = Task.async(fn -> recover(ctx, attestation) end)
        await_lock_waiters(waiters)
        task
      end)

    send(head.pid, :go)
    assert {:ok, _} = Task.await(head, 30_000)
    results = Enum.map(tasks, &Task.await(&1, 30_000))

    assert Enum.all?(results, &match?({:ok, %{invocation: %{status: :unknown}}}, &1)),
           inspect(results)

    assert length(events(ctx, "calibration.owner_attested")) == 1
    assert length(events(ctx, "model.invocation.unknown")) == 1
    assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: auditor(ctx))
  end

  defp recover(ctx, attestation) do
    with_connection(fn ->
      apply(Agents, :recover_calibration, [
        ctx.invocation,
        {:attested, attestation},
        [actor: ctx.agent]
      ])
    end)
  end

  defp hold_head(ctx, parent) do
    SdrAgent.Repo.transaction(fn ->
      {:ok, _} = Audit.Kernel.lock_head(ctx.tenant.id)
      send(parent, :head_held)
      receive do: (:go -> :ok)
    end)
  end

  defp events(ctx, type), do: AuditCase.events_of_type(ctx.tenant, type)

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
