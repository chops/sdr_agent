defmodule SdrAgent.RateLimiter do
  @moduledoc """
  Fixed-window request counters for the unauthenticated magic-link request
  (Codex M3; no dependency, ADR-0008): one public ETS table owned by this
  supervised process.

    * `hit/3,4` counts one request for `key` in the current window of
      `window_ms` (`SdrAgent.Clock`, or an explicit instant) and returns
      `:ok` while the count is within `limit`, else `:limited`. The
      increment is one atomic `:ets.update_counter/4`, so concurrent
      requests never exceed a limit.
    * Retention is bounded: each row expires with its window and is swept
      every minute (`sweep/1`), and the table holds at most `max_keys/0`
      rows (give or take concurrent first inserts) — a new key beyond that is
      refused (`:limited`), never stored.
    * Fail closed: if the table is unavailable, every hit is `:limited`.

  Keys hold no email address in clear (callers pass a client IP tuple or
  the sha256 of a destination address). Counters are per node and reset on restart.
  """
  use GenServer

  alias SdrAgent.Clock

  @table __MODULE__
  @max_keys 10_000
  @sweep_every :timer.minutes(1)

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The most rows the table holds."
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
    expires_at = (window + 1) * window_ms

    cond do
      not room_for?(row) -> :limited
      :ets.update_counter(@table, row, {2, 1}, {row, 0, expires_at}) <= limit -> :ok
      true -> :limited
    end
  rescue
    ArgumentError -> :limited
  end

  @doc "Deletes every row whose window ended at or before `now_ms`; returns how many."
  @spec sweep(integer()) :: non_neg_integer()
  def sweep(now_ms) do
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now_ms}], [true]}])
  end

  @doc "Clears every window."
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

  # A row that exists may always count; a new one only while there is room.
  defp room_for?(row), do: :ets.member(@table, row) or :ets.info(@table, :size) < @max_keys

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_every)

  defp now_ms, do: DateTime.to_unix(Clock.utc_now(), :millisecond)
end
