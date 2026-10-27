defmodule SdrAgent.TestSupport.RawLogTest do
  @moduledoc """
  The raw-event oracle itself (Codex R3): every event captured while
  waiting for an expected one stays in the capture the secrecy assertions
  scan, the wait runs against one monotonic deadline however many
  unrelated events arrive, and a wait can be correlated to one process, so
  an unrelated event is never accepted in its place. A secret is found
  anywhere in an event's terms, even where an Inspect implementation
  would hide it.

  The deadline holds even while the queue is never empty (Codex fc6b86ca
  R3): a wait then fails explicitly, everything consumed or still queued
  stays in the capture, and a capture that cannot be completed (overload)
  fails the absence check explicitly instead of passing on a truncation.
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
    log_from_process(fn -> :logger.error("an expected report", %{domain: [:bandit]}) end)

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

    other = log_from_process(fn -> :logger.error("other process", %{domain: [:bandit]}) end)

    {target, target_ref} =
      spawn_monitor(fn ->
        receive do
          :go -> :logger.error("target process", %{domain: [:bandit]})
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

  # Queues `events` for capture `ref` exactly as the handler would.
  defp enqueue(ref, events) do
    config = %{config: %{pid: self(), ref: ref}}
    Enum.each(events, &RawLog.log(&1, config))
  end

  defp info(text), do: %{level: :info, msg: {:string, text}, meta: %{}}

  # Codex fc6b86ca R3: a deadline is enforced even while the queue is never
  # empty, the wait then fails explicitly rather than accepting a late
  # event, and everything consumed or still queued stays in the capture.
  test "a continuously non-empty queue cannot carry a wait past its deadline" do
    ref = RawLog.start()
    secret = sentinel()
    expected = %{level: :error, msg: {:string, "expected"}, meta: %{domain: [:bandit]}}
    leak = %{level: :error, msg: {:string, "preceding #{secret}"}, meta: %{}}
    enqueue(ref, [leak | Enum.map(1..400, &info("filler #{&1}"))] ++ [expected])

    # Each event costs 5 ms to examine: the queue outlasts the deadline.
    slow = fn event ->
      Process.sleep(5)
      event.msg == {:string, "expected"}
    end

    started = System.monotonic_time(:millisecond)
    assert RawLog.await(ref, slow, 100) == nil, "a wait accepted an event after its deadline"
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 600, "the wait took #{elapsed} ms for a 100 ms deadline"

    captured = RawLog.drain(ref)
    assert Enum.any?(captured, &RawLog.contains?(&1, secret)), "the preceding event was dropped"
    assert Enum.member?(captured, expected), "a still-queued event is missing from the capture"
  end

  test "an overloaded capture fails explicitly, never a silent privacy pass" do
    ref = RawLog.start()
    enqueue(ref, Enum.map(1..25_000, fn _ -> info("flood") end))

    assert_raise ExUnit.AssertionError, ~r/overloaded/, fn ->
      RawLog.assert_absent(ref, [sentinel()], 0)
    end
  end

  test "a wait for a report that never comes fails explicitly" do
    ref = RawLog.start()
    silent = log_from_process(fn -> :ok end)

    assert_raise ExUnit.AssertionError, ~r/no error report/, fn ->
      RawLog.report_of(ref, silent, 100)
    end
  end

  test "a secret inside a struct whose Inspect hides it is still found" do
    secret = sentinel()
    socket = %Phoenix.LiveView.Socket{private: %{operator_session: %{"user_token" => secret}}}
    refute inspect(socket) =~ secret, "the fixture really hides the field from inspect"

    event = %{level: :error, msg: {:string, "x"}, meta: %{crash_reason: {:boom, [socket]}}}
    assert RawLog.contains?(event, secret)
  end
end
