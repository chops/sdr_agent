defmodule SdrAgentWeb.SensitiveAuthTest do
  @moduledoc """
  Auth processes are tagged `sdr_sensitive_input` before they hold a
  credential (Codex M2/L1, P2, I1), so `SdrAgent.Logger.ExceptionFilter`
  withholds their crash, termination and error reports.

    * HTTP: the endpoint's first plug classifies each request on its
      URI-decoded first path segment (as the router decodes segments before
      matching): a credential-bearing family (`auth`, `magic_link`,
      `sign-in`, `sign-out`) tags the process; the tag holds past the
      response (the error report comes after it) until the next ordinary
      request on the same process, which clears only a tag this plug set.
    * LiveView: the sign-in and magic-link channels are tagged by their
      first mount hook, connected only.
  """
  # Process-local logger metadata and process dictionary only.
  use ExUnit.Case, async: true

  defp sensitive_auth(fun, args) do
    assert Code.ensure_loaded?(SdrAgentWeb.SensitiveAuth),
           "SdrAgentWeb.SensitiveAuth is not defined"

    assert function_exported?(SdrAgentWeb.SensitiveAuth, fun, length(args)),
           "SdrAgentWeb.SensitiveAuth.#{fun}/#{length(args)} is not defined"

    apply(Function.capture(SdrAgentWeb.SensitiveAuth, fun, length(args)), args)
  end

  defp tagged?, do: Logger.metadata()[:sdr_sensitive_input] == true
  defp request(path, opts), do: sensitive_auth(:call, [Plug.Test.conn(:get, path), opts])

  test "a credential-bearing request stays tagged past its response, until the next ordinary one" do
    opts = sensitive_auth(:init, [[]])
    refute tagged?()

    conn = request("/%6dagic_link/synthetic", opts)
    assert tagged?()

    # Sending the response does not untag: the error report comes after it.
    Plug.Conn.send_resp(conn, 200, "ok")
    assert tagged?()

    request("/auth/user/password/sign_in", opts)
    assert tagged?()

    request("/leads", opts)
    refute tagged?()
  end

  test "an ordinary request never clears a tag it did not set" do
    :logger.update_process_metadata(%{sdr_sensitive_input: true})
    request("/leads", sensitive_auth(:init, [[]]))
    assert tagged?()
  end

  test "the credential-bearing families are classified on the router's decoding" do
    sensitive =
      ~w(/magic_link/x /%6dagic_link/x /M%61gic_link/x /magic_link%2Fx /auth/user/x /%61uth/x /sign-in /sign-out)

    ordinary = ~w(/ /leads /health /magic /x/magic_link /live/websocket /authx)

    for path <- sensitive,
        do: assert(sensitive_auth(:sensitive_path?, [Plug.Test.conn(:get, path)]), path)

    for path <- ordinary,
        do: refute(sensitive_auth(:sensitive_path?, [Plug.Test.conn(:get, path)]), path)
  end

  test "the auth LiveViews are tagged by their first mount hook, connected only" do
    socket = %Phoenix.LiveView.Socket{transport_pid: self()}
    assert {:cont, ^socket} = sensitive_auth(:on_mount, [:default, %{}, %{}, socket])
    assert tagged?()
  end
end
