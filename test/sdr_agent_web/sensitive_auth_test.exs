defmodule SdrAgentWeb.SensitiveAuthTest do
  @moduledoc """
  Auth processes are tagged `sdr_sensitive_input` before they hold a
  credential (Codex M2/L1), so `SdrAgent.Logger.ExceptionFilter` withholds
  their crash, termination and error reports: an auth request's process
  from the auth pipeline until its response is sent (then untagged, as the
  connection process may serve other requests), and the sign-in and
  magic-link LiveView channels from their first mount hook on.
  """
  # Process-local logger metadata only.
  use ExUnit.Case, async: true

  defp sensitive_auth(fun, args) do
    assert Code.ensure_loaded?(SdrAgentWeb.SensitiveAuth),
           "SdrAgentWeb.SensitiveAuth is not defined"

    apply(Function.capture(SdrAgentWeb.SensitiveAuth, fun, length(args)), args)
  end

  test "an auth request's process is tagged until its response is sent" do
    conn = Plug.Test.conn(:get, "/magic_link/synthetic")
    refute Logger.metadata()[:sdr_sensitive_input]

    conn = sensitive_auth(:call, [conn, sensitive_auth(:init, [[]])])
    assert Logger.metadata()[:sdr_sensitive_input] == true

    Plug.Conn.send_resp(conn, 200, "ok")
    refute Logger.metadata()[:sdr_sensitive_input]
  end

  test "the auth LiveViews are tagged by their first mount hook, connected only" do
    socket = %Phoenix.LiveView.Socket{transport_pid: self()}
    assert {:cont, ^socket} = sensitive_auth(:on_mount, [:default, %{}, %{}, socket])
    assert Logger.metadata()[:sdr_sensitive_input] == true
  end
end
