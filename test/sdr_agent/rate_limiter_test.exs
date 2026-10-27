defmodule SdrAgent.RateLimiterTest do
  @moduledoc """
  The fixed-window request limiter (`SdrAgent.RateLimiter`, an ETS table
  owned by a supervised process): a key admits `limit` hits per fixed UTC
  window and refuses the rest until the next window; keys are independent;
  the clock is `SdrAgent.Clock` (injectable) or an explicit instant;
  retention is bounded — expired windows are swept and the table never
  holds more than `max_keys/0` rows, even when distinct new keys race (a
  new key beyond that is refused); an unavailable table refuses every hit.
  """
  # The limiter's table is node-global.
  use ExUnit.Case, async: false

  alias SdrAgent.Clock

  @window 600_000
  @t0 1_793_000_000_000

  # Guarded: the module is called only once it exists (RED stays an assertion).
  defp limiter(fun, args) do
    assert Code.ensure_loaded?(SdrAgent.RateLimiter), "SdrAgent.RateLimiter is not defined"
    apply(Function.capture(SdrAgent.RateLimiter, fun, length(args)), args)
  end

  setup do
    SdrAgent.TestSupport.RateLimits.reset()

    on_exit(fn ->
      SdrAgent.TestSupport.RateLimits.reset()
      Clock.unfreeze()
    end)
  end

  test "a window admits the limit, refuses the rest, and the next window admits again" do
    key = {:test, make_ref()}
    last_ms = @t0 + @window - 1 - rem(@t0, @window)

    for _ <- 1..5, do: assert(:ok = limiter(:hit, [key, 5, @window, @t0]))
    assert :limited = limiter(:hit, [key, 5, @window, @t0])
    assert :limited = limiter(:hit, [key, 5, @window, last_ms])
    assert :ok = limiter(:hit, [key, 5, @window, last_ms + 1])
  end

  test "keys are independent" do
    a = {:test, make_ref()}
    b = {:test, make_ref()}

    assert :ok = limiter(:hit, [a, 1, @window, @t0])
    assert :limited = limiter(:hit, [a, 1, @window, @t0])
    assert :ok = limiter(:hit, [b, 1, @window, @t0])
  end

  test "concurrent hits never admit more than the limit" do
    assert Code.ensure_loaded?(SdrAgent.RateLimiter), "SdrAgent.RateLimiter is not defined"
    key = {:test, make_ref()}

    results =
      1..50
      |> Task.async_stream(fn _ -> limiter(:hit, [key, 7, @window, @t0]) end, max_concurrency: 50)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 7
  end

  test "without an explicit instant the window follows SdrAgent.Clock" do
    key = {:test, make_ref()}
    now = DateTime.utc_now()
    Clock.freeze(now)

    assert :ok = limiter(:hit, [key, 1, @window])
    assert :limited = limiter(:hit, [key, 1, @window])

    Clock.freeze(DateTime.add(now, @window, :millisecond))
    assert :ok = limiter(:hit, [key, 1, @window])
  end

  test "expired windows are swept" do
    key = {:test, make_ref()}
    assert :ok = limiter(:hit, [key, 1, @window, @t0])

    assert limiter(:sweep, [@t0]) == 0
    assert limiter(:sweep, [@t0 + 2 * @window]) == 1
    assert :ok = limiter(:hit, [key, 1, @window, @t0])
  end

  test "at most max_keys live keys are held; a new key beyond them is refused" do
    max = limiter(:max_keys, [])
    assert is_integer(max) and max > 0

    for n <- 1..max, do: assert(:ok = limiter(:hit, [{:fill, n}, 1, @window, @t0]))

    assert :limited = limiter(:hit, [{:fill, :one_more}, 1, @window, @t0])
    # A held key still counts normally.
    assert :limited = limiter(:hit, [{:fill, 1}, 1, @window, @t0])
    assert limiter(:sweep, [@t0 + 2 * @window]) == max
    assert :ok = limiter(:hit, [{:fill, :one_more}, 1, @window, @t0 + 2 * @window])
  end

  test "distinct new keys racing for the last free rows never exceed max_keys" do
    max = limiter(:max_keys, [])
    free = 5

    for n <- 1..(max - free), do: assert(:ok = limiter(:hit, [{:fill, n}, 1, @window, @t0]))

    # All racers start together (a barrier), each with its own new key.
    parent = self()

    racers =
      for n <- 1..64 do
        spawn_link(fn ->
          receive do
            :go -> send(parent, {:raced, limiter(:hit, [{:race, n}, 1, @window, @t0])})
          end
        end)
      end

    Enum.each(racers, &send(&1, :go))

    results =
      for _ <- racers do
        assert_receive {:raced, result}, 5_000
        result
      end

    assert Enum.count(results, &(&1 == :ok)) == free
    assert :limited = limiter(:hit, [{:fill, :late}, 1, @window, @t0])
    # Exactly max_keys rows were held.
    assert limiter(:sweep, [@t0 + 2 * @window]) == max
  end

  test "an unavailable limiter refuses every hit (fail closed)" do
    assert :ok = Supervisor.terminate_child(SdrAgent.Supervisor, SdrAgent.RateLimiter)

    try do
      assert :limited = limiter(:hit, [{:test, make_ref()}, 5, @window, @t0])
    after
      {:ok, _pid} = Supervisor.restart_child(SdrAgent.Supervisor, SdrAgent.RateLimiter)
    end

    assert :ok = limiter(:hit, [{:test, make_ref()}, 5, @window, @t0])
  end
end
