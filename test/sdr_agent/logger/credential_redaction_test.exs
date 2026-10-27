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
      and so are request bodies held by parse errors;
    * a Bandit report's text is re-rendered from the redacted exception
      and stack, so no argument formatted into it survives;
    * ordinary content (request id, trace ids, domain, plain messages) is
      untouched; the filter never raises.

  It runs before Elixir's report translator (so reports are redacted while
  still terms) and after `SdrAgent.Logger.ExceptionFilter`: the install
  order is deterministic.
  """
  use ExUnit.Case, async: true

  @module SdrAgent.Logger.CredentialRedaction

  defp filter(event) do
    assert Code.ensure_loaded?(@module), "#{inspect(@module)} is not defined"
    assert function_exported?(@module, :filter, 2), "#{inspect(@module)}.filter/2 is not defined"
    Function.capture(@module, :filter, 2).(event, [])
  end

  defp clean?(term, secrets) do
    text = inspect(term, limit: :infinity, printable_limit: :infinity)
    Enum.all?(secrets, &(not String.contains?(text, &1)))
  end

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
end
