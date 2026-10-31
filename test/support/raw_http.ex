defmodule SdrAgent.TestSupport.RawHttp do
  @moduledoc """
  Test helper: a real Bandit listener serving `SdrAgentWeb.Endpoint` itself
  on an ephemeral loopback port, and a minimal raw HTTP/1.1 and WebSocket
  client over `:gen_tcp`, so error reports are produced at the real HTTP
  boundary (Phoenix renders and re-raises, Bandit reports) rather than by
  `Phoenix.ConnTest`.

  The listener logs every exception status, 400..599 (stricter than the
  default 500..599), so 4xx failures produce reports to inspect. Each
  connection's server-side handler process is returned, so tests correlate
  reports to the request they made.

  Credential helpers build a real signed session cookie with the endpoint's
  own session options and a CSRF state, as a browser would hold.
  """

  import ExUnit.Assertions

  @doc "Starts a listener for the test; returns `%{server: pid, port: port}`."
  def listener do
    server =
      ExUnit.Callbacks.start_supervised!(
        {Bandit,
         plug: SdrAgentWeb.Endpoint,
         ip: :loopback,
         port: 0,
         startup_log: false,
         http_options: [log_exceptions_with_status_codes: 400..599],
         http_2_options: [enabled: false]}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{server: server, port: port}
  end

  @doc """
  Sends `requests` in order on one connection; returns their statuses and
  the server process that handled the connection.
  """
  def exchange(listener, requests) do
    {socket, pid} = open(listener)
    statuses = for request <- requests, do: request(socket, request)
    :gen_tcp.close(socket)
    {statuses, pid}
  end

  @doc "A new connection and its server-side handler process."
  def open(%{server: server, port: port}) do
    {:ok, before} = ThousandIsland.connection_pids(server)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    {socket, handler(server, before, System.monotonic_time(:millisecond) + 2_000)}
  end

  defp handler(server, before, deadline) do
    {:ok, pids} = ThousandIsland.connection_pids(server)

    case pids -- before do
      [pid] ->
        pid

      _none_yet ->
        assert System.monotonic_time(:millisecond) < deadline, "no handler for the connection"
        Process.sleep(10)
        handler(server, before, deadline)
    end
  end

  @doc "Sends one request on `socket`; returns its status (or `{:error, reason}`)."
  def request(socket, request) do
    :ok = :gen_tcp.send(socket, request)
    read_response(socket, "")
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

  @doc "A GET request; `headers` is raw header lines, each ending in CRLF."
  def get(path, headers \\ ""),
    do: "GET #{path} HTTP/1.1\r\nhost: localhost\r\n#{headers}\r\n"

  @doc "A POST request with `body` of content `type`."
  def post(path, type, body, headers \\ ""),
    do:
      "POST #{path} HTTP/1.1\r\nhost: localhost\r\ncontent-type: #{type}\r\n" <>
        "content-length: #{byte_size(body)}\r\n#{headers}\r\n" <> body

  @doc "A WebSocket upgrade request for `path`."
  def ws_upgrade(path, headers \\ "") do
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    "GET #{path} HTTP/1.1\r\nhost: localhost\r\norigin: http://localhost\r\n" <>
      "upgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-key: #{key}\r\n" <>
      "sec-websocket-version: 13\r\n#{headers}\r\n"
  end

  @doc "A masked client text frame carrying `payload` (under 126 bytes)."
  def ws_text_frame(payload) when byte_size(payload) < 126 do
    mask = :crypto.strong_rand_bytes(4)

    masked =
      for {byte, index} <- Enum.with_index(:binary.bin_to_list(payload)), into: <<>> do
        <<Bitwise.bxor(byte, :binary.at(mask, rem(index, 4)))>>
      end

    <<1::1, 0::3, 1::4, 1::1, byte_size(payload)::7>> <> mask <> masked
  end

  @doc """
  A real signed session cookie for `session` (the endpoint's own session
  options and secret); returns `{name, value}`.
  """
  def session_cookie(session) do
    %{store: store, store_config: config, key: key} =
      Plug.Session.init(SdrAgentWeb.Endpoint.session_options())

    conn = %Plug.Conn{secret_key_base: SdrAgentWeb.Endpoint.config(:secret_key_base)}
    {key, store.put(conn, nil, session, config)}
  end

  @doc """
  A CSRF pair as a browser page holds it: `{masked_token, session_state}`
  (the state belongs in the session under `"_csrf_token"`).
  """
  def csrf_pair do
    masked = Plug.CSRFProtection.get_csrf_token()
    state = Plug.CSRFProtection.dump_state()
    Plug.CSRFProtection.delete_csrf_token()
    {masked, state}
  end
end
