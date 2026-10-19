defmodule SdrAgent.Test.GatedCommand do
  @moduledoc """
  #197: a command run in its own process, held at a gate until the test
  has checked the clock it runs on.

  - `start!/2` spawns the command. It reports `{Clock.source(),
    Clock.utc_now()}` and waits for the gate before running its function,
    so a failed clock check never lets it launch anything. It is killed on
    the test's exit, whatever happened.
  - `open!/3` checks the reported clock within the test's remaining
    budget, then opens the gate.
  - `await!/3` polls a check against the same deadline. A definite return
    or exit of the command before the check holds fails at once, with
    that outcome; it is never read as success.

  One deadline (`deadline/1`) covers the clock report and the awaited
  state, so the gate adds no time to the test's existing bound.
  """
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias SdrAgent.Clock

  defstruct [:pid, :gate, :monitor, :tag]

  @doc "The absolute deadline `within` ms from now."
  def deadline(within), do: System.monotonic_time(:millisecond) + within

  @doc """
  Spawns `fun` gated; its result is sent to the test as `{tag, result}`.
  `:prelude` (a 0-arity function, default none) runs first in the
  command's process, before it reports its clock.
  """
  def start!(tag, fun, opts \\ []) when is_function(fun, 0) do
    test = self()
    gate = make_ref()
    prelude = Keyword.get(opts, :prelude, fn -> :ok end)

    pid =
      spawn(fn ->
        prelude.()
        send(test, {:command_clock, gate, Clock.source(), Clock.utc_now()})

        receive do
          {:open, ^gate} -> send(test, {tag, fun.()})
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    %__MODULE__{pid: pid, gate: gate, monitor: Process.monitor(pid), tag: tag}
  end

  @doc """
  Asserts the command reported `{:test_fixed, now}` before `deadline`,
  then opens its gate. On failure the gate stays shut.
  """
  def open!(%__MODULE__{gate: gate} = command, now, deadline) do
    assert_receive {:command_clock, ^gate, source, reported}, remaining(deadline)

    assert {source, reported} == {:test_fixed, now},
           "#197: the spawned command must run on the test's frozen clock, got " <>
             inspect({source, reported})

    send(command.pid, {:open, gate})
    command
  end

  @doc """
  Polls `check` until it holds or `deadline` passes; true when it held.
  Flunks as soon as the command has returned or exited without it.
  """
  def await!(%__MODULE__{} = command, deadline, check) when is_function(check, 0) do
    poll(command, deadline, check)
  end

  defp poll(command, deadline, check) do
    cond do
      check.() ->
        true

      remaining(deadline) == 0 ->
        false

      true ->
        ended!(command)
        Process.sleep(25)
        poll(command, deadline, check)
    end
  end

  defp ended!(%__MODULE__{tag: tag, monitor: monitor}) do
    receive do
      {^tag, result} ->
        flunk("#197: the command returned before the awaited state: #{inspect(result)}")

      {:DOWN, ^monitor, :process, _pid, reason} ->
        flunk("#197: the command exited before the awaited state: #{inspect(reason)}")
    after
      0 -> :ok
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
