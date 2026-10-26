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

        # Blocks, and from then on the root reads as `identity` (so only a
        # fallback cleanup can act on it).
        {:block_then, identity} ->
          Agent.update(__MODULE__, &%{&1 | identity: identity})
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

    # #151: an early exit the test controls, not a race. The target prints
    # `ready` and exits when the observer releases it at the spawned event,
    # which follows the launch identity read (isolation.ex:245-247); the
    # observer then waits, bounded, until the probe no longer lists the root,
    # so verification starts only after the exit. The release file lives in
    # an exclusive directory this test created (a collision fails) and
    # removes by exact path. A target that merely exits at once can end
    # `:ok` (an exit status later than the 100 ms hold), unavailable or
    # unconfirmed (an unreadable pid), so it is no oracle.
    test "a target that exits right after its launch is no isolation proof", ctx do
      parent = self()

      dir =
        Path.join(
          System.tmp_dir!(),
          "sdr-isolation-release-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
        )

      assert :ok = File.mkdir(dir)
      File.chmod!(dir, 0o700)
      release = Path.join(dir, "release")

      on_exit(fn ->
        rm = File.rm(release)
        rmdir = File.rmdir(dir)

        unless rm in [:ok, {:error, :enoent}] and rmdir == :ok do
          raise ExUnit.AssertionError,
            message:
              "release fixture cleanup failed: rm=#{inspect(rm)} rmdir=#{inspect(rmdir)} (#{dir})"
        end
      end)

      observer = fn
        {:spawned, os_pid} = event ->
          ctx.observer.(event)
          File.touch!(release)
          deadline = System.monotonic_time(:millisecond) + 2_000

          acknowledged =
            Enum.reduce_while(
              Stream.repeatedly(fn -> ProcessProbe.start_identity(os_pid) end),
              false,
              fn
                :absent, _acc ->
                  {:halt, true}

                _raw, _acc ->
                  if System.monotonic_time(:millisecond) >= deadline do
                    {:halt, false}
                  else
                    Process.sleep(10)
                    {:cont, false}
                  end
              end
            )

          send(parent, {:release_ack, os_pid, acknowledged})

        event ->
          ctx.observer.(event)
      end

      target =
        "printf ready; i=0; until [ -e '#{release}' ] || [ \"$i\" -ge 500 ]; do sleep 0.02; i=$((i+1)); done"

      result = Isolation.preflight(target: target, observer: observer)
      assert_received {:isolation, {:spawned, os_pid}, spawned_identity}
      assert_received {:release_ack, ^os_pid, acknowledged}

      # The result, the acknowledged exit and the launch identity are judged
      # together, so a surprising result never hides the others.
      assert {result, acknowledged, match?({:ok, _}, spawned_identity)} ==
               {{:error, :calibration_isolation_unavailable}, true, true}

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

      # The probe never answers, so no cleanup can be confirmed physically
      # (Codex 01a13590 MF2): reported as unconfirmed, never as stopped.
      assert result == {:error, :calibration_isolation_cleanup_unconfirmed}
      assert elapsed < 20_000, "preflight took #{elapsed} ms"
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

    # MF3, as revised by Codex 01a13590: a same-group child left behind by
    # an exiting root is never signalled on age alone; it is reported as an
    # unconfirmed cleanup (a hard conflict), never as stopped.
    test "a same-group child of an exiting root is an unconfirmed cleanup", ctx do
      result =
        Isolation.preflight(
          target: "/bin/sleep 20 & printf ready; exit 0",
          observer: ctx.observer
        )

      assert_received {:isolation, {:spawned, os_pid}, _identity}

      try do
        assert result == {:error, :calibration_isolation_cleanup_unconfirmed}
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

  describe "code review (Codex 01a13590, 5231107)" do
    # MF1: a group member is never signalled on age alone: a stale snapshot
    # naming a separately owned process leaves it untouched.
    test "a stale member snapshot never signals another process", ctx do
      {port, other} = held_shell!()
      {:ok, other_identity} = ProcessProbe.start_identity(other)

      try do
        GroupProbe.put({:plus, other})
        result = Isolation.preflight(probe: GroupProbe, observer: ctx.observer)
        assert result == {:error, :calibration_isolation_cleanup_unconfirmed}

        assert ProcessProbe.start_identity(other) == {:ok, other_identity},
               "another process was signalled"
      after
        stop!(port, other)
      end
    end

    # MF1: a root whose identity changed after spawn is never signalled, by
    # the preflight or by a reaper fallback.
    test "a root whose identity changed is never signalled", ctx do
      parent = self()

      observer = fn
        {:spawned, os_pid} = event ->
          {:ok, identity} = ProcessProbe.start_identity(os_pid)
          send(parent, {:isolation, event, {:ok, identity}})
          # From now on the root pid reads as another (reused) process.
          GroupProbe.put(:identity, {:fixed, {:ok, "Mon Jan  1 00:00:00 2001"}})

        event ->
          ctx.observer.(event)
      end

      result =
        Isolation.preflight(
          target: "printf ready; exec /bin/sleep 30",
          probe: GroupProbe,
          observer: observer
        )

      assert_received {:isolation, {:spawned, os_pid}, {:ok, identity}}

      try do
        assert result == {:error, :calibration_isolation_cleanup_unconfirmed}
        # Past the helper's exit: no reaper fallback signalled it either.
        Process.sleep(500)
        assert ProcessProbe.start_identity(os_pid) == {:ok, identity}, "the root was signalled"
      after
        stop_group!(os_pid)
      end
    end

    # MF2: a reaper that never completes is cleanup-unconfirmed, not merely
    # unavailable.
    test "a hung reaper after a timeout is cleanup-unconfirmed", ctx do
      GroupProbe.put(:block)
      test = self()

      observer = fn
        {:reaper, reaper} ->
          send(test, {:reaper, reaper})

        {:spawned, _os_pid} = event ->
          ctx.observer.(event)
          # After the launch: the test process suspends the reaper (not the
          # helper, so it stays suspended when the helper is killed).
          send(test, :suspend_now)
          Process.sleep(200)

        event ->
          ctx.observer.(event)
      end

      task =
        Task.async(fn ->
          Isolation.preflight(
            probe: GroupProbe,
            ready_ms: 300,
            bound_ms: 800,
            reaper_ms: 500,
            observer: observer
          )
        end)

      assert_receive {:reaper, reaper}, 5_000
      assert_receive :suspend_now, 5_000
      :erlang.suspend_process(reaper)

      try do
        result =
          case Task.yield(task, 15_000) do
            {:ok, result} -> result
            nil -> Task.shutdown(task, :brutal_kill) && :unbounded
          end

        assert result == {:error, :calibration_isolation_cleanup_unconfirmed}
      after
        :erlang.resume_process(reaper)
      end

      assert_receive {:isolation, {:spawned, os_pid}, _identity}, 1_000
      assert await(fn -> gone?(os_pid) end), "the resumed reaper must still clean up"
    end

    test "a helper crash after launch reports a physical cleanup check", ctx do
      observer = fn
        {:spawned, _os_pid} = event ->
          ctx.observer.(event)
          raise "synthetic observer failure"

        event ->
          ctx.observer.(event)
      end

      # The reaper's exit alone is no receipt: the root and group are
      # checked; here both are gone, so the outcome is plain unavailable.
      assert {:error, :calibration_isolation_unavailable} =
               Isolation.preflight(observer: observer)

      assert_received {:isolation, {:spawned, os_pid}, _identity}
      assert gone?(os_pid)
    end
  end

  describe "code review (Codex 01a135b6, 8435dcf)" do
    # Every cleanup actor obeys the root signal authority: after a timeout
    # or a caller's death the reaper's fallback never signals a root whose
    # identity changed or cannot be read.
    for {label, identity} <- [
          reused: {:fixed, {:ok, "Mon Jan  1 00:00:00 2001"}},
          unreadable: {:fixed, {:error, :ps_failed}}
        ],
        mode <- [:timeout, :cancelled] do
      test "a #{label} root is never signalled by the #{mode} fallback", ctx do
        GroupProbe.put({:block_then, unquote(Macro.escape(identity))})
        parent = self()

        observer = fn
          {:spawned, os_pid} = event ->
            {:ok, spawned} = ProcessProbe.start_identity(os_pid)
            send(parent, {:isolation, event, {:ok, spawned}})

          event ->
            ctx.observer.(event)
        end

        opts = [
          target: "printf ready; exec /bin/sleep 30",
          probe: GroupProbe,
          ready_ms: 300,
          bound_ms: 700,
          reaper_ms: 3_000,
          observer: observer
        ]

        result = run_mode(unquote(mode), opts)
        assert_receive {:isolation, {:spawned, os_pid}, {:ok, spawned}}, 5_000

        try do
          assert_mode_result(unquote(mode), result)

          # Past the fallback: the root was never signalled.
          Process.sleep(1_500)
          assert ProcessProbe.start_identity(os_pid) == {:ok, spawned}, "the root was signalled"
        after
          stop_group!(os_pid)
        end
      end
    end
  end

  ## Fixtures

  # A timed-out preflight reports its cleanup as unconfirmed; a cancelled
  # caller has no result.
  defp assert_mode_result(:timeout, result),
    do: assert(result == {:error, :calibration_isolation_cleanup_unconfirmed})

  defp assert_mode_result(:cancelled, :cancelled), do: :ok

  defp run_mode(:timeout, opts), do: Isolation.preflight(opts)

  defp run_mode(:cancelled, opts) do
    test = self()
    task = Task.async(fn -> Isolation.preflight(opts) end)
    assert_receive {:isolation, {:helper, helper}}, 5_000
    # The launch exists before the caller is cancelled.
    Process.sleep(500)
    Task.shutdown(task, :brutal_kill)
    send(test, :cancelled)
    ref = Process.monitor(helper)
    assert_receive {:DOWN, ^ref, :process, ^helper, _}, 5_000
    :cancelled
  end

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
