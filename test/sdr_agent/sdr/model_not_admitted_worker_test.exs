defmodule SdrAgent.SDR.ModelNotAdmittedWorkerTest do
  @moduledoc """
  R0-07 slice B end to end (packet section 7, row B1; entity PASS at
  3600fcf): an assignment run on ClaudeCLI (the hermetic fake CLI behind
  the named server) whose real call is not admitted — before reservation or
  at launch — stops `:model_not_admitted` with exactly one attention item:
  the admission's own `provider_error` Failure of the run, linked from the
  run and its Operation. At launch the typed receipt crosses the ClaudeCLI
  server and the facade unchanged: the facade writes nothing more, no
  second Failure is opened, and no port is launched. This closes the
  tracked prerequisite "Launch refusal opens two live Failures".
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures, only: [put_env!: 2]

  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Audit
  alias SdrAgent.Operations
  alias SdrAgent.SDR
  alias SdrAgent.SDR.AgentWorker
  alias SdrAgent.SDR.Context

  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)

  setup ctx do
    AgentsFixtures.grant!(
      ctx.tenant,
      %{total_attempts: 10, allocations: [%{key: :b1, applies_to: [:b1], attempts: 10}]},
      ctx.admin
    )

    AdmissionFixtures.admit_tuples!()
    put_env!(:model_provider, ClaudeCLI)
    :ok
  end

  defp server!(opts) do
    start_supervised!(
      {ClaudeCLI,
       [
         name: ClaudeCLI.server(),
         command: System.find_executable("elixir"),
         test_launcher: true,
         command_args: [@fake, "sdr"]
       ] ++ opts}
    )
  end

  defp attention!(ctx) do
    {:ok, items} = Operations.list_attention(actor: ctx.admin)
    items
  end

  defp assert_one_admission_item(ctx, run, operation, before) do
    assert {run.status, run.status_reason} == {:failed, :model_not_admitted}
    assert [failure] = attention!(ctx) -- before
    assert {failure.class, failure.severity} == {:provider_error, :critical}
    assert {failure.subject_resource, failure.subject_id} == {"SdrAgent.Agents.AgentRun", run.id}
    assert failure.operation_id == operation.id
    assert run.attention_failure_id == failure.id

    {:ok, operation} = Operations.get_operation(operation.id, actor: ctx.admin)
    assert operation.status in [:failed, :discarded]
    assert operation.last_failure_id == failure.id
    refute Enum.any?(attention!(ctx), &(&1.class == :run_stopped))
    failure
  end

  test "refused before reservation: no invocation, one Failure", ctx do
    server!([])
    AdmissionFixtures.put_entries!([])
    before = attention!(ctx)
    %{run: run, operation: operation} = assign!(ctx, "01")
    drain!()

    run = run!(ctx, run)
    assert invocations!(ctx, run) == []
    failure = assert_one_admission_item(ctx, run, operation, before)
    assert failure.message =~ "tuple_not_promoted"
  end

  test "refused at launch: the receipt crosses server and facade, one Failure, no port",
       ctx do
    # The real launch admission, after the allowlist lost the tuple between
    # reservation and launch.
    admit = fn id, profile, opts ->
      AdmissionFixtures.put_entries!([])
      Agents.admit_launch(id, profile, opts)
    end

    server!(launch_admission: admit)
    before = attention!(ctx)
    %{run: run, operation: operation} = assign!(ctx, "01")
    drain!()

    run = run!(ctx, run)
    assert [invocation] = invocations!(ctx, run)
    assert {invocation.status, invocation.sent_at} == {:failed, nil}
    assert invocation.error["reason"] == "tuple_not_promoted"
    assert events_of_type(ctx.tenant, "model.invocation.sent") == []

    failure = assert_one_admission_item(ctx, run, operation, before)

    assert [event] = events_of_type(ctx.tenant, "model.launch.refused")
    assert event.payload["failure_id"] == failure.id
    assert event.idempotency_key == invocation.idempotency_key
  end

  test "an inactive result gate refuses through the facade before reservation", ctx do
    server!([])
    AdmissionFixtures.gate_inactive!()
    before = attention!(ctx)
    %{run: run, operation: operation} = assign!(ctx, "01")
    drain!()

    run = run!(ctx, run)
    assert invocations!(ctx, run) == []
    failure = assert_one_admission_item(ctx, run, operation, before)
    assert failure.message =~ "result_gate_inactive"
    assert Agents.list_result_releases(actor: ctx.admin) == {:ok, []}
  end

  test "an inactive result gate refuses through the server at launch", ctx do
    on_exit(fn -> Application.delete_env(:sdr_agent, SdrAgent.Agents.Admission.Gate) end)

    # The gate turns inactive between reservation and launch (the server's
    # process cannot register test callbacks, so it only sets the seam).
    admit = fn id, profile, opts ->
      Application.put_env(:sdr_agent, SdrAgent.Agents.Admission.Gate, force_inactive: true)
      Agents.admit_launch(id, profile, opts)
    end

    server!(launch_admission: admit)
    before = attention!(ctx)
    %{run: run, operation: operation} = assign!(ctx, "01")
    drain!()

    run = run!(ctx, run)
    assert [invocation] = invocations!(ctx, run)
    assert {invocation.status, invocation.error["reason"]} == {:failed, "result_gate_inactive"}
    assert events_of_type(ctx.tenant, "model.invocation.sent") == []
    assert_one_admission_item(ctx, run, operation, before)
    assert Agents.list_result_releases(actor: ctx.admin) == {:ok, []}
  end

  test "a launch refusal resolved before the stop: one deterministic outcome", ctx do
    %{run: run, operation: operation} = assign!(ctx, "01")
    {:ok, operation} = Operations.start_operation(operation, actor: ctx.agent)
    {:ok, run} = Agents.start_run(run, actor: ctx.agent)

    attrs = "race" |> AgentsFixtures.claude_attrs() |> Map.put(:request, ~s({"r":1}))
    {:ok, invocation} = Agents.reserve_model_invocation(run, attrs, actor: ctx.agent)
    AdmissionFixtures.put_entries!([])

    assert {:error, %Refused{stage: :launch} = refused} =
             Agents.admit_launch(invocation.id, :claude_cli_opus, actor: ctx.agent)

    {:ok, cause} = Operations.get_failure(refused.failure_id, actor: ctx.admin)
    {:ok, _} = Operations.resolve_failure(cause, %{resolution_note: "promoted"}, actor: ctx.admin)
    before = attention!(ctx)

    model_ctx = %Context{
      actor: ctx.agent,
      tenant_id: ctx.tenant.id,
      run_id: run.id,
      correlation_id: run.correlation_id
    }

    assert {:ok, stopped} = SDR.Model.stop_refused(model_ctx, run, refused)

    {:ok, :ok} =
      Audit.transaction(fn -> AgentWorker.fail_operation(operation, stopped, ctx.agent) end)

    stopped = run!(ctx, stopped)
    assert {stopped.status, stopped.status_reason} == {:failed, :model_not_admitted}
    assert stopped.attention_failure_id == refused.failure_id

    # The failed Operation keeps a live queue entry of its own; nothing is a crash.
    assert [own] = attention!(ctx) -- before

    assert {own.subject_resource, own.subject_id} ==
             {"SdrAgent.Operations.Operation", operation.id}

    assert own.class == :provider_error
    assert own.message =~ refused.failure_id
    refute Enum.any?(attention!(ctx), &(&1.class == :run_stopped))
  end
end
