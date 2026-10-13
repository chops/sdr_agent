defmodule SdrAgent.Agents.ResultGateRecoveryTest do
  @moduledoc """
  R0-07 slice C, the gate's recovery finalization (packet section 6, rows
  G5 R2/R3, G7, R7-2): `ResultGate.Recovery.run/3` decides a gated
  invocation from its durable witness state in one transaction, in the
  finalization lock order, and `ResultGate.gate/3` runs it once when
  finalization is refused.

    * an existing release is authoritative (no second release, cause or
      stop);
    * a current mismatch gives `:witness_mismatch` on the invocation's
      usable live critical, a bound critical opened under the head when
      none is live, and `{:error, :mismatch_cause_unbound}` (nothing
      written) when the live critical is unusable for this run;
    * otherwise `:gate_interrupted` on the gate-capable live warning, or a
      new one; never `:released`;
    * a terminal run gets the release only (R3).
  """
  use SdrAgent.AuditCase, async: false

  require Ash.Query

  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ReleaseDecision.Prelocked
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.Agents.ResultGate.Recovery
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.GateFixtures
  alias SdrAgent.Operations

  @v3_opus %{
    provider: :claude_cli,
    cli_version: "2.1.291",
    profile_id: :claude_cli_opus,
    model_id: "claude-opus-5-5",
    projection_version: "claude-message-json/3+prompt-builder/1",
    method: :propagated_id
  }

  setup do
    tenant = bootstrap!()
    AgentsFixtures.grant!(tenant)
    root = GateFixtures.root!()
    previous = AgentsFixtures.put_allowlist!([@v3_opus])
    config = Application.get_env(:sdr_agent, ResultGate)
    Application.put_env(:sdr_agent, ResultGate, wait_ms: 300, poll_ms: 25)

    on_exit(fn ->
      File.rm_rf!(root)
      Application.put_env(:sdr_agent, SdrAgent.Agents.Witness, previous)

      if config,
        do: Application.put_env(:sdr_agent, ResultGate, config),
        else: Application.delete_env(:sdr_agent, ResultGate)
    end)

    %{run: run, agent: agent} = AgentsFixtures.operated_run(tenant)
    admin = human(:admin, tenant)
    %{tenant: tenant, run: run, agent: agent, root: root, admin: admin}
  end

  defp gate(ctx), do: %{run_id: ctx.run.id, operation_id: ctx.run.operation_id}

  # The gate's reconcile only (step 2): links and its cause persisted.
  defp reconciled(ctx, variant) do
    invocation = GateFixtures.call_model!(ctx, variant)
    {_kind, receipt} = ResultGate.await(invocation, gate(ctx), store_root: ctx.root)
    {invocation, receipt}
  end

  defp run!(ctx) do
    {:ok, run} = Agents.get_run(ctx.run.id, actor: ctx.agent)
    run
  end

  defp failure!(ctx, id) do
    {:ok, failure} = Operations.get_failure(id, actor: ctx.admin)
    failure
  end

  defp resolve!(ctx, id) do
    {:ok, _} =
      Operations.resolve_failure(failure!(ctx, id), %{resolution_note: "seen"}, actor: ctx.admin)
  end

  defp attention(ctx) do
    {:ok, all} = Operations.list_attention(actor: ctx.admin)
    all
  end

  defp releases(ctx) do
    {:ok, all} = Agents.list_result_releases(actor: system_actor(:auditor_cli, ctx.tenant))
    all
  end

  defp classification(ctx, release) do
    ctx.tenant
    |> events_of_type("model.result.withheld")
    |> Enum.find(&(&1.subject_id == release.id))
    |> then(& &1.payload["arguments"]["gate_classification"])
  end

  defp stray_critical!(ctx, invocation, operation_id) do
    attrs = %{
      subject_resource: "SdrAgent.Agents.ModelInvocation",
      subject_id: invocation.id,
      class: :reconciliation_required,
      severity: :critical,
      message: "wire witness mismatch: model invocation needs operator review",
      retryable: false
    }

    attrs = if operation_id, do: Map.put(attrs, :operation_id, operation_id), else: attrs
    {:ok, failure} = Operations.open_failure(attrs, actor: system_actor(:reconciler, ctx.tenant))
    failure
  end

  # A competing finalizer's committed withheld release (no stop).
  defp competing_withheld!(ctx, invocation, cause) do
    {:ok, release} =
      Audit.transaction(fn ->
        {:ok, %{}} =
          ModelInvocation
          |> Ash.Query.for_read(:read, %{}, Kernel.opts(ctx.tenant.id))
          |> Ash.Query.filter(id == ^invocation.id)
          |> Ash.Query.lock("FOR SHARE")
          |> Ash.read_one()

        {:ok, _} = Kernel.lock_head(ctx.tenant.id)

        bindings = %{
          tenant_id: ctx.tenant.id,
          model_invocation_id: invocation.id,
          wire_witness_link_id: nil,
          receipt_id: cause.id
        }

        Prelocked.run(bindings, fn prelocked ->
          attrs = %{
            model_invocation_id: invocation.id,
            disposition: :withheld,
            reason: :gate_interrupted,
            gate_cause_id: cause.id,
            gate_classification: :interrupted
          }

          {:ok, release} =
            Agents.decide_result_release(attrs, actor: ctx.agent, prelocked: prelocked)

          release
        end)
      end)

    release
  end

  describe "a known mismatch (R7-2)" do
    test "a usable live critical is the cause; the run stops witness_mismatch", ctx do
      {invocation, receipt} = reconciled(ctx, "cli_shape_v3_mismatch")

      assert {:withheld, release, run} = Recovery.run(invocation, gate(ctx))
      assert release.reason == :witness_mismatch

      assert {run.status_reason, run.attention_failure_id} ==
               {:witness_mismatch, receipt.cause_id}

      assert classification(ctx, release) == "mismatch"
    end

    test "with no live critical a bound critical is opened under the head", ctx do
      {invocation, receipt} = reconciled(ctx, "cli_shape_v3_mismatch")
      resolve!(ctx, receipt.cause_id)

      assert {:withheld, _release, run} = Recovery.run(invocation, gate(ctx))
      assert run.status_reason == :witness_mismatch
      refute run.attention_failure_id == receipt.cause_id
      cause = failure!(ctx, run.attention_failure_id)
      assert {cause.severity, cause.operation_id} == {:critical, ctx.run.operation_id}
    end

    test "an unusable live critical fails closed, then completes once resolved", ctx do
      {invocation, receipt} = reconciled(ctx, "cli_shape_v3_mismatch")
      resolve!(ctx, receipt.cause_id)
      stray = stray_critical!(ctx, invocation, nil)
      before = length(attention(ctx))

      assert {:error, :mismatch_cause_unbound} = Recovery.run(invocation, gate(ctx))
      assert releases(ctx) == []
      assert run!(ctx).status == :running
      assert length(attention(ctx)) == before

      resolve!(ctx, stray.id)
      assert {:withheld, release, run} = Recovery.run(invocation, gate(ctx))
      assert {release.reason, run.status_reason} == {:witness_mismatch, :witness_mismatch}
      refute run.attention_failure_id in [stray.id, receipt.cause_id]
    end

    test "a run without an Operation binds its existing critical through the event", ctx do
      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
      ctx = %{ctx | run: run, agent: agent}
      {invocation, receipt} = reconciled(ctx, "cli_shape_v3_mismatch")

      assert {:withheld, _release, run} = Recovery.run(invocation, gate(ctx))

      assert {run.status_reason, run.attention_failure_id} ==
               {:witness_mismatch, receipt.cause_id}
    end
  end

  describe "no mismatch: :gate_interrupted, never released" do
    test "a reconciled exchange is still withheld, on a new interrupted warning", ctx do
      {invocation, %{status: :reconciled}} = reconciled(ctx, "cli_shape_v3")

      assert {:withheld, release, run} = Recovery.run(invocation, gate(ctx))
      assert release.reason == :gate_interrupted
      assert run.status_reason == :witness_unreconciled
      cause = failure!(ctx, run.attention_failure_id)
      assert {cause.severity, cause.operation_id} == {:warning, ctx.run.operation_id}
      assert classification(ctx, release) == "interrupted"
      assert {:error, :result_not_released} = Agents.released_output(invocation, actor: ctx.agent)
    end

    test "the gate's existing warning is reused (no duplicate attention)", ctx do
      {invocation, receipt} = reconciled(ctx, "none")
      assert receipt.cause_id
      before = length(attention(ctx))

      assert {:withheld, _release, run} = Recovery.run(invocation, gate(ctx))
      assert run.attention_failure_id == receipt.cause_id
      assert length(attention(ctx)) == before
    end

    test "a terminal run gets the release only (R3)", ctx do
      {invocation, _receipt} = reconciled(ctx, "cli_shape_v3")
      {:ok, _} = Agents.cancel_run(run!(ctx), actor: ctx.admin)

      assert {:withheld, release, run} = Recovery.run(invocation, gate(ctx))
      assert release.reason == :gate_interrupted
      assert run.status == :cancelled
    end
  end

  describe "an existing release is authoritative (G7)" do
    test "recovery returns the competing release; nothing else is written", ctx do
      {invocation, receipt} = reconciled(ctx, "none")
      competing = competing_withheld!(ctx, invocation, failure!(ctx, receipt.cause_id))
      before = length(attention(ctx))

      assert {:withheld, release, run} = Recovery.run(invocation, gate(ctx))
      assert release.id == competing.id
      assert run.status == :running
      assert [_one] = releases(ctx)
      assert length(attention(ctx)) == before
    end

    test "gate/3: a refused finalization runs one recovery, which respects it", ctx do
      invocation = GateFixtures.call_model!(ctx, "cli_shape_v3")
      {:ok, receipt} = ResultGate.await(invocation, gate(ctx), store_root: ctx.root)
      cause = stray_critical!(ctx, invocation, ctx.run.operation_id)
      competing = competing_withheld!(ctx, invocation, cause)
      assert receipt.status == :reconciled

      assert {:withheld, release, _run} =
               ResultGate.gate(invocation, gate(ctx), store_root: ctx.root)

      assert release.id == competing.id
      assert [_one] = releases(ctx)
    end

    test "gate/3: a known unbound mismatch is final; no recovery, no output", ctx do
      invocation = GateFixtures.call_model!(ctx, "cli_shape_v3_mismatch")
      stray_critical!(ctx, invocation, nil)

      assert {:error, :mismatch_cause_unbound} =
               ResultGate.gate(invocation, gate(ctx), store_root: ctx.root)

      assert releases(ctx) == []
      assert run!(ctx).status == :running
    end
  end

  test "recovery's locks: in finalization order before the head; none after", ctx do
    {invocation, _receipt} = reconciled(ctx, "cli_shape_v3_mismatch")
    {result, sql} = GateFixtures.capture(fn -> Recovery.run(invocation, gate(ctx)) end)
    assert {:withheld, _, _} = result

    order = [
      {"agent_runs", "FOR UPDATE"},
      {"operations", "FOR SHARE"},
      {"model_invocations", "FOR SHARE"},
      {"wire_witness_links", "FOR SHARE"},
      {"failures", "FOR UPDATE"},
      {"audit_chain_heads", "FOR UPDATE"}
    ]

    indices =
      for {table, mode} <- order,
          do:
            GateFixtures.index(sql, &GateFixtures.locks?(&1, table, mode)) ||
              flunk("#{table}: #{inspect(sql)}")

    assert indices == Enum.sort(indices), inspect(Enum.zip(order, indices))
    after_head = Enum.drop(sql, List.last(indices) + 1)

    assert Enum.reject(
             Enum.filter(after_head, &GateFixtures.lock?/1),
             &GateFixtures.locks?(&1, "audit_chain_heads", "FOR UPDATE")
           ) == [],
           inspect(after_head)
  end
end
