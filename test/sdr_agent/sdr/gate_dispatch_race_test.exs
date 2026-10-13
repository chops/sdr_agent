defmodule SdrAgent.SDR.GateDispatchRaceTest do
  @moduledoc """
  R0-07 slice C, review MF2, under real concurrency (`sandbox: false`):
  `SdrAgent.SDR.StaleRunSweeper` chooses between crash recovery and gate
  recovery from an unlocked observation. It must decide again after the run
  lock and before any crash append. Here the run lock is held while a
  `sent` call settles `completed`. The sweeper, started against the old
  `sent` state, waits for that commit, then sees a completed generation-2
  output with no release. It recovers through the gate (withheld, stopped
  `:witness_unreconciled`) and never as a crash.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.Clock
  alias SdrAgent.Repo
  alias SdrAgent.SDR.StaleRunSweeper

  @tables ~w(model_result_releases wire_witness_links model_invocations model_call_allocations
             model_call_grants anchor_sink_receipts audit_exports audit_anchors
             audit_signing_keys audit_accesses audit_events audit_chain_heads
             retention_markers decisions tool_invocations agent_runs failures operations
             oban_jobs agent_definitions tokens users payloads provenance_snapshots tenants)

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    cleanup!()
    on_exit(fn -> with_connection(&cleanup!/0) end)

    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    AgentsFixtures.grant!(tenant)
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)

    {:ok, reserved} =
      Agents.reserve_model_invocation(run, AgentsFixtures.claude_attrs("dispatch-race"),
        actor: agent
      )

    {:ok, sent} = Agents.mark_model_invocation_sent(reserved, actor: agent)
    stale = DateTime.add(run.started_at, StaleRunSweeper.stale_after_seconds() + 1, :second)
    %{tenant: tenant, run: run, agent: agent, sent: sent, stale: stale}
  end

  test "dispatch is decided again after a sent-to-completed settlement wins the run lock",
       ctx do
    parent = self()

    holder =
      Task.async(fn ->
        with_connection(fn -> Audit.transaction(fn -> settle(ctx, parent) end) end)
      end)

    assert_receive :run_held, 10_000

    sweeper =
      Task.async(fn ->
        Clock.freeze(ctx.stale)
        with_connection(fn -> StaleRunSweeper.sweep(ctx.tenant.id) end)
      end)

    assert Task.yield(sweeper, 700) == nil, "the sweeper must wait for the run lock"
    send(holder.pid, :complete)
    assert {:ok, %{status: :completed}} = Task.await(holder, 30_000)
    assert :ok = Task.await(sweeper, 30_000)

    {:ok, run} = Agents.get_run(ctx.run.id, actor: ctx.agent)
    refute run.status_reason == :crash
    assert {run.status, run.status_reason} == {:failed, :witness_unreconciled}

    assert {:ok, %{disposition: :withheld, reason: :gate_interrupted}} =
             Agents.get_result_release(ctx.sent.id, actor: ctx.agent)
  end

  # Holds the run row lock, then settles the sent call `completed`.
  defp settle(ctx, parent) do
    SQL.query!(Repo, "SELECT id FROM agent_runs WHERE id = $1 FOR UPDATE", [
      Ecto.UUID.dump!(ctx.run.id)
    ])

    send(parent, :run_held)

    receive do
      :complete ->
        {:ok, invocation} =
          Agents.complete_model_invocation(ctx.sent, AgentsFixtures.completion(),
            actor: ctx.agent
          )

        invocation
    after
      20_000 -> raise "completion holder not released"
    end
  end

  defp with_connection(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(Repo)
    end
  end

  defp cleanup! do
    Repo.transaction(fn ->
      SQL.query!(Repo, "SET LOCAL session_replication_role = replica", [])

      %{rows: rows} =
        SQL.query!(
          Repo,
          "SELECT t FROM unnest($1::text[]) t WHERE to_regclass(t) IS NOT NULL",
          [@tables]
        )

      SQL.query!(Repo, "TRUNCATE #{Enum.join(List.flatten(rows), ", ")} CASCADE", [])
    end)
  end
end
