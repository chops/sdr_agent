defmodule SdrAgent.Agents.ReleaseGateCauseTest do
  @moduledoc """
  R0-07 slice C, rows G1/G2, decide side (packet section 6.2): a withheld release decided by the finalizer records the selected
  gate cause (`gate_cause_id`) and its bounded typed classification
  (`gate_classification`) as arguments of its immutable
  `model.result.withheld` event.

    * `gate_cause_id` is accepted only for `:withheld`, only under a
      verified Prelocked context whose receipt is that cause;
      `gate_classification` only with a cause, from the pinned code set.
  """
  use SdrAgent.AuditCase, async: false

  require Ash.Query

  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ReleaseDecision.Prelocked
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations

  setup do
    tenant = bootstrap!()
    AgentsFixtures.grant!(tenant)
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    rec = system_actor(:reconciler, tenant)
    invocation = AgentsFixtures.claude_completed!(run, agent, "gc-1")
    ctx = %{tenant: tenant, run: run, agent: agent, rec: rec, invocation: invocation}
    Map.merge(ctx, %{cause: cause!(ctx, invocation), other_cause: cause!(ctx, invocation)})
  end

  defp cause!(ctx, invocation) do
    {:ok, failure} =
      Operations.open_failure(
        %{
          subject_resource: "SdrAgent.Agents.ModelInvocation",
          subject_id: invocation.id,
          class: :reconciliation_required,
          severity: :warning,
          message: "wire witness gate test #{System.unique_integer([:positive])}: needs review",
          retryable: false
        },
        actor: ctx.rec
      )

    failure
  end

  defp withheld(ctx, extra \\ %{}) do
    Map.merge(
      %{model_invocation_id: ctx.invocation.id, disposition: :withheld, reason: :witness_missing},
      Map.new(extra)
    )
  end

  # A finalizer stand-in: lock the invocation, then the head, then decide
  # under a Prelocked context whose receipt is `receipt`.
  defp prelocked(ctx, receipt, attrs) do
    Audit.transaction(fn ->
      {:ok, %{}} =
        ModelInvocation
        |> Ash.Query.for_read(:read, %{}, Kernel.opts(ctx.tenant.id))
        |> Ash.Query.filter(id == ^ctx.invocation.id)
        |> Ash.Query.lock("FOR SHARE")
        |> Ash.read_one()

      {:ok, _head} = Kernel.lock_head(ctx.tenant.id)

      bindings = %{
        tenant_id: ctx.tenant.id,
        model_invocation_id: ctx.invocation.id,
        wire_witness_link_id: nil,
        receipt_id: receipt
      }

      Prelocked.run(bindings, &decide_or_rollback(ctx, attrs, &1))
    end)
    |> case do
      # A refused action inside the transaction rolls it back with its changeset.
      {:error, %Ash.Changeset{errors: errors}} -> {:error, Ash.Error.to_error_class(errors)}
      {:error, error} -> {:error, Ash.Error.to_error_class(error)}
      other -> other
    end
  end

  defp decide_or_rollback(ctx, attrs, context) do
    case Agents.decide_result_release(attrs, actor: ctx.agent, prelocked: context) do
      {:ok, release} -> release
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp withheld_events(ctx), do: events_of_type(ctx.tenant, "model.result.withheld")

  describe "gate_cause_id and gate_classification (G1/G2)" do
    test "the finalizer's withheld release records its cause and classification", ctx do
      attrs = withheld(ctx, gate_cause_id: ctx.cause.id, gate_classification: :method_not_enabled)
      assert {:ok, release} = prelocked(ctx, ctx.cause.id, attrs)
      assert [event] = withheld_events(ctx)
      assert event.subject_id == release.id
      assert event.payload["arguments"]["gate_cause_id"] == ctx.cause.id
      assert event.payload["arguments"]["gate_classification"] == "method_not_enabled"
    end

    test "a cause is refused outside a matching Prelocked receipt, or off withheld", ctx do
      cases = [
        {"standalone",
         fn ->
           Agents.decide_result_release(withheld(ctx, gate_cause_id: ctx.cause.id),
             actor: ctx.agent
           )
         end},
        {"other receipt",
         fn -> prelocked(ctx, ctx.other_cause.id, withheld(ctx, gate_cause_id: ctx.cause.id)) end},
        {"no receipt", fn -> prelocked(ctx, nil, withheld(ctx, gate_cause_id: ctx.cause.id)) end},
        {"classification without cause",
         fn -> prelocked(ctx, ctx.cause.id, withheld(ctx, gate_classification: :inferred)) end},
        {"unknown classification",
         fn ->
           prelocked(
             ctx,
             ctx.cause.id,
             withheld(ctx, gate_cause_id: ctx.cause.id, gate_classification: :whatever)
           )
         end}
      ]

      for {label, decide} <- cases do
        assert {:error, _} = decide.(), label
      end

      assert withheld_events(ctx) == []
    end
  end
end
