defmodule SdrAgentWeb.WebhookController do
  @moduledoc """
  `POST /webhooks/capture_sim/:event_type` — the simulated provider webhook
  (spec §16). Hands the exact request bytes and headers to
  `SdrAgent.Outreach.Webhooks.ingest/3` and answers: 202 accepted (queued
  for processing), 200 duplicate (already received; nothing queued), 401
  for an invalid, missing or stale signature (stored as rejected, never
  processed), 404 for an unknown event type (nothing stored).
  """
  use SdrAgentWeb, :controller

  alias SdrAgent.Outreach.Webhooks

  def receive(conn, %{"event_type" => type}) do
    {raw, conn} = raw_body(conn)

    case Webhooks.ingest(type, raw, Map.new(conn.req_headers)) do
      {:ok, %{status: :accepted}} -> reply(conn, 202, %{status: "accepted"})
      {:ok, %{status: :duplicate}} -> reply(conn, 200, %{status: "duplicate"})
      {:ok, %{status: :rejected}} -> reply(conn, 401, %{error: "signature_invalid"})
      {:error, :unknown_event_type} -> reply(conn, 404, %{error: "unknown_event_type"})
      {:error, _error} -> reply(conn, 500, %{error: "not_recorded"})
    end
  end

  # The bytes cached by SdrAgentWeb.RawBodyReader, or (for a content type
  # Plug.Parsers passed through) the unread body.
  defp raw_body(%{private: %{sdr_raw_body: raw}} = conn), do: {raw, conn}

  defp raw_body(conn) do
    case read_body(conn, length: 1_000_000) do
      {:ok, raw, conn} -> {raw, conn}
      {_more_or_error, _partial, conn} -> {"", conn}
    end
  end

  defp reply(conn, status, body), do: conn |> put_status(status) |> json(body)
end
