defmodule SdrAgent.Outreach.WebhookSignatureTest do
  @moduledoc """
  S9 webhook signature verification (checklist 4.3, S2 WebhookEvent):
  HMAC-SHA256 over "<timestamp>.<raw body>" with a 300 s tolerance, the key
  named by its id. Keys are built at runtime; no secret is a literal.
  """
  use ExUnit.Case, async: false

  alias SdrAgent.Outreach.Webhooks.Signature

  @now ~U[2026-01-06 15:00:00Z]

  setup do
    previous = Application.fetch_env(:sdr_agent, :webhook_hmac)
    key = :crypto.strong_rand_bytes(32)
    Application.put_env(:sdr_agent, :webhook_hmac, key_id: "test-1", source: {:static, key})

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:sdr_agent, :webhook_hmac, value)
        :error -> Application.delete_env(:sdr_agent, :webhook_hmac)
      end
    end)

    %{key: key, body: ~s({"id":"evt_1","data":{"text":"hello"}})}
  end

  defp headers(key, ts, body, key_id \\ "test-1") do
    %{
      "x-sdr-key-id" => key_id,
      "x-sdr-timestamp" => Integer.to_string(ts),
      "x-sdr-signature" => Signature.sign(key, ts, body)
    }
  end

  test "a correct signature within the tolerance is valid", %{key: key, body: body} do
    ts = DateTime.to_unix(@now) - 299

    assert {:valid, %{key_id: "webhook_hmac:test-1", signed_at: signed_at}} =
             Signature.verify(headers(key, ts, body), body, @now)

    assert DateTime.to_unix(signed_at) == ts
    assert "v1=" <> hex = Signature.sign(key, ts, body)
    assert byte_size(hex) == 64
  end

  test "a changed body, another key or an unknown key id is invalid", %{key: key, body: body} do
    ts = DateTime.to_unix(@now)

    assert {:invalid, _} = Signature.verify(headers(key, ts, body), body <> " ", @now)

    assert {:invalid, _} =
             Signature.verify(headers(:crypto.strong_rand_bytes(32), ts, body), body, @now)

    assert {:invalid, %{key_id: "webhook_hmac:other"}} =
             Signature.verify(headers(key, ts, body, "other"), body, @now)

    assert {:invalid, _} =
             Signature.verify(
               Map.put(headers(key, ts, body), "x-sdr-signature", "v1=zz"),
               body,
               @now
             )
  end

  test "a missing signature or timestamp is missing", %{key: key, body: body} do
    ts = DateTime.to_unix(@now)
    assert {:missing, _} = Signature.verify(%{}, body, @now)

    assert {:missing, _} =
             Signature.verify(Map.delete(headers(key, ts, body), "x-sdr-timestamp"), body, @now)

    assert {:missing, _} =
             Signature.verify(Map.delete(headers(key, ts, body), "x-sdr-signature"), body, @now)
  end

  test "a timestamp outside 300 s either way is stale, even when correctly signed",
       %{key: key, body: body} do
    old = DateTime.to_unix(@now) - 301
    future = DateTime.to_unix(@now) + 301
    assert {:stale, _} = Signature.verify(headers(key, old, body), body, @now)
    assert {:stale, _} = Signature.verify(headers(key, future, body), body, @now)
  end

  test "with no key configured every event is invalid", %{key: key, body: body} do
    Application.put_env(:sdr_agent, :webhook_hmac,
      key_id: "test-1",
      source: {:env, "SDR_S9_UNSET"}
    )

    ts = DateTime.to_unix(@now)
    assert {:invalid, _} = Signature.verify(headers(key, ts, body), body, @now)
  end

  test "the derived dev/test key comes from the endpoint secret, not a literal" do
    Application.put_env(:sdr_agent, :webhook_hmac, key_id: "derived-1", source: :derived)
    assert {"derived-1", key} = Signature.current_key!()
    assert byte_size(key) == 32

    base = Application.get_env(:sdr_agent, SdrAgentWeb.Endpoint)[:secret_key_base]
    assert key == :crypto.mac(:hmac, :sha256, base, "sdr-webhook-key/1")
  end
end
