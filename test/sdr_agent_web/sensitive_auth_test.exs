defmodule SdrAgentWeb.SensitiveAuthTest do
  @moduledoc """
  Credential-bearing processes are tagged `sdr_sensitive_input` before they
  hold a credential, so `SdrAgent.Logger.ExceptionFilter` withholds their
  crash, termination and error reports (hosted auth hardening plan r1,
  S1; ported from the deploy-hosted lineage, magic links removed).

    * HTTP: the endpoint's own `call/2`, before Phoenix's socket dispatch
      and every plug, classifies each request: a credential-bearing family
      (`auth`, `sign-in`, `sign-out`, `hosted-enrollment`) on its
      URI-decoded first path segment (as the router decodes segments before
      matching), the LiveView socket (`live`), or any cookie or
      authorization header tags the process; the tag holds past the
      response (the error report comes after it) until the next ordinary
      request on the same process, which clears only a tag this plug set.
    * LiveView: the sign-in channel is tagged by its first mount hook,
      connected only.
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

    conn = request("/hosted-%65nrollment", opts)
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
      ~w(/auth/user/x /%61uth/x /AUTH/x /auth%2Fuser /sign-in /sign-out /hosted-enrollment /Hosted-Enrollment /hosted%2Denrollment)

    ordinary =
      ~w(/ /leads /health /authx /x/auth /hosted /hosted-enrollmentx /magic_link/x /live/websocket)

    for path <- sensitive,
        do: assert(sensitive_auth(:sensitive_path?, [Plug.Test.conn(:get, path)]), path)

    for path <- ordinary,
        do: refute(sensitive_auth(:sensitive_path?, [Plug.Test.conn(:get, path)]), path)
  end

  # Any request carrying a credential header, and every LiveView socket
  # request (its cookie, CSRF token and typed frames), is credential-bearing
  # whatever its path.
  test "credential headers and the LiveView socket are credential-bearing on any path" do
    with_header = fn name, value ->
      Plug.Conn.put_req_header(Plug.Test.conn(:get, "/leads"), name, value)
    end

    bearing = [
      with_header.("cookie", "_sdr_agent_key=x"),
      with_header.("authorization", "Bearer x"),
      with_header.("proxy-authorization", "Basic x"),
      Plug.Test.conn(:get, "/live/websocket?vsn=2.0.0"),
      Plug.Test.conn(:get, "/%6Cive/longpoll"),
      Plug.Test.conn(:post, "/hosted-enrollment")
    ]

    free = [Plug.Test.conn(:get, "/leads"), with_header.("accept", "text/html")]

    for conn <- bearing,
        do: assert(sensitive_auth(:sensitive?, [conn]), inspect(conn.req_headers))

    for conn <- free, do: refute(sensitive_auth(:sensitive?, [conn]), conn.request_path)

    opts = sensitive_auth(:init, [[]])
    sensitive_auth(:call, [with_header.("cookie", "_sdr_agent_key=x"), opts])
    assert tagged?()
    request("/leads", opts)
    refute tagged?()
  end

  test "an undecodable first segment fails closed as sensitive" do
    assert sensitive_auth(:sensitive?, [Plug.Test.conn(:get, "/%E0%A4%A")])
  end

  test "the sign-in LiveView is tagged by its first mount hook, connected only" do
    socket = %Phoenix.LiveView.Socket{transport_pid: self()}
    assert {:cont, ^socket} = sensitive_auth(:on_mount, [:default, %{}, %{}, socket])
    assert tagged?()
  end

  test "a disconnected mount does not tag" do
    socket = %Phoenix.LiveView.Socket{transport_pid: nil}
    assert {:cont, ^socket} = sensitive_auth(:on_mount, [:default, %{}, %{}, socket])
    refute tagged?()
  end
end
