defmodule SdrAgentWeb.BanditFlowControlTest do
  @moduledoc """
  ADR-0008 amendment (EEF-CVE-2026-105659), decision item 4: regression
  evidence for the pinned Bandit fix itself (`d88b219`), adapted from the
  fix's own protocol tests.

  Tests run only with HTTP/2 off would prove the mitigation, not the fix.
  So each test starts its own hermetic, ephemeral loopback Bandit listener
  **with HTTP/2 enabled**, used only here, and speaks cleartext HTTP/2 with
  prior knowledge:

    * a send blocked on the **connection** window is not kept alive by a
      trickle of 1-byte connection `WINDOW_UPDATE`s, nor by empty
      `SETTINGS`;
    * a send blocked on the **stream** window (a 5-byte initial window, an
      ample connection window) is not kept alive by 1-byte stream
      `WINDOW_UPDATE`s;
    * a slow but legitimate client that keeps draining a large send at
      2 KiB/s finishes, though it takes longer than the base timeout.

  On Bandit 1.12.5 the first three keep the stream alive past the window
  of these tests. No ordinary or deployed listener enables HTTP/2. Each
  test takes about 16–18 s.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag timeout: 120_000

  defmodule FlowPlug do
    @moduledoc false
    @behaviour Plug
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      test = :persistent_term.get({__MODULE__, :test})
      send(test, {:plug_ready, self()})
      receive do: (:go -> :ok)
      conn = send_chunked(conn, 200)

      case conn.request_path do
        "/connection" ->
          # 60_000 bytes fit the 65_535-byte connection window; the next
          # 10_000 block on it after 5_535 more.
          conn =
            Enum.reduce(1..6, conn, fn _i, conn ->
              {:ok, conn} = chunk(conn, String.duplicate("a", 10_000))
              conn
            end)

          blocking(conn, String.duplicate("a", 10_000), test)

        "/stream" ->
          blocking(conn, String.duplicate("a", 100), test)

        "/drain" ->
          blocking(conn, String.duplicate("a", 100_000), test)
      end
    end

    defp blocking(conn, data, test) do
      send(test, {:blocking_started, self()})

      case chunk(conn, data) do
        {:ok, conn} ->
          send(test, {:blocking_returned, self()})
          conn

        {:error, reason} ->
          send(test, {:blocking_error, self(), reason})
          conn
      end
    end
  end

  setup do
    :persistent_term.put({FlowPlug, :test}, self())

    server =
      start_supervised!(
        {Bandit,
         plug: FlowPlug,
         ip: :loopback,
         port: 0,
         startup_log: false,
         http_2_options: [enabled: true],
         thousand_island_options: [read_timeout: 2_000]}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> :persistent_term.erase({FlowPlug, :test}) end)
    %{port: port}
  end

  for {name, frame} <- [
        {"connection WINDOW_UPDATE", {8, <<0::1, 1::31>>}},
        {"empty SETTINGS", {4, <<>>}}
      ] do
    @frame frame

    test "a send blocked on the connection window is not kept alive by a #{name} trickle", ctx do
      socket = connect!(ctx.port)
      plug = request!(socket, ctx.port, "/connection", stream_window: 1_000_000)
      ref = Process.monitor(plug)
      refute_receive {:blocking_returned, ^plug}, 500

      {type, body} = @frame
      for_ms(16_000, 250, fn -> frame!(socket, type, 0, body) end)

      assert_receive {:blocking_error, ^plug,
                      "Timeout waiting for space in the connection send_window"},
                     1_000

      assert_receive {:DOWN, ^ref, :process, ^plug, _reason}, 1_000
    end
  end

  test "a send blocked on the stream window is not kept alive by a stream WINDOW_UPDATE trickle",
       ctx do
    # A 5-byte initial stream window, so the stream window is what blocks.
    socket = connect!(ctx.port, <<4::16, 5::32>>)
    plug = request!(socket, ctx.port, "/stream")
    ref = Process.monitor(plug)
    refute_receive {:blocking_returned, ^plug}, 100

    for_ms(16_000, 250, fn -> frame!(socket, 8, 1, <<0::1, 1::31>>) end)

    assert_receive {:blocking_error, ^plug, "Timeout waiting for space in the send_window"},
                   1_000

    assert_receive {:DOWN, ^ref, :process, ^plug, _reason}, 1_000
  end

  test "a slow client that keeps draining a large send is not cut off", ctx do
    socket = connect!(ctx.port)
    plug = request!(socket, ctx.port, "/drain", stream_window: 1_000_000)

    # 100_000 bytes less the 65_535-byte connection window leaves 34_465,
    # which at 2 KiB/s takes about 17 s: longer than the base timeout, at a
    # rate well above the minimum.
    for_ms(18_000, 1_000, fn -> frame!(socket, 8, 0, <<0::1, 2_048::31>>) end)

    assert_receive {:blocking_returned, ^plug}, 1_000
    refute_received {:blocking_error, ^plug, _reason}
  end

  ## A minimal cleartext HTTP/2 client (prior knowledge)

  # Preface, the client's SETTINGS and an ACK of the server's; a reader
  # process discards everything the server sends, so TCP never backs up.
  defp connect!(port, settings \\ <<>>) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
    frame!(socket, 4, 0, settings)
    frame!(socket, 4, 0, <<>>, 1)
    reader = spawn(fn -> drain(socket) end)
    :ok = :gen_tcp.controlling_process(socket, reader)
    socket
  end

  defp drain(socket) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, _data} -> drain(socket)
      {:error, _closed} -> :ok
    end
  end

  # GET `path` on stream 1, then (optionally) widens the stream window
  # before the plug writes anything.
  defp request!(socket, port, path, opts \\ []) do
    {block, _table} =
      [
        {":method", "GET"},
        {":path", path},
        {":scheme", "http"},
        {":authority", "127.0.0.1:#{port}"}
      ]
      |> Enum.map(fn {k, v} -> {:store, k, v} end)
      |> HPAX.encode(HPAX.new(4096))

    # END_STREAM | END_HEADERS
    frame!(socket, 1, 1, block, 0x05)
    assert_receive {:plug_ready, plug}, 2_000

    if increment = opts[:stream_window], do: frame!(socket, 8, 1, <<0::1, increment::31>>)
    # The window update is applied before any body is written.
    Process.sleep(100)
    send(plug, :go)
    assert_receive {:blocking_started, ^plug}, 2_000
    plug
  end

  defp frame!(socket, type, stream_id, body, flags \\ 0) do
    :ok =
      :gen_tcp.send(socket, [
        <<IO.iodata_length(body)::24, type::8, flags::8, 0::1, stream_id::31>>,
        body
      ])
  end

  defp for_ms(duration, interval, fun) do
    deadline = System.monotonic_time(:millisecond) + duration

    Stream.repeatedly(fn ->
      fun.()
      Process.sleep(interval)
      System.monotonic_time(:millisecond)
    end)
    |> Enum.find(&(&1 >= deadline))
  end
end
