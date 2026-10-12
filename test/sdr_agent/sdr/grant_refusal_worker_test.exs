defmodule SdrAgent.SDR.GrantRefusalWorkerTest do
  @moduledoc """
  C9: an assignment run on ClaudeCLI (the hermetic fake CLI behind the named
  server) whose model call is refused at reservation stops without calling
  the provider, and its one operator-attention item is the refusal's own
  deduplicated `budget_exhausted` Failure, linked from the run and its
  Operation — no second `run_stopped` item. No grant (or no allocation)
  fails the run `:grant_unavailable`; an exhausted grant cap stops it
  `budget_exhausted` with `:grant_exhausted`.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures, only: [put_env!: 2]

  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Audit
  alias SdrAgent.Operations
  alias SdrAgent.SDR
  alias SdrAgent.SDR.AgentWorker
  alias SdrAgent.SDR.Context

  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)

  setup do
    start_supervised!(
      {ClaudeCLI,
       name: ClaudeCLI.server(),
       command: System.find_executable("elixir"),
       command_args: [@fake, "sdr"]}
    )

    put_env!(:model_provider, ClaudeCLI)
    :ok
  end

  defp attention!(ctx) do
    {:ok, items} = Operations.list_attention(actor: ctx.admin)
    items
  end

  # The run's one attention item is its refusal Failure, linked from the run
  # and its Operation.
  defp assert_one_refusal_item(ctx, run, operation, before, reason) do
    assert [failure] = attention!(ctx) -- before
    assert failure.class == :budget_exhausted
    assert {failure.subject_resource, failure.subject_id} == {"SdrAgent.Agents.AgentRun", run.id}
    assert failure.message =~ "model call reservation refused: #{reason}"
    assert run.attention_failure_id == failure.id
    assert failure.operation_id == operation.id

    {:ok, operation} = Operations.get_operation(operation.id, actor: ctx.admin)
    assert operation.status in [:failed, :discarded]
    assert operation.last_failure_id == failure.id
  end

  test "without a grant the run fails :grant_unavailable before any provider call", ctx do
    before = attention!(ctx)
    %{run: run, operation: operation} = assign!(ctx, "01")
    drain!()

    run = run!(ctx, run)
    assert {run.status, run.status_reason} == {:failed, :grant_unavailable}
    assert run.failure_reason =~ "no_eligible_grant"
    assert invocations!(ctx, run) == []
    assert_one_refusal_item(ctx, run, operation, before, "no_eligible_grant")
  end

  test "an exhausted grant stops the run :grant_exhausted before any provider call", ctx do
    AgentsFixtures.grant!(
      ctx.tenant,
      %{total_attempts: 1, allocations: [%{key: :b1, applies_to: [:b1], attempts: 1}]},
      ctx.admin
    )

    # Another run spends the grant's one attempt.
    %{run: other, agent: agent} = AgentsFixtures.running_run(ctx.tenant)

    {:ok, _} =
      SdrAgent.Agents.reserve_model_invocation(other, AgentsFixtures.claude_attrs("spent"),
        actor: agent
      )

    before = attention!(ctx)
    %{run: run, operation: operation} = assign!(ctx, "01")
    drain!()

    run = run!(ctx, run)
    assert {run.status, run.status_reason} == {:budget_exhausted, :grant_exhausted}
    assert invocations!(ctx, run) == []
    assert_one_refusal_item(ctx, run, operation, before, "grant_exhausted")
  end

  test "the run stop refuses a Failure that is not this run's reservation refusal", ctx do
    %{run: run} = assign!(ctx, "01")
    {:ok, run} = SdrAgent.Agents.start_run(run, actor: ctx.agent)

    {:ok, foreign} =
      Operations.open_failure(
        %{
          subject_resource: "SdrAgent.Agents.AgentRun",
          subject_id: Ecto.UUID.generate(),
          class: :budget_exhausted,
          severity: :critical,
          message: "another run's refusal"
        },
        actor: ctx.agent
      )

    assert {:error, %Ash.Error.Invalid{}} =
             SdrAgent.Agents.fail_run(
               run,
               %{status_reason: :grant_unavailable, refusal_failure_id: foreign.id},
               actor: ctx.agent
             )

    # A grant stop needs the refusal; any other stop must not carry one.
    assert {:error, %Ash.Error.Invalid{}} =
             SdrAgent.Agents.fail_run(run, %{status_reason: :grant_unavailable}, actor: ctx.agent)

    assert {:error, %Ash.Error.Invalid{}} =
             SdrAgent.Agents.fail_run(
               run,
               %{status_reason: :crash, refusal_failure_id: foreign.id},
               actor: ctx.agent
             )

    assert run!(ctx, run).status == :running
  end

  test "a refusal resolved by an admin before the run stops: one deterministic outcome", ctx do
    %{run: run, operation: operation} = assign!(ctx, "01")
    {:ok, operation} = Operations.start_operation(operation, actor: ctx.agent)
    {:ok, run} = SdrAgent.Agents.start_run(run, actor: ctx.agent)

    assert {:error, %Refused{reason: :no_eligible_grant} = refused} =
             SdrAgent.Agents.reserve_model_invocation(run, AgentsFixtures.claude_attrs("race"),
               actor: ctx.agent
             )

    {:ok, refusal} = Operations.get_failure(refused.failure_id, actor: ctx.admin)

    {:ok, _} =
      Operations.resolve_failure(refusal, %{resolution_note: "grant on its way"},
        actor: ctx.admin
      )

    before = attention!(ctx)

    model_ctx = %Context{
      actor: ctx.agent,
      tenant_id: ctx.tenant.id,
      run_id: run.id,
      correlation_id: run.correlation_id
    }

    # The stop SDR.Model makes, then the Operation write AgentWorker makes.
    assert {:ok, stopped} = SDR.Model.stop_refused(model_ctx, run, refused)

    {:ok, :ok} =
      Audit.transaction(fn -> AgentWorker.fail_operation(operation, stopped, ctx.agent) end)

    stopped = run!(ctx, stopped)
    assert {stopped.status, stopped.status_reason} == {:failed, :grant_unavailable}
    assert stopped.attention_failure_id == refused.failure_id

    assert {:ok, %{status: :resolved}} =
             Operations.get_failure(refused.failure_id, actor: ctx.admin)

    # The failed Operation keeps a live queue entry of its own; nothing is a crash.
    assert [own] = attention!(ctx) -- before

    assert {own.subject_resource, own.subject_id} ==
             {"SdrAgent.Operations.Operation", operation.id}

    assert own.class == :budget_exhausted
    assert own.message =~ refused.failure_id
    {:ok, operation} = Operations.get_operation(operation.id, actor: ctx.admin)
    assert operation.status in [:failed, :discarded]
    assert operation.last_failure_id == own.id
    assert events_of_type(ctx.tenant, "agents.run.failed") |> length() == 1
    refute Enum.any?(attention!(ctx), &(&1.class == :run_stopped))
  end
end
