defmodule SdrAgent.AI.ClaudeCLIReaperUnidentifiedTest do
  @moduledoc """
  R0-07 slice E integration review (Codex, 75f275d): an opened launch whose
  OS pid cannot be read is unidentified, not "never launched". When the
  owner dies the reaper cannot confirm it stopped, so it exits **without**
  erasing the admission lease: a replacement server stays blocked
  (`:previous_cleanup_unconfirmed`) until an operator who has checked the
  machine runs `Reaper.release/1`. A workspace that was only tracked (never
  opened) still releases the lease as before. The pid lookup is forced
  unavailable through the reaper's `:os_pid` failure-injection option;
  every launch is a harmless `/usr/bin/true`.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper

  @spawn {:spawn_executable, "/usr/bin/true"}
  @port_opts {[:binary, :exit_status], {[], []}}

  setup do
    name = :"reaper_unidentified_#{System.unique_integer([:positive])}"
    on_exit(fn -> Reaper.release(name) end)
    %{name: name}
  end

  test "an unidentified launch keeps the lease after owner death", %{tmp_dir: tmp, name: name} do
    {owner, reaper, result} = launch(name, tmp, os_pid: fn _port -> nil end)

    assert result == {:unknown, :post_spawn_failure}
    stop_owner(owner, reaper)

    assert Reaper.lease(name) == {:held, reaper},
           "no pid was obtained, so owner death must not certify cleanup"

    assert {:blocked, :previous_cleanup_unconfirmed} = Reaper.start(name)

    # The operator recovery: the dead holder's lease is released.
    assert :ok = Reaper.release(name)
    assert Reaper.lease(name) == nil
  end

  test "a workspace tracked but never opened still releases the lease", %{
    tmp_dir: tmp,
    name: name
  } do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, reaper} = Reaper.start(name)
        Reaper.track(reaper, tmp)
        send(parent, {:reaper, reaper})
        receive do: (:exit -> :ok)
      end)

    assert_receive {:reaper, reaper}, 5_000
    stop_owner(owner, reaper)
    assert Reaper.lease(name) == nil
  end

  test "an identified launch is still reaped and releases the lease", %{tmp_dir: tmp, name: name} do
    {owner, reaper, result} = launch(name, tmp, [])

    assert {:ok, _port, _os_pid} = result
    stop_owner(owner, reaper)
    assert Reaper.lease(name) == nil
  end

  # An owner process starts the named reaper and opens one launch through
  # it, then waits to be told to exit.
  defp launch(name, tmp, reaper_opts) do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, reaper} = Reaper.start(name, reaper_opts)
        Reaper.track(reaper, tmp)
        deadline = System.monotonic_time(:millisecond) + 5_000
        send(parent, {:opened, reaper, Reaper.open(reaper, tmp, @spawn, @port_opts, deadline)})
        receive do: (:exit -> :ok)
      end)

    assert_receive {:opened, reaper, result}, 10_000
    {owner, reaper, result}
  end

  defp stop_owner(owner, reaper) do
    ref = Process.monitor(reaper)
    send(owner, :exit)
    assert_receive {:DOWN, ^ref, :process, ^reaper, _reason}, 10_000
  end
end
