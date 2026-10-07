defmodule SdrAgentWeb.WebhookIntake do
  @moduledoc """
  Endpoint plug placed before `Plug.Parsers`: for webhook requests
  (`/webhooks/…`) it reads the exact request bytes itself (bounded:
  65,536 bytes) into `conn.private[:sdr_raw_body]`, so the signature
  is verified over — and the Payload stores — what the sender sent, and a
  malformed body reaches `SdrAgent.Outreach.Webhooks.ingest/3` (stored,
  rejected) instead of failing in the JSON parser. The parser then sees an
  already-read (empty) body. A larger body is refused with 413 and nothing
  is stored. Other requests pass through untouched.
  """
  @behaviour Plug

  import Plug.Conn

  @limit 64 * 1024

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: "/webhooks/" <> _} = conn, _opts) do
    case read_body(conn, length: @limit, read_length: @limit) do
      {:ok, body, conn} ->
        put_private(conn, :sdr_raw_body, body)

      {:more, _partial, conn} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(413, ~s({"error":"payload_too_large"}))
        |> halt()

      {:error, _reason} ->
        conn |> send_resp(400, "") |> halt()
    end
  end

  def call(conn, _opts), do: conn
end
