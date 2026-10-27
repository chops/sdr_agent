defmodule SdrAgentWeb.SensitiveAuth do
  @moduledoc """
  Tags auth processes `sdr_sensitive_input` before they hold a credential
  (Codex M2/L1), so `SdrAgent.Logger.ExceptionFilter` replaces their
  crash, termination and error-or-higher reports with a fixed diagnostic
  (the same mechanism as the AdminLive channel, ADR-0005 R0-05 amendment):

    * as a plug in the auth pipeline (`:auth_edge`), the request's process
      (it holds the magic-link token from the path or body, or a typed
      password) until its response is sent; it is then untagged, as the
      connection process may serve other requests;
    * as the first `on_mount` hook of the sign-in and magic-link LiveViews
      (`on_mount_prepend`), each connected channel, for its lifetime — before
      the view assigns the token or receives typed input.

  Ordinary `:info` and `:debug` lines of tagged processes are not affected;
  their parameters and sessions are filtered separately
  (`config :phoenix, :filter_parameters`, `SdrAgentWeb.LiveViewMountLog`).
  """
  @behaviour Plug

  @tag :sdr_sensitive_input

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    tag()
    Plug.Conn.register_before_send(conn, &untag/1)
  end

  @doc "LiveView hook: tags a connected channel; a disconnected render is the tagged request."
  def on_mount(:default, _params, _session, socket) do
    if Phoenix.LiveView.connected?(socket), do: tag()
    {:cont, socket}
  end

  defp tag, do: :logger.update_process_metadata(%{@tag => true})

  defp untag(conn) do
    Logger.metadata([{@tag, nil}])
    conn
  end
end
