defmodule SdrAgentWeb.RawBodyReader do
  @moduledoc """
  `Plug.Parsers` body reader that keeps the exact request bytes of webhook
  requests (`/webhooks/…`) in `conn.private[:sdr_raw_body]` before they are
  parsed, so the signature is verified over — and the Payload stores — the
  bytes the sender signed (S2 WebhookEvent, checklist 4.3). Other requests
  are read unchanged.
  """

  @doc "Reads the body like `Plug.Conn.read_body/2`, caching it for webhook paths."
  def read_body(%Plug.Conn{request_path: "/webhooks/" <> _} = conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {status, body, conn} when status in [:ok, :more] ->
        cached = Map.get(conn.private, :sdr_raw_body, "")
        {status, body, Plug.Conn.put_private(conn, :sdr_raw_body, cached <> body)}

      other ->
        other
    end
  end

  def read_body(conn, opts), do: Plug.Conn.read_body(conn, opts)
end
