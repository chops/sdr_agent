defmodule SdrAgentWeb.WebhookControllerTest do
  @moduledoc """
  The simulated provider webhook endpoint (spec §16, checklist 4.3, S2
  WebhookEvent): every request's raw bytes are stored before anything else;
  only a valid signature is accepted and queued for processing; a forged,
  unsigned or stale request is stored as rejected with a
  `signature_invalid` Failure and answered 401; a duplicate valid event
  inserts nothing and queues nothing.
  """
  use SdrAgent.SDRCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn
  import SdrAgent.WebhookFixtures

  alias SdrAgent.Audit
  alias SdrAgent.Operations
  alias SdrAgent.Outreach.WebhookWorker

  @endpoint SdrAgentWeb.Endpoint

  defp body(id \\ "evt_ctl_1"),
    do: ~s({"id":"#{id}","type":"reply","data":{"text":"Sounds interesting."}})

  defp post_signed(body, opts \\ []) do
    headers = Keyword.get_lazy(opts, :headers, fn -> signed_headers(body) end)
    type = Keyword.get(opts, :type, "reply")

    headers
    |> Enum.reduce(build_conn(), fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> post("/webhooks/capture_sim/#{type}", body)
  end

  test "a valid event: raw bytes stored, WebhookEvent received, job queued, 202", ctx do
    raw = body()
    conn = post_signed(raw)
    assert json_response(conn, 202) == %{"status" => "accepted"}

    assert [event] = webhook_events!(ctx)

    assert {event.provider, event.event_type, event.external_event_id} ==
             {:capture_sim, :reply, "evt_ctl_1"}

    assert {event.signature_verdict, event.processing_status} == {:valid, :received}
    assert event.signature_key_id =~ "webhook_hmac:"
    assert event.signed_timestamp
    assert event.raw_body_sha256 == :crypto.hash(:sha256, raw)
    refute Map.has_key?(event.headers, "cookie")

    assert {:ok, ^raw} = Audit.read_content(event.raw_body_sha256, actor: ctx.admin)

    assert_enqueued(
      worker: WebhookWorker,
      queue: :integration,
      args: %{"webhook_event_id" => event.id, "tenant_id" => ctx.tenant.id}
    )

    assert [received] = events_of_type(ctx.tenant, "webhook.received")
    assert received.actor_type == :webhook_ingestor
    assert received.payload["changes"]["signature_verdict"] == "valid"
  end

  test "a forged signature: stored rejected with a signature_invalid Failure, 401, never queued",
       ctx do
    raw = body()
    forged = signed_headers(raw, key: :crypto.strong_rand_bytes(32))
    conn = post_signed(raw, headers: forged)
    assert json_response(conn, 401) == %{"error" => "signature_invalid"}

    assert [event] = webhook_events!(ctx)
    assert {event.signature_verdict, event.processing_status} == {:invalid, :rejected}
    assert event.raw_body_sha256 == :crypto.hash(:sha256, raw)
    refute_enqueued(worker: WebhookWorker)

    {:ok, failure} = Operations.get_failure(event.failure_id, actor: ctx.admin)
    assert {failure.class, failure.status} == {:signature_invalid, :open}
    assert failure.subject_id == event.id
  end

  test "unsigned and stale requests are rejected the same way", ctx do
    raw = body("evt_ctl_2")

    conn = post_signed(raw, headers: [{"content-type", "application/json"}])
    assert json_response(conn, 401)

    old = DateTime.to_unix(SdrAgent.Clock.utc_now()) - 600
    conn = post_signed(raw, headers: signed_headers(raw, timestamp: old))
    assert json_response(conn, 401)

    assert [:missing, :stale] = Enum.map(webhook_events!(ctx), & &1.signature_verdict)
    assert Enum.all?(webhook_events!(ctx), &(&1.processing_status == :rejected))
    refute_enqueued(worker: WebhookWorker)
  end

  test "a forged event cannot pre-claim a real event id", ctx do
    raw = body("evt_ctl_3")
    _ = post_signed(raw, headers: signed_headers(raw, key: :crypto.strong_rand_bytes(32)))
    conn = post_signed(raw)
    assert json_response(conn, 202)

    assert [:invalid, :valid] = Enum.map(webhook_events!(ctx), & &1.signature_verdict)
  end

  test "a duplicate valid event inserts no row and no job; it is recorded and acknowledged",
       ctx do
    raw = body("evt_ctl_4")
    assert json_response(post_signed(raw), 202)
    assert json_response(post_signed(raw), 200) == %{"status" => "duplicate"}

    assert [event] = webhook_events!(ctx)
    assert [_job] = all_enqueued(worker: WebhookWorker)
    assert [duplicate] = events_of_type(ctx.tenant, "webhook.duplicate_ignored")
    assert duplicate.subject_id == event.id
    assert [_] = events_of_type(ctx.tenant, "webhook.received")
  end

  test "a malformed JSON body is stored and rejected, never a parser crash", ctx do
    raw = ~s({"id":"evt_bad_json","type":"reply",)
    conn = post_signed(raw)
    assert json_response(conn, 401) == %{"error" => "signature_invalid"}

    assert [event] = webhook_events!(ctx)
    assert {event.signature_verdict, event.processing_status} == {:invalid, :rejected}
    assert event.raw_body_sha256 == :crypto.hash(:sha256, raw)
    refute_enqueued(worker: WebhookWorker)
  end

  test "a body over the intake limit is refused with 413 and nothing stored", ctx do
    raw =
      ~s({"id":"evt_big","type":"reply","data":{"text":") <>
        String.duplicate("a", 70_000) <> ~s("}})

    conn = post_signed(raw)
    assert conn.status == 413
    assert webhook_events!(ctx) == []
  end

  test "an unknown event type is not routed and stores nothing", ctx do
    raw = body("evt_ctl_5")
    conn = post_signed(raw, type: "refund")
    assert conn.status == 404
    assert webhook_events!(ctx) == []
  end
end
