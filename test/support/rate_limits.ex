defmodule SdrAgent.TestSupport.RateLimits do
  @moduledoc """
  Test helper: clears every window of the magic-link request limiter
  (`SdrAgent.RateLimiter`), so tests that request links start from zero
  and never couple through its node-global counters. Synchronous tests only.
  """

  @doc "Clears the limiter's windows."
  def reset, do: SdrAgent.RateLimiter.reset()
end
