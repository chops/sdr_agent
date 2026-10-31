defmodule SdrAgentWeb.HealthControllerTest do
  @moduledoc """
  The unauthenticated liveness probe that the reverse proxy and the build or
  runbook checks call. `GET /health` answers 200 `ok` without a session. It
  reads nothing and sets no cookie. It is endpoint liveness only, not
  database, sign-in or activation readiness.
  """
  use SdrAgentWeb.ConnCase, async: true

  test "GET /health answers 200 ok without a session", %{conn: conn} do
    conn = get(conn, "/health")

    assert response(conn, 200) == "ok"
    assert ["text/plain" <> _] = get_resp_header(conn, "content-type")
    assert get_resp_header(conn, "set-cookie") == []
  end
end
