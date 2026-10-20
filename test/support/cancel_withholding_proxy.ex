defmodule SdrAgent.CancelWithholdingProxy do
  @moduledoc """
  A test-only TCP forwarder in front of the test PostgreSQL server that
  withholds every CancelRequest packet (C3-02 G3-2b).

  Why: on a client-timeout disconnect, `Postgrex.Protocol.disconnect/2`
  first sends a CancelRequest for the connection's backend on a new
  connection to the address the socket is connected to, then sends
  Terminate and closes the socket. A backend blocked in a lock wait
  answers the cancel with an `ErrorResponse` (57014, query_canceled); when
  the client reads it, and the `ReadyForQuery` after its `Sync`, before
  the socket closes, the call ends with a `Postgrex.Error` and the driver
  does not retry. When the close comes first, the client's pending receive
  ends with reason `:closed`, which Postgrex marks retriable. Which comes
  first is a race between two BEAM processes and the server, so the
  driver-retry path is not reproducible against the server directly.

  A connection pool pointed at this proxy (a test-owned dynamic
  `SdrAgent.Repo` instance) sends its CancelRequests here, and the proxy
  reads and drops them (counting them) without contacting the server, so
  a backend blocked in a lock wait never answers: every client-timeout
  disconnect ends the client's pending receive with `:closed`. Every
  other connection is forwarded byte for byte to the upstream server. The
  application's own pool and configuration are not touched.

  Processes: the proxy process owns the listen socket and links an
  acceptor; the acceptor links one handler per accepted connection (the
  handler owns both sockets and links a pump for the upstream direction).
  An acceptor whose accept fails exits abnormally, so no handler outlives
  the proxy; a socket closes when its owner exits. Start it with
  `ExUnit.Callbacks.start_supervised!/1`.
  """

  # PostgreSQL CancelRequest code: 1234 in the high 16 bits, 5678 in the low.
  @cancel_request_code 80_877_102
  @recv_ms 5_000

  @doc "A temporary child spec; `opts` needs `upstream: {host, port}`."
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @doc "Starts the proxy on an ephemeral loopback port."
  def start_link(opts) do
    {host, port} = Keyword.fetch!(opts, :upstream)
    :proc_lib.start_link(__MODULE__, :init, [{String.to_charlist(host), port}])
  end

  @doc "The proxy's loopback port."
  def port(proxy), do: request(proxy, :port)

  @doc "How many CancelRequests the proxy has withheld so far."
  def withheld(proxy), do: :counters.get(request(proxy, :counter), 1)

  @doc false
  def init(upstream) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, port} = :inet.port(listen)
    counter = :counters.new(1, [:atomics])
    _acceptor = spawn_link(fn -> accept(listen, upstream, counter) end)
    :proc_lib.init_ack({:ok, self()})
    serve_requests(%{port: port, counter: counter})
  end

  defp request(proxy, key) do
    ref = make_ref()
    send(proxy, {__MODULE__, self(), ref, key})

    receive do
      {^ref, value} -> value
    after
      @recv_ms -> exit({:cancel_withholding_proxy_unresponsive, key})
    end
  end

  defp serve_requests(state) do
    receive do
      {__MODULE__, from, ref, key} ->
        send(from, {ref, Map.fetch!(state, key)})
        serve_requests(state)
    end
  end

  defp accept(listen, upstream, counter) do
    case :gen_tcp.accept(listen) do
      {:ok, client} ->
        handler = spawn_link(fn -> handle(upstream, counter) end)
        :ok = :gen_tcp.controlling_process(client, handler)
        send(handler, {__MODULE__, :socket, client})
        accept(listen, upstream, counter)

      {:error, reason} ->
        exit({:cancel_withholding_proxy_closed, reason})
    end
  end

  defp handle(upstream, counter) do
    receive do
      {__MODULE__, :socket, client} -> first_packet(client, upstream, counter)
    end
  end

  # The first packet of a connection: a CancelRequest is read and dropped;
  # anything else (the startup packet) opens the upstream connection.
  defp first_packet(client, upstream, counter) do
    case :gen_tcp.recv(client, 8, @recv_ms) do
      {:ok, <<length::32, @cancel_request_code::32>>} ->
        :counters.add(counter, 1, 1)
        _ = :gen_tcp.recv(client, max(length - 8, 0), @recv_ms)
        :gen_tcp.close(client)

      {:ok, head} ->
        forward(client, head, upstream)

      {:error, _reason} ->
        :gen_tcp.close(client)
    end
  end

  defp forward(client, head, {host, port}) do
    with {:ok, server} <- :gen_tcp.connect(host, port, [:binary, active: false], @recv_ms),
         :ok <- :gen_tcp.send(server, head) do
      _pump = spawn_link(fn -> pipe(server, client) end)
      pipe(client, server)
    else
      _error -> :gen_tcp.close(client)
    end
  end

  # Copies `from` to `to` until either side ends, then closes both.
  defp pipe(from, to) do
    with {:ok, data} <- :gen_tcp.recv(from, 0),
         :ok <- :gen_tcp.send(to, data) do
      pipe(from, to)
    else
      _ended ->
        :gen_tcp.close(from)
        :gen_tcp.close(to)
    end
  end
end
