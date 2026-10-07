defmodule SdrAgent.OperationsTest do
  @moduledoc """
  S2 rows Operation and Failure (Operations domain, S7): lifecycles and their
  transition tables, the operator-attention queue (`list_attention/1`), who
  may write what (system actors by kind, ADM/REV for operator actions, the
  auditor never), and secret redaction of failure messages.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Operations
  alias SdrAgent.Operations.Failure
  alias SdrAgent.Operations.Operation
  alias SdrAgent.Operations.Redactor
  alias SdrAgent.Test.SecretShapes
  alias SdrAgent.SalesFixtures, as: F

  setup do
    tenant = bootstrap!()

    %{
      tenant: tenant,
      admin: human(:admin, tenant),
      reviewer: human(:reviewer, tenant),
      auditor: human(:auditor, tenant),
      agent: system_actor(:agent_runtime, tenant),
      delivery: system_actor(:delivery_worker, tenant),
      aud: system_actor(:auditor_cli, tenant)
    }
  end

  defp operation_attrs(overrides \\ %{}) do
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
    )
  end

  defp operation!(ctx, overrides \\ %{}) do
    {:ok, op} = Operations.create_operation(operation_attrs(overrides), actor: ctx.agent)
    op
  end

  defp failure_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        subject_resource: "SdrAgent.Agents.AgentRun",
        subject_id: Ecto.UUID.generate(),
        class: :provider_error,
        severity: :critical,
        message: "model provider unavailable",
        retryable: true
      },
      overrides
    )
  end

  defp failure!(ctx, overrides \\ %{}) do
    {:ok, failure} = Operations.open_failure(failure_attrs(overrides), actor: ctx.agent)
    failure
  end

  defp table(resource) do
    resource
    |> Ash.Resource.Info.actions()
    |> Enum.flat_map(fn action ->
      Enum.flat_map(Map.get(action, :changes, []), fn
        %{change: {SdrAgent.Audit.Changes.Transition, opts}} ->
          [{action.name, Enum.sort(opts[:from]), opts[:to]}]

        _ ->
          []
      end)
    end)
    |> Enum.sort()
  end

  defp declared(resource) do
    resource.transitions()
    |> Enum.map(fn {name, from, to} -> {name, Enum.sort(from), to} end)
    |> Enum.sort()
  end

  describe "Operation" do
    test "the declared transition table is the S2 lifecycle and matches the actions" do
      assert declared(Operation) == table(Operation)

      assert declared(Operation) ==
               Enum.sort([
                 {:start, [:enqueued], :running},
                 {:succeed, [:running], :succeeded},
                 {:fail, [:running], :failed},
                 {:retry, [:failed], :running},
                 {:discard, [:failed], :discarded},
                 {:cancel, [:enqueued, :failed], :cancelled}
               ])
    end

    test "enqueued → running → succeeded, each audited with trace ids", ctx do
      op = operation!(ctx)
      assert op.status == :enqueued
      assert op.attempts == 0
      assert op.tenant_id == ctx.tenant.id
      assert op.trace_id =~ ~r/^[0-9a-f]{32}$/

      {:ok, running} = Operations.start_operation(op, actor: ctx.agent)
      assert running.status == :running
      assert running.attempts == 1
      assert running.started_at

      {:ok, done} = Operations.succeed_operation(running, actor: ctx.agent)
      assert done.status == :succeeded
      assert done.finished_at

      for type <- ~w(operations.operation.created operations.operation.started
                     operations.operation.succeeded) do
        assert [event] = events_of_type(ctx.tenant, type)
        assert event.subject_id == op.id
      end
    end

    test "failing at max attempts opens one Failure and discards the operation", ctx do
      {:ok, running} = Operations.start_operation(operation!(ctx), actor: ctx.agent)

      {:ok, discarded} =
        Operations.fail_operation(
          running,
          %{failure: %{class: :crash, severity: :critical, message: "worker crashed"}},
          actor: ctx.agent
        )

      assert discarded.status == :discarded
      assert discarded.last_failure_id

      {:ok, [failure]} = Operations.list_attention(actor: ctx.reviewer)
      assert failure.id == discarded.last_failure_id
      assert failure.operation_id == discarded.id
      assert failure.subject_resource == "SdrAgent.Operations.Operation"
      assert failure.subject_id == discarded.id
      assert failure.class == :crash
      assert [_] = events_of_type(ctx.tenant, "operations.operation.failed")
      assert [_] = events_of_type(ctx.tenant, "operations.operation.discarded")
    end

    test "a failure below max attempts stays failed and may be retried", ctx do
      {:ok, running} =
        Operations.start_operation(operation!(ctx, %{max_attempts: 2}), actor: ctx.agent)

      {:ok, failed} =
        Operations.fail_operation(
          running,
          %{failure: %{class: :timeout, severity: :warning, message: "timed out"}},
          actor: ctx.agent
        )

      assert failed.status == :failed
      {:ok, again} = Operations.retry_operation(failed, actor: ctx.agent)
      assert again.status == :running
      assert again.attempts == 2
    end

    test "an operation failing because of an existing Failure links it instead of a duplicate",
         ctx do
      existing = failure!(ctx)
      {:ok, running} = Operations.start_operation(operation!(ctx), actor: ctx.agent)

      {:ok, discarded} =
        Operations.fail_operation(running, %{failure_id: existing.id}, actor: ctx.agent)

      assert discarded.last_failure_id == existing.id
      {:ok, failures} = Operations.list_attention(actor: ctx.admin)
      assert Enum.map(failures, & &1.id) == [existing.id]
    end

    test "ADM cancels an enqueued operation; REV and the auditor cannot (auditor audited)",
         ctx do
      op = operation!(ctx)

      assert {:error, %Ash.Error.Forbidden{}} =
               Operations.cancel_operation(op, actor: ctx.reviewer)

      before = length(events_of_type(ctx.tenant, "authz.denied"))

      assert {:error, %Ash.Error.Forbidden{}} =
               Operations.cancel_operation(op, actor: ctx.auditor)

      assert length(events_of_type(ctx.tenant, "authz.denied")) == before + 1

      {:ok, cancelled} = Operations.cancel_operation(op, actor: ctx.admin)
      assert cancelled.status == :cancelled
    end

    test "forbidden transitions are rejected; actors write only their own kinds", ctx do
      op = operation!(ctx)
      assert {:error, %Ash.Error.Invalid{}} = Operations.succeed_operation(op, actor: ctx.agent)

      assert {:error, %Ash.Error.Forbidden{}} =
               Operations.create_operation(operation_attrs(), actor: ctx.delivery)

      assert {:ok, _} =
               Operations.create_operation(operation_attrs(%{kind: :deliver, queue: :delivery}),
                 actor: ctx.delivery
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Operations.create_operation(operation_attrs(), actor: ctx.admin)
    end

    test "the idempotency key is unique per tenant", ctx do
      attrs = operation_attrs()
      {:ok, _} = Operations.create_operation(attrs, actor: ctx.agent)
      assert {:error, %Ash.Error.Invalid{}} = Operations.create_operation(attrs, actor: ctx.agent)
    end
  end

  describe "Failure" do
    test "the declared transition table is the S2 lifecycle and matches the actions" do
      assert declared(Failure) == table(Failure)

      assert declared(Failure) ==
               Enum.sort([
                 {:acknowledge, [:open], :acknowledged},
                 {:resolve, [:open, :acknowledged], :resolved}
               ])
    end

    test "system actors open failures; the message is redacted and detail kept as payload",
         ctx do
      failure =
        failure!(ctx, %{
          message: "upstream said: Authorization: " <> SecretShapes.bearer(),
          detail: SecretShapes.json_api_key(503)
        })

      assert failure.status == :open
      assert failure.occurred_at
      refute failure.message =~ SecretShapes.bearer_value()
      assert failure.message =~ "[REDACTED]"
      assert byte_size(failure.detail_sha256) == 32
      assert [event] = events_of_type(ctx.tenant, "operations.failure.opened")
      assert event.subject_id == failure.id
      refute inspect(event.payload) =~ SecretShapes.provider_key()

      {:ok, detail} = SdrAgent.Audit.read_content(failure.detail_sha256, actor: ctx.admin)
      refute detail =~ SecretShapes.provider_key()
      assert detail =~ "503"
    end

    test "humans cannot open failures", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               Operations.open_failure(failure_attrs(), actor: ctx.admin)
    end

    test "ADM/REV acknowledge and resolve with a required note; resolution is terminal", ctx do
      failure = failure!(ctx)
      {:ok, acked} = Operations.acknowledge_failure(failure, actor: ctx.reviewer)
      assert acked.status == :acknowledged
      assert acked.acknowledged_at

      assert {:error, %Ash.Error.Invalid{}} =
               Operations.resolve_failure(acked, %{}, actor: ctx.admin)

      {:ok, resolved} =
        Operations.resolve_failure(acked, %{resolution_note: "provider restored"},
          actor: ctx.admin
        )

      assert resolved.status == :resolved
      assert resolved.resolved_at
      assert resolved.resolved_by_type == :user
      assert resolved.resolved_by_id == ctx.admin.id

      assert {:error, %Ash.Error.Invalid{}} =
               Operations.resolve_failure(resolved, %{resolution_note: "again"}, actor: ctx.admin)
    end

    test "a system actor resolves with a system note", ctx do
      failure = failure!(ctx)

      {:ok, resolved} =
        Operations.resolve_failure(failure, %{resolution_note: "condition cleared"},
          actor: ctx.agent
        )

      assert resolved.resolved_by_type == :agent_runtime
      assert resolved.resolved_by_id == nil
    end

    test "the auditor reads the queue but every mutation is denied and audited", ctx do
      failure = failure!(ctx)
      before = length(events_of_type(ctx.tenant, "authz.denied"))

      assert {:error, %Ash.Error.Forbidden{}} =
               Operations.acknowledge_failure(failure, actor: ctx.auditor)

      assert {:error, %Ash.Error.Forbidden{}} =
               Operations.resolve_failure(failure, %{resolution_note: "x"}, actor: ctx.auditor)

      assert length(events_of_type(ctx.tenant, "authz.denied")) == before + 2
      assert {:ok, [_]} = Operations.list_attention(actor: ctx.auditor)
    end
  end

  describe "list_attention/1" do
    test "returns open and acknowledged failures only, newest first", ctx do
      first = failure!(ctx, %{message: "first"})
      second = failure!(ctx, %{message: "second"})
      third = failure!(ctx, %{message: "third"})
      {:ok, _} = Operations.acknowledge_failure(second, actor: ctx.admin)
      {:ok, _} = Operations.resolve_failure(third, %{resolution_note: "ok"}, actor: ctx.admin)

      for actor <- [ctx.admin, ctx.reviewer, ctx.auditor, ctx.aud] do
        {:ok, attention} = Operations.list_attention(actor: actor)
        assert Enum.map(attention, & &1.id) == [second.id, first.id]
        assert Enum.map(attention, & &1.status) == [:acknowledged, :open]
      end
    end
  end

  describe "Redactor" do
    test "redacts secret-shaped substrings and keeps ordinary text" do
      for secret <- SecretShapes.samples() do
        redacted = Redactor.redact("failure: " <> secret <> " (retry later)")
        assert redacted =~ "[REDACTED]", secret
        assert redacted =~ "failure:"
        assert redacted =~ "(retry later)"
      end

      assert Redactor.redact("model provider unavailable (503)") ==
               "model provider unavailable (503)"
    end
  end
end
