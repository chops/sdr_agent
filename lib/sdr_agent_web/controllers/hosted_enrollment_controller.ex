defmodule SdrAgentWeb.HostedEnrollmentController do
  @moduledoc """
  Browser exchange for a console-issued hosted-owner link (ADR-0024).
  GET receives no fragment and never consumes a link. A dedicated root avoids
  inline/third-party scripts; the bundled handoff fills an initially closed
  CSRF form only after removing the fragment from browser history.
  POST consumes the signed, stored one-use link through Operations, clears
  the previous session and uses the existing authentication session helper.
  Rejections use one closed message, never token content.
  """
  use SdrAgentWeb, :controller

  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]

  alias SdrAgent.Operations

  def new(conn, _params) do
    conn
    |> private_headers()
    |> assign(:current_scope, nil)
    |> put_root_layout(html: {SdrAgentWeb.HostedEnrollmentHTML, :root})
    |> render(:new)
  end

  def create(conn, params) do
    conn = private_headers(conn)

    case Operations.consume_hosted_owner_link(Map.get(params, "enrollment_token")) do
      {:ok, user} ->
        conn
        |> clear_session()
        |> store_in_session(user)
        |> redirect(to: ~p"/")

      {:error, _refusal} ->
        conn
        |> put_flash(:error, "Enrollment link is not valid.")
        |> redirect(to: ~p"/hosted-enrollment")
    end
  end

  defp private_headers(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
  end
end
