defmodule SdrAgent.Agents.RemoteLaunchBoundTest do
  @moduledoc """
  S-B4 RED (reservation addendum 037a03d2, Codex PASS 77dcda1e, choice (a)):
  a claim never emits, and never commits, an undeliverable launch.

  A legacy call (stored before the tightened reservation invariant) whose
  stored request encodes to a `{"call": launch}` response over 1048576
  bytes is planted honestly. The oversized request is reserved through
  the domain under the `:local` transport (no remote caps), which stores
  its true content-addressed Payload and invocation. A narrow, test-only
  SQL fixture then INSERTs the RemoteModelCall row such a reservation had
  before the invariant (and, for the replay case, the claimed call and its
  spent nonce). INSERT only: no UPDATE, no DELETE, no trigger or role
  change; every database protection stays on.

  - A fresh claim of that call returns `{:error, :launch_undeliverable}`.
    Everything rolls back, audit included: the call stays pending, the
    invocation reserved, no nonce row, and no audit event at all (no
    `remote_call.claimed`, no payload-view access record).
  - A replay of a nonce already bound to a claimed call whose stored request
    is undeliverable returns `{:error, :launch_undeliverable}` and
    changes nothing (call row, nonce rows, audit count). The W2 lock and
    fresh-owner order is unchanged (covered by RemoteClaimOwnerTest).
  - Controls: a deliverable reservation, and the same legacy plant of a
    deliverable request, claim normally.

  Synthetic fixtures only; no model, CLI or network.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.RemoteCallFixtures, as: F

  setup do
    fx = F.world!()
    F.remote!()
    %{token: token, worker: worker} = F.enrol!(fx)
    %{fx: fx, token: token, worker: worker}
  end

  # The undeliverable body: 262144 escaping bytes (each is \u0001 on the wire).
  defp oversized_body, do: F.request(String.duplicate(<<1>>, 262_144))

  # The honest reservation of `body` under the :local transport (no remote
  # caps): its Payload and invocation are written by the domain.
  defp local_reservation!(fx, body) do
    F.remote!(:local)
    invocation = F.reserve!(fx, %{request: body})
    F.remote!(:remote)
    assert F.call_of(invocation.id) == nil, "prerequisite: a :local reservation has no call"
    invocation
  end

  # Test-only legacy plant, INSERT only (no UPDATE, no DELETE, no trigger or
  # role change). The call row copies the invocation's own tenant and stored
  # request_sha256, so it points at the honest Payload.
  @insert_call ~s[INSERT INTO "remote_model_calls" ] <>
                 ~s[(tenant_id, state, request_sha256, profile_id, model_id, claim_deadline, ] <>
                 ~s[claimed_at, result_deadline, worker_id, model_invocation_id) ] <>
                 ~s[SELECT tenant_id, $1, request_sha256, $2, $3, $4, $5, $6, $7, id ] <>
                 ~s[FROM "model_invocations" WHERE id = $8 RETURNING id]

  @insert_nonce ~s[INSERT INTO "claim_nonces" (tenant_id, claim_nonce, created_at, worker_id, call_id) ] <>
                  ~s[VALUES ($1, $2, $3, $4, $5)]

  defp legacy_pending!(invocation) do
    pins = F.pins()
    now = SdrAgent.Clock.utc_now()

    %{num_rows: 1, rows: [[id]]} =
      Repo.query!(@insert_call, [
        "pending",
        pins["profile_id"],
        pins["model_id"],
        DateTime.add(now, 120, :second),
        nil,
        nil,
        nil,
        F.dump(invocation.id)
      ])

    F.load(id)
  end

  defp legacy_claimed!(ctx, invocation, nonce) do
    pins = F.pins()
    now = SdrAgent.Clock.utc_now()
    worker = F.dump(ctx.worker.id)

    %{num_rows: 1, rows: [[id]]} =
      Repo.query!(@insert_call, [
        "claimed",
        pins["profile_id"],
        pins["model_id"],
        DateTime.add(now, 120, :second),
        now,
        DateTime.add(now, 600, :second),
        worker,
        F.dump(invocation.id)
      ])

    %{num_rows: 1} =
      Repo.query!(@insert_nonce, [F.dump(ctx.fx.tenant.id), nonce, now, worker, id])

    F.load(id)
  end

  defp nonces(ctx), do: F.count(F.nonce_resource(), "worker_id = $1", [F.dump(ctx.worker.id)])

  test "control: a deliverable call claims normally", ctx do
    invocation = F.reserve!(ctx.fx)
    launch = F.claim!(ctx.token, F.nonce())
    assert launch.call_id == F.load(F.call_of(invocation.id)["id"])
  end

  test "control: the legacy plant of a deliverable request claims normally", ctx do
    invocation = local_reservation!(ctx.fx, F.request())
    call_id = legacy_pending!(invocation)
    launch = F.claim!(ctx.token, F.nonce())
    assert launch.call_id == call_id
  end

  test "a fresh claim of an undeliverable legacy call rolls back everything", ctx do
    invocation = local_reservation!(ctx.fx, oversized_body())
    _call_id = legacy_pending!(invocation)
    events = F.event_count(ctx.fx)

    result = F.claim(ctx.token, F.nonce())
    assert result == {:error, :launch_undeliverable}, "claim: #{inspect(result, limit: 5)}"
    refute inspect(result) =~ F.prompt_marker()

    call = F.call_of(invocation.id)
    assert call["state"] == "pending"
    assert call["worker_id"] == nil
    assert F.invocation(invocation.id).status == :reserved
    assert nonces(ctx) == 0
    assert F.event_count(ctx.fx) == events, "an audit row survived the refused claim"
  end

  test "a replay whose stored request is undeliverable changes nothing", ctx do
    invocation = local_reservation!(ctx.fx, oversized_body())
    nonce = F.nonce()
    call_id = legacy_claimed!(ctx, invocation, nonce)
    before = F.call_row(call_id)
    events = F.event_count(ctx.fx)

    result = F.claim(ctx.token, nonce)
    assert result == {:error, :launch_undeliverable}, "replay: #{inspect(result, limit: 5)}"
    refute inspect(result) =~ F.prompt_marker()
    assert F.call_row(call_id) == before
    assert nonces(ctx) == 1
    assert F.event_count(ctx.fx) == events, "an audit row survived the refused replay"
  end
end
