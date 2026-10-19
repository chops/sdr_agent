defmodule SdrAgent.Test.GatedCommandTest do
  @moduledoc """
  #197: harness controls for `SdrAgent.Test.GatedCommand`, with synthetic
  commands and no database. They pin the gate, the shared deadline and the
  fail-fast reads; they are not the calibration clock RED.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Clock
  alias SdrAgent.Test.GatedCommand

  @now ~U[2026-10-15 12:00:00.000000Z]

  defp frozen, do: [prelude: fn -> Clock.freeze(@now) end]

  test "a command that returns before the awaited state fails at once, with its result" do
    deadline = GatedCommand.deadline(5_000)

    command =
      GatedCommand.start!(:result, fn -> {:stop, :refused} end, frozen())
      |> GatedCommand.open!(@now, deadline)

    error =
      assert_raise ExUnit.AssertionError, fn ->
        GatedCommand.await!(command, deadline, fn -> false end)
      end

    assert error.message =~ "returned before the awaited state: {:stop, :refused}"
    assert System.monotonic_time(:millisecond) < deadline
  end

  test "a command that exits abnormally before the awaited state fails at once, with its reason" do
    deadline = GatedCommand.deadline(5_000)

    command =
      GatedCommand.start!(:result, fn -> exit(:boom) end, frozen())
      |> GatedCommand.open!(@now, deadline)

    error =
      assert_raise ExUnit.AssertionError, fn ->
        GatedCommand.await!(command, deadline, fn -> false end)
      end

    assert error.message =~ "exited before the awaited state: :boom"
  end

  test "the awaited state counts even if the command returns afterwards" do
    deadline = GatedCommand.deadline(5_000)
    test = self()

    command =
      GatedCommand.start!(
        :result,
        fn ->
          send(test, :reached)
          :done
        end,
        frozen()
      )
      |> GatedCommand.open!(@now, deadline)

    assert_receive :reached, 1_000
    assert_receive {:result, :done}, 1_000
    send(self(), {:result, :done})

    assert GatedCommand.await!(command, deadline, fn -> true end)
  end

  test "a wrong clock keeps the gate shut: the command never runs" do
    test = self()
    command = GatedCommand.start!(:result, fn -> send(test, :ran) end)

    assert_raise ExUnit.AssertionError, ~r/frozen clock, got \{:system_utc/, fn ->
      GatedCommand.open!(command, @now, GatedCommand.deadline(1_000))
    end

    refute_receive :ran, 200
    assert Process.alive?(command.pid)
  end

  test "one deadline: an unmet state stops at the deadline set before the command" do
    deadline = GatedCommand.deadline(300)

    command =
      GatedCommand.start!(:result, fn -> Process.sleep(:infinity) end, frozen())
      |> GatedCommand.open!(@now, deadline)

    refute GatedCommand.await!(command, deadline, fn -> false end)
    assert System.monotonic_time(:millisecond) - deadline < 200
  end
end
