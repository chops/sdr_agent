defmodule SdrAgent.Logger.CredentialRedaction do
  @moduledoc """
  The primary `:logger` filter `:sdr_agent_credential_redaction` (Codex
  R1): removes credential-bearing data from EVERY log event, whatever
  process, route or level it comes from, as the event's terms (message
  report or format arguments, and every metadata value) are walked:

    * a `Plug.Conn` becomes `%{method, request_path, status}` — never its
      headers, cookies, query, params, body, session, assigns or private
      data; a magic-link path keeps its prefix and loses its token
      segments; a conn without a status gets the status of the event's
      reported exception (`Plug.Exception.status/1`), as Bandit answers;
    * a stack frame `{module, function, args, location}` keeps its arity,
      never its arguments;
    * a map or keyword entry (or any `{key, value}` pair) whose atom or
      string key names a credential — `token`, `password`, `passwd`,
      `secret`, `cookie`, `authorization`, `session`, `api_key`,
      `private_key`, `credential` — keeps its key, its value replaced by
      `"[FILTERED]"` (so request headers, session maps, `user_token`,
      `_csrf_token`, `hashed_password`, LiveView `connect_info` sessions);
    * a `Jason.DecodeError` loses both fields built from the request
      body, `data` (the body) and `token` (the slice its message prints);
      its message then reports only the position (Codex fc6b86ca R4);
    * socket data in a `{:tcp | :ssl, socket, data}` message (a connection
      process's last message: a masked WebSocket frame is reversible)
      keeps only its size, and a ThousandIsland connection process's state
      `{%ThousandIsland.Socket{}, state}` (buffers, the WebSocket transport
      and its decoded session) is dropped whole: defence in depth behind
      the transport's tag;
    * a Bandit report (`domain` includes `:bandit`) whose text is a
      formatted exception is re-rendered from the redacted exception and
      stack (`Exception.format/3`), so no argument formatted into its text
      survives.

  Plain strings are not parsed: free text written by other code is out of
  its reach, which is why credential-bearing requests and processes are
  also tagged so `SdrAgent.Logger.ExceptionFilter` withholds their reports
  whole (`SdrAgentWeb.SensitiveAuth`). Request ids, trace ids, domains and
  other metadata are unchanged; an event with nothing to redact is
  returned equal to itself.

  **Order.** `attach/0` installs it so it runs after the exception filter
  (attached after it, `:logger` prepends) and before Elixir's report
  translator (`:logger_translator`, re-added after it), so OTP reports are
  redacted while still terms, before their state and last message are
  formatted into text. The walk is bounded: a subterm beyond the budget
  becomes `"[REDACTED: scan limit]"`. The filter never raises (`:logger`
  would drop it): an internal failure yields a new, fixed diagnostic with
  no event content, only a validated level, pid, group leader and time
  (Codex fc6b86ca R5).
  """

  @id :sdr_agent_credential_redaction
  @translator :logger_translator
  @filtered "[FILTERED]"
  @scan_limit "[REDACTED: scan limit]"
  @budget 200_000
  @sensitive ~w(token password passwd secret cookie authorization session api_key private_key credential)
  # Exception fields built from request input, filtered whatever their
  # names: a JSON decode error's body (`data`) and the slice of it its
  # message prints (`token`, Codex fc6b86ca R4). With a binary token its
  # message reads only the position and the token, never `data`.
  @input_fields %{Jason.DecodeError => [:data, :token]}
  @connection_state "[FILTERED: connection state]"
  @unrenderable "unrenderable log event (credential redaction)"
  @levels [:emergency, :alert, :critical, :error, :warning, :notice, :info, :debug]

  @doc """
  Installs the filter before Elixir's report translator (idempotent). Call
  it before `SdrAgent.Logger.ExceptionFilter.attach/0`.
  """
  @spec attach() :: :ok | {:error, term()}
  def attach do
    # :logger runs primary filters in list order and add_primary_filter/2
    # prepends: re-adding the translator first, then this filter, puts this
    # filter just ahead of the translator.
    translator = List.keyfind(:logger.get_primary_config().filters, @translator, 0)
    _ = :logger.remove_primary_filter(@id)

    with {@translator, filter} <- translator do
      _ = :logger.remove_primary_filter(@translator)
      :ok = :logger.add_primary_filter(@translator, filter)
    end

    :logger.add_primary_filter(@id, {&__MODULE__.filter/2, []})
  end

  @doc "The filter function (`:logger` primary filter API)."
  @spec filter(term(), term()) :: term()
  def filter(%{meta: meta} = event, _opts) when is_map(meta) do
    status = exception_status(meta)
    budget = make_ref()
    Process.put(budget, @budget)

    try do
      redacted_meta =
        Map.new(meta, fn {key, value} -> {key, entry(key, value, budget, status)} end)

      case event do
        %{msg: msg} ->
          %{event | meta: redacted_meta, msg: message(msg, redacted_meta, budget, status)}

        _no_message ->
          %{event | meta: redacted_meta}
      end
    after
      Process.delete(budget)
    end
  rescue
    _exception -> content_free(event)
  catch
    _kind, _reason -> content_free(event)
  end

  def filter(event, _opts), do: event

  # --- messages --------------------------------------------------------

  defp message({:report, report}, _meta, budget, status),
    do: {:report, walk(report, budget, status)}

  defp message({:string, _text} = msg, meta, _budget, _status) do
    case {bandit?(meta), Map.get(meta, :crash_reason)} do
      {true, {reason, stack}} when is_list(stack) -> {:string, render(reason, stack)}
      _other -> msg
    end
  end

  defp message({format, args}, _meta, budget, status) when is_list(args),
    do: {format, walk(args, budget, status)}

  defp message(msg, _meta, _budget, _status), do: msg

  defp bandit?(meta), do: :bandit in List.wrap(Map.get(meta, :domain))

  # Bandit's text is Exception.format(kind, reason, stack); re-render it
  # from the already-redacted crash reason.
  defp render({:nocatch, value}, stack), do: Exception.format(:throw, value, stack)

  defp render(reason, stack) do
    kind = if is_exception(reason), do: :error, else: :exit
    Exception.format(kind, reason, stack)
  rescue
    _unformattable -> "** (redacted report)"
  end

  # --- terms -----------------------------------------------------------

  defp entry(key, value, budget, status) do
    if sensitive_key?(key), do: @filtered, else: walk(value, budget, status)
  end

  defp walk(term, budget, status) do
    case Process.get(budget) do
      left when left > 0 ->
        Process.put(budget, left - 1)
        redact(term, budget, status)

      _exhausted ->
        @scan_limit
    end
  end

  defp redact(%Plug.Conn{} = conn, _budget, status), do: conn_summary(conn, status)

  defp redact(%{__struct__: module} = struct, budget, status) do
    input = Map.get(@input_fields, module, [])

    struct
    |> Map.from_struct()
    |> Map.new(fn {key, value} ->
      if key in input, do: {key, @filtered}, else: {key, entry(key, value, budget, status)}
    end)
    |> Map.put(:__struct__, module)
  end

  defp redact(map, budget, status) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, entry(key, value, budget, status)} end)

  defp redact(list, budget, status) when is_list(list), do: walk_list(list, budget, status)

  defp redact({module, function, args, location}, _budget, _status)
       when is_atom(module) and is_atom(function) and is_list(args) and is_list(location),
       do: {module, function, length(args), location}

  # Socket data a connection process received (a masked WebSocket frame is
  # reversible) keeps only its size.
  defp redact({tag, socket, data}, budget, status) when tag in [:tcp, :ssl] and is_binary(data),
    do: {tag, walk(socket, budget, status), "[FILTERED: #{byte_size(data)} bytes]"}

  defp redact({tag, socket, data}, budget, status) when tag in [:tcp, :ssl] and is_list(data),
    do: {tag, walk(socket, budget, status), "[FILTERED: socket data]"}

  # A ThousandIsland connection process's state (`{socket, handler_state}`:
  # buffers, the WebSocket transport, its decoded session) is dropped whole.
  defp redact({%{__struct__: ThousandIsland.Socket}, _state}, _budget, _status),
    do: @connection_state

  defp redact({key, value}, budget, status) when is_atom(key) or is_binary(key),
    do: {key, entry(key, value, budget, status)}

  defp redact(tuple, budget, status) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&walk(&1, budget, status)) |> List.to_tuple()
  end

  defp redact(other, _budget, _status), do: other

  # Proper and improper lists (iodata) alike.
  defp walk_list([], _budget, _status), do: []

  defp walk_list([head | tail], budget, status) when is_list(tail),
    do: [walk(head, budget, status) | walk_list(tail, budget, status)]

  defp walk_list([head | tail], budget, status),
    do: [walk(head, budget, status) | walk(tail, budget, status)]

  defp sensitive_key?(key) when is_atom(key), do: key |> Atom.to_string() |> sensitive_name?()
  defp sensitive_key?(key) when is_binary(key), do: sensitive_name?(key)
  defp sensitive_key?(_key), do: false

  defp sensitive_name?(name) do
    name = String.downcase(name)
    Enum.any?(@sensitive, &String.contains?(name, &1))
  end

  # --- conns -----------------------------------------------------------

  defp conn_summary(conn, status) do
    %{
      method: if(is_binary(conn.method), do: conn.method),
      request_path: redact_path(conn.request_path),
      status: conn.status || status
    }
  end

  # A magic-link path keeps its segments up to `magic_link` (in any
  # spelling the router decodes) and loses the rest.
  defp redact_path(path) when is_binary(path) do
    segments = String.split(path, "/")

    case Enum.find_index(segments, &magic_link?/1) do
      nil -> path
      index -> Enum.join(Enum.take(segments, index + 1) ++ [@filtered], "/")
    end
  end

  defp redact_path(_path), do: nil

  defp magic_link?(segment), do: segment |> URI.decode() |> String.downcase() == "magic_link"

  defp exception_status(meta) do
    case Map.get(meta, :crash_reason) do
      {reason, _stack} when is_exception(reason) -> Plug.Exception.status(reason)
      {_reason, _stack} -> 500
      _none -> nil
    end
  rescue
    _unknown -> 500
  end

  # --- failure ---------------------------------------------------------

  # Fail closed (Codex fc6b86ca R5): a new event, not an edited copy, built
  # only from separately validated values: a known level (else :error), a
  # fixed message, and the pid, group leader and time when they are a pid,
  # a pid and an integer. Nothing else of the event survives, whatever its
  # key names; nothing here can raise.
  defp content_free(event) do
    meta = Map.get(event, :meta)
    level = Map.get(event, :level)

    %{
      level: if(level in @levels, do: level, else: :error),
      msg: {:string, @unrenderable},
      meta: validated(meta)
    }
  end

  defp validated(meta) do
    [pid: &is_pid/1, gl: &is_pid/1, time: &is_integer/1]
    |> Enum.flat_map(fn {key, valid?} ->
      value = Map.get(meta, key)
      if valid?.(value), do: [{key, value}], else: []
    end)
    |> Map.new()
  end
end
