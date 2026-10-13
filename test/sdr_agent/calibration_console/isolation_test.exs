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

    def start_link(_),
      do:
        Agent.start_link(fn -> %{group: :real, identity: :real, self: :real} end,
          name: __MODULE__
        )

    def put(group), do: Agent.update(__MODULE__, &%{&1 | group: group})
    def put(key, value), do: Agent.update(__MODULE__, &Map.put(&1, key, value))

    def self_pid do
      case Agent.get(__MODULE__, & &1.self) do
        :real -> ProcessProbe.self_pid()
        {:fixed, reply} -> reply
      end
    end

    def start_identity(pid) do
      case Agent.get(__MODULE__, & &1.identity) do
        :real -> ProcessProbe.start_identity(pid)
        {:fixed, reply} -> reply
      end
    end

    def group_members(pgid) do
      case Agent.get(__MODULE__, & &1.group) do
        :real ->
          ProcessProbe.group_members(pgid)

        # A probe that never answers, or raises.
        :block ->
          Process.sleep(:infinity)

        :raise ->
          raise "synthetic probe failure"

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

    # The observer also records the root's start identity at spawn time, so
    # a test can tell a real launched root from a made-up pid.
    observer = fn
      {:spawned, os_pid} = event ->
        send(parent, {:isolation, event, ProcessProbe.start_identity(os_pid)})

      # Ownership events (helper, reaper, workspace): forwarded as they are.
      event ->
        send(parent, {:isolation, event})
    end

    %{observer: observer}
  end

  describe "preflight/1" do
    test "a held target in its own process group passes and leaves nothing running", ctx do
      assert :ok = Isolation.preflight(observer: ctx.observer)

      assert_received {:isolation, {:spawned, os_pid}, spawned_identity}
      assert match?({:ok, _}, spawned_identity), "no real root was launched"
      assert gone?(os_pid), "the held target #{os_pid} is still running"
    end

    test "a target that exits at once is no isolation proof", ctx do
      result = Isolation.preflight(target: "printf ready", observer: ctx.observer)
      assert result == {:error, :calibration_isolation_unavailable}
      assert_received {:isolation, {:spawned, os_pid}, _identity}
      assert gone?(os_pid)
    end

    test "no ready within the bound is unavailable and the target is stopped", ctx do
      result =
        Isolation.preflight(target: "IFS= read -r _", ready_ms: 200, observer: ctx.observer)

      assert result == {:error, :calibration_isolation_unavailable}
      assert_received {:isolation, {:spawned, os_pid}, _identity}
      assert gone?(os_pid), "an unready target must still be stopped"
    end

    test "a root missing from its own group is unavailable and stopped", ctx do
      GroupProbe.put({:without_root, nil})

      result = Isolation.preflight(probe: GroupProbe, observer: ctx.observer)
      assert result == {:error, :calibration_isolation_unavailable}
      assert_received {:isolation, {:spawned, os_pid}, _identity}
      assert gone?(os_pid)
    end

    test "a probe error is unavailable, never isolation", ctx do
      GroupProbe.put({:fixed, {:error, :ps_failed}})

      # The group can never be observed, so its cleanup is reported as
      # unconfirmed, never as stopped (Codex 01a13570 MF3).
      result = Isolation.preflight(probe: GroupProbe, observer: ctx.observer)
      assert result == {:error, :calibration_isolation_cleanup_unconfirmed}
      assert_received {:isolation, {:spawned, os_pid}, _identity}
      assert gone?(os_pid)
    end

    test "a group never observed empty after close is an unconfirmed cleanup", ctx do
      # Verification passes (the root leads its group), but a phantom member
      # never leaves: the cleanup is never confirmed.
      GroupProbe.put({:plus, 999_999})

      # Reported explicitly, never as stopped (Codex 01a13570 MF3).
      result = Isolation.preflight(probe: GroupProbe, observer: ctx.observer)
      assert result == {:error, :calibration_isolation_cleanup_unconfirmed}
      assert_received {:isolation, {:spawned, os_pid}, _identity}
      assert gone?(os_pid), "the real target is still stopped"
    end

    test "the preflight leaves no reaper or port behind", ctx do
      before_ports = length(Port.list())
      assert :ok = Isolation.preflight(observer: ctx.observer)
      assert length(Port.list()) == before_ports
      assert_received {:isolation, {:spawned, _os_pid}, {:ok, _identity}}
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

  describe "code review (Codex 01a13570, 119dd22)" do
    # MF1: the reaper only ever cleans a private directory this preflight
    # created exclusively, never a synthesized relative name.
    test "the tracked workspace is a private absolute directory the preflight created", ctx do
      parent = self()

      observer = fn
        {:workspace, path} = event ->
          send(parent, {:isolation, event, File.lstat(path)})

        event ->
          ctx.observer.(event)
      end

      assert :ok = Isolation.preflight(observer: observer)
      assert_received {:isolation, {:workspace, path}, stat}
      assert Path.type(path) == :absolute
      assert match?({:ok, %File.Stat{type: :directory}}, stat), inspect(stat)
      {:ok, %File.Stat{mode: mode}} = stat
      assert Bitwise.band(mode, 0o777) == 0o700
      refute File.exists?(path), "the workspace must be removed after cleanup"
    end

    test "a helper crash after launch cleans only its own workspace and the tree", ctx do
      parent = self()

      observer = fn
        {:spawned, _os_pid} = event ->
          ctx.observer.(event)
          raise "synthetic observer failure"

        {:workspace, path} = event ->
          send(parent, {:isolation, event})
          File.write!(Path.join(path, "../" <> Path.basename(path) <> ".canary"), "keep")

        event ->
          ctx.observer.(event)
      end

      assert {:error, :calibration_isolation_unavailable} =
               Isolation.preflight(observer: observer)

      assert_received {:isolation, {:spawned, os_pid}, _identity}
      assert_received {:isolation, {:workspace, path}}
      canary = Path.join(Path.dirname(path), Path.basename(path) <> ".canary")

      try do
        assert await(fn -> gone?(os_pid) and not File.exists?(path) end),
               "the tree and the workspace must be cleaned"

        assert File.read!(canary) == "keep", "a file the preflight did not create was touched"
      after
        File.rm(canary)
      end
    end

    # MF2: the whole preflight is bounded, and a dead caller still cleans.
    test "a blocking probe is bounded and its target is stopped", ctx do
      GroupProbe.put(:block)
      started = System.monotonic_time(:millisecond)

      # Run under an outer bound, so an unbounded preflight fails as an
      # assertion rather than as a test timeout.
      task =
        Task.async(fn ->
          Isolation.preflight(
            probe: GroupProbe,
            ready_ms: 200,
            bound_ms: 1_500,
            observer: ctx.observer
          )
        end)

      result =
        case Task.yield(task, 8_000) do
          {:ok, result} -> result
          nil -> Task.shutdown(task, :brutal_kill) && :unbounded
        end

      elapsed = System.monotonic_time(:millisecond) - started
      assert result == {:error, :calibration_isolation_unavailable}
      assert elapsed < 6_000, "preflight took #{elapsed} ms"
      assert_receive {:isolation, {:spawned, os_pid}, _identity}
      assert_receive {:isolation, {:helper, helper}}
      assert await(fn -> not Process.alive?(helper) and gone?(os_pid) end)
    end

    test "a cancelled caller still stops the helper and the target", ctx do
      GroupProbe.put(:block)

      task =
        Task.async(fn ->
          Isolation.preflight(probe: GroupProbe, observer: ctx.observer, bound_ms: 60_000)
        end)

      assert_receive {:isolation, {:spawned, os_pid}, _identity}, 5_000
      assert_receive {:isolation, {:helper, helper}}, 5_000
      Task.shutdown(task, :brutal_kill)

      assert await(fn -> not Process.alive?(helper) and gone?(os_pid) end),
             "a dead caller left its helper or target running"
    end

    test "a raising probe is unavailable and stopped", ctx do
      GroupProbe.put(:raise)
      result = Isolation.preflight(probe: GroupProbe, observer: ctx.observer)
      assert result == {:error, :calibration_isolation_cleanup_unconfirmed}
      assert_received {:isolation, {:spawned, os_pid}, _identity}
      assert await(fn -> gone?(os_pid) end)
    end

    # MF3: a same-group child left behind by an exiting root is stopped,
    # and tracking is kept until the cleanup is confirmed.
    test "a same-group child of an exiting root is stopped", ctx do
      result =
        Isolation.preflight(
          target: "/bin/sleep 20 & printf ready; exit 0",
          observer: ctx.observer
        )

      assert result == {:error, :calibration_isolation_unavailable}
      assert_received {:isolation, {:spawned, os_pid}, _identity}

      try do
        assert ProcessProbe.group_members(os_pid) == {:ok, []},
               "a same-group child is still running"
      after
        stop_group!(os_pid)
      end
    end

    # Important: verify_group shapes every observation.
    test "verify_group refuses malformed observations" do
      {port, os_pid} = held_shell!()

      try do
        for {key, reply} <- [
              identity: {:fixed, {:ok, ""}},
              self: {:fixed, {:ok, -1}},
              self: {:fixed, {:ok, "x"}}
            ] do
          GroupProbe.put(key, reply)

          assert Isolation.verify_group(os_pid, probe: GroupProbe) ==
                   {:error, :calibration_isolation_unavailable},
                 inspect({key, reply})

          GroupProbe.put(key, :real)
        end

        GroupProbe.put({:plus, "not-a-pid"})

        assert Isolation.verify_group(os_pid, probe: GroupProbe) ==
                 {:error, :calibration_isolation_unavailable}
      after
        stop!(port, os_pid)
      end
    end
  end

  ## Fixtures

  # Bounded wait for `check` to hold.
  defp await(check, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    cond do
      check.() -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(50) && await(check, deadline)
    end
  end

  # Test cleanup only: stops whatever is left in a fixture's own group.
  defp stop_group!(pgid) do
    case ProcessProbe.group_members(pgid) do
      {:ok, members} -> Enum.each(members, &Reaper.kill_tree/1)
      _ -> :ok
    end
  end

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
