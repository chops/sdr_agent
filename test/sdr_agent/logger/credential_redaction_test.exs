defmodule SdrAgent.Logger.CredentialRedactionTest do
  @moduledoc """
  The primary `:logger` filter that removes credential-bearing data from
  every log event (Codex R1), whatever process or route it comes from:

    * a `Plug.Conn` anywhere in an event becomes `%{method, request_path,
      status}` (a magic-link path's token segment filtered; the status from
      the reported exception when the conn has none) — no headers, cookies,
      query, params, session or assigns;
    * stack frames keep their arity, never their arguments;
    * map and keyword entries whose key names a credential (token,
      password, secret, cookie, authorization, session, …) are filtered,
      and so are the request input a JSON decode error holds (`data` and
      `token`, Codex fc6b86ca R4);
    * socket data in a `{:tcp | :ssl, socket, data}` message is reduced to
      its size, and a connection process's state (`{%ThousandIsland.Socket{},
      state}`) is dropped, in real OTP reports too; ordinary process
      reports keep their state and last message;
    * a Bandit report's text is re-rendered from the redacted exception
      and stack, so no argument formatted into it survives;
    * ordinary content (request id, trace ids, domain, plain messages) is
      untouched; the filter never raises, and an internal failure yields a
      fixed diagnostic with no event content (Codex fc6b86ca R5).

  It runs before Elixir's report translator (so reports are redacted while
  still terms) and after `SdrAgent.Logger.ExceptionFilter`: the install
  order is deterministic.
  """
  # A :logger handler sees every process's events; some tests set the
  # global level to :debug.
  use ExUnit.Case, async: false

  alias SdrAgent.TestSupport.RawLog

  @module SdrAgent.Logger.CredentialRedaction

  defp filter(event) do
    assert Code.ensure_loaded?(@module), "#{inspect(@module)} is not defined"
    assert function_exported?(@module, :filter, 2), "#{inspect(@module)}.filter/2 is not defined"
    Function.capture(@module, :filter, 2).(event, [])
  end

  # The term-walk oracle (Codex R3): the rendered message and every term,
  # struct fields included, never their Inspect text.
  defp clean?(event, secrets), do: Enum.all?(secrets, &(not RawLog.contains?(event, &1)))

  defp conn do
    %Plug.Conn{
      method: "POST",
      request_path: "/leads",
      query_string: "token=SECRET-QUERY",
      req_headers: [
        {"cookie", "_sdr_agent_key=SECRET-COOKIE"},
        {"authorization", "Bearer SECRET-BEARER"},
        {"accept", "text/html"}
      ],
      req_cookies: %{"_sdr_agent_key" => "SECRET-COOKIE"},
      private: %{plug_session: %{"user_token" => "SECRET-SESSION"}},
      assigns: %{current_user: %{hashed_password: "SECRET-HASH"}}
    }
  end

  @secrets ~w(SECRET-QUERY SECRET-COOKIE SECRET-BEARER SECRET-SESSION SECRET-HASH)

  test "it is installed after the exception filter and before the report translator" do
    ids = Enum.map(:logger.get_primary_config().filters, &elem(&1, 0))

    assert Enum.take(ids, 3) == [
             :sdr_agent_exception_filter,
             :sdr_agent_credential_redaction,
             :logger_translator
           ]
  end

  test "a conn in metadata is reduced to method, path and status" do
    event = %{
      level: :error,
      msg: {:string, "** (RuntimeError) boom"},
      meta: %{
        conn: conn(),
        request_id: "req-123",
        domain: [:elixir, :bandit],
        crash_reason: {%RuntimeError{message: "boom"}, []}
      }
    }

    filtered = filter(event)

    assert filtered.meta.conn == %{method: "POST", request_path: "/leads", status: 500}
    assert filtered.meta.request_id == "req-123"
    assert filtered.meta.domain == [:elixir, :bandit]
    assert clean?(filtered, @secrets)
  end

  test "a magic-link path's token segment is filtered in the conn summary" do
    conn = %{conn() | request_path: "/%6dagic_link/eyJSECRET-LINK", method: "GET", status: 200}
    filtered = filter(%{level: :error, msg: {:string, "x"}, meta: %{conn: conn}})

    assert filtered.meta.conn.request_path == "/%6dagic_link/[FILTERED]"
    assert clean?(filtered, ["SECRET-LINK" | @secrets])
  end

  test "stack arguments become arities, and a Bandit report is re-rendered without them" do
    exception = %FunctionClauseError{module: SdrAgent.Example, function: :run, arity: 2}
    stack = [{SdrAgent.Example, :run, [conn(), %{"token" => "SECRET-ARG"}], [line: 7]}]
    message = Exception.format(:error, exception, stack)
    assert message =~ "SECRET-COOKIE", "the fixture really formats its arguments"

    event = %{
      level: :error,
      msg: {:string, message},
      meta: %{domain: [:elixir, :bandit], crash_reason: {exception, stack}, conn: conn()}
    }

    filtered = filter(event)

    assert {_exception, [{SdrAgent.Example, :run, 2, [line: 7]}]} = filtered.meta.crash_reason
    assert {:string, text} = filtered.msg
    assert IO.chardata_to_string(text) =~ "FunctionClauseError"
    assert IO.chardata_to_string(text) =~ "SdrAgent.Example.run/2"
    assert clean?(filtered, ["SECRET-ARG" | @secrets])
  end

  test "a process report's state and last message lose their credentials" do
    report = %{
      label: {:gen_server, :terminate},
      report: %{
        name: self(),
        reason: {%RuntimeError{message: "boom"}, [{SdrAgent.Example, :handle, [conn()], []}]},
        last_message: {:event, %{"user" => %{"password" => "SECRET-TYPED"}}},
        state: %{
          private: %{operator_session: %{"user_token" => "SECRET-OPERATOR"}},
          connect_info: %{session: %{"user_token" => "SECRET-CONNECT"}}
        },
        client_info: nil
      }
    }

    filtered = filter(%{level: :error, msg: {:report, report}, meta: %{domain: [:otp]}})

    assert {:report, %{label: {:gen_server, :terminate}}} = filtered.msg
    assert clean?(filtered, ~w(SECRET-TYPED SECRET-OPERATOR SECRET-CONNECT) ++ @secrets)
  end

  test "a parse error's request body is filtered" do
    exception = %Plug.Parsers.ParseError{
      exception: %Jason.DecodeError{position: 3, data: ~s({"password": "SECRET-BODY")}
    }

    filtered =
      filter(%{level: :error, msg: {:string, "x"}, meta: %{crash_reason: {exception, []}}})

    assert clean?(filtered, ["SECRET-BODY"])
  end

  test "an ordinary event passes unchanged" do
    event = %{
      level: :info,
      msg: {:string, "GET /leads"},
      meta: %{request_id: "req-1", otel_trace_id: "abc", otel_span_id: "def", domain: [:elixir]}
    }

    assert filter(event) == event
  end

  test "it never raises" do
    for event <- [%{msg: :weird, meta: :not_a_map}, %{}, :not_an_event] do
      assert filter(event)
    end
  end

  defp unique, do: Integer.to_string(System.unique_integer([:positive]))

  # Logs from a fresh process and waits until it has finished.
  defp log_from_process(fun) do
    {pid, monitor} = spawn_monitor(fun)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 2_000
    pid
  end

  defp debug_level do
    previous = Logger.level()
    on_exit(fn -> Logger.configure(level: previous) end)
    # :debug, so a translated process report prints its state.
    Logger.configure(level: :debug)
  end

  # --- Codex fc6b86ca R4: a decode error's token ---------------------------

  # The parse error Plug itself raises for a JSON `body` (pinned decoder).
  defp parse_error(body) do
    conn =
      :post
      |> Plug.Test.conn("/leads", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    opts = Plug.Parsers.init(parsers: [:json], json_decoder: Jason)
    assert_raise Plug.Parsers.ParseError, fn -> Plug.Parsers.call(conn, opts) end
  end

  # More digits than the decoder accepts in an integer (1024): its error
  # carries them as `token`, which its message prints.
  defp digits_sentinel, do: "4" <> unique() <> String.duplicate("7", 1_100)

  test "a decode error's token inside a parse error is filtered in metadata and Bandit's text" do
    secret = digits_sentinel()
    parse = parse_error(~s({"user": {"pin": #{secret}}}))
    assert %Jason.DecodeError{token: ^secret} = parse.exception, "the fixture carries a token"
    text = Exception.format(:error, parse, [])
    assert text =~ secret, "the fixture's text really prints the token"

    event = %{
      level: :error,
      msg: {:string, text},
      meta: %{domain: [:elixir, :bandit], crash_reason: {parse, []}, request_id: "req-7"}
    }

    filtered = filter(event)

    assert clean?(filtered, [secret])
    # Still the parse error's report, at the position the body failed.
    assert {:string, rendered} = filtered.msg
    rendered = IO.chardata_to_string(rendered)
    assert rendered =~ "Plug.Parsers.ParseError"
    assert rendered =~ "position #{parse.exception.position}"
    assert filtered.meta.request_id == "req-7"

    assert {%Plug.Parsers.ParseError{exception: %Jason.DecodeError{position: position}}, []} =
             filtered.meta.crash_reason

    assert position == parse.exception.position
  end

  test "a decode error anywhere in an event loses its token and data" do
    secret = digits_sentinel()
    {:error, decode} = Jason.decode(~s({"pin": #{secret}}))
    assert decode.token == secret, "the fixture carries a token"

    events = [
      metadata: %{level: :error, msg: {:string, "failed"}, meta: %{reason: decode}},
      report: %{
        level: :error,
        msg: {:report, %{error: %Plug.Parsers.ParseError{exception: decode}}},
        meta: %{}
      },
      format_args: %{level: :error, msg: {"failed: ~p", [decode]}, meta: %{}}
    ]

    for {carrier, event} <- events do
      assert clean?(filter(event), [secret]), "the token survives in #{carrier}"
    end
  end

  test "a parse error's Bandit report is still emitted, its token nowhere in the capture" do
    ref = RawLog.start()
    secret = digits_sentinel()
    parse = parse_error(~s({"pin": #{secret}}))
    meta = %{domain: [:elixir, :bandit], crash_reason: {parse, []}}

    pid = log_from_process(fn -> :logger.error(Exception.format(:error, parse, []), meta) end)

    event = RawLog.report_of(ref, pid)
    refute RawLog.withheld?(event)
    assert RawLog.rendered(event) =~ "Plug.Parsers.ParseError"
    RawLog.assert_absent(ref, [secret])
  end

  # --- Codex fc6b86ca R5: an internal failure fails closed -------------------

  # A stack-frame-shaped term with an improper argument list: its arity
  # (length/1) raises inside the filter.
  @breaking {SdrAgent.Example, :f, [0 | :bad_tail], []}

  test "an internal failure yields a fixed diagnostic without any event content" do
    secret = "SECRET-FALLBACK-" <> unique()

    event = %{
      level: :error,
      msg: {:string, "boom " <> secret},
      meta: %{
        pid: self(),
        gl: self(),
        time: 1_234,
        # Nominally standard keys holding credentials.
        mfa: {SdrAgent.Example, :f, [%{"password" => secret}]},
        domain: [:elixir, secret],
        line: secret,
        file: secret,
        request_id: secret,
        report: @breaking
      },
      extra: secret
    }

    filtered = filter(event)

    assert filtered.msg == {:string, "unrenderable log event (credential redaction)"}
    assert filtered.level == :error
    assert filtered.meta == %{pid: self(), gl: self(), time: 1_234}
    assert clean?(filtered, [secret])
  end

  test "the fixed diagnostic is still emitted through :logger" do
    ref = RawLog.start()
    secret = "SECRET-FALLBACK-" <> unique()
    meta = %{mfa: {SdrAgent.Example, :f, [%{"password" => secret}]}, report: @breaking}

    pid = log_from_process(fn -> :logger.error("boom " <> secret, meta) end)

    event = RawLog.report_of(ref, pid)
    assert RawLog.rendered(event) == "unrenderable log event (credential redaction)"
    RawLog.assert_absent(ref, [secret])
  end

  # --- defence in depth: socket data and connection state --------------------

  defmodule Connection do
    @moduledoc false
    use GenServer

    @impl GenServer
    def init(state), do: {:ok, state}

    @impl GenServer
    def handle_info(_message, _state), do: raise("connection crashed")
  end

  # A real OTP terminate report: a GenServer holding `state` crashes on
  # `message`. Returns the capture ref and the report event.
  defp terminate_report(state, message) do
    ref = RawLog.start()
    {:ok, pid} = GenServer.start(Connection, state)
    monitor = Process.monitor(pid)
    send(pid, message)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 2_000

    terminating? = fn event ->
      RawLog.error?(event) and event.meta[:pid] == pid and
        RawLog.rendered(event) =~ "Last message"
    end

    event = RawLog.await(ref, terminating?, 3_000)
    assert event, "no terminate report from the crashed process was emitted"
    {ref, event}
  end

  defp socket_struct(port) do
    %ThousandIsland.Socket{
      socket: port,
      transport_module: ThousandIsland.Transports.TCP,
      read_timeout: 60_000,
      silent_terminate_on_error: false,
      span: nil
    }
  end

  test "a connection process's terminate report keeps no socket data or connection state" do
    debug_level()
    secret = "SECRET-STATE-" <> unique()
    frame = <<129, 149>> <> :crypto.strong_rand_bytes(25)
    port = hd(Port.list())

    {ref, event} =
      terminate_report({socket_struct(port), %{handler: secret}}, {:tcp, port, frame})

    text = RawLog.rendered(event)
    assert text =~ "connection crashed"
    assert text =~ "[FILTERED: #{byte_size(frame)} bytes]"
    assert text =~ "[FILTERED: connection state]"
    frame_text = frame |> inspect() |> String.trim_leading("<<") |> String.trim_trailing(">>")
    RawLog.assert_absent(ref, [secret, frame, frame_text])
  end

  test "an ordinary process's terminate report keeps its state and last message" do
    debug_level()
    marker = "ORDINARY-" <> unique()

    {_ref, event} = terminate_report(%{marker: marker}, {:work, marker <> "-MESSAGE"})

    text = RawLog.rendered(event)
    assert text =~ marker <> "-MESSAGE"
    assert text =~ ~s(marker: "#{marker}")
  end

  test "socket data anywhere in an event is reduced to its size; other tuples are kept" do
    data = :crypto.strong_rand_bytes(32)
    port = hd(Port.list())
    ssl = {:sslsocket, :fake, self()}

    report = %{
      last_message: {:ssl, ssl, data},
      messages: [{:tcp, port, data}, {:tcp_closed, port}, {:other, port, "kept"}]
    }

    filtered = filter(%{level: :error, msg: {:report, report}, meta: %{}})

    assert {:report,
            %{
              last_message: {:ssl, ^ssl, "[FILTERED: 32 bytes]"},
              messages: [
                {:tcp, ^port, "[FILTERED: 32 bytes]"},
                {:tcp_closed, ^port},
                {:other, ^port, "kept"}
              ]
            }} = filtered.msg

    assert clean?(filtered, [data])
  end
end
