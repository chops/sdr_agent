defmodule SdrAgent.RateLimiter do
  @moduledoc """
  Fixed-window request counters for the unauthenticated magic-link request
  (Codex M3; no dependency, ADR-0008): one public ETS table owned by this
  supervised process, on this node only.

    * **Fixed UTC windows, not a rolling cooldown.** `hit/3,4` counts one
      request for `key` in the window `div(unix_ms, window_ms)` — aligned
      buckets of `window_ms` (`SdrAgent.Clock`, or an explicit instant) —
      and returns `:ok` while that window's count is within `limit`, else
      `:limited`. Up to twice a limit can pass across one bucket boundary,
      and counters start again from zero when the process (or the node)
      restarts.
    * **Atomic counts.** Each count is one `:ets.update_counter/3`, so
      concurrent requests for one key never exceed its limit.
    * **Bounded retention, atomically.** A row for a new key first takes a
      capacity slot from an atomic counter; a key that gets no slot is
      refused (`:limited`) and never stored, so the table never holds more
      than `max_keys/0` rows, however many distinct keys race. Rows expire
      with their window and are swept every minute (`sweep/1`), which
      frees their slots.
    * **Fail closed.** If the table is unavailable, every hit is
      `:limited`.

  Keys hold no email address in clear (callers pass a client IP tuple or
  the sha256 of a destination address).
  """
  use GenServer

  alias SdrAgent.Clock

  @table __MODULE__
  @slots :__rows__
  @max_keys 10_000
  @sweep_every :timer.minutes(1)

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The most rows the table ever holds."
  @spec max_keys() :: pos_integer()
  def max_keys, do: @max_keys

  @doc "Counts one hit for `key` now (`SdrAgent.Clock`); `:ok` within `limit`, else `:limited`."
  @spec hit(term(), pos_integer(), pos_integer()) :: :ok | :limited
  def hit(key, limit, window_ms), do: hit(key, limit, window_ms, now_ms())

  @doc "Counts one hit for `key` at `now_ms` (Unix milliseconds)."
  @spec hit(term(), pos_integer(), pos_integer(), integer()) :: :ok | :limited
  def hit(key, limit, window_ms, now_ms)
      when is_integer(limit) and limit > 0 and is_integer(window_ms) and window_ms > 0 do
    window = div(now_ms, window_ms)
    row = {key, window_ms, window}

    if stored?(row, (window + 1) * window_ms) and
         :ets.update_counter(@table, row, {2, 1}) <= limit,
       do: :ok,
       else: :limited
  rescue
    # No table, or the row vanished (swept) between the checks: fail closed.
    ArgumentError -> :limited
  end

  @doc "Deletes every row whose window ended at or before `now_ms`, freeing their slots; returns how many."
  @spec sweep(integer()) :: non_neg_integer()
  def sweep(now_ms) do
    deleted =
      :ets.select_delete(@table, [
        {{:_, :_, :"$1"}, [{:is_integer, :"$1"}, {:"=<", :"$1", now_ms}], [true]}
      ])

    if deleted > 0, do: release(deleted)
    deleted
  end

  @doc "Clears every window and slot."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      write_concurrency: true,
      read_concurrency: true
    ])

    schedule_sweep()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep(now_ms())
    schedule_sweep()
    {:noreply, state}
  end

  # Whether `row` exists, creating it only under a capacity slot taken
  # first: the slot counter is incremented atomically, so at most
  # `@max_keys` creators ever hold one; a creator over the bound gives its
  # increment back and stores nothing. A creator that loses the insert race
  # to another for the same row gives its slot back (the winner holds one).
  defp stored?(row, expires_at) do
    cond do
      :ets.member(@table, row) ->
        true

      :ets.update_counter(@table, @slots, {2, 1}, {@slots, 0, :slots}) > @max_keys ->
        release(1)
        false

      :ets.insert_new(@table, {row, 0, expires_at}) ->
        true

      true ->
        release(1)
        true
    end
  end

  defp release(n), do: :ets.update_counter(@table, @slots, {2, -n}, {@slots, 0, :slots})

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_every)

  defp now_ms, do: DateTime.to_unix(Clock.utc_now(), :millisecond)
end
