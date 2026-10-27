defmodule SdrAgentWeb.AuthErrorBoundaryTest do
  @moduledoc """
  Auth requests' error reports through the real HTTP error boundary (Codex
  P2, I1): a Bandit listener serving `SdrAgentWeb.Endpoint` itself, raw HTTP
  over a socket, and the raw `:logger` events (message and metadata, after
  the primary filters) captured by `SdrAgent.TestSupport.RawLog`.

  The listener logs every exception status, 400..599 (stricter than the
  default 500..599 in use elsewhere), so parser (400), CSRF (403) and
  content-negotiation (406) failures produce reports too. Each case carries
  a unique sentinel credential; for a request in the credential-bearing
  route families (`/auth`, `/magic_link`, any spelling the router routes
  there) a report must be emitted and withheld, with the sentinel nowhere
  in its message or metadata:

    * P2: a crash after the auth pipeline, whose exception stack arguments
      and request query carry the sentinel (Phoenix renders and sends the
      error response, re-raises, and Bandit reports it afterwards);
    * I1: a body-parser failure and two browser-pipeline failures, before
      the router reaches the auth routes.

  Positive controls: the same failure on an ordinary path is reported in
  full (sentinel included), and on one keep-alive connection the tag of a
  credential-bearing request does not withhold a later ordinary request's
  report, while an ordinary request does not unprotect a later auth one.
  """
  use SdrAgentWeb.ConnCase, async: false

  alias SdrAgent.TestSupport.RawLog

  @withheld "diagnostic withheld: process holds operator input"

  setup do
    server =
      start_supervised!(
        {Bandit,
         plug: SdrAgentWeb.Endpoint,
         ip: :loopback,
         port: 0,
         startup_log: false,
         http_options: [log_exceptions_with_status_codes: 400..599],
         http_2_options: [enabled: false]}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    sentinel = "SENTINEL" <> Integer.to_string(System.unique_integer([:positive]))
    %{port: port, sentinel: sentinel, ref: RawLog.start()}
  end

  # --- raw HTTP/1.1 over one socket ------------------------------------

  defp exchange(port, requests) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    responses =
      for request <- requests do
        :ok = :gen_tcp.send(socket, request)
        read_response(socket, "")
      end

    :gen_tcp.close(socket)
    responses
  end

  defp read_response(socket, acc) do
    with [head, body] <- :binary.split(acc, "\r\n\r\n"),
         length = content_length(head),
         true <- byte_size(body) >= length do
      [status_line | _] = String.split(head, "\r\n")
      [_version, status | _] = String.split(status_line, " ")
      String.to_integer(status)
    else
      _incomplete ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, data} -> read_response(socket, acc <> data)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp content_length(head) do
    case Regex.run(~r/\r\ncontent-length: *(\d+)/i, head) do
      [_, length] -> String.to_integer(length)
      nil -> 0
    end
  end

  defp raw_get(path, headers \\ ""),
    do: "GET #{path} HTTP/1.1\r\nhost: localhost\r\n#{headers}\r\n"

  defp raw_post(path, type, body),
    do:
      "POST #{path} HTTP/1.1\r\nhost: localhost\r\ncontent-type: #{type}\r\n" <>
        "content-length: #{byte_size(body)}\r\n\r\n" <> body

  # --- assertions on raw events ----------------------------------------

  # A credential-bearing request's report: emitted, withheld, sentinel-free.
  defp assert_withheld(ctx) do
    event = RawLog.await_error(ctx.ref, :bandit)
    assert event, "no error report was emitted"
    Process.sleep(200)
    events = [event | RawLog.drain(ctx.ref)]

    leaking = Enum.filter(events, &RawLog.contains?(&1, ctx.sentinel))
    assert leaking == [], "the sentinel is in #{length(leaking)} raw event(s)"
    assert RawLog.rendered(event) == @withheld
  end

  # An ordinary request's report: emitted in full (positive control).
  defp assert_reported(ctx) do
    event = RawLog.await_error(ctx.ref, :bandit)
    assert event, "no error report was emitted"
    assert RawLog.contains?(event, ctx.sentinel)
    refute RawLog.rendered(event) == @withheld
  end

  defp malformed_json(sentinel), do: ~s({"user": {"email": "x", "password": "#{sentinel}")

  # A malformed JSON body: the parser raises before the router. Under Bandit,
  # Phoenix then renders with the conn from before the body was read, Bandit
  # refuses it as stale, and the answer is a 500 whose report carries that
  # conn (its path and query) in metadata; the sentinel also rides in the
  # query string, where a credential can (a token query).
  defp parser_failure(path, sentinel),
    do: raw_post(path <> "?token=#{sentinel}", "application/json", malformed_json(sentinel))

  # --- P2: after the auth pipeline -------------------------------------

  test "a crash on an auth route after its pipeline is reported withheld", ctx do
    # The accept phase reads `user` as a map; a string crashes it
    # (FunctionClauseError in Access.get/3, the sentinel among its arguments).
    query = "token=#{ctx.sentinel}&user=#{ctx.sentinel}"
    assert [500] = exchange(ctx.port, [raw_get("/auth/user/magic_link?" <> query)])
    assert_withheld(ctx)
  end

  # --- I1: before the router reaches the auth routes ---------------------

  test "a body-parser failure on an auth path is reported withheld, any spelling", ctx do
    for path <- ["/auth/user/password/sign_in", "/%61uth/user/password/sign_in"] do
      assert [status] = exchange(ctx.port, [parser_failure(path, ctx.sentinel)])
      assert status in [400, 500]
      assert_withheld(ctx)
    end
  end

  test "a CSRF failure on an auth path is reported withheld", ctx do
    body = "user[email]=x&user[password]=#{ctx.sentinel}"

    request =
      raw_post(
        "/auth/user/password/sign_in?token=#{ctx.sentinel}",
        "application/x-www-form-urlencoded",
        body
      )

    assert [403] = exchange(ctx.port, [request])
    assert_withheld(ctx)
  end

  test "a content-negotiation failure on a confirmation path is reported withheld", ctx do
    for prefix <- ["magic_link", "%6dagic_link"] do
      request = raw_get("/#{prefix}/#{ctx.sentinel}", "accept: application/json\r\n")
      assert [406] = exchange(ctx.port, [request])
      assert_withheld(ctx)
    end
  end

  # --- positive controls and process reuse -------------------------------

  test "the same parser failure on an ordinary path is reported in full", ctx do
    assert [status] = exchange(ctx.port, [parser_failure("/leads", ctx.sentinel)])
    assert status in [400, 500]

    assert_reported(ctx)
  end

  test "on one connection, an auth request's tag does not withhold a later ordinary report",
       ctx do
    assert [200, status] =
             exchange(ctx.port, [
               raw_get("/magic_link/not-a-real-token"),
               parser_failure("/leads", ctx.sentinel)
             ])

    assert status in [400, 500]

    assert_reported(ctx)
  end

  test "on one connection, an ordinary request does not unprotect a later auth crash", ctx do
    query = "token=#{ctx.sentinel}&user=#{ctx.sentinel}"

    assert [200, 500] =
             exchange(ctx.port, [raw_get("/health"), raw_get("/auth/user/magic_link?" <> query)])

    assert_withheld(ctx)
  end
end
