defmodule SdrAgent.Prototype.KnownEvidenceTest do
  @moduledoc """
  IF-4 known evidence (interfaces r6; amendment item 5 "Known evidence
  first"; Codex A2, residual 1), D-237 slice S2, in prototype runtime.

  The absent store's empty receipt never clears known evidence. After the
  run (`FOR UPDATE`), its Operation and the invocation (`FOR SHARE`), the
  prototype finalizer plain-reads every wire-witness link of the invocation
  and every `reconciliation_required` Failure of it (the Failures again
  under the head):

    * a link with status `mismatch` (current or superseded) is withheld
      `witness_mismatch` on the invocation's critical cause, selected as
      run recovery selects it, and the run stops `witness_mismatch`;
    * a critical Failure without such a link (live or resolved) is withheld
      `prototype_authority_refused` / `known_integrity_signal`: a usable live
      critical cause stays the bound cause, identity and severity unchanged,
      and no mismatch is claimed;
    * any other link, or a live warning Failure, is
      `prototype_authority_refused` / `witness_evidence_present`;
    * a link inserted between the observation and the decision (the
      `before_gate` seam, `result_gate.ex:113-126`) is seen;
    * none of these: `released_unverified` (with S1's provisioned grant,
      RED-b2; the cases here need no grant and record no authority).
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.GateFixtures
  alias SdrAgent.Operations
  alias SdrAgent.PrototypeGateFixtures, as: G

  # Before provisioning (RED-b1): the invocation was reserved and completed
  # before prototype runtime (PrototypeGateFixtures.pre_runtime!/1), so it
  # records no prototype authority; every case below is decided by known
  # evidence, which comes first.
  setup do
    fx = G.pre_runtime!()
    rec = system_actor(:reconciler, fx.tenant)
    %{fx: fx, run: fx.run, rec: rec, invocation: fx.invocation}
  end

  defp withheld_args(fx, release) do
    [event] = G.release_events(fx, "model.result.withheld", release)
    event.payload["arguments"]
  end

  defp refused?(fx, result, code) do
    case result do
      {:withheld, %{reason: :prototype_authority_refused} = release, _run} ->
        withheld_args(fx, release)["prototype_refusal"] == Atom.to_string(code)

      _other ->
        false
    end
  end

  test "a mismatch link with the store unset is witness_mismatch on the live critical cause",
       ctx do
    AgentsFixtures.reconciled_link!(ctx.invocation, ctx.rec, link_status: :mismatch)

    critical =
      GateFixtures.cause!(ctx.invocation, severity: :critical, operation_id: ctx.run.operation_id)

    result = G.finalize(ctx.invocation, ctx.run)
    assert match?({:withheld, %{reason: :witness_mismatch}, _}, result), inspect(result)
    {:withheld, release, run} = result

    assert {run.status, run.status_reason, run.attention_failure_id} ==
             {:failed, :witness_mismatch, critical.id}

    assert withheld_args(ctx.fx, release)["gate_cause_id"] == critical.id
  end

  test "a mismatch link with no live critical opens a bound critical under the head", ctx do
    AgentsFixtures.reconciled_link!(ctx.invocation, ctx.rec, link_status: :mismatch)

    result = G.finalize(ctx.invocation, ctx.run)
    assert match?({:withheld, %{reason: :witness_mismatch}, _}, result), inspect(result)
    {:withheld, _release, run} = result

    cause = Ash.get!(SdrAgent.Operations.Failure, run.attention_failure_id, authorize?: false)
    assert {cause.severity, cause.subject_id} == {:critical, ctx.invocation.id}
  end

  test "a superseded mismatch link is still witness_mismatch", ctx do
    mismatch = AgentsFixtures.reconciled_link!(ctx.invocation, ctx.rec, link_status: :mismatch)

    # A mismatch is superseded only under a different projection version
    # (WitnessLineage); the v2 projection carries its context group.
    AgentsFixtures.reconciled_link!(ctx.invocation, ctx.rec,
      link_status: :inferred,
      supersedes_id: mismatch.id,
      proxy_record_ref: mismatch.proxy_record_ref,
      evidence: %{
        "projection_version" => "claude-message-json/2+prompt-builder/1",
        "supersede_reason" => "projection_version_changed",
        "reminder_count" => 0,
        "reminder_sha256s" => [],
        "reminder_bytes" => [],
        "trailing_system_count" => 0,
        "trailing_system_sha256s" => [],
        "trailing_system_bytes" => [],
        "request_extras_sha256" => String.duplicate("c3", 32),
        "request_fields" => []
      }
    )

    result = G.finalize(ctx.invocation, ctx.run)
    assert match?({:withheld, %{reason: :witness_mismatch}, _}, result), inspect(result)
  end

  test "a critical Failure without a mismatch link is known_integrity_signal; its cause is kept",
       ctx do
    critical =
      GateFixtures.cause!(ctx.invocation, severity: :critical, operation_id: ctx.run.operation_id)

    result = G.finalize(ctx.invocation, ctx.run)
    assert refused?(ctx.fx, result, :known_integrity_signal), inspect(result)
    {:withheld, release, run} = result

    assert {run.status_reason, run.attention_failure_id} == {:witness_unreconciled, critical.id}
    assert withheld_args(ctx.fx, release)["gate_cause_id"] == critical.id

    kept = Ash.get!(SdrAgent.Operations.Failure, critical.id, authorize?: false)
    assert {kept.severity, kept.status} == {:critical, critical.status}

    assert Enum.filter(
             events_of_type(ctx.fx.tenant, "model.result.withheld"),
             &(&1.payload["changes"]["reason"] == "witness_mismatch")
           ) == []
  end

  test "a resolved critical Failure is still known_integrity_signal", ctx do
    critical =
      GateFixtures.cause!(ctx.invocation, severity: :critical, operation_id: ctx.run.operation_id)

    {:ok, _resolved} =
      Operations.resolve_failure(critical, %{resolution_note: "synthetic: reviewed"},
        actor: ctx.fx.admin
      )

    result = G.finalize(ctx.invocation, ctx.run)
    assert refused?(ctx.fx, result, :known_integrity_signal), inspect(result)
  end

  test "a live warning Failure is witness_evidence_present, bound to that warning", ctx do
    warning =
      GateFixtures.cause!(ctx.invocation, severity: :warning, operation_id: ctx.run.operation_id)

    result = G.finalize(ctx.invocation, ctx.run)
    assert refused?(ctx.fx, result, :witness_evidence_present), inspect(result)
    {:withheld, _release, run} = result
    assert run.attention_failure_id == warning.id
  end

  test "any other link is witness_evidence_present", ctx do
    AgentsFixtures.reconciled_link!(ctx.invocation, ctx.rec, link_status: :inferred)
    result = G.finalize(ctx.invocation, ctx.run)
    assert refused?(ctx.fx, result, :witness_evidence_present), inspect(result)
  end

  test "a link inserted between the observation and the decision is seen (before_gate)", ctx do
    previous = Application.get_env(:sdr_agent, ResultGate)
    rec = ctx.rec

    Application.put_env(:sdr_agent, ResultGate,
      wait_ms: 300,
      poll_ms: 25,
      before_gate: fn invocation ->
        AgentsFixtures.reconciled_link!(invocation, rec, link_status: :inferred)
      end
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:sdr_agent, ResultGate, previous),
        else: Application.delete_env(:sdr_agent, ResultGate)
    end)

    result = ResultGate.gate(ctx.invocation, G.gate(ctx.run))
    assert refused?(ctx.fx, result, :witness_evidence_present), inspect(result)
  end
end
