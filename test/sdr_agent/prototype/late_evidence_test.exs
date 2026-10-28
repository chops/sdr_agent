defmodule SdrAgent.Prototype.LateEvidenceTest do
  @moduledoc """
  IF-4 known evidence re-read under the head (amendment item 5: Failure
  writers append under the chain head, so the Failures are re-read under
  the head; Codex 0235e6fd ruling 2), D-237 slice S2, in prototype runtime.

  A synthetic late Failure is opened at the test-build-only `before_head`
  boundary of `SdrAgent.Prototype.Release` (Codex 2c9450b7 ruling 2): after
  the plain reads and the cause lock, before the chain head, inside the
  finalizer's own transaction (in a sandboxed test that is how a write can
  become visible to the under-head re-read; it rolls back with the attempt).

    * Evidence seen first under the head that changes the refusal code or
      the bound cause writes nothing: the attempt rolls back, and the gate
      decides once more, refusal-only, taking its locks before the head
      again. It never continues with a stale cause and never escalates.
    * A repeat that again sees changed evidence returns
      `{:error, :recheck_failed}` with nothing written: no third attempt.
      Through the facade it is returned unchanged (TF-1, Codex eff38bd0 and
      cc688175: no Recovery fallback in prototype runtime), and nothing is
      decided.

  The invocation was reserved and completed before prototype runtime
  (`PrototypeGateFixtures.pre_runtime!/1`), so it records no prototype
  authority and is never released; no provisioning is needed.
  """
  use SdrAgent.PrototypeCase, async: false

  require Ash.Query

  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.GateFixtures
  alias SdrAgent.Operations
  alias SdrAgent.Operations.Failure
  alias SdrAgent.Prototype.Release
  alias SdrAgent.PrototypeGateFixtures, as: G

  setup do
    fx = G.pre_runtime!()
    previous = Application.get_env(:sdr_agent, Release)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:sdr_agent, Release, previous),
        else: Application.delete_env(:sdr_agent, Release)
    end)

    %{fx: fx, run: fx.run, invocation: fx.invocation}
  end

  # A before_head hook that counts every call in the finalizing (test)
  # process, marks it in a captured SQL stream, and opens a live,
  # gate-capable critical Failure of the invocation on the calls in `on`.
  defp late_critical!(ctx, on) do
    me = self()
    operation_id = ctx.run.operation_id

    Application.put_env(:sdr_agent, Release,
      before_head: fn invocation ->
        call = Process.get(:late_calls, 0) + 1
        Process.put(:late_calls, call)
        send(me, {:gate_sql, "-- before_head #{call}"})

        if call in on,
          do: GateFixtures.cause!(invocation, severity: :critical, operation_id: operation_id)
      end
    )
  end

  defp calls, do: Process.get(:late_calls, 0)

  defp failures(invocation) do
    Failure
    |> Ash.Query.filter(subject_id == ^invocation.id and class == :reconciliation_required)
    |> Ash.read!(SdrAgent.Audit.Kernel.opts(invocation.tenant_id))
  end

  defp withheld_events(fx), do: events_of_type(fx.tenant, "model.result.withheld")

  defp arguments(fx, release) do
    [event] = G.release_events(fx, "model.result.withheld", release)
    event.payload["arguments"]
  end

  defp reloaded(run), do: Ash.get!(AgentRun, run.id, authorize?: false)

  test "a late critical seen first under the head: nothing written, one refusal-only repeat",
       ctx do
    late_critical!(ctx, [1])
    result = G.finalize(ctx.invocation, ctx.run)

    assert calls() == 2,
           "after #{calls()} before_head call(s) the late critical forced no repeat: #{inspect(result)}"

    assert {:withheld, release, run} = result
    assert {release.disposition, release.reason} == {:withheld, :prototype_authority_refused}

    args = arguments(ctx.fx, release)

    assert {args["prototype_refusal"], args["gate_classification"]} ==
             {"authority_unrecorded", "store_unconfigured"}

    # The first attempt wrote nothing (its late critical rolled back with
    # it); the repeat bound the cause it selected and opened itself.
    assert [cause] = failures(ctx.invocation)
    assert cause.id == args["gate_cause_id"]
    assert {cause.severity, cause.status} == {:warning, :open}

    assert {run.status, run.status_reason, run.attention_failure_id} ==
             {:failed, :witness_unreconciled, cause.id}

    assert length(withheld_events(ctx.fx)) == 1
  end

  test "a late live critical that would change the bound cause is never kept stale", ctx do
    resolved =
      GateFixtures.cause!(ctx.invocation, severity: :critical, operation_id: ctx.run.operation_id)

    {:ok, _resolved} =
      Operations.resolve_failure(resolved, %{resolution_note: "synthetic: reviewed"},
        actor: ctx.fx.admin
      )

    late_critical!(ctx, [1])
    result = G.finalize(ctx.invocation, ctx.run)

    assert calls() == 2,
           "after #{calls()} before_head call(s) the changed cause forced no repeat: #{inspect(result)}"

    assert {:withheld, release, run} = result
    args = arguments(ctx.fx, release)
    assert args["prototype_refusal"] == "known_integrity_signal"

    assert ctx.invocation |> failures() |> Enum.map(&{&1.severity, &1.status}) |> Enum.sort() ==
             [{:critical, :resolved}, {:warning, :open}]

    assert run.attention_failure_id == args["gate_cause_id"]
  end

  test "evidence that changes again on the repeat: recheck_failed, nothing written, no third attempt",
       ctx do
    late_critical!(ctx, [1, 2, 3])
    result = G.finalize(ctx.invocation, ctx.run)

    assert result == {:error, :recheck_failed},
           "finalize after #{calls()} before_head call(s): #{inspect(result)}"

    assert calls() == 2
    assert G.release(ctx.invocation) == nil
    assert withheld_events(ctx.fx) == []
    assert failures(ctx.invocation) == []
    assert reloaded(ctx.run).status == :running
  end

  # TF-1 (Codex eff38bd0, cc688175): an explicit contract correction of the
  # former "goes to Recovery" expectation, not a weakening: the facade
  # returns recheck_failed unchanged and nothing is decided.
  test "through the facade, a recheck failure is returned unchanged; nothing decided", ctx do
    late_critical!(ctx, [1, 2, 3])
    result = ResultGate.gate(ctx.invocation, G.gate(ctx.run))

    assert result == {:error, :recheck_failed},
           "gate after #{calls()} before_head call(s): #{inspect(G.summary(result))}"

    assert calls() == 2
    assert G.release(ctx.invocation) == nil
    assert withheld_events(ctx.fx) == []
    assert events_of_type(ctx.fx.tenant, "model.result.released_unverified") == []
    assert reloaded(ctx.run).status == :running
  end

  test "each attempt locks run, Operation, invocation and cause before the head; none after",
       ctx do
    late_critical!(ctx, [1])
    {result, sql} = GateFixtures.capture(fn -> G.finalize(ctx.invocation, ctx.run) end)
    assert match?({:withheld, _, _}, result), inspect(result)

    starts =
      sql
      |> Enum.with_index()
      |> Enum.filter(fn {query, _i} -> GateFixtures.locks?(query, "agent_runs", "FOR UPDATE") end)
      |> Enum.map(fn {_query, i} -> i end)

    assert length(starts) == 2, "attempts: #{inspect(starts)}, before_head calls: #{calls()}"

    starts
    |> Enum.zip(tl(starts) ++ [length(sql)])
    |> Enum.with_index(1)
    |> Enum.each(fn {{from, to}, call} ->
      assert_attempt_order!(Enum.slice(sql, from, to - from), call)
    end)
  end

  defp assert_attempt_order!(sql, call) do
    order = [
      &GateFixtures.locks?(&1, "agent_runs", "FOR UPDATE"),
      &GateFixtures.locks?(&1, "operations", "FOR SHARE"),
      &GateFixtures.locks?(&1, "model_invocations", "FOR SHARE"),
      &GateFixtures.locks?(&1, "failures", "FOR UPDATE"),
      &(&1 == "-- before_head #{call}"),
      &GateFixtures.locks?(&1, "audit_chain_heads", "FOR UPDATE")
    ]

    indices =
      Enum.map(order, &(GateFixtures.index(sql, &1) || flunk("attempt #{call}: #{inspect(sql)}")))

    assert indices == Enum.sort(indices), "attempt #{call}: #{inspect(indices)}"

    after_head = Enum.drop(sql, List.last(indices) + 1)

    assert Enum.reject(
             Enum.filter(after_head, &GateFixtures.lock?/1),
             &GateFixtures.locks?(&1, "audit_chain_heads", "FOR UPDATE")
           ) == [],
           "attempt #{call} locked after the head: #{inspect(after_head)}"
  end
end
