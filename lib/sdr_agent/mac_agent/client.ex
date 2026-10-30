defmodule SdrAgent.MacAgent.Client do
  @moduledoc """
  Outbound HTTPS transport for the Mac worker's three fixed endpoints.

  Uses normal TLS verification. Redirects and automatic HTTP retries are
  disabled. Errors are closed atoms, never request/response structures that
  could expose a token, prompt or transcript. Only the server computes the
  result digest. Test plugs replace transport, not domain authorization.
  `deliver/5` alone retries an identical completion at application level,
  without opening a new claim or model process.
  """

  alias SdrAgent.MacAgent.Config

  @derive {Inspect, only: []}
  defstruct [:config, :options]
  @limit 1_048_576

  @doc "Build a redacted client. Only the Req test plug can be overridden."
  def new(%Config{} = config, options \\ []) do
    if Keyword.keys(options) -- [:plug] == [],
      do: {:ok, %__MODULE__{config: config, options: options}},
      else: {:error, :invalid_config}
  end

  @doc "Publish pins; paused intake holds new claims, not an already-running call."
  def heartbeat(client, mode \\ :intake) when mode in [:intake, :inflight] do
    case post(client, "/worker/heartbeat", %{"pins" => client.config.pins}) do
      {:ok, %{"intake" => "open"}} -> :ok
      {:ok, %{"intake" => "paused"}} when mode == :inflight -> :ok
      {:ok, %{"intake" => "paused"}} -> {:error, :worker_paused}
      {:ok, _} -> {:error, :invalid_response}
      error -> error
    end
  end

  @doc "Retrieve one claim; an empty or spent nonce response launches nothing."
  def claim(client, nonce) do
    case post(client, "/worker/claim", %{"claim_nonce" => nonce, "pins" => client.config.pins}) do
      {:ok, %{"call" => call}} when is_map(call) or is_nil(call) -> {:ok, call}
      {:ok, _} -> {:error, :invalid_response}
      {:error, :remote_unavailable} -> {:error, :remote_refused}
      error -> error
    end
  end

  @doc "Submit a bounded transcript once. Late/conflicting replies are terminal."
  def complete(client, call, nonce, transcript)
      when is_binary(transcript) and byte_size(transcript) <= 2_097_152 do
    complete_request(client, call, nonce, transcript, 15_000)
  end

  def complete(_, _, _, _), do: {:error, :transcript_too_large}

  @doc """
  Retry only uncertain result delivery, with the same nonce and in-memory
  transcript. Backoff is capped at 15 s and the wait at the call deadline
  (at most 600 s). Terminal replies never retry; no claim or child is opened.
  """
  def deliver(client, call, nonce, transcript, options \\ [])
      when is_binary(transcript) and byte_size(transcript) <= 2_097_152 do
    with {:ok, deadline, _} <- DateTime.from_iso8601(call["result_deadline"]),
         delay = Keyword.get(options, :retry_delay, 1_000),
         true <- is_integer(delay) and delay in 1..15_000 do
      wait = min(max(DateTime.diff(deadline, DateTime.utc_now(), :millisecond), 0), 600_000)
      until = System.monotonic_time(:millisecond) + wait
      deliver_loop(client, call, nonce, transcript, until, delay)
    else
      _ -> {:error, :invalid_call}
    end
  end

  defp deliver_loop(client, call, nonce, transcript, until, delay) do
    case remaining(until) do
      0 ->
        {:error, :result_delivery_expired}

      timeout ->
        case complete_request(client, call, nonce, transcript, timeout) do
          {:error, reason}
          when reason in [:transport_failed, :remote_unavailable, :invalid_response] ->
            retry_delivery(client, call, nonce, transcript, until, delay)

          result ->
            result
        end
    end
  end

  defp retry_delivery(client, call, nonce, transcript, until, delay) do
    Process.sleep(min(delay, remaining(until)))

    case remaining(until) do
      0 ->
        {:error, :result_delivery_expired}

      timeout ->
        resume_delivery(client, call, nonce, transcript, until, min(delay * 2, 15_000), timeout)
    end
  end

  defp resume_delivery(client, call, nonce, transcript, until, delay, timeout) do
    case post(client, "/worker/heartbeat", %{"pins" => client.config.pins}, timeout) do
      {:error, :unauthorized} = error -> error
      _ -> deliver_loop(client, call, nonce, transcript, until, delay)
    end
  end

  defp remaining(until), do: min(max(until - System.monotonic_time(:millisecond), 0), 15_000)

  defp complete_request(client, call, nonce, transcript, timeout) do
    payload = %{
      "call_id" => call["call_id"],
      "claim_nonce" => nonce,
      "request_digest" => call["request_digest"],
      "transcript" => transcript
    }

    case post(client, "/worker/complete", payload, timeout) do
      {:ok, %{"status" => "accepted"}} -> {:ok, :accepted}
      {:ok, %{"status" => "duplicate_same"}} -> {:ok, :duplicate_same}
      {:ok, %{"status" => "late"}} -> {:ok, :late}
      {:ok, %{"status" => "conflict"}} -> {:ok, :conflict}
      {:ok, _} -> {:error, :invalid_response}
      error -> error
    end
  end

  defp post(client, path, body, timeout \\ 15_000) do
    options = [
      method: :post,
      url: client.config.base_url <> path,
      headers: [{"authorization", "Bearer " <> client.config.token}],
      json: body,
      retry: false,
      retry_log_level: false,
      redirect: false,
      decode_body: false,
      receive_timeout: timeout,
      connect_options: [timeout: min(timeout, 10_000)],
      into: &bounded_body/2
    ]

    case Req.request(options ++ client.options) do
      {:ok, %{status: status}} when status in [401, 403] -> {:error, :unauthorized}
      {:ok, %{status: 413}} -> {:error, :payload_too_large}
      {:ok, %{status: status}} when status in 500..599 -> {:error, :remote_unavailable}
      {:ok, %{status: 200, body: bytes}} when is_binary(bytes) -> decode(bytes)
      {:ok, _} -> {:error, :remote_refused}
      {:error, _} -> {:error, :transport_failed}
    end
  rescue
    _ -> {:error, :transport_failed}
  end

  defp bounded_body({:data, data}, {req, resp}) do
    body = resp.body || ""

    if byte_size(body) + byte_size(data) <= @limit do
      {:cont, {req, %{resp | body: body <> data}}}
    else
      {:halt, {req, %{resp | body: :too_large}}}
    end
  end

  defp decode(bytes) do
    case Jason.decode(bytes) do
      {:ok, body} when is_map(body) -> {:ok, body}
      _ -> {:error, :invalid_response}
    end
  end
end
