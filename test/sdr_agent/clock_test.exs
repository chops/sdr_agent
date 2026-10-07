defmodule SdrAgent.ClockTest do
  use ExUnit.Case, async: true

  alias SdrAgent.Clock

  test "returns a UTC microsecond datetime from the system clock by default" do
    now = Clock.utc_now()
    assert now.time_zone == "Etc/UTC"
    assert {_, 6} = now.microsecond
    assert Clock.source() == :system_utc
  end

  test "a frozen clock is visible to the process and its tasks" do
    fixed = ~U[2026-10-06 08:00:00.000000Z]
    Clock.freeze(fixed)
    assert Clock.utc_now() == fixed
    assert Clock.source() == :test_fixed

    assert Task.await(Task.async(fn -> {Clock.utc_now(), Clock.source()} end)) ==
             {fixed, :test_fixed}

    Clock.unfreeze()
    assert Clock.source() == :system_utc
  end
end
