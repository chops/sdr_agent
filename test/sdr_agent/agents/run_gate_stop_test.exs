defmodule SdrAgent.Agents.RunGateStopTest do
  @moduledoc """
  R0-07 slice C, AgentRun gate stop (packet section 2, AgentRun row; rows
  G1 and G6). `:fail` with `:witness_mismatch` or `:witness_unreconciled`
  takes `witness_failure_id` and `release_id` (required with these
  reasons, refused with any other) and links that exact cause instead of
  opening a Failure. The validator requires:

    * the release withheld, for an invocation of this run, with a reason
      of the stop's category;
    * the Failure of the run's tenant, class `reconciliation_required`,
      subject that invocation, and bound by the release's withheld event;
    * with an Operation, the Failure's `operation_id` equal to it; without
      one, a null `operation_id` (G1).

  A resolved cause is still the run's cause. G6: under a verified
  Prelocked context for this run's invocation and that receipt, the stop
  re-reads the run and the cause with no lock clause; ordinary `:fail`
  keeps its locks.
  """
  use SdrAgent.AuditCase, async: false

  require Ash.Query

  alias SdrAgent.Agents
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ReleaseDecision.Prelocked
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.GateFixtures
  alias SdrAgent.Operations
  alias SdrAgent.Operations.Failure

  setup do
    tenant = bootstrap!()
    AgentsFixtures.grant!(tenant)
    %{tenant: tenant, rec: system_actor(:reconciler, tenant)}
  end

  defp gated!(ctx, run_fixture, reason \\ :witness_missing) do
    %{run: run, agent: agent} = run_fixture

    invocation =
      AgentsFixtures.claude_completed!(run, agent, "stop-#{System.unique_integer([:positive])}")

    cause = cause!(ctx, invocation, run.operation_id)
    release = withhold!(ctx, invocation, agent, cause, reason)
    %{run: run, agent: agent, invocation: invocation, cause: cause, release: release}
  end

  defp cause!(ctx, invocation, operation_id, severity \\ :warning) do
    attrs = %{
      subject_resource: "SdrAgent.Agents.ModelInvocation",
      subject_id: invocation.id,
      class: :reconciliation_required,
      severity: severity,
      message: "wire witness gate stop test #{System.unique_integer([:positive])}",
      retryable: false
    }

    attrs = if operation_id, do: Map.put(attrs, :operation_id, operation_id), else: attrs
    {:ok, failure} = Operations.open_failure(attrs, actor: ctx.rec)
    failure
  end

  # The finalizer's withheld decision, binding `cause` in its event.
  defp withhold!(ctx, invocation, agent, cause, reason) do
    {:ok, release} =
      Audit.transaction(fn ->
        lock!(ModelInvocation, invocation.id, ctx.tenant.id, "FOR SHARE")
        {:ok, _} = Kernel.lock_head(ctx.tenant.id)

        Prelocked.run(bindings(ctx, invocation, cause), fn prelocked ->
          attrs = %{
            model_invocation_id: invocation.id,
            disposition: :withheld,
            reason: reason,
            gate_cause_id: cause.id,
            gate_classification: :inferred
          }

          {:ok, release} =
            Agents.decide_result_release(attrs, actor: agent, prelocked: prelocked)

          release
        end)
      end)

    release
  end

  defp bindings(ctx, invocation, cause),
    do: %{
      tenant_id: ctx.tenant.id,
      model_invocation_id: invocation.id,
      wire_witness_link_id: nil,
      receipt_id: cause && cause.id
    }

  defp lock!(resource, id, tenant_id, mode) do
    {:ok, %{}} =
      resource
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.lock(mode)
      |> Ash.read_one()
  end

  defp stop(g, overrides \\ %{}, opts \\ []) do
    attrs =
      Map.merge(
        %{
          status_reason: :witness_unreconciled,
          failure_reason: "model output withheld: witness_missing",
          witness_failure_id: g.cause.id,
          release_id: g.release.id
        },
        Map.new(overrides)
      )

    {:ok, run} = Agents.get_run(g.run.id, actor: g.agent)
    Agents.fail_run(run, attrs, [actor: g.agent] ++ opts)
  end

  defp failures(ctx) do
    {:ok, all} = Operations.list_attention(actor: human(:admin, ctx.tenant))
    all
  end

  describe "with an Operation" do
    setup ctx, do: %{g: gated!(ctx, AgentsFixtures.operated_run(ctx.tenant))}

    test "the stop links the exact cause and opens no Failure", ctx do
      before = length(failures(ctx))
      assert {:ok, run} = stop(ctx.g)
      assert {run.status, run.status_reason} == {:failed, :witness_unreconciled}
      assert run.attention_failure_id == ctx.g.cause.id
      assert length(failures(ctx)) == before

      [event] = events_of_type(ctx.tenant, "agents.run.failed")
      assert event.payload["arguments"]["witness_failure_id"] == ctx.g.cause.id
      assert event.payload["arguments"]["release_id"] == ctx.g.release.id
    end

    test "a resolved cause is still the run's cause", ctx do
      {:ok, _} =
        Operations.resolve_failure(ctx.g.cause, %{resolution_note: "seen"},
          actor: human(:admin, ctx.tenant)
        )

      assert {:ok, %{attention_failure_id: id}} = stop(ctx.g)
      assert id == ctx.g.cause.id
    end

    test "every receipt mismatch is refused, and nothing is written", ctx do
      other = gated!(ctx, AgentsFixtures.operated_run(ctx.tenant))
      unbound = cause!(ctx, ctx.g.invocation, ctx.g.run.operation_id)
      no_op = cause!(ctx, ctx.g.invocation, nil)

      for {label, overrides} <- [
            {"mismatch reason on a missing release", %{status_reason: :witness_mismatch}},
            {"another run's release", %{release_id: other.release.id}},
            {"another invocation's cause", %{witness_failure_id: other.cause.id}},
            {"a cause the event does not bind", %{witness_failure_id: unbound.id}},
            {"a cause without the run's Operation", %{witness_failure_id: no_op.id}},
            {"no release", %{release_id: nil}},
            {"no cause", %{witness_failure_id: nil}},
            {"gate receipt on another reason", %{status_reason: :provider_error}}
          ] do
        assert {:error, %Ash.Error.Invalid{}} = stop(ctx.g, overrides), label
      end

      assert events_of_type(ctx.tenant, "agents.run.failed") == []
    end

    test "the mismatch stop needs a mismatch release", ctx do
      g = gated!(ctx, AgentsFixtures.operated_run(ctx.tenant), :witness_mismatch)
      assert {:error, %Ash.Error.Invalid{}} = stop(g, %{status_reason: :witness_unreconciled})

      assert {:ok, %{status_reason: :witness_mismatch}} =
               stop(g, %{status_reason: :witness_mismatch})
    end
  end

  describe "without an Operation (G1)" do
    setup ctx, do: %{g: gated!(ctx, AgentsFixtures.running_run(ctx.tenant))}

    test "the event-bound null-Operation cause is linked", ctx do
      assert ctx.g.cause.operation_id == nil
      assert {:ok, %{attention_failure_id: id}} = stop(ctx.g)
      assert id == ctx.g.cause.id
    end

    test "a null-Operation Failure the event does not bind is refused", ctx do
      stray = cause!(ctx, ctx.g.invocation, nil)
      assert {:error, %Ash.Error.Invalid{}} = stop(ctx.g, %{witness_failure_id: stray.id})
    end
  end

  describe "G6: lock-free re-read under the finalizer's context" do
    setup ctx, do: %{g: gated!(ctx, AgentsFixtures.operated_run(ctx.tenant))}

    test "the stop requests no lock clause after the head", ctx do
      g = ctx.g

      {result, sql} =
        GateFixtures.capture(fn ->
          Audit.transaction(fn ->
            lock!(AgentRun, g.run.id, ctx.tenant.id, "FOR UPDATE")
            lock!(ModelInvocation, g.invocation.id, ctx.tenant.id, "FOR SHARE")
            lock!(Failure, g.cause.id, ctx.tenant.id, "FOR UPDATE")
            {:ok, _} = Kernel.lock_head(ctx.tenant.id)

            Prelocked.run(bindings(ctx, g.invocation, g.cause), fn prelocked ->
              {:ok, run} = stop(g, %{}, prelocked: prelocked)
              run
            end)
          end)
        end)

      assert {:ok, %{status: :failed}} = result
      head = GateFixtures.index(sql, &GateFixtures.locks?(&1, "audit_chain_heads", "FOR UPDATE"))
      after_head = Enum.drop(sql, head + 1)

      assert Enum.reject(
               Enum.filter(after_head, &GateFixtures.lock?/1),
               &GateFixtures.locks?(&1, "audit_chain_heads", "FOR UPDATE")
             ) == [],
             inspect(after_head)
    end

    test "a context for another invocation or receipt does not skip the locks", ctx do
      g = ctx.g
      other = cause!(ctx, g.invocation, g.run.operation_id)

      {result, sql} =
        GateFixtures.capture(fn ->
          Audit.transaction(fn ->
            Prelocked.run(bindings(ctx, g.invocation, other), fn prelocked ->
              {:ok, run} = stop(g, %{}, prelocked: prelocked)
              run
            end)
          end)
        end)

      assert {:ok, _} = result
      assert Enum.any?(sql, &GateFixtures.locks?(&1, "agent_runs", "FOR UPDATE"))
    end

    test "ordinary :fail keeps its locks", ctx do
      %{run: run, agent: agent} = AgentsFixtures.operated_run(ctx.tenant)

      {result, sql} =
        GateFixtures.capture(fn ->
          Agents.fail_run(run, %{status_reason: :provider_error, failure_reason: "x"},
            actor: agent
          )
        end)

      assert {:ok, _} = result
      assert Enum.any?(sql, &GateFixtures.locks?(&1, "agent_runs", "FOR UPDATE"))
    end
  end
end
