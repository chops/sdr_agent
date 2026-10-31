defmodule SdrAgent.Agents.RemoteLaunchBoundTest do
  @moduledoc """
  S-B4 RED (reservation addendum 037a03d2, Codex PASS 77dcda1e, choice (a)):
  a claim never emits, and never commits, an undeliverable launch.

  A legacy call (stored before the tightened reservation invariant) whose
  stored request encodes to a `{"call": launch}` response over 1048576
  bytes is planted by a narrow, test-only SQL fixture. It inserts one
  honest content-addressed Payload (the true SHA-256 of the oversized
  body) and repoints the call's and invocation's `request_sha256` at it,
  with triggers suppressed for that one transaction. No production path
  is bypassed.

  - A fresh claim of that call returns `{:error, :launch_undeliverable}`.
    Everything rolls back, audit included: the call stays pending, the
    invocation reserved, no nonce row, and no audit event at all (no
    `remote_call.claimed`, no payload-view access record).
  - A replay of a nonce already bound to a claimed call whose stored request
    became undeliverable returns `{:error, :launch_undeliverable}` and
    changes nothing (call row, nonce rows, audit count). The W2 lock and
    fresh-owner order is unchanged (covered by RemoteClaimOwnerTest).
  - Control: the same world with a deliverable request claims normally.

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

  # Test-only legacy plant: one honest Payload for `body`, then the call and
  # its invocation point at it. Triggers are suppressed for this one
  # transaction only.
  defp plant_request!(fx, invocation, body) do
    sha = :crypto.hash(:sha256, body)
    old = F.invocation(invocation.id).request_sha256
    tenant = F.dump(fx.tenant.id)

    {:ok, _} =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL session_replication_role = replica")

        %{num_rows: 1} =
          Repo.query!(
            ~s[INSERT INTO "payloads" (sha256, tenant_id, byte_size, content_type, content, trace_id, span_id, inserted_at) ] <>
              ~s[SELECT $1, tenant_id, $2, content_type, $3, trace_id, span_id, inserted_at FROM "payloads" ] <>
              ~s[WHERE tenant_id = $4 AND sha256 = $5],
            [sha, byte_size(body), body, tenant, old]
          )

        %{num_rows: 1} =
          Repo.query!(~s[UPDATE "model_invocations" SET request_sha256 = $1 WHERE id = $2], [
            sha,
            F.dump(invocation.id)
          ])

        %{num_rows: 1} =
          Repo.query!(
            ~s[UPDATE "remote_model_calls" SET request_sha256 = $1 WHERE model_invocation_id = $2],
            [sha, F.dump(invocation.id)]
          )

        Repo.query!("SET LOCAL session_replication_role = origin")
      end)

    sha
  end

  defp nonces(ctx), do: F.count(F.nonce_resource(), "worker_id = $1", [F.dump(ctx.worker.id)])

  test "control: a deliverable call claims normally", ctx do
    invocation = F.reserve!(ctx.fx)
    launch = F.claim!(ctx.token, F.nonce())
    assert launch.call_id == F.load(F.call_of(invocation.id)["id"])
  end

  test "a fresh claim of an undeliverable legacy call rolls back everything", ctx do
    invocation = F.reserve!(ctx.fx)
    _sha = plant_request!(ctx.fx, invocation, oversized_body())
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

  test "a replay whose stored request became undeliverable changes nothing", ctx do
    invocation = F.reserve!(ctx.fx)
    nonce = F.nonce()
    launch = F.claim!(ctx.token, nonce)
    _sha = plant_request!(ctx.fx, invocation, oversized_body())
    before = F.call_row(launch.call_id)
    events = F.event_count(ctx.fx)

    result = F.claim(ctx.token, nonce)
    assert result == {:error, :launch_undeliverable}, "replay: #{inspect(result, limit: 5)}"
    assert F.call_row(launch.call_id) == before
    assert nonces(ctx) == 1
    assert F.event_count(ctx.fx) == events, "an audit row survived the refused replay"
  end
end
