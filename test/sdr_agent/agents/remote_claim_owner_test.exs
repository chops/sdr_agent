defmodule SdrAgent.Agents.RemoteClaimOwnerTest do
  @moduledoc """
  W2 RED (S-B5 controls steps 60407d82 item 2; entity 48dfc516 W2): a
  remote claim rechecks the binding's live hosted owner at the serialized
  launch point. In prototype runtime a pending call emits no launch input
  when the owner is disabled or was never enrolled: the claim is refused
  with `{:error, :owner_unavailable}` and writes nothing (the call stays
  pending, the invocation reserved, no nonce row, no `remote_call.claimed`
  event). The ordinary-runtime claim path is unchanged. The head-wait
  disable race is in `SdrAgent.Prototype.HostedOwnerRaceTest`.
  Synthetic fixtures only; no model, CLI or network.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Actor
  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.HostedOwnerFixtures, as: H
  alias SdrAgent.PrototypeFixtures
  alias SdrAgent.PrototypeGateFixtures, as: G
  alias SdrAgent.RemoteCallFixtures, as: F

  setup do
    ctx = H.activated!()
    admin = human(:admin, ctx.fx.tenant)
    :ok = AgentsFixtures.ensure_offering!(ctx.fx.tenant)
    definition = AgentsFixtures.definition!(ctx.fx.tenant)
    agent = Actor.system(:agent_runtime, ctx.fx.tenant.id)
    fx = Map.merge(ctx.fx, %{admin: admin, definition: definition, agent: agent})
    F.remote!()
    %{token: token, worker: worker} = F.enrol!(fx)
    Map.merge(ctx, %{fx: fx, token: token, worker: worker})
  end

  # Prototype runtime: the provisioned grant, a run and one pending call.
  defp prototype_call!(ctx) do
    H.enter!(ctx)
    grant = G.provision!(ctx.fx)
    run = G.run!(ctx.fx)
    fx = Map.merge(ctx.fx, %{grant: grant, run: run})
    invocation = F.reserve!(fx)
    assert %{"state" => "pending"} = F.call_of(invocation.id)
    Map.merge(ctx, %{fx: fx, invocation: invocation})
  end

  # The owner-run disable, as the relocation race holder runs it.
  defp disable_owner!(ctx, owner) do
    :ok = PrototypeFixtures.leave_runtime()
    :ok = PrototypeFixtures.put_live_identity(ctx.destination)
    assert {:ok, _} = H.disable(ctx, owner.id)
  end

  defp assert_no_claim_writes!(ctx, result) do
    call = F.call_of(ctx.invocation.id)
    assert call["state"] == "pending", "the call left pending: #{inspect(call["state"])}"
    assert call["worker_id"] == nil
    assert F.invocation(ctx.invocation.id).status == :reserved
    assert F.count(F.nonce_resource(), "worker_id = $1", [F.dump(ctx.worker.id)]) == 0
    assert F.subject_count(ctx.fx, "remote_call.claimed", F.load(call["id"])) == 0
    refute inspect(result) =~ F.prompt_marker(), "launch input emitted: #{inspect(result)}"
  end

  test "control: prototype runtime with the live owner launches the pending call", ctx do
    _enrolled = H.enrol!(ctx)
    ctx = prototype_call!(ctx)

    launch = F.claim!(ctx.token, F.nonce())
    assert launch.call_id == F.load(F.call_of(ctx.invocation.id)["id"])
    assert launch.prompt =~ F.prompt_marker()
    assert F.call_of(ctx.invocation.id)["state"] == "claimed"
  end

  test "a disabled owner: the claim is refused and emits no launch input", ctx do
    enrolled = H.enrol!(ctx)
    ctx = prototype_call!(ctx)
    disable_owner!(ctx, enrolled.owner)
    H.enter!(ctx)

    result = F.claim(ctx.token, F.nonce())
    assert result == {:error, :owner_unavailable}
    assert_no_claim_writes!(ctx, result)
  end

  test "no hosted owner enrolled: the claim is refused and emits no launch input", ctx do
    ctx = prototype_call!(ctx)

    result = F.claim(ctx.token, F.nonce())
    assert result == {:error, :owner_unavailable}
    assert_no_claim_writes!(ctx, result)
  end

  test "a refused claim spends no nonce: the same nonce launches once an owner is live", ctx do
    ctx = prototype_call!(ctx)
    nonce = F.nonce()
    assert F.claim(ctx.token, nonce) == {:error, :owner_unavailable}

    :ok = PrototypeFixtures.leave_runtime()
    :ok = PrototypeFixtures.put_live_identity(ctx.destination)
    _enrolled = H.enrol!(ctx)
    H.enter!(ctx)

    launch = F.claim!(ctx.token, nonce)
    assert launch.call_id == F.load(F.call_of(ctx.invocation.id)["id"])
  end

  # W2 supplemental (Codex m_codex_w2_red_go_77f8af2f_20261031 choice 4): a
  # launch-producing replay of a call claimed before the disable rechecks
  # the owner; the claim, nonce, charge and deadlines are kept as they are.
  test "control: a live owner's replay of the claimed nonce returns the same launch", ctx do
    _enrolled = H.enrol!(ctx)
    ctx = prototype_call!(ctx)
    nonce = F.nonce()
    launch = F.claim!(ctx.token, nonce)
    assert F.claim!(ctx.token, nonce) == launch
  end

  test "after owner disable, a claimed call's replay emits no launch input and keeps its state",
       ctx do
    enrolled = H.enrol!(ctx)
    ctx = prototype_call!(ctx)
    nonce = F.nonce()
    launch = F.claim!(ctx.token, nonce)
    disable_owner!(ctx, enrolled.owner)
    H.enter!(ctx)
    before = F.call_row(launch.call_id)
    events = F.event_count(ctx.fx)

    result = F.claim(ctx.token, nonce)
    assert result == {:error, :owner_unavailable}
    refute inspect(result) =~ F.prompt_marker(), "launch input emitted: #{inspect(result)}"
    assert F.call_row(launch.call_id) == before
    assert F.invocation(ctx.invocation.id).status == :sent
    assert F.count(F.nonce_resource(), "worker_id = $1", [F.dump(ctx.worker.id)]) == 1
    assert F.event_count(ctx.fx) == events
  end

  test "ordinary runtime is unchanged: a disabled hosted owner does not gate the claim", ctx do
    enrolled = H.enrol!(ctx)
    AdmissionFixtures.admit_tuples!()
    grant = AgentsFixtures.grant!(ctx.fx.tenant, %{}, ctx.fx.admin)
    run = G.run!(ctx.fx)
    fx = Map.merge(ctx.fx, %{grant: grant, run: run})
    invocation = F.reserve!(fx)
    disable_owner!(ctx, enrolled.owner)

    launch = F.claim!(ctx.token, F.nonce())
    assert launch.call_id == F.load(F.call_of(invocation.id)["id"])
  end
end
