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
  replaced by the same summary; its level and every other metadata key are
  kept. Crash reports and framework error logs are covered this way. Any
  other event is returned unchanged. The filter never raises (`:logger`
  would remove it): an internal failure yields a content-free event.
  """

  alias SdrAgent.Repo.SafeMetadata

  @id :sdr_agent_exception_filter

  @doc "Attaches the filter as a primary logger filter (idempotent)."
  @spec attach() :: :ok | {:error, term()}
  def attach do
    _ = :logger.remove_primary_filter(@id)
    :logger.add_primary_filter(@id, {&__MODULE__.filter/2, []})
  end

  @doc "The filter function (`:logger` primary filter API)."
  @spec filter(:logger.log_event(), term()) :: :logger.log_event()
  def filter(%{msg: msg, meta: meta} = event, _opts) do
    case SafeMetadata.find_raw_error(msg) || SafeMetadata.find_raw_error(meta) do
      nil -> event
      error -> rewrite(event, SafeMetadata.error_summary(error))
    end
  rescue
    # `:logger` removes a filter that raises, which would silently drop this
    # control: an internal failure yields a content-free event instead.
    _exception ->
      %{event | msg: {:string, "unrenderable log event (exception filter)"}, meta: %{}}
  end

  def filter(event, _opts), do: event

  defp rewrite(%{msg: msg, meta: meta} = event, summary) do
    message =
      case SafeMetadata.find_raw_error(msg) do
        nil -> msg
        _error -> {:string, "sanitized error report: " <> summary}
      end

    meta =
      Map.new(meta, fn {key, value} ->
        case SafeMetadata.find_raw_error(value) do
          nil -> {key, value}
          error -> {key, "sanitized: " <> SafeMetadata.error_summary(error)}
        end
      end)

    %{event | msg: message, meta: meta}
  end
end
