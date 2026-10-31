defmodule SdrAgentWeb.WorkerController do
  @moduledoc """
  S-B4: the hosted Mac worker API (the S-B7 wire contract that
  `SdrAgent.MacAgent.Client` speaks). Bodies are JSON objects read by
  `SdrAgentWeb.WorkerIntake`; every decision is
  `SdrAgent.Agents.RemoteCalls`'.

  `authorization: Bearer <token>` carries the worker's 32-byte token,
  base64url without padding. A missing, undecodable or unknown token is 401;
  a disabled worker or a pin mismatch is 403 (the client treats both as
  terminal).

    * `POST /worker/heartbeat {pins}` → 200 `{"intake": "open" | "paused"}`.
    * `POST /worker/claim {claim_nonce, pins}` → 200 `{"call": launch}` (the
      exact `SdrAgent.Agents.RemoteLaunch.encode/1` bytes) or
      `{"call": null}` (no work, a nonce spent with no call or bound to
      another state, or a reversible hold: paused intake or no live hosted
      owner). An invalid nonce is 400; a refused launch check 503 (the
      claim rolled back; the same nonce may be retried); an undeliverable
      launch 500 (rolled back; never shown as no work).
    * `POST /worker/complete {call_id, claim_nonce, request_digest,
      transcript}` → 200 `{"status": "accepted" | "duplicate_same" | "late"
      | "conflict"}`; a transcript over 2097152 bytes 413; a posted call or
      digest that is not the nonce's call 409 `refused_mismatch`; a
      disabled worker 403; an unknown nonce 404; a non-string transcript
      400.

  Anything else is 500 with a fixed code. Responses carry fixed codes
  only: never a token, nonce, prompt, schema or transcript; refusals are
  logged by code only.
  """
  use SdrAgentWeb, :controller

  require Logger

  alias SdrAgent.Agents.RemoteCalls
  alias SdrAgent.Agents.RemoteLaunch

  @statuses [:accepted, :duplicate_same, :late, :conflict]

  def heartbeat(conn, params) do
    with {:ok, token} <- token(conn) do
      case RemoteCalls.heartbeat(token, params["pins"]) do
        {:ok, intake} when intake in [:open, :paused] -> reply(conn, 200, %{intake: intake})
        {:error, reason} -> refusal(conn, :heartbeat, reason)
        _other -> refusal(conn, :heartbeat, :unexpected)
      end
    end
  end

  def claim(conn, params) do
    with {:ok, token} <- token(conn) do
      case RemoteCalls.claim(token, params["claim_nonce"], params["pins"]) do
        {:ok, %{call_id: _} = launch} -> launch(conn, launch)
        {:ok, :none} -> reply(conn, 200, %{call: nil})
        {:ok, :none, _state} -> reply(conn, 200, %{call: nil})
        {:error, hold} when hold in [:intake_paused, :owner_unavailable] -> hold(conn, hold)
        {:error, reason} -> refusal(conn, :claim, reason)
        _other -> refusal(conn, :claim, :unexpected)
      end
    end
  end

  def complete(conn, params) do
    with {:ok, token} <- token(conn) do
      case RemoteCalls.complete(
             token,
             params["claim_nonce"],
             params["call_id"],
             digest(params["request_digest"]),
             params["transcript"]
           ) do
        {:ok, kind} when kind in @statuses -> reply(conn, 200, %{status: kind})
        {:error, reason} -> refusal(conn, :complete, reason)
        _other -> refusal(conn, :complete, :unexpected)
      end
    end
  end

  # The exact encoder bytes; the domain already refused an undeliverable one.
  defp launch(conn, launch) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, RemoteLaunch.encode(launch))
  end

  # A reversible hold on CLAIM only (plan r2 Q-C1): no work, no write.
  defp hold(conn, reason) do
    Logger.info("worker claim held: #{reason}")
    reply(conn, 200, %{call: nil})
  end

  defp refusal(conn, endpoint, reason) do
    {status, code} = wire(reason)
    Logger.info("worker #{endpoint} refused: #{code}")
    reply(conn, status, %{error: code})
  end

  defp wire(:unauthorized), do: {401, "unauthorized"}
  defp wire(:pins_mismatch), do: {403, "pins_mismatch"}
  defp wire(:worker_disabled), do: {403, "worker_disabled"}
  defp wire(:refused_disabled), do: {403, "worker_disabled"}
  defp wire(:refused_mismatch), do: {409, "refused_mismatch"}
  defp wire(:payload_too_large), do: {413, "payload_too_large"}
  defp wire(:unknown_nonce), do: {404, "unknown_nonce"}
  defp wire(:invalid_nonce), do: {400, "invalid_nonce"}
  defp wire(:invalid_transcript), do: {400, "invalid_transcript"}
  defp wire({:launch_refused, _reason}), do: {503, "launch_refused"}
  defp wire(:launch_undeliverable), do: {500, "launch_undeliverable"}
  defp wire(_unexpected), do: {500, "internal"}

  # The bearer token: base64url without padding of exactly 32 bytes.
  defp token(conn) do
    with ["Bearer " <> encoded] <- get_req_header(conn, "authorization"),
         {:ok, <<_::binary-size(32)>> = token} <- Base.url_decode64(encoded, padding: false) do
      {:ok, token}
    else
      _missing_or_invalid -> reply(conn, 401, %{error: "unauthorized"})
    end
  end

  # The wire digest is lowercase hex; the domain compares raw bytes. Anything
  # else is passed on unchanged, so the domain refuses it as a mismatch.
  defp digest(hex) when is_binary(hex) and byte_size(hex) == 64 do
    case Base.decode16(hex, case: :lower) do
      {:ok, raw} -> raw
      :error -> hex
    end
  end

  defp digest(other), do: other

  defp reply(conn, status, body), do: conn |> put_status(status) |> json(body)
end
