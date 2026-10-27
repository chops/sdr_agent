defmodule SdrAgent.RateLimiterTest do
  @moduledoc """
  The fixed-window request limiter (`SdrAgent.RateLimiter`, ETS owned by a
  supervised process): a key admits `limit` hits per window and refuses the
  rest until the next window; keys are independent; the clock is
  `SdrAgent.Clock` (injectable) or an explicit instant; expired windows are
  swept.
  """
  # The limiter's table is node-global.
  use ExUnit.Case, async: false

  alias SdrAgent.Clock
  alias SdrAgent.RateLimiter

  @window 600_000

  setup do
    RateLimiter.reset()

    on_exit(fn ->
      RateLimiter.reset()
      Clock.unfreeze()
    end)
  end

  test "a window admits the limit, refuses the rest, and the next window admits again" do
    key = {:test, make_ref()}
    t0 = 1_793_000_000_000

    for _ <- 1..5, do: assert(:ok = RateLimiter.hit(key, 5, @window, t0))
    assert :limited = RateLimiter.hit(key, 5, @window, t0)
    assert :limited = RateLimiter.hit(key, 5, @window, t0 + @window - 1 - rem(t0, @window))
    assert :ok = RateLimiter.hit(key, 5, @window, t0 + @window)
  end

  test "keys are independent" do
    t0 = 1_793_000_000_000
    a = {:test, make_ref()}
    b = {:test, make_ref()}

    assert :ok = RateLimiter.hit(a, 1, @window, t0)
    assert :limited = RateLimiter.hit(a, 1, @window, t0)
    assert :ok = RateLimiter.hit(b, 1, @window, t0)
  end

  test "without an explicit instant the window follows SdrAgent.Clock" do
    key = {:test, make_ref()}
    t0 = DateTime.utc_now()
    Clock.freeze(t0)

    assert :ok = RateLimiter.hit(key, 1, @window)
    assert :limited = RateLimiter.hit(key, 1, @window)

    Clock.freeze(DateTime.add(t0, @window, :millisecond))
    assert :ok = RateLimiter.hit(key, 1, @window)
  end

  test "expired windows are swept" do
    t0 = 1_793_000_000_000
    key = {:test, make_ref()}
    assert :ok = RateLimiter.hit(key, 1, @window, t0)

    assert RateLimiter.sweep(t0) == 0
    assert RateLimiter.sweep(t0 + 2 * @window) == 1
    assert :ok = RateLimiter.hit(key, 1, @window, t0)
  end
end
