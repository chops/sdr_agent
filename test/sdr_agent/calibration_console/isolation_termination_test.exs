defmodule SdrAgent.CalibrationConsole.IsolationTerminationTest do
  @moduledoc """
  R0-07 slice E4c-b code-review evidence (Codex 01a13550): every BEAM
  process a preflight starts — its short-lived owner and the owner's
  unnamed reaper — has terminated once it returns (within a short bound),
  on success and on failure, and no port is left. A port count alone is
  not proof, so this compares the VM's whole process list.
  """
  use ExUnit.Case, async: false

  alias SdrAgent.CalibrationConsole.Isolation

  @bound_ms 3_000

  setup do
    assert Code.ensure_loaded?(Isolation), "SdrAgent.CalibrationConsole.Isolation is not defined"
    :ok
  end

  test "a passing preflight leaves no process it started" do
    assert_terminates(fn -> assert :ok = Isolation.preflight([]) end)
  end

  test "a failing preflight leaves no process it started" do
    assert_terminates(fn ->
      assert {:error, :calibration_isolation_unavailable} =
               Isolation.preflight(target: "printf ready")
    end)
  end

  defp assert_terminates(run) do
    before = MapSet.new(Process.list())
    ports = MapSet.new(Port.list())
    run.()

    leftover = await(fn -> Enum.reject(Process.list(), &MapSet.member?(before, &1)) end)
    assert leftover == [], "processes still alive: #{inspect(describe(leftover))}"
    assert Enum.reject(Port.list(), &MapSet.member?(ports, &1)) == []
  end

  defp await(list, deadline \\ System.monotonic_time(:millisecond) + @bound_ms) do
    case list.() do
      [] ->
        []

      left ->
        if System.monotonic_time(:millisecond) >= deadline do
          left
        else
          Process.sleep(20)
          await(list, deadline)
        end
    end
  end

  defp describe(pids), do: Enum.map(pids, &{&1, Process.info(&1, [:current_function])})
end
