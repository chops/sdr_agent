defmodule SdrAgent.TestSupport.RateLimits do
  @moduledoc """
  Test helper: clears every window of the sign-in and enrollment limiter
  (`SdrAgent.RateLimiter`), so tests start from zero and never couple
  through its node-global counters. Synchronous tests only.
  """

  @doc "Clears the limiter's windows."
  # A capture, and a no-op while the limiter is absent, so a RED fails on
  # its own assertion rather than in setup.
  def reset do
    if Code.ensure_loaded?(SdrAgent.RateLimiter),
      do: Function.capture(SdrAgent.RateLimiter, :reset, 0).(),
      else: :ok
  end
end
