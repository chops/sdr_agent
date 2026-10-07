defmodule SdrAgent.Operations.AttentionLifecycleTest do
  @moduledoc """
  S7a review (Codex, PR #10) — attention ownership and lifecycle:

    1. an Operation fails only into a *live* Failure of its own condition
       (a resolved or unrelated Failure cannot be linked; the run's Failure
       carries the run's operation id so it can be);
    2. only ADM, REV, the reconciler and the system actor that opened a
       Failure (recorded provenance) may resolve it;
    3. a successful Operation retry resolves its Failure in the same
       transaction;
    4. secret-shaped text is redacted before the *causing* row and its event
       are written, not only in the attention copy.
  """
  use SdrAgent.AuditCase, async: false

  import ExUnit.CaptureLog

  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Operations
  alias SdrAgent.Sales
  alias SdrAgent.SalesFixtures, as: F
  alias SdrAgent.Test.SecretShapes

  setup do
    tenant = bootstrap!()

    %{
      tenant: tenant,
      admin: human(:admin, tenant),
      reviewer: human(:reviewer, tenant),
      agent: system_actor(:agent_runtime, tenant),
      reconciler: system_actor(:reconciler, tenant),
      webhook: system_actor(:webhook_ingestor, tenant),
      scheduler: system_actor(:scheduler, tenant)
    }
  end

  defp operation!(ctx, overrides \\ %{}) do
    {:ok, op} =
      Operations.create_operation(
        Map.merge(
          %{
            kind: :research_lead,
            queue: :research,
            subject_resource: "SdrAgent.Sales.Lead",
            subject_id: Ecto.UUID.generate(),
            idempotency_key: "op-#{F.unique()}",
            correlation_id: Ecto.UUID.generate(),
            max_attempts: 1
          },
          overrides
        ),
        actor: ctx.agent
      )

    {:ok, op} = Operations.start_operation(op, actor: ctx.agent)
    op
  end

  defp run_for!(ctx, operation) do
    definition = AgentsFixtures.definition!(ctx.tenant)

    {:ok, run} =
      Agents.create_run(
        Map.put(AgentsFixtures.run_attrs(definition), :operation_id, operation.id),
        actor: ctx.agent
      )

    {:ok, run} = Agents.start_run(run, actor: ctx.agent)
    run
  end

  defp failure!(_ctx, actor, overrides \\ %{}) do
    {:ok, failure} =
      Operations.open_failure(
        Map.merge(
          %{
            subject_resource: "SdrAgent.Agents.AgentRun",
            subject_id: Ecto.UUID.generate(),
            class: :provider_error,
            severity: :critical,
            message: "provider unavailable",
            retryable: true
          },
          overrides
        ),
        actor: actor
      )

    failure
  end

  defp count(ctx, type), do: length(events_of_type(ctx.tenant, type))

  defp attention_ids(ctx) do
    {:ok, failures} = Operations.list_attention(actor: ctx.admin)
    Enum.map(failures, & &1.id)
  end

  describe "1. an operation fails only into a live Failure of its own condition" do
    test "the run's attention Failure carries the operation id and can be linked", ctx do
      operation = operation!(ctx)
      run = run_for!(ctx, operation)
      {:ok, failed} = Agents.fail_run(run, %{status_reason: :crash}, actor: ctx.agent)
      {:ok, failure} = Operations.get_failure(failed.attention_failure_id, actor: ctx.admin)
      assert failure.operation_id == operation.id

      {:ok, discarded} =
        Operations.fail_operation(operation, %{failure_id: failure.id}, actor: ctx.agent)

      assert discarded.status == :discarded
      assert discarded.last_failure_id == failure.id
      assert attention_ids(ctx) == [failure.id]
    end

    test "a resolved Failure cannot be linked; nothing is written", ctx do
      operation = operation!(ctx)
      run = run_for!(ctx, operation)
      {:ok, failed} = Agents.fail_run(run, %{status_reason: :crash}, actor: ctx.agent)
      {:ok, failure} = Operations.get_failure(failed.attention_failure_id, actor: ctx.admin)

      {:ok, _} =
        Operations.resolve_failure(failure, %{resolution_note: "fixed"}, actor: ctx.admin)

      before = count(ctx, "operations.operation.failed")

      assert {:error, %Ash.Error.Invalid{}} =
               Operations.fail_operation(operation, %{failure_id: failure.id}, actor: ctx.agent)

      {:ok, reloaded} = Operations.get_operation(operation.id, actor: ctx.admin)
      assert reloaded.status == :running
      assert count(ctx, "operations.operation.failed") == before
    end

    test "a Failure of another condition cannot be linked", ctx do
      operation = operation!(ctx)
      other = failure!(ctx, ctx.agent)

      assert {:error, %Ash.Error.Invalid{}} =
               Operations.fail_operation(operation, %{failure_id: other.id}, actor: ctx.agent)

      {:ok, reloaded} = Operations.get_operation(operation.id, actor: ctx.admin)
      assert reloaded.status == :running
    end

    test "unknown keys in the failure map are ignored, not raised", ctx do
      operation = operation!(ctx)

      {:ok, discarded} =
        Operations.fail_operation(
          operation,
          %{
            failure: %{
              "class" => "crash",
              "severity" => "critical",
              "message" => "worker crashed",
              "no_such_failure_key_s7" => "ignored"
            }
          },
          actor: ctx.agent
        )

      assert discarded.status == :discarded

      assert {:error, %Ash.Error.Invalid{}} =
               Operations.fail_operation(operation!(ctx), %{failure: %{"class" => "crash"}},
                 actor: ctx.agent
               )
    end
  end

  describe "2. who may resolve a Failure" do
    test "the system actor that opened it and the reconciler may; others may not", ctx do
      opened_by_agent = failure!(ctx, ctx.agent)

      {:ok, resolved} =
        Operations.resolve_failure(opened_by_agent, %{resolution_note: "cleared"},
          actor: ctx.agent
        )

      assert resolved.resolved_by_type == :agent_runtime

      for_reconciler = failure!(ctx, ctx.agent)

      {:ok, resolved} =
        Operations.resolve_failure(for_reconciler, %{resolution_note: "reconciled"},
          actor: ctx.reconciler
        )

      assert resolved.resolved_by_type == :reconciler

      untouched = failure!(ctx, ctx.agent)
      before = count(ctx, "operations.failure.resolved")

      for actor <- [ctx.webhook, ctx.scheduler] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Operations.resolve_failure(untouched, %{resolution_note: "not mine"},
                   actor: actor
                 )
      end

      {:ok, reloaded} = Operations.get_failure(untouched.id, actor: ctx.admin)
      assert reloaded.status == :open
      assert count(ctx, "operations.failure.resolved") == before
    end

    test "ADM and REV may resolve any Failure", ctx do
      for actor <- [ctx.admin, ctx.reviewer] do
        failure = failure!(ctx, ctx.webhook)

        assert {:ok, %{status: :resolved}} =
                 Operations.resolve_failure(failure, %{resolution_note: "ok"}, actor: actor)
      end
    end
  end

  describe "3. a successful retry resolves the operation's Failure" do
    test "start → fail → retry → succeed leaves no attention entry for it", ctx do
      operation = operation!(ctx, %{max_attempts: 2})
      unrelated = failure!(ctx, ctx.agent)

      {:ok, failed} =
        Operations.fail_operation(
          operation,
          %{failure: %{class: :timeout, severity: :warning, message: "timed out"}},
          actor: ctx.agent
        )

      assert failed.last_failure_id in attention_ids(ctx)
      {:ok, retried} = Operations.retry_operation(failed, actor: ctx.agent)
      {:ok, succeeded} = Operations.succeed_operation(retried, actor: ctx.agent)

      assert attention_ids(ctx) == [unrelated.id]
      {:ok, failure} = Operations.get_failure(succeeded.last_failure_id, actor: ctx.admin)
      assert failure.status == :resolved
      assert failure.resolved_by_type == :agent_runtime
      assert failure.resolution_note =~ operation.id
    end

    test "if the Failure cannot be resolved the operation does not succeed", ctx do
      operation = operation!(ctx, %{max_attempts: 2})

      {:ok, failed} =
        Operations.fail_operation(
          operation,
          %{failure: %{class: :timeout, severity: :warning, message: "timed out"}},
          actor: ctx.agent
        )

      {:ok, retried} = Operations.retry_operation(failed, actor: ctx.agent)

      Repo.query!("""
      CREATE FUNCTION pg_temp.s7_reject_failure_update() RETURNS trigger LANGUAGE plpgsql AS
      $$ BEGIN RAISE EXCEPTION 's7 test: failure update rejected'; END $$
      """)

      Repo.query!("""
      CREATE TRIGGER s7_reject_failure_update BEFORE UPDATE ON failures
      FOR EACH ROW EXECUTE FUNCTION pg_temp.s7_reject_failure_update()
      """)

      assert {:error, _} = Operations.succeed_operation(retried, actor: ctx.agent)
      assert events_of_type(ctx.tenant, "operations.operation.succeeded") == []
    end
  end

  describe "4. the causing record is redacted before it is written" do
    defp secret_absent!(ctx, secret) do
      for event <- events(ctx.tenant) do
        refute event.canonical_bytes =~ secret
        refute inspect(event.payload) =~ secret
      end

      %{rows: [[n]]} =
        Repo.query!("SELECT count(*) FROM payloads WHERE position($1 in content) > 0", [secret])

      assert n == 0
    end

    test "AgentRun failure_reason", ctx do
      %{run: run} = AgentsFixtures.running_run(ctx.tenant)
      reason = "provider said Authorization: " <> SecretShapes.bearer() <> " (HTTP 401)"
      Logger.put_process_level(self(), :debug)

      log =
        capture_log([level: :debug], fn ->
          {:ok, _} =
            Agents.fail_run(run, %{status_reason: :provider_error, failure_reason: reason},
              actor: ctx.agent
            )
        end)

      {:ok, reloaded} = Agents.get_run(run.id, actor: ctx.agent)
      refute reloaded.failure_reason =~ SecretShapes.bearer_value()
      assert reloaded.failure_reason =~ "[REDACTED]"
      assert reloaded.failure_reason =~ "(HTTP 401)"
      {:ok, failure} = Operations.get_failure(reloaded.attention_failure_id, actor: ctx.admin)
      refute failure.message =~ SecretShapes.bearer_value()
      refute log =~ SecretShapes.bearer_value()
      secret_absent!(ctx, SecretShapes.bearer_value())
    end

    test "Lead blocked reason", ctx do
      lead = F.lead_in!(ctx.tenant, :researching)
      %{run: run} = F.run!(ctx.tenant)
      decision = F.decision!(ctx.tenant, run, lead, "blocked")
      reason = "crm said " <> SecretShapes.json_api_key(500)

      {:ok, blocked} =
        Sales.update(lead, :block, %{decision_id: decision.id, status_reason: reason},
          actor: ctx.agent
        )

      refute blocked.status_reason =~ SecretShapes.provider_key()
      assert blocked.status_reason =~ "crm said"
      secret_absent!(ctx, SecretShapes.provider_key())
    end
  end
end
