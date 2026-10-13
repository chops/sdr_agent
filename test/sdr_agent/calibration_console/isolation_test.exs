defmodule SdrAgent.CalibrationConsole.IsolationTest do
  @moduledoc """
  R0-07 slice E4c, sub-slice b (packet 8.12 E4c-1, entity PASS at 25c1b18):
  the isolation capability check and the launch group verification.

  `Isolation.preflight/1` launches no CLI. Through the existing
  `Reaper.start/track/open` + `ChildEnv` shape it opens a held synthetic
  target (`/bin/sh -c 'printf ready; IFS= read -r _'`), waits (bounded) for
  `ready`, requires the root's start identity and its own process group
  (the root is listed in `group_members(root)`), closes the port (EOF on
  stdin), and confirms the tree gone through the reaper and an observed
  empty group, all before any reservation. A timeout, a probe error, a
  target that merely exited early, or an unconfirmed cleanup is `{:error,
  :calibration_isolation_unavailable}`; the tree is stopped either way.

  `Isolation.verify_group/2` is the same group check for a launched root
  (step 7): `:ok` or `{:error, :calibration_isolation_unavailable}`.

  The `target:`, `ready_ms:` and `observer:` options (an `fn {:spawned,
  os_pid} -> any end` callback) are honoured only in test-seam builds;
  `probe:` names the OS probe (default `ProcessProbe`). Every launch here
  is a harmless `/bin/sh`.
  """
  use ExUnit.Case, async: false

  alias SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper
  alias SdrAgent.CalibrationConsole.{Isolation, ProcessProbe}

  defmodule GroupProbe do
    @moduledoc false
    # The real probe, except for group answers set per test: `:real`, a
    # fixed reply, the real group without its leader, or the real group
    # plus a phantom member that never exits.
    use Agent

    def start_link(_), do: Agent.start_link(fn -> %{group: :real} end, name: __MODULE__)
    def put(group), do: Agent.update(__MODULE__, &%{&1 | group: group})
    def self_pid, do: ProcessProbe.self_pid()
    def start_identity(pid), do: ProcessProbe.start_identity(pid)

    def group_members(pgid) do
      case Agent.get(__MODULE__, & &1.group) do
        :real ->
          ProcessProbe.group_members(pgid)

        {:fixed, reply} ->
          reply

        {:without_root, _} ->
          without_root(pgid)

        {:plus, extra} ->
          with({:ok, members} <- ProcessProbe.group_members(pgid), do: {:ok, members ++ [extra]})
      end
    end

    defp without_root(pgid) do
      with {:ok, members} <- ProcessProbe.group_members(pgid), do: {:ok, members -- [pgid]}
    end
  end

  setup do
    start_supervised!(GroupProbe)
    parent = self()

    # After the fixtures: a missing module fails as an assertion.
    assert Code.ensure_loaded?(Isolation),
           "SdrAgent.CalibrationConsole.Isolation is not defined"

    %{observer: fn event -> send(parent, {:isolation, event}) end}
  end

  describe "preflight/1" do
    test "a held target in its own process group passes and leaves nothing running", ctx do
      assert :ok = Isolation.preflight(observer: ctx.observer)
      assert_received {:isolation, {:spawned, os_pid}}
      assert gone?(os_pid), "the held target #{os_pid} is still running"
    end

    test "a target that exits at once is no isolation proof", ctx do
      result = Isolation.preflight(target: "printf ready", observer: ctx.observer)
      assert result == {:error, :calibration_isolation_unavailable}
      assert_received {:isolation, {:spawned, os_pid}}
      assert gone?(os_pid)
    end

    test "no ready within the bound is unavailable and the target is stopped", ctx do
      result =
        Isolation.preflight(target: "IFS= read -r _", ready_ms: 200, observer: ctx.observer)

      assert result == {:error, :calibration_isolation_unavailable}
      assert_received {:isolation, {:spawned, os_pid}}
      assert gone?(os_pid), "an unready target must still be stopped"
    end

    test "a root missing from its own group is unavailable and stopped", ctx do
      GroupProbe.put({:without_root, nil})

      result = Isolation.preflight(probe: GroupProbe, observer: ctx.observer)
      assert result == {:error, :calibration_isolation_unavailable}
      assert_received {:isolation, {:spawned, os_pid}}
      assert gone?(os_pid)
    end

    test "a probe error is unavailable, never isolation", ctx do
      GroupProbe.put({:fixed, {:error, :ps_failed}})

      result = Isolation.preflight(probe: GroupProbe, observer: ctx.observer)
      assert result == {:error, :calibration_isolation_unavailable}
      assert_received {:isolation, {:spawned, os_pid}}
      assert gone?(os_pid)
    end

    test "a group never observed empty after close is an unconfirmed cleanup", ctx do
      # Verification passes (the root leads its group), but a phantom member
      # never leaves: the cleanup is never confirmed.
      GroupProbe.put({:plus, 999_999})

      result = Isolation.preflight(probe: GroupProbe, observer: ctx.observer)
      assert result == {:error, :calibration_isolation_unavailable}
      assert_received {:isolation, {:spawned, os_pid}}
      assert gone?(os_pid), "the real target is still stopped"
    end

    test "the preflight leaves no reaper or port behind", ctx do
      before_ports = length(Port.list())
      assert :ok = Isolation.preflight(observer: ctx.observer)
      assert length(Port.list()) == before_ports
      assert_received {:isolation, {:spawned, _os_pid}}
    end

    test "the preflight takes no named reaper lease" do
      lease = Reaper.lease(SdrAgent.AI.ModelProvider.ClaudeCLI)
      assert :ok = Isolation.preflight([])
      assert Reaper.lease(SdrAgent.AI.ModelProvider.ClaudeCLI) == lease
    end
  end

  describe "verify_group/2" do
    test "a live root leading its own group is verified" do
      {port, os_pid} = held_shell!()

      try do
        assert :ok = Isolation.verify_group(os_pid, [])
      after
        stop!(port, os_pid)
      end
    end

    test "a root that is not its group's leader, or a probe error, is unavailable" do
      {port, os_pid} = held_shell!()

      try do
        GroupProbe.put({:without_root, nil})

        assert {:error, :calibration_isolation_unavailable} =
                 Isolation.verify_group(os_pid, probe: GroupProbe)

        GroupProbe.put({:fixed, {:error, :ps_failed}})

        assert {:error, :calibration_isolation_unavailable} =
                 Isolation.verify_group(os_pid, probe: GroupProbe)
      after
        stop!(port, os_pid)
      end
    end

    test "an absent root is unavailable" do
      {port, os_pid} = held_shell!()
      stop!(port, os_pid)

      assert {:error, :calibration_isolation_unavailable} = Isolation.verify_group(os_pid, [])
    end

    test "the VM's own process is never a verified launch root" do
      {:ok, vm} = ProcessProbe.self_pid()
      assert {:error, :calibration_isolation_unavailable} = Isolation.verify_group(vm, [])
    end
  end

  ## Fixtures

  # A held shell opened like a launch (Port + ChildEnv), for verify_group.
  defp held_shell! do
    port =
      Port.open(
        {:spawn_executable, "/bin/sh"},
        [
          {:env, SdrAgent.ChildEnv.port([], [])},
          :binary,
          :exit_status,
          args: ["-c", "printf ready; IFS= read -r _"]
        ]
      )

    assert_receive {^port, {:data, "ready"}}, 5_000
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {port, os_pid}
  end

  defp stop!(port, os_pid) do
    if Port.info(port), do: Port.close(port)
    assert Reaper.kill_tree(os_pid) == :ok
  end

  # Gone: no start identity of that pid and an empty group.
  defp gone?(os_pid) do
    ProcessProbe.start_identity(os_pid) == :absent and
      ProcessProbe.group_members(os_pid) == {:ok, []}
  end
end
