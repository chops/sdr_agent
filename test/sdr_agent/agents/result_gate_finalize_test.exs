defmodule SdrAgent.Agents.ResultGateFinalizeTest do
  @moduledoc """
  R0-07 slice C, step 3 "Finalize" (packet section 2; rows G1, G2, G6):
  `ResultGate.finalize/4`, one transaction, in this order — run `FOR
  UPDATE`, the run's Operation `FOR SHARE`, invocation `FOR SHARE`, the
  current primary link `FOR SHARE`, the exact selected cause `FOR UPDATE`
  (live or resolved), then the chain head; under the head with every
  dependent row already held: a deduplicated gate cause when the receipt
  names none, the release, and for a withheld outcome the run stop with its
  receipt. No row lock is requested after the head.

  Reasons (G2): a mismatch dominates (`:witness_mismatch`, its critical
  cause); an unconfigured or unreadable store is `:store_unreadable`; a
  capture still pending at the bound is `:witness_timeout`; any other
  non-reconciled outcome is `:witness_missing` (no usable exact witness),
  with the typed classification recorded as metadata.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.GateFixtures
  alias SdrAgent.Operations

  @v3_opus %{
    provider: :claude_cli,
    cli_version: "2.1.294",
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

    %{run: run, agent: agent, operation: operation} = AgentsFixtures.operated_run(tenant)
    %{tenant: tenant, run: run, agent: agent, operation: operation, root: root}
  end

  defp gate(ctx), do: %{run_id: ctx.run.id, operation_id: ctx.run.operation_id}

  defp gated(ctx, variant, opts \\ []) do
    invocation = GateFixtures.call_model!(ctx, variant)
    store = Keyword.get(opts, :store_root, ctx.root)
    outcome = ResultGate.await(invocation, gate(ctx), store_root: store)
    {invocation, outcome}
  end

  defp finalize(ctx, invocation, outcome), do: ResultGate.finalize(invocation, gate(ctx), outcome)

  defp run!(ctx) do
    {:ok, run} = Agents.get_run(ctx.run.id, actor: ctx.agent)
    run
  end

  defp failure!(ctx, id) do
    {:ok, failure} = Operations.get_failure(id, actor: human(:admin, ctx.tenant))
    failure
  end

  defp withheld_event(ctx, release) do
    ctx.tenant
    |> events_of_type("model.result.withheld")
    |> Enum.find(&(&1.subject_id == release.id))
  end

  test "reconciled: the output is released and the run keeps running", ctx do
    {invocation, outcome} = gated(ctx, "cli_shape_v3")
    assert {:ok, %{status: :reconciled}} = outcome

    assert {:released, release, output} = finalize(ctx, invocation, outcome)
    assert {release.disposition, release.reason} == {:released, :reconciled}
    assert is_map(output)
    assert run!(ctx).status == :running
  end

  test "mismatch: withheld on reconcile's critical cause; the run stops witness_mismatch", ctx do
    {invocation, {:ok, receipt} = outcome} = gated(ctx, "cli_shape_v3_mismatch")

    assert {:withheld, release, run} = finalize(ctx, invocation, outcome)
    assert {release.disposition, release.reason} == {:withheld, :witness_mismatch}
    assert {run.status, run.status_reason} == {:failed, :witness_mismatch}
    assert run.attention_failure_id == receipt.cause_id
    assert failure!(ctx, receipt.cause_id).severity == :critical

    event = withheld_event(ctx, release)
    assert event.payload["arguments"]["gate_cause_id"] == receipt.cause_id
    assert event.payload["arguments"]["gate_classification"] == "mismatch"
  end

  test "timeout: a deduplicated cause is opened under the head; witness_unreconciled", ctx do
    {invocation, {:timeout, receipt} = outcome} = gated(ctx, "none")

    assert {:withheld, release, run} = finalize(ctx, invocation, outcome)
    assert release.reason == :witness_timeout
    assert {run.status, run.status_reason} == {:failed, :witness_unreconciled}
    cause = failure!(ctx, run.attention_failure_id)
    assert cause.operation_id == ctx.run.operation_id
    assert cause.subject_id == invocation.id
    refute cause.id == receipt.cause_id

    assert withheld_event(ctx, release).payload["arguments"]["gate_classification"] ==
             "capture_pending"
  end

  test "an unconfigured store after spend is store_unreadable, with its own cause", ctx do
    {invocation, {:ok, %{status: :skipped}} = outcome} =
      gated(ctx, "cli_shape_v3", store_root: nil)

    assert {:withheld, release, run} = finalize(ctx, invocation, outcome)
    assert release.reason == :store_unreadable
    assert run.status_reason == :witness_unreconciled

    assert withheld_event(ctx, release).payload["arguments"]["gate_classification"] ==
             "store_unconfigured"
  end

  test "a match on an unpromoted tuple is witness_missing (method_not_enabled)", ctx do
    AgentsFixtures.put_allowlist!([])
    {invocation, {:ok, %{status: :inferred}} = outcome} = gated(ctx, "cli_shape_v3")

    assert {:withheld, release, run} = finalize(ctx, invocation, outcome)
    assert release.reason == :witness_missing
    assert run.status_reason == :witness_unreconciled

    assert withheld_event(ctx, release).payload["arguments"]["gate_classification"] ==
             "method_not_enabled"
  end

  test "a run without an Operation stops on the event-bound cause (G1)", ctx do
    %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
    ctx = %{ctx | run: run, agent: agent}
    {invocation, outcome} = gated(ctx, "cli_shape_v3_mismatch")

    assert {:withheld, _release, run} = finalize(ctx, invocation, outcome)
    assert run.status_reason == :witness_mismatch
    assert failure!(ctx, run.attention_failure_id).operation_id == nil
  end

  test "a cause resolved before finalization is still the run's cause; no crash", ctx do
    {invocation, {:ok, receipt} = outcome} = gated(ctx, "cli_shape_v3_mismatch")

    {:ok, _} =
      Operations.resolve_failure(failure!(ctx, receipt.cause_id), %{resolution_note: "seen"},
        actor: human(:admin, ctx.tenant)
      )

    assert {:withheld, _release, run} = finalize(ctx, invocation, outcome)
    assert {run.status_reason, run.attention_failure_id} == {:witness_mismatch, receipt.cause_id}

    refute Enum.any?(
             events_of_type(ctx.tenant, "agents.run.failed"),
             &(&1.payload["changes"]["status_reason"] == "crash")
           )
  end

  test "a run no longer running gets the release only (no stop)", ctx do
    {invocation, outcome} = gated(ctx, "cli_shape_v3_mismatch")
    {:ok, _} = Agents.cancel_run(run!(ctx), actor: human(:admin, ctx.tenant))

    assert {:withheld, release, run} = finalize(ctx, invocation, outcome)
    assert release.reason == :witness_mismatch
    assert run.status == :cancelled
  end

  test "whole finalization: dependent locks in order before the head; none after", ctx do
    {invocation, outcome} = gated(ctx, "cli_shape_v3_mismatch")

    {result, sql} = GateFixtures.capture(fn -> finalize(ctx, invocation, outcome) end)
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

    head = List.last(indices)
    after_head = Enum.drop(sql, head + 1)

    assert Enum.reject(
             Enum.filter(after_head, &GateFixtures.lock?/1),
             &GateFixtures.locks?(&1, "audit_chain_heads", "FOR UPDATE")
           ) == [],
           inspect(after_head)
  end
end
