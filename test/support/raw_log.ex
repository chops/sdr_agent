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

  Windows (Codex fc6b86ca R3): the deadline is checked before every
  receive, so even a queue that is never empty cannot carry a wait past
  it; a wait that ends there returns nil (`report_of/3` then fails), and
  whatever is still queued stays for the next wait or seal. `drain/1`
  seals the capture at the first instant no event of it is queued, and an
  incomplete capture fails explicitly: more than 20,000 events (overload)
  or a queue that keeps refilling for 2 s. A truncated capture never
  counts as a privacy pass.

  The handler is removed when the test exits. Events of every process are
  forwarded; tests correlate by process and by a unique sentinel.
  """

  import ExUnit.Assertions

  @error_levels [:emergency, :alert, :critical, :error]
  # A capture holds at most this many events: more is an overload, which
  # fails explicitly instead of truncating.
  @max_events 20_000
  # Sealing must finish within this; a queue that keeps refilling fails.
  @seal_ms 2_000
  @withheld "diagnostic withheld: process holds operator input"

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

  @doc """
  Seals and returns the complete capture, in arrival order: every kept
  event plus every event still queued, up to the first instant the mailbox
  holds none for this capture. Fails explicitly, never truncating, when
  the capture exceeds #{@max_events} events or the queue keeps refilling for
  more than #{@seal_ms} ms. Events logged after the seal join the capture at a
  later wait or seal.
  """
  @spec drain(reference()) :: [map()]
  def drain(ref) do
    seal(ref, System.monotonic_time(:millisecond) + @seal_ms)
    ref |> buffer() |> Enum.reverse()
  end

  defp seal(ref, deadline) do
    receive do
      {^ref, event} ->
        keep(ref, event)

        if System.monotonic_time(:millisecond) > deadline,
          do:
            flunk(
              "raw log capture never sealed: events kept arriving for #{@seal_ms} ms; " <>
                "an incomplete capture is not a privacy pass"
            )

        seal(ref, deadline)
    after
      0 -> :ok
    end
  end

  # The deadline is checked before every receive: a queue that is never
  # empty cannot carry a wait past it (a receive with `after 0` still takes
  # a queued message). What is left queued stays for the next wait or seal.
  defp do_await(ref, pred, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      receive do
        {^ref, event} ->
          keep(ref, event)
          if pred.(event), do: event, else: do_await(ref, pred, deadline)
      after
        remaining -> nil
      end
    end
  end

  @doc "The error report of process `pid` (one deadline), asserted to have been emitted."
  @spec report_of(reference(), pid(), non_neg_integer()) :: map()
  def report_of(ref, pid, timeout \\ 3_000) do
    event = await(ref, &(error?(&1) and &1.meta[:pid] == pid), timeout)
    assert event, "no error report from the tested process was emitted"
    event
  end

  @doc "Asserts no secret appears anywhere in the complete capture (after a `settle_ms` settle)."
  @spec assert_absent(reference(), [String.t()], non_neg_integer()) :: [map()]
  def assert_absent(ref, secrets, settle_ms \\ 200) do
    captured = settle(ref, settle_ms)

    for secret <- secrets, is_binary(secret) and secret != "" do
      leaking = Enum.filter(captured, &contains?(&1, secret))

      assert leaking == [],
             "a secret is in #{length(leaking)} of #{length(captured)} raw event(s)"
    end

    captured
  end

  @doc "Whether `event` is `SdrAgent.Logger.ExceptionFilter`'s withheld diagnostic."
  @spec withheld?(map()) :: boolean()
  def withheld?(event), do: rendered(event) == @withheld

  defp keep(ref, event) do
    count = Process.get({__MODULE__, ref, :count}, 0) + 1

    if count > @max_events,
      do:
        flunk(
          "raw log capture overloaded: more than #{@max_events} events; " <>
            "a truncated capture is not a privacy pass"
        )

    Process.put({__MODULE__, ref, :count}, count)
    Process.put({__MODULE__, ref}, [event | buffer(ref)])
  end

  defp buffer(ref), do: Process.get({__MODULE__, ref}, [])

  @doc """
  Whether `event`'s message or metadata contains `secret` anywhere: in the
  rendered message, or in any binary, atom, chardata or closure environment
  among its terms, found by walking the terms themselves (struct fields
  included) rather than their `inspect/2` text, which an Inspect
  implementation may abbreviate or hide (`Phoenix.LiveView.Socket` hides
  its `private`).
  """
  @spec contains?(map(), String.t()) :: boolean()
  def contains?(event, secret) do
    rendered =
      try do
        rendered(event)
      rescue
        _unrenderable -> ""
      end

    String.contains?(rendered, secret) or term_contains?(event, secret)
  end

  defp term_contains?(term, secret) when is_binary(term),
    do: :binary.match(term, secret) != :nomatch

  defp term_contains?(term, secret) when is_atom(term),
    do: term |> Atom.to_string() |> term_contains?(secret)

  defp term_contains?(term, secret) when is_map(term),
    do: Enum.any?(Map.to_list(term), &term_contains?(&1, secret))

  defp term_contains?(term, secret) when is_tuple(term),
    do: term |> Tuple.to_list() |> term_contains?(secret)

  defp term_contains?(term, secret) when is_list(term),
    do: chardata_contains?(term, secret) or list_contains?(term, secret)

  defp term_contains?(term, secret) when is_function(term) do
    {:env, env} = :erlang.fun_info(term, :env)
    term_contains?(env, secret)
  end

  defp term_contains?(_term, _secret), do: false

  # Proper and improper lists alike.
  defp list_contains?([], _secret), do: false

  defp list_contains?([head | tail], secret) when is_list(tail),
    do: term_contains?(head, secret) or list_contains?(tail, secret)

  defp list_contains?([head | tail], secret),
    do: term_contains?(head, secret) or term_contains?(tail, secret)

  # A secret split across the parts of a charlist or iodata.
  defp chardata_contains?(list, secret) do
    list |> IO.chardata_to_string() |> String.contains?(secret)
  rescue
    _not_chardata -> false
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
