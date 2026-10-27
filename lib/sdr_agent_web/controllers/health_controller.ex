defmodule SdrAgentWeb.HealthController do
  @moduledoc """
  Liveness probe (`GET /health`) for the deploy script and the reverse
  proxy: answers `200 ok` in plain text once the endpoint serves requests.
  Unauthenticated; it reads no session and no data, so it reveals nothing.
  """
  use SdrAgentWeb, :controller

  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "ok")
  end
end
