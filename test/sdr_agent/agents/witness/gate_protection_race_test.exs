defmodule SdrAgent.Agents.Witness.GateProtectionRaceTest do
  @moduledoc """
  R0-07 slice C, review MF3, under real concurrency (`sandbox: false`):
  a gate-mode reconcile that observed before a competing finalizer, and
  persists after it, must honour the release's protected cause. The
  finalizer holds the invocation `FOR SHARE`, so the reconcile's persist
  (`FOR UPDATE`) waits. The finalizer then commits a withheld release
  bound to the gate's earlier warning. The reconcile's changed condition
  would normally resolve that warning; under protection it stays open.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  require Ash.Query

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ReleaseDecision.Prelocked
  alias SdrAgent.Agents.Witness
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.GateFixtures
  alias SdrAgent.Operations.Failure
  alias SdrAgent.Repo
  alias SdrAgent.Test.FakeWitnessProxy, as: Proxy

  @tables ~w(model_result_releases wire_witness_links model_invocations model_call_allocations
             model_call_grants anchor_sink_receipts audit_exports audit_anchors
             audit_signing_keys audit_accesses audit_events audit_chain_heads
             retention_markers decisions tool_invocations agent_runs failures operations
             oban_jobs agent_definitions tokens users payloads provenance_snapshots tenants)

  setup do
    unless Code.ensure_loaded?(Proxy),
      do: Code.require_file(Path.expand("../../../support/fake_witness_proxy.exs", __DIR__))

    :ok = Sandbox.checkout(Repo, sandbox: false)
    cleanup!()
    root = GateFixtures.root!()

    on_exit(fn ->
      File.rm_rf!(root)
      with_connection(&cleanup!/0)
    end)

    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    AgentsFixtures.grant!(tenant)
    %{run: run, agent: agent} = AgentsFixtures.operated_run(tenant)
    invocation = AgentsFixtures.claude_completed!(run, agent, "protection-race")
    rec = SdrAgent.Actor.system(:reconciler, tenant.id)
    gate = %{run_id: run.id, operation_id: run.operation_id}

    %{tenant: tenant, agent: agent, invocation: invocation, root: root, rec: rec, gate: gate}
  end

  defp reconcile(ctx),
    do: Witness.reconcile(ctx.invocation.id, actor: ctx.rec, store_root: ctx.root, gate: ctx.gate)

  defp live_warnings(ctx) do
    {:ok, failures} =
      Failure
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(ctx.tenant.id))
      |> Ash.Query.filter(
        subject_id == ^ctx.invocation.id and severity == :warning and
          status in [:open, :acknowledged]
      )
      |> Ash.read()

    failures
  end

  test "a gate reconcile persisting after a competing finalizer keeps its bound cause", ctx do
    # The gate's first poll: no capture yet, one pending warning W.
    assert {:ok, _} = reconcile(ctx)
    assert [warning] = live_warnings(ctx)

    # The condition changes (an incomplete capture): a fresh reconcile would
    # resolve W as stale.
    Proxy.exchange!(ctx.root, ctx.invocation.id,
      request: Proxy.messages_request("synthetic"),
      response: Proxy.sse_response("{}"),
      capture_complete: false,
      outcome: "capture_incomplete"
    )

    parent = self()

    holder =
      Task.async(fn ->
        with_connection(fn ->
          Audit.transaction(fn -> finalize_on_go(ctx, warning, parent) end)
        end)
      end)

    assert_receive :held, 10_000
    late = Task.async(fn -> with_connection(fn -> reconcile(ctx) end) end)
    assert Task.yield(late, 700) == nil, "the reconcile's persist must wait for the finalizer"
    send(holder.pid, :go)
    assert {:ok, %{disposition: :withheld}} = Task.await(holder, 30_000)
    assert {:ok, _} = Task.await(late, 30_000)

    assert warning.id in Enum.map(live_warnings(ctx), & &1.id)
  end

  defp finalize_on_go(ctx, cause, parent) do
    {:ok, %{}} =
      ModelInvocation
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(ctx.tenant.id))
      |> Ash.Query.filter(id == ^ctx.invocation.id)
      |> Ash.Query.lock("FOR SHARE")
      |> Ash.read_one()

    send(parent, :held)

    receive do
      :go -> decide(ctx, cause)
    after
      20_000 -> raise "finalizer never released"
    end
  end

  defp decide(ctx, cause) do
    {:ok, _head} = Kernel.lock_head(ctx.tenant.id)

    bindings = %{
      tenant_id: ctx.tenant.id,
      model_invocation_id: ctx.invocation.id,
      wire_witness_link_id: nil,
      receipt_id: cause.id
    }

    Prelocked.run(bindings, fn prelocked ->
      attrs = %{
        model_invocation_id: ctx.invocation.id,
        disposition: :withheld,
        reason: :witness_timeout,
        gate_cause_id: cause.id,
        gate_classification: :capture_pending
      }

      {:ok, release} = Agents.decide_result_release(attrs, actor: ctx.agent, prelocked: prelocked)
      release
    end)
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
