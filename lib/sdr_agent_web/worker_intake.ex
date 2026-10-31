defmodule SdrAgentWeb.WorkerIntake do
  @moduledoc """
  S-B4: Endpoint plug placed before `Plug.Parsers`, next to
  `SdrAgentWeb.WebhookIntake`, for the Mac worker API (`/worker/…`).

  A worker request must be a `POST` (else 405) with content type
  `application/json` (else 415). Its body is read with a bound of 13 MiB:
  the worst-case JSON escape of the raw 2097152-byte transcript cap (six
  bytes per byte, 12 MiB) plus 1 MiB for the envelope. A larger body is 413
  `{"error":"payload_too_large"}`. The body must decode to a JSON object
  (arrays, scalars, empty and malformed bodies are 400). The object becomes
  `body_params` and `params`, so `Plug.Parsers` skips the request (its
  `body_params` is no longer unfetched). Every refusal halts before any
  route, so nothing is written, and no body byte is logged. Other paths and
  the global parser's limits are unchanged.
  """
  @behaviour Plug

  import Plug.Conn

  @limit 13 * 1_048_576

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: "/worker/" <> _} = conn, _opts) do
    cond do
      conn.method != "POST" -> refuse(conn, 405, "method_not_allowed")
      not json?(conn) -> refuse(conn, 415, "unsupported_media_type")
      true -> read(conn)
    end
  end

  def call(conn, _opts), do: conn

  @doc "The intake's body bound, in bytes."
  @spec limit() :: pos_integer()
  def limit, do: @limit

  defp read(conn) do
    case read_body(conn, length: @limit, read_length: 1_048_576) do
      {:ok, body, conn} -> decode(conn, body)
      {:more, _partial, conn} -> refuse(conn, 413, "payload_too_large")
      {:error, _reason} -> refuse(conn, 400, "invalid_request")
    end
  end

  defp decode(conn, body) do
    case Jason.decode(body) do
      {:ok, object} when is_map(object) -> %{conn | body_params: object, params: object}
      _not_an_object -> refuse(conn, 400, "invalid_request")
    end
  end

  defp json?(conn) do
    case get_req_header(conn, "content-type") do
      [type | _] ->
        match?({:ok, "application", "json", _params}, Plug.Conn.Utils.content_type(type))

      [] ->
        false
    end
  end

  defp refuse(conn, status, error) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: error}))
    |> halt()
  end
end
