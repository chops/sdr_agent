defmodule SdrAgent.Agents.RemoteLedgerTest do
  @moduledoc """
  S-B2 RED item 4 (entity/plan r2 6f0de674 AuditEvent row; Codex PASS
  ed0835d1): every remote-call create, transition and receipt, every stored
  result and every MacWorker owner action appends exactly one AuditEvent
  through the unchanged `SdrAgent.Audit.Changes.AppendEvent`, category
  `:domain_change`, whose subject is the stored row:

  - `remote_call.created`, `remote_call.claimed`, `remote_call.completed`,
    `remote_call.expired_unknown` (subject: the RemoteModelCall);
  - `remote_call.receipt_appended` (subject: each RemoteCallReceipt);
  - `remote_call.result_stored` (subject resource: RemoteCallResult);
  - `mac_worker.enrolled`, `mac_worker.disabled`, `mac_worker.intake_set`
    (subject: the MacWorker).

  Counts are by event_type and subject, never all tenant events. No
  AuditEvent payload of the tenant carries the transcript bytes, the token
  (raw, hex, base64 or its sha256) or the prompt text (synthetic marker
  byte-search).
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Clock
  alias SdrAgent.RemoteCallFixtures, as: F

  setup do
    fx = F.world!()
    F.remote!()
    %{fx: fx}
  end

  defp one!(fx, type, subject_id) do
    assert F.subject_count(fx, type, subject_id) == 1,
           "expected exactly one #{type} for #{subject_id}, got " <>
             "#{F.subject_count(fx, type, subject_id)}"
  end

  defp category(fx, type) do
    %{rows: rows} =
      Repo.query!(
        "SELECT DISTINCT category::text FROM audit_events WHERE tenant_id = $1 AND event_type = $2",
        [F.dump(fx.tenant.id), type]
      )

    List.flatten(rows)
  end

  defp result_events(fx) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM audit_events WHERE tenant_id = $1 AND event_type = $2 " <>
          "AND subject_resource = $3",
        [F.dump(fx.tenant.id), "remote_call.result_stored", inspect(F.result_resource())]
      )

    n
  end

  # One completed call (accepted, duplicate_same, conflict) and one call that
  # expired unknown (late), plus the worker's owner actions.
  defp lifecycle!(fx) do
    %{worker: worker, token: token} = F.enrol!(fx)
    t0 = F.instant()
    Clock.freeze(t0)
    first = F.reserve!(fx)
    second = F.reserve!(fx)
    n1 = F.nonce()
    l1 = F.claim!(token, n1)
    bytes = F.transcript("ledger")
    assert F.kind(F.complete(token, n1, l1.call_id, l1.request_sha256, bytes)) == :accepted
    assert F.kind(F.complete(token, n1, l1.call_id, l1.request_sha256, bytes)) == :duplicate_same

    assert F.kind(F.complete(token, n1, l1.call_id, l1.request_sha256, F.transcript("other"))) ==
             :conflict

    n2 = F.nonce()
    l2 = F.claim!(token, n2)
    Clock.freeze(DateTime.add(t0, 600, :second))
    assert F.kind(F.complete(token, n2, l2.call_id, l2.request_sha256, F.transcript())) == :late

    F.set_intake!(fx, worker, :paused)
    F.disable!(fx, worker)

    %{worker: worker, token: token, first: first, second: second, l1: l1, l2: l2}
  end

  test "every create, transition, receipt, result and worker action has exactly one event",
       %{fx: fx} do
    life = lifecycle!(fx)

    for launch <- [life.l1, life.l2] do
      one!(fx, "remote_call.created", launch.call_id)
      one!(fx, "remote_call.claimed", launch.call_id)
    end

    one!(fx, "remote_call.completed", life.l1.call_id)
    assert F.subject_count(fx, "remote_call.expired_unknown", life.l1.call_id) == 0
    one!(fx, "remote_call.expired_unknown", life.l2.call_id)
    assert F.subject_count(fx, "remote_call.completed", life.l2.call_id) == 0

    receipts = F.receipts(life.l1.call_id) ++ F.receipts(life.l2.call_id)
    assert length(receipts) == 4
    Enum.each(receipts, &one!(fx, "remote_call.receipt_appended", F.load(&1["id"])))

    assert result_events(fx) == 1, "expected one remote_call.result_stored (one stored result)"

    one!(fx, "mac_worker.enrolled", life.worker.id)
    one!(fx, "mac_worker.intake_set", life.worker.id)
    one!(fx, "mac_worker.disabled", life.worker.id)

    for type <- [
          "remote_call.created",
          "remote_call.claimed",
          "remote_call.completed",
          "remote_call.expired_unknown",
          "remote_call.receipt_appended",
          "remote_call.result_stored",
          "mac_worker.enrolled",
          "mac_worker.intake_set",
          "mac_worker.disabled"
        ] do
      assert category(fx, type) == ["domain_change"], "#{type} category"
    end
  end

  test "no event payload carries transcript bytes, the token or the prompt text", %{fx: fx} do
    life = lifecycle!(fx)
    texts = Enum.join(F.payload_texts(fx), "\n")
    token = life.token

    needles = [
      {"transcript marker", F.transcript_marker()},
      {"prompt marker", F.prompt_marker()},
      {"token hex", F.hex(token)},
      {"token base64", Base.encode64(token)},
      {"token url base64", Base.url_encode64(token, padding: false)},
      {"token sha256 hex", F.hex(:crypto.hash(:sha256, token))},
      {"token sha256 base64", Base.encode64(:crypto.hash(:sha256, token))}
    ]

    for {label, needle} <- needles do
      refute String.contains?(texts, needle), "an AuditEvent payload carries the #{label}"
    end
  end
end
