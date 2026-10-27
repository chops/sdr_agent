defmodule SdrAgent.Agents.DemoExceptionAuthorityTest do
  @moduledoc """
  C2* S3 RED-3, decision authority, locks and replay (plan r2 §8 row
  `demo_exception_authority_test.exs`, §6 and §6.1; ADR-0005 C2* amendment
  items 6 and 7; AC5, AC6, AC7):

    * who may decide (T-L1): a `:demo_exception` decide is accepted only
      under the result-gate finalizer's verified `Prelocked` context with
      `finalizer: :result_gate`, `receipt_id: nil` and matching link set,
      grant, allocation, snapshot generation and decision instant. A
      standalone decide, Recovery's context, a hand-built or stale context
      and every mismatched binding are refused, writing nothing;
    * the under-head recheck (T-L2): a refusal rolls back with nothing
      written (`{:error, {:demo_exception_refused, code}}`), and `gate/3`
      repeats `finalize/4` exactly once with the exception disabled, so
      the ordinary withheld outcome carries that code;
    * lock order (T-L4, T-L4b): run, Operation, invocation, every current
      link, the funding grant and allocation, then the chain head; no row
      lock after it; only `attestation/0` is consulted before the head and
      the read-performing `live_binding?/2` after it;
    * replay (T-R1, T-R2, T-R3) and the finalize halves of T-R6, T-R7 and
      T-R8 (the Recovery halves are RED-4).

  RED-3 supplement (Codex facf9dcf): T-L2's gate test counts finalize
  attempts (run `FOR UPDATE` locks: one exception attempt and exactly one
  disabled repeat), not only the immutable withheld event.

  Classification (RED-3 at 2578a6f5): T-L1's positive control, its refusal
  cases (today they are refused only for the pair, so "refused, but not
  for the pair" fails), T-L2, T-L4, T-L4b, T-R1 and T-R2 are behavioural;
  T-R3 is a `control:` (a withheld row already conflicts today); the
  existing-demo-row tests (T-R6, T-R7, T-R8 finalize halves) are structural
  until a demo row can exist: they fail in
  `DemoExceptionFixtures.demo_invocation!/3`. T-L3 (a lead or contact edit
  committed before the head) is deferred to the RED-4 race file: in test
  builds no domain write can break an E1 lead/contact predicate (the
  reserved-name validation refuses it), and an edit committing while the
  finalizer waits needs separate connections (`sandbox: false`).
  """
  use SdrAgent.AuditCase, async: false

  require Ash.Query

  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission
  alias SdrAgent.Agents.Errors.ReleaseConflict
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ReleaseDecision.Prelocked
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.Agents.WireWitnessLink
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Clock
  alias SdrAgent.DemoExceptionFixtures, as: Fx
  alias SdrAgent.GateFixtures
  alias SdrAgent.Repo

  @end_at ~U[2026-11-01 06:00:00.000000Z]
  @lock_order [
    {"agent_runs", "FOR UPDATE"},
    {"operations", "FOR SHARE"},
    {"model_invocations", "FOR SHARE"},
    {"wire_witness_links", "FOR SHARE"},
    {"model_call_grants", "FOR SHARE"},
    {"model_call_allocations", "FOR SHARE"},
    {"audit_chain_heads", "FOR UPDATE"}
  ]

  setup do
    %{env: Fx.demo_env!()}
  end

  describe "who may decide (T-L1, AC5)" do
    test "T-L1 positive control: the finalizer's exact context decides", %{env: env} do
      parts = Fx.constructed!(env)
      assert {:ok, release} = prelocked_decide(env, parts, %{})
      assert {release.disposition, release.reason} == {:demo_exception, :v4_uncalibrated}
      assert release.decided_at == Clock.utc_now()
      assert release.exception_policy_id == Fx.selector()
    end

    test "T-L1: a standalone decide is refused and writes nothing", %{env: env} do
      parts = Fx.constructed!(env)
      result = Agents.decide_result_release(demo_attrs(parts), actor: env.agent)
      refused_not_for_pair!(env, parts, result)
    end

    test "T-L1: Recovery's context (a receipt cause, no finalizer) is refused", %{env: env} do
      parts = Fx.constructed!(env)
      cause = GateFixtures.cause!(parts.invocation, operation_id: env.run.operation_id)
      recovery = %{receipt_id: cause.id, finalizer: nil}
      refused_not_for_pair!(env, parts, prelocked_decide(env, parts, recovery))
    end

    test "T-L1: a hand-built context is refused", %{env: env} do
      parts = Fx.constructed!(env)

      forged = %Prelocked{
        ref: make_ref(),
        tenant_id: env.tenant.id,
        model_invocation_id: parts.invocation.id,
        wire_witness_link_id: parts.link.id,
        xact_id: "0"
      }

      result =
        Audit.transaction(fn ->
          Agents.decide_result_release(demo_attrs(parts), actor: env.agent, prelocked: forged)
        end)

      refused_not_for_pair!(env, parts, unwrap(result))
    end

    test "T-L1: a stale context (its owner has completed) is refused", %{env: env} do
      parts = Fx.constructed!(env)

      {:ok, stale} =
        Audit.transaction(fn ->
          Prelocked.run(exception_bindings(env, parts, Clock.utc_now()), & &1)
        end)

      result =
        Audit.transaction(fn ->
          Agents.decide_result_release(demo_attrs(parts), actor: env.agent, prelocked: stale)
        end)

      refused_not_for_pair!(env, parts, unwrap(result))
    end

    for {label, binding} <- [
          {"another current link set", :current_link_ids},
          {"another grant", :grant_id},
          {"another allocation", :allocation_id},
          {"another snapshot generation", :snapshot_generation},
          {"another decision instant", :decided_at},
          {"another finalizer", :finalizer},
          {"a receipt id", :receipt_id}
        ] do
      @tag binding: binding
      test "T-L1: a context binding #{label} is refused", %{env: env} = ctx do
        parts = Fx.constructed!(env)
        result = prelocked_decide(env, parts, %{ctx.binding => wrong(ctx.binding)})
        refused_not_for_pair!(env, parts, result)
      end
    end
  end

  describe "the under-head recheck and the one fallback (T-L2, AC6)" do
    test "T-L2: finalize/4 refuses under the head, writing nothing; the disabled repeat " <>
           "is the ordinary withheld outcome with the code",
         %{env: env} do
      parts = Fx.constructed!(env)
      # Committed after the receipt and before the head: the receipt stays
      # clean, so only the under-head re-read can see it.
      GateFixtures.cause!(parts.invocation, severity: :critical)
      before = length(events(env.tenant))

      result = ResultGate.finalize(parts.invocation, Fx.gate(env), {:ok, parts.receipt})
      assert result == {:error, {:demo_exception_refused, :invocation_not_clean}}
      assert {:ok, nil} = Agents.get_result_release(parts.invocation.id, actor: env.agent)
      assert length(events(env.tenant)) == before

      assert {:withheld, release, run} =
               ResultGate.finalize(parts.invocation, Fx.gate(env), {:ok, parts.receipt},
                 demo_exception: {:disabled, :invocation_not_clean}
               )

      assert {release.disposition, release.reason} == {:withheld, :witness_missing}
      assert {run.status, run.status_reason} == {:failed, :witness_unreconciled}
      assert refusal_code(env, release) == "invocation_not_clean"
    end

    test "T-L2: gate/3 makes exactly one disabled repeat, carrying the code", %{env: env} do
      invocation = GateFixtures.call_model!(env, "cli_shape_v4_thinking", clock_from: self())
      GateFixtures.cause!(invocation, severity: :critical)

      {result, sql} =
        GateFixtures.capture(fn ->
          ResultGate.gate(invocation, Fx.gate(env), store_root: env.root)
        end)

      assert {:withheld, release, run} = result
      assert {release.disposition, release.reason} == {:withheld, :witness_missing}
      assert {run.status, run.status_reason} == {:failed, :witness_unreconciled}
      assert events_for(env, "model.result.demo_exception", release) == []
      assert length(events_for(env, "model.result.withheld", release)) == 1

      # Codex facf9dcf: count finalize ATTEMPTS, not events. Each finalize
      # (and Recovery) opens by locking the run FOR UPDATE; the gate's
      # reconcile reads the run without a lock (`witness.ex:319-324`). One
      # rolled-back exception attempt plus exactly one disabled repeat is two;
      # a further repeat or a Recovery fallback is more.
      run_locks = Enum.count(sql, &GateFixtures.locks?(&1, "agent_runs", "FOR UPDATE"))

      assert run_locks == 2,
             "expected one exception attempt and one disabled repeat, saw #{run_locks} " <>
               "run lock(s)"

      assert refusal_code(env, release) == "invocation_not_clean"
    end
  end

  describe "lock order (T-L4, T-L4b)" do
    test "T-L4: the exception branch locks in order before the head; none after", %{env: env} do
      parts = Fx.constructed!(env)

      {result, sql} =
        GateFixtures.capture(fn ->
          ResultGate.finalize(parts.invocation, Fx.gate(env), {:ok, parts.receipt})
        end)

      indices = lock_indices(sql)
      assert indices == Enum.sort(indices), inspect(Enum.zip(@lock_order, indices))
      assert locks_after_head(sql, List.last(indices)) == []
      assert {:released, %{disposition: :demo_exception}, _output} = result
    end

    test "T-L4b: only attestation/0 precedes the head; the binding read follows it",
         %{env: env} do
      parts = Fx.constructed!(env)
      Fx.put_source!(:gate_sql, self())

      {_result, sql} =
        GateFixtures.capture(fn ->
          ResultGate.finalize(parts.invocation, Fx.gate(env), {:ok, parts.receipt})
        end)

      head =
        GateFixtures.index(sql, &GateFixtures.locks?(&1, "audit_chain_heads", "FOR UPDATE")) ||
          flunk("no chain head lock: #{inspect(sql)}")

      before_head = sql |> Enum.take(head) |> Enum.filter(&source_marker?/1)
      assert before_head != [], "the source was not consulted before the head: #{inspect(sql)}"
      assert Enum.uniq(before_head) == ["-- source:attestation"], inspect(before_head)

      live = GateFixtures.index(sql, &(&1 == "-- source:live_binding?"))
      assert live && live > head, "live_binding? did not follow the head: #{inspect(sql)}"
      binding = GateFixtures.index(sql, &(&1 =~ Fx.binding_marker()))
      assert binding && binding > live, inspect(sql)
      assert locks_after_head(sql, head) == []
    end
  end

  describe "replay and competing releases (T-R1, T-R2, T-R3; AC7)" do
    test "T-R1: a second eligible finalizer is an identical replay; use authority is " <>
           "checked again before the output",
         %{env: env} do
      parts = Fx.constructed!(env)
      assert {:released, first, _output} = finalize(env, parts)
      Fx.reset_calls!(env)
      :ok = Clock.freeze(DateTime.add(env.now, 60, :second))

      assert {:released, again, output} = finalize(env, parts)
      assert row(again) == row(first)
      assert is_map(output)
      assert length(events_for(env, "model.result.demo_exception", first)) == 1
      assert Enum.any?(Fx.calls(env), &match?({:live_binding?, _pid}, &1)), inspect(Fx.calls(env))
    end

    test "T-R2: a replay after the evidence changed is a ReleaseConflict", %{env: env} do
      parts = Fx.constructed!(env)
      assert {:released, first, _output} = finalize(env, parts)
      successor = successor!(env, parts)

      result = finalize(env, %{parts | receipt: %{parts.receipt | link_id: successor.id}})
      assert conflict?(result, first.id), inspect(result)
      assert {:ok, current} = Agents.get_result_release(parts.invocation.id, actor: env.agent)
      assert row(current) == row(first)
      assert length(events_for(env, "model.result.demo_exception", first)) == 1
    end

    test "control: T-R3 a committed withheld gate_interrupted row conflicts with the " <>
           "exception and remains",
         %{env: env} do
      parts = Fx.constructed!(env)
      cause = GateFixtures.cause!(parts.invocation, operation_id: env.run.operation_id)
      withheld = GateFixtures.withhold!(parts.invocation, env.agent, cause, :gate_interrupted)

      result = finalize(env, parts)
      assert conflict?(result, withheld.id), inspect(result)
      assert {:ok, current} = Agents.get_result_release(parts.invocation.id, actor: env.agent)
      assert row(current) == row(withheld)
      assert events_for(env, "model.result.demo_exception", withheld) == []
    end
  end

  describe "an existing demo row (finalize halves of T-R6, T-R7, T-R8)" do
    test "T-R6: after expiry the second finalize is an identical replay without output",
         %{env: env} do
      demo = Fx.demo_invocation!(env)
      before = length(events(env.tenant))
      :ok = Clock.freeze(DateTime.add(@end_at, 1, :second))

      assert finalize(env, demo) == {:error, :result_not_released}
      assert length(events(env.tenant)) == before
      assert {:ok, stored} = Agents.get_result_release(demo.invocation.id, actor: env.agent)
      assert row(stored) == row(demo.release)
    end

    test "T-R7: with no active snapshot the row is routed to Recovery, no conflict; " <>
           "only attestation/0 is consulted",
         %{env: env} do
      demo = Fx.demo_invocation!(env)
      before = length(events(env.tenant))
      Fx.put_source!(:attestation, :none)
      Fx.reset_calls!(env)

      assert finalize(env, demo) == {:error, :demo_exception_exists}
      assert length(events(env.tenant)) == before
      assert Fx.calls(env) |> Enum.map(&elem(&1, 0)) |> Enum.uniq() == [:attestation]
    end

    test "T-R8: with the selector off the row is routed to Recovery, no conflict", %{env: env} do
      demo = Fx.demo_invocation!(env)
      before = length(events(env.tenant))
      Application.delete_env(:sdr_agent, SdrAgent.Agents.DemoException)
      Fx.reset_calls!(env)

      assert finalize(env, demo) == {:error, :demo_exception_exists}
      assert length(events(env.tenant)) == before
      assert Enum.all?(Fx.calls(env), &match?({:attestation, _pid}, &1)), inspect(Fx.calls(env))
    end
  end

  ## Harness

  defp finalize(env, parts),
    do: ResultGate.finalize(parts.invocation, Fx.gate(env), {:ok, parts.receipt})

  defp demo_attrs(parts) do
    %{
      model_invocation_id: parts.invocation.id,
      disposition: :demo_exception,
      reason: :v4_uncalibrated,
      wire_witness_link_id: parts.link.id
    }
  end

  # The finalizer's exception context (plan r2 §6 `Prelocked`): the
  # receipt's link, the sorted current link ids, the funding grant and
  # allocation, the snapshot generation and the decision instant.
  defp exception_bindings(env, parts, decided_at) do
    %{
      tenant_id: env.tenant.id,
      model_invocation_id: parts.invocation.id,
      wire_witness_link_id: parts.link.id,
      receipt_id: nil,
      finalizer: :result_gate,
      current_link_ids: [parts.link.id],
      grant_id: env.grant.id,
      allocation_id: env.allocation.id,
      snapshot_generation: env.attestation.generation,
      decided_at: decided_at
    }
  end

  # The exception branch's locks (invocation, current links, grant and
  # allocation `FOR SHARE`, then the head), the instant, and the decide
  # under `Prelocked` with `overrides` applied to the bindings. Rolls back
  # on refusal; returns the decide's result.
  defp prelocked_decide(env, parts, overrides) do
    tenant_id = env.tenant.id

    Audit.transaction(fn ->
      {:ok, %ModelInvocation{} = invocation} = lock_invocation(parts.invocation.id, tenant_id)
      _links = lock_links(invocation)
      :ok = Admission.lock_charge(invocation)
      {:ok, _head} = Kernel.lock_head(tenant_id)
      bindings = Map.merge(exception_bindings(env, parts, Clock.utc_now()), overrides)

      bindings
      |> Prelocked.run(fn prelocked ->
        Agents.decide_result_release(demo_attrs(parts), actor: env.agent, prelocked: prelocked)
      end)
      |> case do
        {:ok, release} -> release
        {:error, error} -> Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, release} -> {:ok, release}
      {:error, error} -> {:error, error}
    end
  end

  defp lock_invocation(id, tenant_id) do
    ModelInvocation
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock("FOR SHARE")
    |> Ash.read_one()
  end

  defp lock_links(invocation) do
    WireWitnessLink
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(model_invocation_id == ^invocation.id and not exists(successors, true))
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock("FOR SHARE")
    |> Ash.read!()
  end

  defp wrong(:current_link_ids), do: [Ash.UUIDv7.generate()]
  defp wrong(:snapshot_generation), do: 2
  defp wrong(:decided_at), do: DateTime.add(Clock.utc_now(), -1, :second)
  defp wrong(:finalizer), do: :result_gate_recovery
  defp wrong(:receipt_id), do: Ecto.UUID.generate()
  defp wrong(_id), do: Ecto.UUID.generate()

  @row [
    :id,
    :disposition,
    :reason,
    :wire_witness_link_id,
    :evidence_sha256,
    :decided_at,
    :exception_policy_id,
    :exception_expires_at,
    :exception_basis,
    :exception_basis_sha256
  ]

  defp row(release), do: Map.take(release, @row)

  defp unwrap({:ok, result}), do: result
  defp unwrap({:error, error}), do: {:error, error}

  # Refused, nothing written, and not merely for the pair: today the pair
  # check is the only refusal a `:demo_exception` decide meets.
  defp refused_not_for_pair!(env, parts, result) do
    assert {:error, error} = result
    messages = error_messages(error)

    refute Enum.any?(messages, &(&1 =~ "is not a reason for")),
           "refused only for the disposition/reason pair, not by demo-exception " <>
             "decision authority: #{inspect(messages)}"

    assert {:ok, nil} = Agents.get_result_release(parts.invocation.id, actor: env.agent)
    assert events_of_type(env.tenant, "model.result.demo_exception") == []
  end

  defp error_messages(%Ash.Error.Invalid{errors: errors}), do: Enum.map(errors, &message/1)
  defp error_messages(error), do: [message(error)]

  defp message(%{__exception__: true} = error), do: Exception.message(error)
  defp message(other), do: inspect(other)

  defp conflict?({:error, %ReleaseConflict{existing_id: id}}, id), do: true

  defp conflict?({:error, %Ash.Error.Invalid{errors: errors}}, id),
    do: Enum.any?(errors, &match?(%ReleaseConflict{existing_id: ^id}, &1))

  defp conflict?(_result, _id), do: false

  defp events_for(env, type, release),
    do: env.tenant |> events_of_type(type) |> Enum.filter(&(&1.subject_id == release.id))

  defp refusal_code(env, release) do
    [event] = events_for(env, "model.result.withheld", release)
    event.payload["arguments"]["demo_exception_refusal"]
  end

  defp lock_indices(sql) do
    for {table, mode} <- @lock_order,
        do:
          GateFixtures.index(sql, &GateFixtures.locks?(&1, table, mode)) ||
            flunk("#{table} #{mode} not requested: #{inspect(sql)}")
  end

  defp locks_after_head(sql, head) do
    sql
    |> Enum.drop(head + 1)
    |> Enum.filter(&GateFixtures.lock?/1)
    |> Enum.reject(&GateFixtures.locks?(&1, "audit_chain_heads", "FOR UPDATE"))
  end

  defp source_marker?(statement), do: String.starts_with?(statement, "-- source:")

  # A successor of the primary link's exchange (a later observation of the
  # same exchange): L changes.
  defp successor!(env, parts) do
    rec = system_actor(:reconciler, env.tenant)

    evidence =
      Fx.v4_evidence(parts.invocation, %{
        "supersede_reason" => "reobserved",
        "inventory_sha256" => Fx.hex("a later inventory")
      })

    attrs = %{
      model_invocation_id: parts.invocation.id,
      proxy_record_ref: parts.link.proxy_record_ref,
      proxy_request_sha256: parts.link.proxy_request_sha256,
      proxy_response_sha256: parts.link.proxy_response_sha256,
      link_status: :inferred,
      method: :propagated_id,
      evidence: evidence,
      supersedes_id: parts.link.id
    }

    {:ok, link} = Agents.link_wire_witness(attrs, actor: rec)
    link
  end
end
