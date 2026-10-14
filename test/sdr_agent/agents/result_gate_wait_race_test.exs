defmodule SdrAgent.Agents.ResultGateWaitRaceTest do
  @moduledoc """
  R0-07 slice C (packet section 4, "Gate"): no lock is held during the
  result gate's wait. Under real concurrency (`sandbox: false`), while one
  process waits for a capture that never comes, another reserves a model
  call on the same run — run row lock, chain head, grant admission — and
  commits before the wait ends. Committed rows are removed afterwards.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.GateFixtures

  @tables ~w(model_result_releases wire_witness_links model_invocations model_call_allocations
             model_call_grants anchor_sink_receipts audit_exports audit_anchors
             audit_signing_keys audit_accesses audit_events audit_chain_heads
             retention_markers decisions tool_invocations agent_runs failures operations
             agent_definitions tokens users payloads provenance_snapshots tenants)

  setup do
    :ok = Sandbox.checkout(SdrAgent.Repo, sandbox: false)
    cleanup!()
    root = GateFixtures.root!()
    config = Application.get_env(:sdr_agent, ResultGate)
    Application.put_env(:sdr_agent, ResultGate, wait_ms: 3_000, poll_ms: 50)

    on_exit(fn ->
      File.rm_rf!(root)

      if config,
        do: Application.put_env(:sdr_agent, ResultGate, config),
        else: Application.delete_env(:sdr_agent, ResultGate)

      with_connection(&cleanup!/0)
    end)

    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    AgentsFixtures.grant!(tenant)
    %{run: run, agent: agent, operation: operation} = AgentsFixtures.operated_run(tenant)
    %{tenant: tenant, run: run, agent: agent, operation: operation, root: root}
  end

  test "a concurrent reservation on the same run commits while the gate waits", ctx do
    # Completed through the domain API: no exchange is ever captured.
    invocation = AgentsFixtures.claude_completed!(ctx.run, ctx.agent, "gate-race-call")
    gate = %{run_id: ctx.run.id, operation_id: ctx.operation.id}

    waiter =
      Task.async(fn ->
        with_connection(fn ->
          started = System.monotonic_time(:millisecond)
          result = ResultGate.await(invocation, gate, store_root: ctx.root)
          {result, System.monotonic_time(:millisecond) - started}
        end)
      end)

    Process.sleep(300)

    # This process holds its own connection (setup): a separate transaction.
    {:ok, run} = Agents.get_run(ctx.run.id, actor: ctx.agent)
    started = System.monotonic_time(:millisecond)
    attrs = AgentsFixtures.claude_attrs("gate-race-#{System.unique_integer([:positive])}")
    # R0-07 slice B: admitted only for the reservation itself.
    reserved =
      SdrAgent.AdmissionFixtures.admitting(fn ->
        Agents.reserve_model_invocation(run, attrs, actor: ctx.agent)
      end)

    reserve_ms = System.monotonic_time(:millisecond) - started

    assert {:ok, %{status: :reserved}} = reserved
    {{:timeout, _receipt}, wait_ms} = Task.await(waiter, 30_000)

    # The reservation did not wait for the gate's bound.
    assert reserve_ms < 2_000, inspect(reserve_ms)
    assert wait_ms >= 3_000, inspect(wait_ms)
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

      %{rows: rows} =
        SQL.query!(
          SdrAgent.Repo,
          "SELECT t FROM unnest($1::text[]) t WHERE to_regclass(t) IS NOT NULL",
          [@tables]
        )

      SQL.query!(SdrAgent.Repo, "TRUNCATE #{Enum.join(List.flatten(rows), ", ")} CASCADE", [])
    end)
  end
end
