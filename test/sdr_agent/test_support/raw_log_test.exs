defmodule SdrAgent.TestSupport.RawLogTest do
  @moduledoc """
  The raw-event oracle itself (Codex R3): every event captured while
  waiting for an expected one stays in the capture the secrecy assertions
  scan, the wait runs against one monotonic deadline however many
  unrelated events arrive, and a wait can be correlated to one process, so
  an unrelated event is never accepted in its place.
  """
  # A :logger handler sees every process's events.
  use ExUnit.Case, async: false

  require Logger

  alias SdrAgent.TestSupport.RawLog

  defp sentinel, do: "SENTINEL" <> Integer.to_string(System.unique_integer([:positive]))

  # Logs from a fresh process and waits until it has finished.
  defp log_from_process(fun) do
    {pid, ref} = spawn_monitor(fun)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
    pid
  end

  test "an error received while awaiting a later one stays in the capture" do
    ref = RawLog.start()
    secret = sentinel()

    log_from_process(fn -> Logger.error("an unrelated failure #{secret}") end)
    log_from_process(fn -> Logger.error("an expected report", domain: [:bandit]) end)

    assert %{} = RawLog.await_error(ref, :bandit)
    captured = RawLog.drain(ref)

    assert Enum.any?(captured, &RawLog.contains?(&1, secret)),
           "an event received before the awaited one was dropped from the capture"
  end

  test "unrelated events arriving during a wait do not extend its deadline" do
    ref = RawLog.start()

    chatter =
      spawn(fn ->
        for _ <- 1..30 do
          Logger.error("unrelated")
          Process.sleep(50)
        end
      end)

    started = System.monotonic_time(:millisecond)
    assert RawLog.await_error(ref, :bandit, 300) == nil
    elapsed = System.monotonic_time(:millisecond) - started
    Process.exit(chatter, :kill)

    assert elapsed < 800, "the wait took #{elapsed} ms for a 300 ms deadline"
  end

  test "a correlated wait accepts only the given process's event" do
    assert function_exported?(RawLog, :await, 3), "RawLog.await/3 is not defined"
    ref = RawLog.start()

    other = log_from_process(fn -> Logger.error("other process", domain: [:bandit]) end)

    {target, target_ref} =
      spawn_monitor(fn ->
        receive do
          :go -> Logger.error("target process", domain: [:bandit])
        end
      end)

    send(target, :go)
    assert_receive {:DOWN, ^target_ref, :process, ^target, _reason}, 2_000

    error? = Function.capture(RawLog, :error?, 1)
    await = Function.capture(RawLog, :await, 3)
    event = await.(ref, fn e -> error?.(e) and e.meta[:pid] == target end, 2_000)

    assert event.meta[:pid] == target
    refute event.meta[:pid] == other
    assert Enum.any?(RawLog.drain(ref), &(&1.meta[:pid] == other)), "the other event was dropped"
  end
end
