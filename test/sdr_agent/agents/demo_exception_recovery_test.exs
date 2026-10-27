defmodule SdrAgent.Agents.DemoExceptionRecoveryTest do
  @moduledoc """
  C2* S3 RED-4, Recovery's demo-exception clause and the narrow
  `LinkGateCause` binding (plan r2 §6 `ResultGate.Recovery` and
  `LinkGateCause`, §8 rows T-R4, T-R5 and the Recovery halves of T-R6,
  T-R7, T-R8; ADR-0005 C2* items 6, 7 and 9; AC10; OQ11).

  Recovery never creates an exception. On an existing demo row it returns
  the output only with present use authority; otherwise a running run is
  stopped `:witness_unreconciled` on the deduplicated warning cause
  "demo exception not in use" (this invocation, the run's Operation), with
  `failure_reason` "model output withheld by the result gate: demo
  exception not in use", writing no release or release event; a terminal
  run is returned as it is. `LinkGateCause` accepts, for a `:demo_exception`
  release only, exactly that cause.

  The demo row comes from the real finalizer (`demo_invocation!/3`);
  `finalize/4` stands for `gate/3`'s first step (H2 writes no store
  exchange, so `gate/3`'s await would re-observe it).

  Classification (RED-4 at 109b2614): T-R4's two branches, the T-R6/T-R7/
  T-R8 Recovery halves, the terminal run, the cause deduplication and the
  `LinkGateCause` allow case are behavioural (today Recovery refuses a demo
  row `:not_gated`, and `LinkGateCause` accepts withheld releases only);
  T-R5 and the `LinkGateCause` deny cases pass now (`control:`; T-R5's
  `exception_off` was implemented in GREEN-3b).
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.Agents.ResultGate.Recovery
  alias SdrAgent.Clock
  alias SdrAgent.DemoExceptionFixtures, as: Fx
  alias SdrAgent.Operations

  @end_at ~U[2026-11-01 06:00:00.000000Z]
  @message "demo exception not in use"
  @failure_reason "model output withheld by the result gate: demo exception not in use"

  setup do
    %{env: Fx.demo_env!()}
  end

  describe "Recovery on an existing demo row (T-R4; AC10)" do
    test "T-R4: with use authority Recovery returns the stored release and its output",
         %{env: env} do
      demo = Fx.demo_invocation!(env)
      before = release_events(env)

      assert {:released, release, output} = Recovery.run(demo.invocation, Fx.gate(env))
      assert release.id == demo.release.id
      assert output == demo.output
      assert run!(env).status == :running
      assert release_events(env) == before
    end

    test "T-R6: after expiry the gate's replay has no output; Recovery stops the run " <>
           "on the fixed cause and writes no release",
         %{env: env} do
      demo = Fx.demo_invocation!(env)
      :ok = Clock.freeze(DateTime.add(@end_at, 1, :second))
      assert finalize(env, demo) == {:error, :result_not_released}
      assert_stopped!(env, demo)
    end

    test "T-R7: with no active snapshot Recovery honours the row without output",
         %{env: env} do
      demo = Fx.demo_invocation!(env)
      Fx.put_source!(:attestation, :none)
      assert finalize(env, demo) == {:error, :demo_exception_exists}
      assert_stopped!(env, demo)
    end

    test "T-R8: with the selector off Recovery honours the row without output", %{env: env} do
      demo = Fx.demo_invocation!(env)
      Application.delete_env(:sdr_agent, SdrAgent.Agents.DemoException)
      assert finalize(env, demo) == {:error, :demo_exception_exists}
      assert_stopped!(env, demo)
    end

    test "a terminal run is returned as it is: no cause, no stop", %{env: env} do
      demo = Fx.demo_invocation!(env)
      {:ok, cancelled} = Agents.cancel_run(env.run, actor: human(:admin, env.tenant))
      Fx.put_source!(:attestation, :none)
      before = {release_events(env), fixed_causes(env, demo)}

      assert {:withheld, release, run} = Recovery.run(demo.invocation, Fx.gate(env))
      assert release.id == demo.release.id
      assert {run.status, run.status_reason} == {cancelled.status, cancelled.status_reason}
      assert {release_events(env), fixed_causes(env, demo)} == before
    end

    test "a live fixed cause is reused, never duplicated", %{env: env} do
      demo = Fx.demo_invocation!(env)
      existing = fixed_cause!(env, demo.invocation, @message)
      Fx.put_source!(:attestation, :none)

      assert {:withheld, _release, run} = Recovery.run(demo.invocation, Fx.gate(env))
      assert run.attention_failure_id == existing.id
      assert Enum.map(fixed_causes(env, demo), & &1.id) == [existing.id]
    end
  end

  describe "Recovery never decides an exception (T-R5)" do
    test "control: T-R5 eligible evidence and no release is withheld gate_interrupted, " <>
           "recording exception_off",
         %{env: env} do
      parts = Fx.constructed!(env)

      assert {:withheld, release, _run} = Recovery.run(parts.invocation, Fx.gate(env))
      assert {release.disposition, release.reason} == {:withheld, :gate_interrupted}
      assert events_for(env, "model.result.demo_exception", release) == []
      assert [event] = events_for(env, "model.result.withheld", release)
      assert event.payload["arguments"]["demo_exception_refusal"] == "exception_off"
    end
  end

  describe "LinkGateCause for a demo row (OQ11)" do
    test "allow: the fixed warning of this invocation and Operation links the stop",
         %{env: env} do
      demo = Fx.demo_invocation!(env)
      cause = fixed_cause!(env, demo.invocation, @message)

      assert {:ok, run} = stop(env, demo, cause, :witness_unreconciled)
      assert {run.status, run.status_reason} == {:failed, :witness_unreconciled}
      assert run.attention_failure_id == cause.id
    end

    for {label, variant} <- [
          {"an arbitrary warning", :other_message},
          {"a cause of no Operation", :no_operation},
          {"a critical cause", :critical},
          {"the mismatch stop", :mismatch_stop}
        ] do
      @tag variant: variant
      test "control: deny #{label}", %{env: env} = ctx do
        demo = Fx.demo_invocation!(env)
        {cause, stop_reason} = deny_case(env, demo, ctx.variant)

        assert {:error, %Ash.Error.Invalid{}} = stop(env, demo, cause, stop_reason)
        assert run!(env).status == :running
      end
    end
  end

  ## Harness

  defp finalize(env, demo),
    do: ResultGate.finalize(demo.invocation, Fx.gate(env), {:ok, demo.receipt})

  defp run!(env) do
    {:ok, run} = Agents.get_run(env.run.id, actor: env.agent)
    run
  end

  defp events_for(env, type, release),
    do: env.tenant |> events_of_type(type) |> Enum.filter(&(&1.subject_id == release.id))

  defp release_events(env),
    do: Enum.count(events(env.tenant), &String.starts_with?(&1.event_type, "model.result."))

  defp fixed_causes(env, demo) do
    {:ok, failures} = Operations.list_attention(actor: human(:admin, env.tenant))

    Enum.filter(
      failures,
      &(&1.subject_id == demo.invocation.id and &1.message == @message)
    )
  end

  # AC10: no output; the run stopped on the one fixed cause; nothing decided.
  defp assert_stopped!(env, demo) do
    before = release_events(env)
    assert {:withheld, release, run} = Recovery.run(demo.invocation, Fx.gate(env))
    assert release.id == demo.release.id
    assert {run.status, run.status_reason} == {:failed, :witness_unreconciled}
    assert run.failure_reason == @failure_reason
    assert [cause] = fixed_causes(env, demo)
    assert run.attention_failure_id == cause.id

    assert {cause.class, cause.severity, cause.operation_id} ==
             {:reconciliation_required, :warning, env.run.operation_id}

    assert {:ok, stored} = Agents.get_result_release(demo.invocation.id, actor: env.agent)
    assert stored.id == demo.release.id
    assert stored.exception_basis_sha256 == demo.release.exception_basis_sha256
    assert release_events(env) == before
  end

  defp fixed_cause!(env, invocation, message, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          subject_resource: "SdrAgent.Agents.ModelInvocation",
          subject_id: invocation.id,
          class: :reconciliation_required,
          severity: :warning,
          message: message,
          retryable: false,
          operation_id: env.run.operation_id
        },
        overrides
      )

    {:ok, failure} =
      Operations.open_failure(attrs, actor: system_actor(:reconciler, env.tenant))

    failure
  end

  defp deny_case(env, demo, :other_message),
    do: {fixed_cause!(env, demo.invocation, "another warning"), :witness_unreconciled}

  defp deny_case(env, demo, :no_operation),
    do:
      {fixed_cause!(env, demo.invocation, @message, %{operation_id: nil}), :witness_unreconciled}

  defp deny_case(env, demo, :critical),
    do:
      {fixed_cause!(env, demo.invocation, @message, %{severity: :critical}),
       :witness_unreconciled}

  defp deny_case(env, demo, :mismatch_stop),
    do: {fixed_cause!(env, demo.invocation, @message), :witness_mismatch}

  defp stop(env, demo, cause, stop_reason) do
    Agents.fail_run(
      run!(env),
      %{
        status_reason: stop_reason,
        failure_reason: @failure_reason,
        witness_failure_id: cause.id,
        release_id: demo.release.id
      },
      actor: env.agent
    )
  end
end
