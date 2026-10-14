defmodule SdrAgentWeb.CalibrationConsole do
  @moduledoc """
  The R0-07 calibration console's page allowlist (readiness packet §3: it
  "offers only the admin sign-in and budget pages").

  Inert unless `mix sdr.calibration.console serve` activated it (`config
  :sdr_agent, SdrAgentWeb.CalibrationConsole, active: true`, set only by
  `SdrAgent.CalibrationConsole.apply!/2` for that VM). Active:

    * as a plug in the endpoint (test builds only, after static assets),
      `/` redirects to `/admin`; the sign-in page, the `/auth` and
      `/sign-out` routes, `/admin` and the LiveView socket pass; every other
      request is answered 404 before the router;
    * as the operator console's last `on_mount` hook, a live navigation to
      any console view other than `SdrAgentWeb.AdminLive` is redirected to
      `/admin`, so no other page is reachable over the socket either; a
      signed-in operator who is not an admin is sent to `/sign-out`;
    * the endpoint's session cookie is `_sdr_agent_calibration_key`
      (`session_key/0`), not the app's `_sdr_agent_key`: browsers scope
      cookies by host, not port, so the console on localhost:4124 and the
      app on localhost:4120 would otherwise overwrite each other's sessions.
      `SdrAgentWeb.Endpoint.session_options/0` applies it to HTTP requests
      and the LiveView socket alike.

  It only narrows what is served; authentication and the domain's policies
  still decide everything on the pages it lets through.
  """
  @behaviour Plug

  import Plug.Conn

  @session_key "_sdr_agent_calibration_key"

  @doc "The console's own session cookie name."
  def session_key, do: @session_key

  @doc "Whether this VM serves the calibration console."
  def active? do
    :sdr_agent |> Application.get_env(__MODULE__, []) |> Keyword.get(:active, false) == true
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    cond do
      not active?() ->
        conn

      conn.path_info == [] ->
        conn
        |> put_resp_header("location", "/admin")
        |> send_resp(302, "")
        |> halt()

      allowed?(conn.path_info) ->
        conn

      true ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Not available in the calibration console")
        |> halt()
    end
  end

  defp allowed?(["admin"]), do: true
  defp allowed?(["sign-out"]), do: true
  defp allowed?([head | _rest]) when head in ["sign-in", "auth", "live"], do: true
  defp allowed?(_path_info), do: false

  @doc """
  `on_mount` hook for the operator console's live session: active, only
  `SdrAgentWeb.AdminLive` mounts; any other view is redirected to `/admin`.
  """
  def on_mount(:admin_only, _params, _session, socket) do
    cond do
      not active?() ->
        {:cont, socket}

      # A signed-in non-admin would be sent to "/" by AdminLive's role hook,
      # which this console sends back to /admin: a redirect loop. Sign-out
      # is the only page left for them here.
      not match?(%SdrAgentWeb.Scope{role: :admin}, socket.assigns[:current_scope]) ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(:error, "The calibration console is for the admin only.")
         |> Phoenix.LiveView.redirect(to: "/sign-out")}

      socket.view != SdrAgentWeb.AdminLive ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/admin")}

      true ->
        {:cont, socket}
    end
  end
end
