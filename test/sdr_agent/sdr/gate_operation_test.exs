defmodule SdrAgent.SDR.GateOperationTest do
  @moduledoc """
  R0-07 slice C, the worker side of the result gate (packet section 2,
  Operations.Operation row; REQ-07-4, G7):

    * `AgentWorker.fail_operation/3` for a run stopped `:witness_mismatch`
      or `:witness_unreconciled` follows the #132 race rule — the gate
      cause when it is still live, otherwise the Operation's own Failure
      naming the resolved cause; never a generic provider-error fallback;
    * `ResultGate.unreleased?/1` — a run with a completed generation-2
      ClaudeCLI invocation that has no `:released` release (none, or
      withheld; review MF5) holds an unreleased output,
      which the workers never turn into a success or a `:crash`.
  """
  use SdrAgent.AuditCase, async: false

  require Ash.Query

  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ReleaseDecision.Prelocked
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations
  alias SdrAgent.SDR.AgentWorker

  setup do
    tenant = bootstrap!()
    AgentsFixtures.grant!(tenant)
    %{run: run, agent: agent, operation: operation} = AgentsFixtures.operated_run(tenant)
    %{tenant: tenant, run: run, agent: agent, operation: operation, admin: human(:admin, tenant)}
  end

  defp cause!(ctx, invocation, severity) do
    {:ok, failure} =
      Operations.open_failure(
        %{
          subject_resource: "SdrAgent.Agents.ModelInvocation",
          subject_id: invocation.id,
          class: :reconciliation_required,
          severity: severity,
          message: "wire witness gate test: model invocation needs operator review",
          retryable: false,
          operation_id: ctx.run.operation_id
        },
        actor: system_actor(:reconciler, ctx.tenant)
      )

    failure
  end

  defp withhold!(ctx, invocation, cause, reason) do
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
            reason: reason,
            gate_cause_id: cause.id,
            gate_classification: if(reason == :witness_mismatch, do: :mismatch, else: :inferred)
          }

          {:ok, release} =
            Agents.decide_result_release(attrs, actor: ctx.agent, prelocked: prelocked)

          release
        end)
      end)

    release
  end

  defp stopped!(ctx, reason, stop) do
    invocation = AgentsFixtures.claude_completed!(ctx.run, ctx.agent, "op-#{reason}")
    severity = if reason == :witness_mismatch, do: :critical, else: :warning
    cause = cause!(ctx, invocation, severity)
    release = withhold!(ctx, invocation, cause, reason)

    {:ok, run} =
      Agents.fail_run(
        ctx.run,
        %{
          status_reason: stop,
          failure_reason: "model output withheld by the result gate: #{reason}",
          witness_failure_id: cause.id,
          release_id: release.id
        },
        actor: ctx.agent
      )

    {run, cause}
  end

  defp operation!(ctx) do
    {:ok, operation} = Operations.get_operation(ctx.operation.id, actor: ctx.admin)
    operation
  end

  describe "fail_operation/3 for gate stops" do
    test "a live gate cause is linked", ctx do
      {run, cause} = stopped!(ctx, :witness_missing, :witness_unreconciled)

      assert :ok = AgentWorker.fail_operation(operation!(ctx), run, ctx.agent)
      operation = operation!(ctx)
      assert operation.status in [:failed, :discarded]
      assert operation.last_failure_id == cause.id
    end

    test "a resolved cause: the Operation fails with its own Failure naming it", ctx do
      {run, cause} = stopped!(ctx, :witness_mismatch, :witness_mismatch)

      {:ok, _} =
        Operations.resolve_failure(cause, %{resolution_note: "seen"}, actor: ctx.admin)

      assert :ok = AgentWorker.fail_operation(operation!(ctx), run, ctx.agent)
      operation = operation!(ctx)
      assert operation.status in [:failed, :discarded]
      refute operation.last_failure_id == cause.id

      {:ok, own} = Operations.get_failure(operation.last_failure_id, actor: ctx.admin)
      assert own.status == :open
      assert {own.class, own.severity} == {:reconciliation_required, :critical}
      assert own.message =~ cause.id
      refute own.message =~ "crash"
      assert run.attention_failure_id == cause.id
    end
  end

  describe "unreleased?/1" do
    test "a run with no gated invocation holds no unreleased output", ctx do
      refute ResultGate.unreleased?(ctx.run)
    end

    test "a completed generation-2 invocation without a release is unreleased", ctx do
      invocation = AgentsFixtures.claude_completed!(ctx.run, ctx.agent, "unreleased-1")
      assert ResultGate.unreleased?(ctx.run)

      # Review MF5: a withheld output is still no business output; the
      # running run stays the gate's until it is stopped.
      withhold!(ctx, invocation, cause!(ctx, invocation, :warning), :witness_missing)
      assert ResultGate.unreleased?(ctx.run)
    end
  end
end
