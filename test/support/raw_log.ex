defmodule SdrAgent.TestSupport.RawLog do
  @moduledoc """
  Test helper: captures raw `:logger` events (message AND metadata, after
  the primary filters such as `SdrAgent.Logger.ExceptionFilter`, before any
  formatter) by adding a `:logger` handler that forwards every event to the
  test process. Assertions then see exactly what any handler would receive,
  not only what the console formatter happens to print.

  The handler is removed when the test exits. Events of every process are
  forwarded; tests correlate by a unique sentinel and by metadata.
  """

  @error_levels [:emergency, :alert, :critical, :error]

  @doc "Starts forwarding raw events to the calling process; returns the capture ref."
  @spec start() :: reference()
  def start do
    ref = make_ref()
    id = :"sdr_raw_log_#{System.unique_integer([:positive])}"
    :ok = :logger.add_handler(id, __MODULE__, %{level: :all, config: %{pid: self(), ref: ref}})
    ExUnit.Callbacks.on_exit(fn -> :logger.remove_handler(id) end)
    ref
  end

  @doc false
  # The :logger handler callback: forwards the event unchanged.
  def log(event, %{config: %{pid: pid, ref: ref}}) do
    send(pid, {ref, event})
    :ok
  end

  @doc """
  Waits up to `timeout` ms for an error-or-higher event whose metadata
  `domain` includes `domain` (Elixir's Logger prepends `:elixir`); returns
  it, or nil.
  """
  @spec await_error(reference(), atom(), timeout()) :: map() | nil
  def await_error(ref, domain, timeout \\ 3_000) do
    receive do
      {^ref, %{level: level, meta: meta} = event} when level in @error_levels ->
        if domain in List.wrap(Map.get(meta, :domain)),
          do: event,
          else: await_error(ref, domain, timeout)
    after
      timeout -> nil
    end
  end

  @doc "Every event received so far for `ref` (drains the mailbox of them)."
  @spec drain(reference()) :: [map()]
  def drain(ref) do
    receive do
      {^ref, event} -> [event | drain(ref)]
    after
      0 -> []
    end
  end

  @doc "Whether `event`'s message or metadata contains `secret` anywhere."
  @spec contains?(map(), String.t()) :: boolean()
  def contains?(event, secret) do
    rendered =
      try do
        rendered(event)
      rescue
        _unrenderable -> ""
      end

    String.contains?(rendered, secret) or
      String.contains?(inspect(event, limit: :infinity, printable_limit: :infinity), secret)
  end

  @doc "The event's message rendered as text (string, report or format)."
  @spec rendered(map()) :: String.t()
  def rendered(%{msg: {:string, chardata}}), do: IO.chardata_to_string(chardata)

  def rendered(%{msg: {:report, report}}),
    do: inspect(report, limit: :infinity, printable_limit: :infinity)

  def rendered(%{msg: {format, args}}),
    do: format |> :io_lib.format(args) |> IO.chardata_to_string()

  def rendered(_event), do: ""
end
