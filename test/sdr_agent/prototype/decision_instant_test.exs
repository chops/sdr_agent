defmodule SdrAgent.Prototype.DecisionInstantTest do
  @moduledoc """
  RED-α N2 (Codex c0f98ba6), D-237 slice S2: the prototype gate's decision
  instant, bound in its own Prelocked context. Inside the gate's own context
  (finalizer :prototype_gate) a server-derived `decided_at` binding is the
  decision instant of a NEW released_unverified decision: the persisted row,
  its basis and its one event agree on it while the action's own default
  clock reads a DIFFERENT, later, valid instant. The instant is never taken
  from the supplied basis. A non-nil binding in an ordinary context (no
  finalizer), and an invalid instant (not a UTC DateTime with microsecond
  precision 6), are refused before the function runs. Without a binding the
  action's default instant decides, as today.

  Own-context stand-in only (the gate's release-branch locks, then
  `Prelocked.run/2`) and the test clock only: no production callback, no raw
  persistence. Messages are value-free (`G.summary/1`).
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.Agents.ReleaseDecision.Prelocked
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.Clock
  alias SdrAgent.PrototypeGateFixtures, as: G

  # Two distinct valid instants inside the window: the gate's (bound) and the
  # action's own default clock (later).
  @gate ~U[2026-11-01 00:00:00.000001Z]
  @action ~U[2026-11-01 00:00:01.000002Z]
  @gate_text "2026-11-01T00:00:00.000001Z"

  setup do
    Clock.freeze(@gate)
    fx = G.prototype!()
    run = G.run!(fx)
    invocation = G.completed!(fx, run)
    %{fx: fx, run: run, invocation: invocation}
  end

  test "N2-1: the gate's bound instant is the row's, the basis's and the event's, not the action clock's",
       ctx do
    refute @gate == @action
    basis = G.expected_basis(ctx.fx, ctx.invocation, @gate)
    Clock.freeze(@action)

    result =
      own(ctx, %{decided_at: @gate}, fn prelocked ->
        if Map.get(prelocked, :decided_at) == @gate,
          do: decide(ctx, prelocked, basis),
          else: SdrAgent.Repo.rollback(:instant_unbound)
      end)

    assert result != {:error, :instant_unbound},
           "the gate's instant is not bound in its own context"

    assert match?({:ok, %ModelResultRelease{disposition: :released_unverified}}, result),
           "decided: #{inspect(G.summary(result))}"

    {:ok, release} = result
    assert release.decided_at == @gate
    assert [event] = G.release_events(ctx.fx, "model.result.released_unverified", release)
    assert event.payload["arguments"]["basis"] == basis
    assert basis["window"]["decided_at"] == @gate_text
  end

  test "N2-2: an ordinary context (no finalizer) with a bound instant is refused before its function runs",
       ctx do
    result = own(ctx, %{finalizer: nil, decided_at: @gate}, fn _prelocked -> :ran end)
    assert result == {:ok, {:error, :invalid_decided_at}}, inspect(G.summary(result))
  end

  test "N2-3: an invalid bound instant is refused before the function runs", ctx do
    cases = [
      text: @gate_text,
      naive: ~N[2026-11-01 00:00:00.000001],
      non_utc: %DateTime{@gate | time_zone: "Etc/GMT+6", zone_abbr: "-06", utc_offset: -21_600},
      second_precision: %DateTime{@gate | microsecond: {0, 0}},
      millisecond_precision: %DateTime{@gate | microsecond: {0, 3}}
    ]

    wrong =
      for {label, at} <- cases,
          result = own(ctx, %{decided_at: at}, fn _prelocked -> :ran end),
          result != {:ok, {:error, :invalid_decided_at}},
          do: {label, G.summary(result)}

    assert wrong == [], "not refused before the function ran: #{inspect(wrong)}"
  end

  # Control: struct equality in verify/1 already refuses any changed context.
  test "N2-4 (control): a context whose bound instant changed after registration is refused",
       ctx do
    basis = G.expected_basis(ctx.fx, ctx.invocation, @action)
    Clock.freeze(@action)

    result =
      own(ctx, %{decided_at: @gate}, fn prelocked ->
        decide(ctx, Map.put(prelocked, :decided_at, @action), basis)
      end)

    assert refused_on?(result, :model_invocation_id, "the prelocked decision context is refused"),
           inspect(G.summary(result))

    assert G.release(ctx.invocation) == nil
  end

  test "N2-5: without a bound instant the action's own default instant decides", ctx do
    Clock.freeze(@action)
    basis = G.expected_basis(ctx.fx, ctx.invocation, @action)
    result = own(ctx, %{}, fn prelocked -> decide(ctx, prelocked, basis) end)

    assert match?({:ok, %ModelResultRelease{disposition: :released_unverified}}, result),
           "prerequisite: the own-context decision: #{inspect(G.summary(result))}"

    {:ok, release} = result
    assert release.decided_at == @action
  end

  test "N2-6: the supplied basis never sets the instant: a self-consistent basis at the action clock is refused",
       ctx do
    Clock.freeze(@action)
    basis = G.expected_basis(ctx.fx, ctx.invocation, @action)
    result = own(ctx, %{decided_at: @gate}, fn prelocked -> decide(ctx, prelocked, basis) end)

    assert refused_on?(result, :basis, "must be a valid d237-basis/1 with its digest"),
           "decided: #{inspect(G.summary(result))}"

    assert G.release(ctx.invocation) == nil
    assert events_of_type(ctx.fx.tenant, "model.result.released_unverified") == []
  end

  # The gate's release-branch locks (the run FOR UPDATE, its Operation, the
  # invocation FOR SHARE, the charged grant and allocation, the head), then
  # Prelocked.run/2 with the gate's bindings merged with `extra`, then `fun`.
  # The transaction's result.
  defp own(ctx, extra, fun) do
    tenant_id = ctx.invocation.tenant_id

    SdrAgent.Audit.transaction(fn ->
      {:ok, run} = ResultGate.lock(AgentRun, ctx.run.id, tenant_id, "FOR UPDATE")
      :ok = ResultGate.lock_operation(run, tenant_id)
      {:ok, held} = ResultGate.lock(ModelInvocation, ctx.invocation.id, tenant_id, "FOR SHARE")
      :ok = SdrAgent.Agents.Admission.lock_charge(held)
      {:ok, _head} = SdrAgent.Audit.Kernel.lock_head(tenant_id)

      %{tenant_id: tenant_id, model_invocation_id: ctx.invocation.id, finalizer: :prototype_gate}
      |> Map.merge(extra)
      |> Prelocked.run(fun)
    end)
  end

  defp decide(ctx, prelocked, basis) do
    attrs = %{
      model_invocation_id: ctx.invocation.id,
      disposition: :released_unverified,
      reason: :owner_prototype_unverified,
      basis: basis,
      basis_sha256: G.canonical_hex(basis)
    }

    case Agents.decide_result_release(attrs, actor: ctx.fx.agent, prelocked: prelocked) do
      {:ok, release} -> release
      {:error, error} -> SdrAgent.Repo.rollback(error)
    end
  end

  # The transaction rolled back with an Invalid error on `field` with `message`.
  defp refused_on?({:error, error}, field, message) do
    error
    |> Ash.Error.to_error_class()
    |> Map.get(:errors, [])
    |> Enum.any?(&(Map.get(&1, :field) == field and Map.get(&1, :message) == message))
  end

  defp refused_on?(_result, _field, _message), do: false
end
