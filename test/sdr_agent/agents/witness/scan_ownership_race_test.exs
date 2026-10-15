defmodule SdrAgent.Agents.Witness.ScanOwnershipRaceTest do
  @moduledoc """
  R0-07 slice C, row G3 under real concurrency (`sandbox: false`, each
  side on its own connection): the scan's locked ownership recheck sees the
  committed outcome of whichever gate step holds the invocation.

    * the gate's reconcile holds the invocation `FOR UPDATE`: the scan's
      persist waits, then sees no release (still the gate's) — deferred,
      no link and no attention;
    * finalization holds it `FOR SHARE` and commits the release: the scan's
      persist waits, then sees the release — backfill is allowed.
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

  @tables ~w(model_result_releases wire_witness_links model_invocations model_call_allocations
             model_call_grants anchor_sink_receipts audit_exports audit_anchors
             audit_signing_keys audit_accesses audit_events audit_chain_heads
             retention_markers decisions tool_invocations agent_runs failures operations
             oban_jobs agent_definitions tokens users payloads provenance_snapshots tenants)

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    cleanup!()
    root = GateFixtures.root!()

    on_exit(fn ->
      File.rm_rf!(root)
      with_connection(&cleanup!/0)
    end)

    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    AgentsFixtures.grant!(tenant)
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    invocation = AgentsFixtures.claude_completed!(run, agent, "scan-race")
    rec = SdrAgent.Actor.system(:reconciler, tenant.id)
    %{tenant: tenant, agent: agent, invocation: invocation, root: root, rec: rec}
  end

  defp lock_invocation!(ctx, mode) do
    {:ok, %ModelInvocation{}} =
      ModelInvocation
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(ctx.tenant.id))
      |> Ash.Query.filter(id == ^ctx.invocation.id)
      |> Ash.Query.lock(mode)
      |> Ash.read_one()
  end

  # Holds the invocation in `mode` until told to go on, runs `then` (still
  # in the transaction) and commits.
  defp holder(ctx, mode, then) do
    parent = self()

    held = fn -> Audit.transaction(fn -> hold(ctx, mode, parent, then) end) end
    Task.async(fn -> with_connection(held) end)
  end

  defp hold(ctx, mode, parent, then) do
    lock_invocation!(ctx, mode)
    send(parent, :held)

    receive do
      :go -> then.()
    after
      30_000 -> raise "holder never released"
    end
  end

  defp scan(ctx) do
    Task.async(fn ->
      with_connection(fn ->
        Witness.reconcile(ctx.invocation.id, actor: ctx.rec, store_root: ctx.root)
      end)
    end)
  end

  # Starts the scan while the holder holds the invocation; proves it is
  # blocked, then lets the holder commit; returns the scan's result.
  defp race(ctx, holder) do
    assert_receive :held, 10_000
    scan = scan(ctx)
    assert Task.yield(scan, 500) == nil, "the scan must wait for the holder's commit"
    send(holder.pid, :go)
    assert {:ok, _} = Task.await(holder, 30_000)
    Task.await(scan, 30_000)
  end

  defp decide_withheld(ctx, cause) do
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
        reason: :witness_missing,
        gate_cause_id: cause.id,
        gate_classification: :no_exchange
      }

      {:ok, release} = Agents.decide_result_release(attrs, actor: ctx.agent, prelocked: prelocked)
      release
    end)
  end

  defp written(ctx) do
    {:ok, links} = Agents.list_wire_witness_links(ctx.invocation.id, actor: ctx.rec)

    {:ok, failures} =
      Failure
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(ctx.tenant.id))
      |> Ash.Query.filter(subject_id == ^ctx.invocation.id and status in [:open, :acknowledged])
      |> Ash.read()

    {links, failures}
  end

  test "the gate's reconcile commit: the waiting scan is deferred and writes nothing", ctx do
    holder = holder(ctx, "FOR UPDATE", fn -> :reconciled end)

    assert {:ok, %{status: :deferred_to_gate}} = race(ctx, holder)
    assert written(ctx) == {[], []}
  end

  test "the finalizer's commit: the waiting scan sees the release and backfills", ctx do
    # The finalizer's own cause, opened before it (so it is not the scan's).
    cause = GateFixtures.cause!(ctx.invocation)
    holder = holder(ctx, "FOR SHARE", fn -> decide_withheld(ctx, cause) end)

    # No capture exists, so the backfill's honest answer is unwitnessed.
    assert {:ok, %{status: :unwitnessed}} = race(ctx, holder)
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
