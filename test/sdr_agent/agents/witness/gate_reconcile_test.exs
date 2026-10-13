defmodule SdrAgent.Agents.Witness.GateReconcileTest do
  @moduledoc """
  R0-07 slice C, step 2 of "Commit and lock boundaries" (packet section 2;
  entity PASS at 1da747a): `Witness.reconcile/2` with `gate: %{run_id,
  operation_id}`, passed only by the facade gate step and run recovery.

    * The gate must be the invocation's own run and that run's Operation.
    * The Failure reconcile opens carries `operation_id`; without `gate:`
      (the scan) it carries none, as before.
    * The persist step locks the Operation `FOR SHARE`, then the invocation
      `FOR UPDATE`, then the chain head.
    * It returns a receipt naming the primary link it evaluated and the
      gate cause it opened or found (its Failure id).

  Hermetic: the fake CLI plays shim and stand-in proxy store; no real call.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.Agents.Witness
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.GateFixtures
  alias SdrAgent.Operations

  @allow [:propagated_id]

  setup do
    tenant = bootstrap!()
    AgentsFixtures.grant!(tenant)
    %{run: run, agent: agent, operation: operation} = AgentsFixtures.operated_run(tenant)
    root = GateFixtures.root!()
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      tenant: tenant,
      run: run,
      agent: agent,
      operation: operation,
      root: root,
      rec: system_actor(:reconciler, tenant)
    }
  end

  defp gate(ctx), do: %{run_id: ctx.run.id, operation_id: ctx.operation.id}

  defp reconcile(ctx, invocation, extra \\ []) do
    Witness.reconcile(invocation.id, [actor: ctx.rec, store_root: ctx.root] ++ extra)
  end

  defp causes(ctx, invocation) do
    {:ok, failures} = Operations.list_attention(actor: human(:admin, ctx.tenant))
    Enum.filter(failures, &(&1.subject_id == invocation.id))
  end

  test "a mismatch: the critical cause carries the Operation; the receipt names it", ctx do
    invocation = GateFixtures.call_model!(ctx, "cli_shape_v3_mismatch")

    assert {:ok, %{status: :mismatch, receipt: receipt}} =
             reconcile(ctx, invocation, gate: gate(ctx))

    assert [cause] = causes(ctx, invocation)
    assert {cause.severity, cause.class} == {:critical, :reconciliation_required}
    assert cause.operation_id == ctx.operation.id
    assert receipt.cause_id == cause.id

    {:ok, [link]} = Agents.current_wire_witness_links(invocation.id, actor: ctx.rec)
    assert receipt.link_id == link.id
    assert receipt.status == :mismatch
  end

  test "a missing exchange: the warning cause carries the Operation; no link", ctx do
    invocation = GateFixtures.call_model!(ctx, "none")

    assert {:ok, %{receipt: receipt}} = reconcile(ctx, invocation, gate: gate(ctx))
    assert [cause] = causes(ctx, invocation)
    assert {cause.severity, cause.operation_id} == {:warning, ctx.operation.id}
    assert receipt.cause_id == cause.id
    assert receipt.link_id == nil
    assert receipt.status == :unwitnessed
  end

  test "a reconciled exchange: the receipt names the primary link and no cause", ctx do
    invocation = GateFixtures.call_model!(ctx, "cli_shape_v3")

    assert {:ok, %{status: :reconciled, receipt: receipt}} =
             reconcile(ctx, invocation, gate: gate(ctx), methods: @allow)

    {:ok, [link]} = Agents.current_wire_witness_links(invocation.id, actor: ctx.rec)
    assert {receipt.link_id, receipt.cause_id, receipt.status} == {link.id, nil, :reconciled}
    assert causes(ctx, invocation) == []
  end

  test "without gate: (the scan) the cause carries no Operation and there is no receipt", ctx do
    # Row G3: the scan writes only for a decided generation-2 row.
    invocation =
      ctx |> GateFixtures.call_model!("cli_shape_v3_mismatch") |> GateFixtures.decided!()

    assert {:ok, result} = reconcile(ctx, invocation)
    refute Map.has_key?(result, :receipt)
    assert [%{operation_id: nil}] = causes(ctx, invocation)
  end

  test "the gate must be the invocation's own run and Operation", ctx do
    invocation = GateFixtures.call_model!(ctx, "cli_shape_v3_mismatch")
    %{run: other_run, operation: other_op} = AgentsFixtures.operated_run(ctx.tenant)

    for gate <- [
          %{run_id: other_run.id, operation_id: ctx.operation.id},
          %{run_id: ctx.run.id, operation_id: other_op.id},
          %{run_id: ctx.run.id, operation_id: nil},
          %{run_id: ctx.run.id},
          :yes
        ] do
      assert {:error, :invalid_gate} = reconcile(ctx, invocation, gate: gate), inspect(gate)
    end

    assert causes(ctx, invocation) == []
    assert {:ok, []} = Agents.list_wire_witness_links(invocation.id, actor: ctx.rec)
  end

  test "lock order: Operation FOR SHARE, then the invocation FOR UPDATE, then the head", ctx do
    invocation = GateFixtures.call_model!(ctx, "cli_shape_v3_mismatch")

    {result, sql} = GateFixtures.capture(fn -> reconcile(ctx, invocation, gate: gate(ctx)) end)
    assert {:ok, %{status: :mismatch}} = result

    # The persist step starts at the Operation lock. (Observation's audited
    # payload read appends its AuditAccess earlier, in its own transaction.)
    operation = GateFixtures.index(sql, &GateFixtures.locks?(&1, "operations", "FOR SHARE"))
    assert operation, inspect(sql)
    persist = Enum.drop(sql, operation + 1)

    locked =
      GateFixtures.index(persist, &GateFixtures.locks?(&1, "model_invocations", "FOR UPDATE"))

    head =
      GateFixtures.index(persist, &GateFixtures.locks?(&1, "audit_chain_heads", "FOR UPDATE"))

    assert locked && head && locked < head, inspect(persist)

    # Nothing in the persist step locks the Operation again or anything before it.
    refute Enum.any?(Enum.take(persist, locked), &GateFixtures.lock?/1), inspect(persist)
  end
end
