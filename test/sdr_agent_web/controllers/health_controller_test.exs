defmodule SdrAgentWeb.HealthControllerTest do
  @moduledoc """
  The unauthenticated liveness probe the deploy script and the proxy check:
  `GET /health` answers 200 `ok` without a session, reads nothing and sets no
  cookie.
  """
  use SdrAgentWeb.ConnCase, async: true

  test "GET /health answers 200 ok without a session", %{conn: conn} do
    conn = get(conn, "/health")

    assert response(conn, 200) == "ok"
    assert ["text/plain" <> _] = get_resp_header(conn, "content-type")
    assert get_resp_header(conn, "set-cookie") == []
  end
end
