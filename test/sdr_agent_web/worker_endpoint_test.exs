defmodule SdrAgentWeb.WorkerEndpointTest do
  @moduledoc """
  S-B4 RED (plan r1 4f2863c8 section C, r2 ca6ba97d M4/M5; Codex reviews
  c506097c and 27883f4d): the hosted worker API through the real
  `SdrAgentWeb.Endpoint`, matching the S-B7 wire contract that
  `SdrAgent.MacAgent.Client` speaks.

  - `POST /worker/heartbeat {pins}` → 200 `{"intake": "open" | "paused"}`.
  - `POST /worker/claim {claim_nonce, pins}` → 200 `{"call": null | launch}`.
    The launch has exactly seven keys: `call_id`, `profile_id`, `model_id`,
    `request_digest` (lowercase hex of the stored request SHA-256),
    `prompt`, `schema` and `result_deadline` (ISO 8601). A paused intake or
    an unavailable hosted owner on CLAIM is 200 `{"call": null}` (a
    reversible hold), with no write.
  - `POST /worker/complete {call_id, claim_nonce, request_digest,
    transcript}` → 200 `{"status": "accepted" | "duplicate_same" | "late" |
    "conflict"}`.
  - `authorization: Bearer <base64url token>`. Missing or invalid → 401.
    Disabled worker or pin mismatch → 403. These are closed refusals with
    no write.
  - `SdrAgentWeb.WorkerIntake` runs before `Plug.Parsers`. It accepts a
    JSON object only: arrays, scalars and malformed JSON → 400, a non-JSON
    content type → 415, a body over 13 MiB → 413. None of them writes. A
    raw transcript over 2097152 bytes → 413. Other paths keep the global
    parser.
  - No bearer token, prompt, schema, transcript or nonce reaches the logs,
    on success or refusal, with Logger at debug.

  Synthetic fixtures only; no model, CLI or network.
  """
  use SdrAgent.PrototypeCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Plug.Conn

  alias SdrAgent.RemoteCallFixtures, as: F

  @endpoint SdrAgentWeb.Endpoint
  @launch_keys ~w(call_id model_id profile_id prompt request_digest result_deadline schema)

  setup do
    fx = F.world!()
    F.remote!()
    %{token: token, worker: worker} = F.enrol!(fx)
    %{fx: fx, token: token, worker: worker, bearer: bearer(token)}
  end

  ## Helpers

  defp bearer(token), do: Base.url_encode64(token, padding: false)

  defp pins_body(extra \\ %{}), do: Map.merge(%{"pins" => F.pins()}, extra)

  # Posts through the whole endpoint. A raised error (for example, no route
  # yet) is returned as {:raised, exception}, never crashing the test.
  defp post_raw(path, body, opts) do
    conn =
      build_conn()
      |> put_req_header("content-type", Keyword.get(opts, :type, "application/json"))

    conn =
      case Keyword.get(opts, :bearer) do
        nil -> conn
        false -> conn
        value -> put_req_header(conn, "authorization", "Bearer " <> value)
      end

    try do
      post(conn, path, body)
    rescue
      error -> {:raised, error}
    end
  end

  defp post_json(ctx, path, body, opts \\ []),
    do: post_raw(path, Jason.encode!(body), Keyword.put_new(opts, :bearer, ctx.bearer))

  defp status_of({:raised, error}), do: {:raised, error.__struct__}
  defp status_of(conn), do: conn.status

  defp body_of({:raised, error}), do: {:raised, Exception.message(error)}

  defp body_of(conn) do
    case Jason.decode(conn.resp_body) do
      {:ok, body} -> body
      _ -> {:undecodable, conn.resp_body}
    end
  end

  defp assert_json!(result, status) do
    assert status_of(result) == status,
           "expected #{status}, got #{inspect(status_of(result))}: #{inspect(body_of(result))}"

    body_of(result)
  end

  defp pending!(ctx) do
    invocation = F.reserve!(ctx.fx)
    assert %{"state" => "pending"} = F.call_of(invocation.id)
    invocation
  end

  defp no_claim_writes!(ctx, invocation) do
    call = F.call_of(invocation.id)
    assert call["state"] == "pending", "the call left pending: #{inspect(call["state"])}"
    assert F.invocation(invocation.id).status == :reserved
    assert F.count(F.nonce_resource(), "worker_id = $1", [F.dump(ctx.worker.id)]) == 0
  end

  defp claim_launch!(ctx, nonce) do
    body =
      assert_json!(post_json(ctx, "/worker/claim", pins_body(%{"claim_nonce" => nonce})), 200)

    assert %{"call" => %{} = launch} = body, "claim returned no launch: #{inspect(body)}"
    launch
  end

  defp complete_body(launch, nonce, transcript),
    do: %{
      "call_id" => launch["call_id"],
      "claim_nonce" => nonce,
      "request_digest" => launch["request_digest"],
      "transcript" => transcript
    }

  ## Heartbeat

  describe "heartbeat" do
    test "an active worker with its pins: 200 intake open, then paused", ctx do
      assert assert_json!(post_json(ctx, "/worker/heartbeat", pins_body()), 200) ==
               %{"intake" => "open"}

      F.set_intake!(ctx.fx, ctx.worker, :paused)

      assert assert_json!(post_json(ctx, "/worker/heartbeat", pins_body()), 200) ==
               %{"intake" => "paused"}
    end

    test "a missing or invalid bearer: 401", ctx do
      assert status_of(post_json(ctx, "/worker/heartbeat", pins_body(), bearer: false)) == 401
      assert status_of(post_raw("/worker/heartbeat", Jason.encode!(pins_body()), [])) == 401

      garbage = bearer(:crypto.strong_rand_bytes(32))
      assert status_of(post_json(ctx, "/worker/heartbeat", pins_body(), bearer: garbage)) == 401

      assert status_of(post_json(ctx, "/worker/heartbeat", pins_body(), bearer: "not base64!")) ==
               401
    end

    test "a pin mismatch or a disabled worker: 403", ctx do
      wrong = Map.put(F.pins(), "cli_version", "0.0.0-wrong")
      assert status_of(post_json(ctx, "/worker/heartbeat", %{"pins" => wrong})) == 403

      F.disable!(ctx.fx, ctx.worker)
      assert status_of(post_json(ctx, "/worker/heartbeat", pins_body())) == 403
    end
  end

  ## Claim

  describe "claim" do
    test "a pending call: 200 with exactly the seven-key launch", ctx do
      invocation = pending!(ctx)
      launch = claim_launch!(ctx, F.nonce())

      assert launch |> Map.keys() |> Enum.sort() == @launch_keys
      call = F.call_of(invocation.id)
      assert launch["call_id"] == F.load(call["id"])
      assert launch["prompt"] =~ F.prompt_marker()
      assert launch["schema"] == F.schema()
      assert launch["profile_id"] == F.pins()["profile_id"]
      assert launch["model_id"] == F.pins()["model_id"]

      digest = Base.encode16(F.invocation(invocation.id).request_sha256, case: :lower)
      assert launch["request_digest"] == digest
      assert launch["request_digest"] =~ ~r/\A[0-9a-f]{64}\z/

      assert {:ok, at, 0} = DateTime.from_iso8601(launch["result_deadline"])
      assert DateTime.compare(at, F.ts(F.call_row(launch["call_id"])["result_deadline"])) == :eq
    end

    test "no pending call: 200 call null; a replayed nonce returns the same launch", ctx do
      assert assert_json!(
               post_json(ctx, "/worker/claim", pins_body(%{"claim_nonce" => F.nonce()})),
               200
             ) == %{"call" => nil}

      _invocation = pending!(ctx)
      nonce = F.nonce()
      launch = claim_launch!(ctx, nonce)
      assert claim_launch!(ctx, nonce) == launch
    end

    test "paused intake on claim: 200 call null and no write", ctx do
      invocation = pending!(ctx)
      F.set_intake!(ctx.fx, ctx.worker, :paused)

      assert assert_json!(
               post_json(ctx, "/worker/claim", pins_body(%{"claim_nonce" => F.nonce()})),
               200
             ) == %{"call" => nil}

      no_claim_writes!(ctx, invocation)
    end

    test "a disabled worker, a pin mismatch or a bad token on claim: closed, no write", ctx do
      invocation = pending!(ctx)
      wrong = Map.put(F.pins(), "model_id", "other-model")

      assert status_of(
               post_json(ctx, "/worker/claim", %{"claim_nonce" => F.nonce(), "pins" => wrong})
             ) == 403

      garbage = bearer(:crypto.strong_rand_bytes(32))

      assert status_of(
               post_json(ctx, "/worker/claim", pins_body(%{"claim_nonce" => F.nonce()}),
                 bearer: garbage
               )
             ) == 401

      F.disable!(ctx.fx, ctx.worker)

      assert status_of(post_json(ctx, "/worker/claim", pins_body(%{"claim_nonce" => F.nonce()}))) ==
               403

      no_claim_writes!(ctx, invocation)
    end
  end

  ## Complete

  describe "complete" do
    test "accepted, then duplicate_same; a different transcript is conflict", ctx do
      _invocation = pending!(ctx)
      nonce = F.nonce()
      launch = claim_launch!(ctx, nonce)

      body = complete_body(launch, nonce, F.transcript("a"))

      assert assert_json!(post_json(ctx, "/worker/complete", body), 200) == %{
               "status" => "accepted"
             }

      assert F.call_row(launch["call_id"])["state"] == "completed"

      assert assert_json!(post_json(ctx, "/worker/complete", body), 200) ==
               %{"status" => "duplicate_same"}

      other = complete_body(launch, nonce, F.transcript("b"))

      assert assert_json!(post_json(ctx, "/worker/complete", other), 200) == %{
               "status" => "conflict"
             }
    end

    test "after the result deadline: 200 late", ctx do
      _invocation = pending!(ctx)
      nonce = F.nonce()
      launch = claim_launch!(ctx, nonce)
      {:ok, deadline, 0} = DateTime.from_iso8601(launch["result_deadline"])
      SdrAgent.Clock.freeze(deadline)

      body = complete_body(launch, nonce, F.transcript())
      assert assert_json!(post_json(ctx, "/worker/complete", body), 200) == %{"status" => "late"}
    end

    test "a raw transcript over 2097152 bytes: 413 and no result", ctx do
      _invocation = pending!(ctx)
      nonce = F.nonce()
      launch = claim_launch!(ctx, nonce)

      body = complete_body(launch, nonce, String.duplicate("a", 2_097_153))
      assert status_of(post_json(ctx, "/worker/complete", body)) == 413
      assert F.call_row(launch["call_id"])["state"] == "claimed"
      assert F.count(F.result_resource()) == 0
    end
  end

  ## Intake (before Plug.Parsers)

  describe "WorkerIntake" do
    test "an array, a scalar or malformed JSON: 400 and no write", ctx do
      invocation = pending!(ctx)

      for raw <- ["[1,2]", "\"text\"", "42", "{not json", ""] do
        result = post_raw("/worker/claim", raw, bearer: ctx.bearer)
        assert status_of(result) == 400, "#{inspect(raw)}: #{inspect(status_of(result))}"
      end

      no_claim_writes!(ctx, invocation)
    end

    test "a non-JSON content type: 415", ctx do
      result =
        post_raw("/worker/heartbeat", Jason.encode!(pins_body()),
          bearer: ctx.bearer,
          type: "application/x-www-form-urlencoded"
        )

      assert status_of(result) == 415
    end

    test "a body over 13 MiB is refused 413 before parsing, no write", ctx do
      invocation = pending!(ctx)
      raw = ~s({"claim_nonce":"x","pad":") <> String.duplicate("a", 13 * 1_048_576) <> ~s("})
      assert status_of(post_raw("/worker/claim", raw, bearer: ctx.bearer)) == 413
      no_claim_writes!(ctx, invocation)
    end

    test "a 2 MiB transcript of escaped bytes is within the intake bound", ctx do
      _invocation = pending!(ctx)
      nonce = F.nonce()
      launch = claim_launch!(ctx, nonce)

      # Each 0x01 byte is six bytes on the wire (\u0001).
      transcript = String.duplicate(<<1>>, 2_097_152)
      body = complete_body(launch, nonce, transcript)
      assert byte_size(Jason.encode!(body)) > 12 * 1_048_576
      result = post_json(ctx, "/worker/complete", body)
      refute status_of(result) == 413, "the worst-case escaped 2 MiB transcript was refused 413"
    end

    test "control: the global parser is unchanged for other paths", _ctx do
      result = post_raw("/webhooks/capture_sim/reply", String.duplicate("a", 70_000), [])
      assert status_of(result) == 413
    end
  end

  ## Logging

  describe "logs" do
    @tag capture_log: true
    test "no bearer, prompt, schema, transcript or nonce in debug logs", ctx do
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      _invocation = pending!(ctx)
      nonce = F.nonce()
      private = "private-oversize-#{System.unique_integer([:positive])}"

      oversized =
        ~s({"claim_nonce":"#{private}","pad":"#{private}) <>
          String.duplicate("a", 13 * 1_048_576) <> ~s("})

      log =
        capture_log([level: :debug], fn ->
          launch = claim_launch!(ctx, nonce)
          _ = post_json(ctx, "/worker/complete", complete_body(launch, nonce, F.transcript()))
          _ = post_json(ctx, "/worker/heartbeat", pins_body())
          _ = post_raw("/worker/claim", "{not json " <> nonce, bearer: ctx.bearer)
          _ = post_json(ctx, "/worker/claim", pins_body(%{"claim_nonce" => nonce}), bearer: "bad")
          # Codex 13795d74 item 5: an oversized body with a valid bearer must
          # not leak through Endpoint exception logging.
          _ = post_raw("/worker/claim", oversized, bearer: ctx.bearer)
        end)

      assert log =~ "/worker/", "control: the requests were logged at all"

      for {label, marker} <- [
            bearer: ctx.bearer,
            prompt: F.prompt_marker(),
            transcript: F.transcript_marker(),
            nonce: nonce,
            oversized_body: private
          ] do
        refute log =~ marker, "#{label} reached the logs"
      end

      refute log =~ ~s("qualified"), "the schema reached the logs"
    end
  end
end

defmodule SdrAgentWeb.WorkerEndpointPrototypeTest do
  @moduledoc """
  S-B4 RED (Codex 27883f4d Q-C1): in prototype runtime, a claim refused
  for an unavailable hosted owner (W2 `{:error, :owner_unavailable}`) is a
  reversible hold. Through the real endpoint it is 200 `{"call": null}`,
  never 401/403, and it writes nothing. Synthetic fixtures only.
  """
  use SdrAgent.PrototypeCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias SdrAgent.Actor
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.HostedOwnerFixtures, as: H
  alias SdrAgent.PrototypeGateFixtures, as: G
  alias SdrAgent.RemoteCallFixtures, as: F

  @endpoint SdrAgentWeb.Endpoint

  setup do
    ctx = H.activated!()
    admin = human(:admin, ctx.fx.tenant)
    :ok = AgentsFixtures.ensure_offering!(ctx.fx.tenant)
    definition = AgentsFixtures.definition!(ctx.fx.tenant)
    agent = Actor.system(:agent_runtime, ctx.fx.tenant.id)
    fx = Map.merge(ctx.fx, %{admin: admin, definition: definition, agent: agent})
    F.remote!()
    %{token: token, worker: worker} = F.enrol!(fx)
    H.enter!(ctx)
    grant = G.provision!(fx)
    run = G.run!(fx)
    fx = Map.merge(fx, %{grant: grant, run: run})
    Map.merge(ctx, %{fx: fx, token: token, worker: worker})
  end

  defp claim(ctx, nonce) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header(
        "authorization",
        "Bearer " <> Base.url_encode64(ctx.token, padding: false)
      )

    try do
      post(conn, "/worker/claim", Jason.encode!(%{"claim_nonce" => nonce, "pins" => F.pins()}))
    rescue
      error -> {:raised, error.__struct__}
    end
  end

  test "no live hosted owner: claim is 200 call null with no write", ctx do
    invocation = F.reserve!(ctx.fx)
    result = claim(ctx, F.nonce())

    assert match?(%Plug.Conn{status: 200}, result), "expected 200, got #{inspect(result)}"
    assert Jason.decode!(result.resp_body) == %{"call" => nil}

    call = F.call_of(invocation.id)
    assert call["state"] == "pending"
    assert F.invocation(invocation.id).status == :reserved
    assert F.count(F.nonce_resource(), "worker_id = $1", [F.dump(ctx.worker.id)]) == 0
  end
end
