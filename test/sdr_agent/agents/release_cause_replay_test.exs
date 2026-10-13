defmodule SdrAgent.Agents.ReleaseCauseReplayTest do
  @moduledoc """
  R0-07 slice C, row R7-1 (packet section 6.4), kept apart from the G1
  decide-side tests so a ruling change stays cheap. R7-1: the bound cause joins the replay identity. An identical replay
      (same cause, or both absent) returns the row with no event; any other
      binding is a typed `ReleaseConflict` naming the existing cause.
  """
  use SdrAgent.AuditCase, async: false

  require Ash.Query

  alias SdrAgent.Agents
  alias SdrAgent.Agents.Errors.ReleaseConflict
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

  describe "replay identity includes the bound cause (R7-1)" do
    setup ctx do
      attrs = withheld(ctx, gate_cause_id: ctx.cause.id, gate_classification: :inferred)
      {:ok, release} = prelocked(ctx, ctx.cause.id, attrs)
      %{release: release, attrs: attrs}
    end

    test "an identical replay returns the row and appends no event", ctx do
      assert {:ok, again} = prelocked(ctx, ctx.cause.id, ctx.attrs)
      assert again.id == ctx.release.id
      assert length(withheld_events(ctx)) == 1
    end

    test "a different cause, or none, is a typed conflict naming the bound cause", ctx do
      for {receipt, attrs} <- [
            {ctx.other_cause.id, %{ctx.attrs | gate_cause_id: ctx.other_cause.id}},
            {nil, Map.drop(ctx.attrs, [:gate_cause_id, :gate_classification])}
          ] do
        assert {:error, %Ash.Error.Invalid{errors: errors}} = prelocked(ctx, receipt, attrs)

        assert Enum.any?(
                 errors,
                 &match?(
                   %ReleaseConflict{existing_id: id, existing_cause_id: cause}
                   when id == ctx.release.id and cause == ctx.cause.id,
                   &1
                 )
               ),
               inspect(errors)
      end

      # Standalone (no cause) against a bound release conflicts too.
      assert {:error, %Ash.Error.Invalid{}} =
               Agents.decide_result_release(withheld(ctx), actor: ctx.agent)

      assert length(withheld_events(ctx)) == 1
    end

    test "absent to present conflicts: a release decided without a cause stays unbound", ctx do
      other = AgentsFixtures.claude_completed!(ctx.run, ctx.agent, "gc-2")
      bare = %{model_invocation_id: other.id, disposition: :withheld, reason: :witness_missing}
      assert {:ok, release} = Agents.decide_result_release(bare, actor: ctx.agent)
      cause = cause!(ctx, other)
      ctx = %{ctx | invocation: other}

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               prelocked(ctx, cause.id, Map.put(bare, :gate_cause_id, cause.id))

      assert Enum.any?(
               errors,
               &match?(
                 %ReleaseConflict{existing_id: id, existing_cause_id: nil} when id == release.id,
                 &1
               )
             )

      # The unbound replay is identical.
      assert {:ok, %{id: id}} = Agents.decide_result_release(bare, actor: ctx.agent)
      assert id == release.id
    end
  end
end
