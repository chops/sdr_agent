defmodule SdrAgent.Agents.Witness.RaceTest do
  @moduledoc """
  C2/C4 under real concurrency (`sandbox: false`): duplicate enqueues of one
  invocation produce exactly one job and one `reconcile_model` Operation;
  concurrent reconciliations of a missing witness leave exactly one live
  attention condition. Committed rows are removed afterwards with triggers
  disabled.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 180_000

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Witness
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.Test.WitnessRoot

  @tables ~w(oban_jobs wire_witness_links anchor_sink_receipts audit_exports audit_anchors
             audit_signing_keys audit_accesses audit_events audit_chain_heads retention_markers
             decisions tool_invocations model_invocations agent_runs failures operations
             agent_definitions tokens users payloads provenance_snapshots tenants)

  setup do
    :ok = Sandbox.checkout(SdrAgent.Repo, sandbox: false)
    cleanup!()

    root = WitnessRoot.mkdir!("race")
    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf!(root)
      with_connection(&cleanup!/0)
    end)

    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    attrs = AgentsFixtures.model_attrs("race-witness") |> Map.put(:provider, :claude_cli)
    {:ok, invocation} = Agents.reserve_model_invocation(run, attrs, actor: agent)
    {:ok, invocation} = Agents.mark_model_invocation_sent(invocation, actor: agent)

    {:ok, invocation} =
      Agents.complete_model_invocation(invocation, AgentsFixtures.completion(), actor: agent)

    %{
      tenant: tenant,
      invocation: invocation,
      root: root,
      rec: SdrAgent.Actor.system(:reconciler, tenant.id)
    }
  end

  test "concurrent duplicate enqueues create one job and one Operation", ctx do
    results = race(8, fn -> Witness.enqueue(ctx.invocation.id, actor: ctx.rec) end)
    assert Enum.all?(results, &match?({:ok, _}, &1)), inspect(results)
    assert results |> Enum.map(fn {:ok, op} -> op.id end) |> Enum.uniq() |> length() == 1

    %{rows: [[jobs]]} =
      SQL.query!(SdrAgent.Repo, "SELECT count(*) FROM oban_jobs WHERE queue = 'reconciliation'")

    assert jobs == 1
  end

  test "concurrent reconciliations of a missing witness open one live condition", ctx do
    results =
      race(4, fn ->
        Witness.reconcile(ctx.invocation.id, actor: ctx.rec, store_root: ctx.root)
      end)

    assert Enum.all?(results, &match?({:ok, %{status: :unwitnessed}}, &1)), inspect(results)

    %{rows: [[live]]} =
      SQL.query!(
        SdrAgent.Repo,
        "SELECT count(*) FROM failures WHERE status IN ('open','acknowledged') AND class = 'reconciliation_required'"
      )

    assert live == 1
  end

  defp race(n, fun) do
    1..n
    |> Enum.map(fn _ -> Task.async(fn -> with_connection(fun) end) end)
    |> Task.await_many(60_000)
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
