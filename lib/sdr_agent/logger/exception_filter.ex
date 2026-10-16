defmodule SdrAgent.Logger.ExceptionFilter do
  @moduledoc """
  The primary `:logger` filter `:sdr_agent_exception_filter` (ADR-0005 C4
  amendment, "Error boundaries and automatic reports"), attached at
  application start (`attach/0`).

  A log event whose message (string, report or format arguments) or
  metadata holds a Postgrex, DBConnection or Ash error struct
  (`SdrAgent.Repo.SafeMetadata.find_raw_error/1`) is rewritten: its message
  becomes the sanitized summary (`SafeMetadata.error_summary/1`, fixed
  identifiers only) and each metadata value holding such a struct is
  replaced by the same summary, and a metadata key holding one is dropped
  with its value; its level and every other metadata entry are kept. Crash
  reports and framework error logs are covered this way. Any other event is
  returned unchanged. An event too large for the bounded scan fails closed:
  it becomes the content-free `scan_limit` event, with its level and only
  the standard logger metadata whose value is validated as a bounded safe
  shape (`pid`/`gl` pids, `time` and `line` integers, `mfa` an `{atom,
  atom, arity}`, `file` a bounded string or charlist, `domain` a bounded
  list of atoms); anything else is dropped. The filter never raises (`:logger`
  would remove it): an internal failure yields a content-free event.
  """

  alias SdrAgent.Repo.SafeMetadata

  @id :sdr_agent_exception_filter
  @max_file 1_024
  @max_domain 16

  @doc "Attaches the filter as a primary logger filter (idempotent)."
  @spec attach() :: :ok | {:error, term()}
  def attach do
    _ = :logger.remove_primary_filter(@id)
    :logger.add_primary_filter(@id, {&__MODULE__.filter/2, []})
  end

  @doc "The filter function (`:logger` primary filter API)."
  @spec filter(:logger.log_event(), term()) :: :logger.log_event()
  def filter(%{msg: msg, meta: meta} = event, _opts) do
    case {SafeMetadata.find_raw_error(msg), SafeMetadata.find_raw_error(meta)} do
      {nil, nil} ->
        event

      {msg_error, meta_error} when :scan_limit in [msg_error, meta_error] ->
        scan_limit(event)

      {msg_error, meta_error} ->
        rewrite(event, SafeMetadata.error_summary(msg_error || meta_error))
    end
  rescue
    # `:logger` removes a filter that raises, which would silently drop this
    # control: an internal failure yields a content-free event instead.
    _exception ->
      %{event | msg: {:string, "unrenderable log event (exception filter)"}, meta: %{}}
  end

  def filter(event, _opts), do: event

  # Fail closed: an event too large to scan may hold a raw error, so it
  # becomes content-free: the level, and only standard logger metadata whose
  # value is separately validated as a bounded safe shape; all else dropped.
  defp scan_limit(%{meta: meta} = event) do
    %{
      event
      | msg: {:string, "sanitized error report: scan_limit"},
        meta: meta |> Enum.filter(&safe_standard?/1) |> Map.new()
    }
  end

  defp safe_standard?({:pid, pid}), do: is_pid(pid)
  defp safe_standard?({:gl, pid}), do: is_pid(pid)
  defp safe_standard?({:time, time}), do: is_integer(time)
  defp safe_standard?({:line, line}), do: is_integer(line)

  defp safe_standard?({:mfa, {m, f, a}}),
    do: is_atom(m) and is_atom(f) and is_integer(a) and a >= 0

  defp safe_standard?({:file, file}) when is_binary(file),
    do: byte_size(file) <= @max_file and String.valid?(file)

  defp safe_standard?({:file, file}) when is_list(file),
    do: length(file) <= @max_file and Enum.all?(file, &(is_integer(&1) and &1 in 0..0x10FFFF))

  defp safe_standard?({:domain, domain}) when is_list(domain),
    do: length(domain) <= @max_domain and Enum.all?(domain, &is_atom/1)

  defp safe_standard?(_entry), do: false

  defp rewrite(%{msg: msg, meta: meta} = event, summary) do
    message =
      case SafeMetadata.find_raw_error(msg) do
        nil -> msg
        _error -> {:string, "sanitized error report: " <> summary}
      end

    # A key holding a raw error (or unscannable) is dropped with its value;
    # a value holding one is replaced by the summary.
    meta =
      for {key, value} <- meta, is_nil(SafeMetadata.find_raw_error(key)), into: %{} do
        case SafeMetadata.find_raw_error(value) do
          nil -> {key, value}
          error -> {key, "sanitized: " <> SafeMetadata.error_summary(error)}
        end
      end

    %{event | msg: message, meta: meta}
  end
end
