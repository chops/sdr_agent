defmodule SdrAgent.Prototype.TestSeamTest do
  @moduledoc """
  Ruling (a) of the D-237 S1 RED review: the test-build-only seam
  `SdrAgent.Prototype.Authority.TestSeam` scopes prototype runtime to the
  calling process and its explicit local `$callers`; an unrelated process
  and a dead caller contribute nothing; `leave_runtime/0` and `clear/0`
  clean up deterministically. A synthetic snapshot, no database.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Prototype
  alias SdrAgent.Prototype.Authority.TestSeam
  alias SdrAgent.Prototype.Binding

  defp snapshot do
    %Binding{
      id: Ecto.UUID.generate(),
      tenant_id: Ecto.UUID.generate(),
      instance_id: Ecto.UUID.generate(),
      operator_user_id: Ecto.UUID.generate(),
      auditor_user_id: nil,
      dataset_class: "real_prototype",
      policy_id: "d237-prototype/1",
      policy_entry_sha256: String.duplicate("a", 64),
      funding_id: "d237-funding/1",
      witness_mode: "absent",
      database: "sdr_agent_prototype",
      database_oid: 16_384,
      system_identifier: 7_000_000_000_000_000_001,
      bound_at: ~U[2026-10-28 06:00:00.000000Z]
    }
  end

  defp runtime_in(fun) do
    parent = self()
    ref = make_ref()
    fun.(fn -> send(parent, {ref, Prototype.runtime()}) end)
    assert_receive {^ref, runtime}, 2_000
    runtime
  end

  test "the calling process enters and leaves prototype runtime with its snapshot" do
    snap = snapshot()
    assert TestSeam.enter_runtime(snap) == :ok
    assert Prototype.runtime() == :prototype
    assert Prototype.binding() == {:ok, snap}
    assert TestSeam.leave_runtime() == :ok
    assert Prototype.runtime() == :ordinary
    assert Prototype.binding() == {:error, :not_prototype_runtime}
  end

  test "a task of the caller (through $callers) sees it; an unrelated process does not" do
    assert TestSeam.enter_runtime(snapshot()) == :ok

    assert runtime_in(fn report -> Task.async(report) |> Task.await() end) == :prototype
    assert runtime_in(fn report -> spawn(report) end) == :ordinary
  end

  test "a dead caller contributes nothing" do
    parent = self()
    ref = make_ref()
    snap = snapshot()

    caller =
      spawn(fn ->
        send(parent, {ref, TestSeam.enter_runtime(snap)})
        receive do: (:exit -> :ok)
      end)

    assert_receive {^ref, :ok}, 2_000
    monitor = Process.monitor(caller)
    send(caller, :exit)
    assert_receive {:DOWN, ^monitor, :process, _, _}, 2_000

    child =
      spawn(fn ->
        Process.put(:"$callers", [caller])
        send(parent, {ref, Prototype.runtime()})
      end)

    assert is_pid(child)
    assert_receive {^ref, :ordinary}, 2_000
  end

  test "clear/0 removes every seam key of the process" do
    assert TestSeam.enter_runtime(snapshot()) == :ok
    assert TestSeam.put_live_identity(%{database_oid: 1}) == :ok
    assert TestSeam.clear() == :ok
    assert Prototype.runtime() == :ordinary

    seam_keys =
      for {{SdrAgent.Prototype, _} = key, _} <- Process.get(), do: key

    assert seam_keys == []
  end
end
