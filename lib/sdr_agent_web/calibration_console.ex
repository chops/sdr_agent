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
      `/admin`, so no other page is reachable over the socket either.

  It only narrows what is served; authentication and the domain's policies
  still decide everything on the pages it lets through.
  """
  @behaviour Plug

  import Plug.Conn

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
    if active?() and socket.view != SdrAgentWeb.AdminLive do
      {:halt, Phoenix.LiveView.redirect(socket, to: "/admin")}
    else
      {:cont, socket}
    end
  end
end
