defmodule SdrAgentWeb.HostedEnrollmentController do
  @moduledoc """
  Inert landing page for a console-issued hosted-owner link (ADR-0024).
  GET receives no fragment and never consumes a link. A dedicated root avoids
  inline/third-party scripts; the bundled handoff fills an initially closed
  CSRF form only after removing the fragment from browser history.
  """
  use SdrAgentWeb, :controller

  def new(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> assign(:current_scope, nil)
    |> put_root_layout(html: {SdrAgentWeb.HostedEnrollmentHTML, :root})
    |> render(:new)
  end
end
