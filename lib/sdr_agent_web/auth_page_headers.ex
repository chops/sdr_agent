defmodule SdrAgentWeb.AuthPageHeaders do
  @moduledoc """
  Response headers for the sign-in pages and auth routes (Codex M2): the
  magic-link confirmation page carries a live token in its URL, so no
  auth response is stored (`Cache-Control: no-store`) and none sends a
  referrer (`Referrer-Policy: no-referrer`, replacing the browser
  pipeline's default). The pages load nothing from other origins (the
  sign-in banners are off, `SdrAgentWeb.AuthOverrides`).
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
  end
end
