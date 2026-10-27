defmodule SdrAgent.TestSupport.RawLog do
  @moduledoc """
  Test helper: captures raw `:logger` events (message AND metadata, after
  the primary filters such as `SdrAgent.Logger.ExceptionFilter`, before any
  formatter) by adding a `:logger` handler that forwards every event to the
  test process. Assertions then see exactly what any handler would receive,
  not only what the console formatter happens to print.

  The capture is complete and append-only (Codex R3): every event received
  while waiting (`await/3`, `await_error/3`, `settle/2`) is kept, matching
  or not, and `drain/1` returns all of them plus any still in the mailbox,
  in arrival order. A wait runs against one monotonic deadline, however
  many unrelated events arrive. Waits can be correlated to one process
  (`await/3` with a predicate on `meta.pid`).

  The handler is removed when the test exits. Events of every process are
  forwarded; tests correlate by process and by a unique sentinel.
  """

  @error_levels [:emergency, :alert, :critical, :error]

  @doc "Starts forwarding raw events to the calling process; returns the capture ref."
  @spec start() :: reference()
  def start do
    ref = make_ref()
    id = :"sdr_raw_log_#{System.unique_integer([:positive])}"
    Process.put({__MODULE__, ref}, [])
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

  @doc "Whether `event` is at error level or above."
  @spec error?(map()) :: boolean()
  def error?(%{level: level}), do: level in @error_levels
  def error?(_event), do: false

  @doc """
  Waits until `deadline_ms` from now (one monotonic deadline) for an event
  matching `pred`; returns it, or nil. Every event received meanwhile is
  kept in the capture.
  """
  @spec await(reference(), (map() -> boolean()), non_neg_integer()) :: map() | nil
  def await(ref, pred, timeout \\ 3_000) do
    do_await(ref, pred, System.monotonic_time(:millisecond) + timeout)
  end

  @doc "`await/3` for an error-or-higher event whose `domain` includes `domain`."
  @spec await_error(reference(), atom(), non_neg_integer()) :: map() | nil
  def await_error(ref, domain, timeout \\ 3_000) do
    await(ref, &(error?(&1) and domain in List.wrap(&1.meta[:domain])), timeout)
  end

  @doc "Keeps every event received within the next `ms` (one deadline); returns the complete capture."
  @spec settle(reference(), non_neg_integer()) :: [map()]
  def settle(ref, ms) do
    _ = do_await(ref, fn _event -> false end, System.monotonic_time(:millisecond) + ms)
    drain(ref)
  end

  @doc "The complete capture: every kept event plus those still in the mailbox, in arrival order."
  @spec drain(reference()) :: [map()]
  def drain(ref) do
    receive do
      {^ref, event} ->
        keep(ref, event)
        drain(ref)
    after
      0 -> ref |> buffer() |> Enum.reverse()
    end
  end

  defp do_await(ref, pred, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^ref, event} ->
        keep(ref, event)
        if pred.(event), do: event, else: do_await(ref, pred, deadline)
    after
      remaining -> nil
    end
  end

  defp keep(ref, event), do: Process.put({__MODULE__, ref}, [event | buffer(ref)])
  defp buffer(ref), do: Process.get({__MODULE__, ref}, [])

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
