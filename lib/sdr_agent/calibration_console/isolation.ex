defmodule SdrAgent.CalibrationConsole.Isolation do
  @moduledoc """
  The calibration console's process-group isolation check (R0-07 slice
  E4c-1, packet 8.12; entity PASS at 25c1b18; code review Codex 01a13570).
  An Erlang Port child is already the leader of its own process group, so
  no wrapper is used: the harness verifies the group instead.

    * `preflight/1` — a capability check that launches no CLI. Through the
      existing `Reaper.start/track/open` + `SdrAgent.ChildEnv` shape it
      opens a held synthetic target (`/bin/sh -c 'printf ready; IFS= read
      -r _'`), waits (bounded) for `ready`, requires the root's start
      identity and its own group (`verify_group/2`), checks that the target
      is still held a moment later, closes its stdin (EOF), and confirms
      the tree gone.
    * `verify_group/2` — a launched root has a start identity, is not this
      VM, and is listed in its own group (`pgid == root pid`).

  **Ownership.** The work runs in a helper process with its own unnamed
  reaper (no admission lease). The reaper tracks only a private 0700
  directory the helper created exclusively under the system temporary
  directory (its recursive cleanup never reaches a name it did not
  create). Closing stdin does not forget the launch: the reaper keeps it
  tracked until the cleanup is confirmed, and only then is it forgotten
  and the empty directory removed.

  **Cleanup** (conservative; Codex 01a13590). The root's start identity is
  read at spawn and re-read just before its one stop. If it still matches,
  the root's tree is stopped through `Reaper.kill_tree/1`; if the pid is
  absent or reads as another process, the root is already gone and is
  never signalled. Once the root is confirmed gone its tracking is
  released, so no reaper fallback re-signals a stopped or reused pid. The
  root's group is then only observed until empty: a member left behind is
  never signalled (age is no ownership). A root that cannot be verified, a
  member that stays, or a group that cannot be observed is `{:error,
  :calibration_isolation_cleanup_unconfirmed}`, never "stopped": for the
  console a hard owner conflict (packet 8.12, E4c-1 cleanup delta).

  **Bounds.** The caller waits at most `ready_ms + bound_ms` for the
  helper. On timeout, or when the helper dies, the helper is killed so its
  reaper stops the tracked tree; the caller waits at most `reaper_ms` for
  that reaper and then checks physically, within `check_ms`, that the root
  is gone and its group empty (a reaper's exit is no cleanup receipt).
  Anything less is cleanup-unconfirmed. When the caller itself dies, a
  watchdog kills the helper so its reaper still cleans up. The total bound
  is `ready_ms + bound_ms + reaper_ms + check_ms`.

  Any other timeout, probe error, early exit or crash is `{:error,
  :calibration_isolation_unavailable}`. This is the observed process-group
  scope: a descendant that changes its group escapes it (OQ-E3).

  `probe:` names the OS probe (default
  `SdrAgent.CalibrationConsole.ProcessProbe`). Only test-seam builds honour
  `target:` (the shell script), `ready_ms:`, `bound_ms:`, `reaper_ms:`,
  `check_ms:` and `observer:` (`fn event -> any end`, called with
  `{:helper, pid}`, `{:workspace, path}`, `{:reaper, pid}` and `{:spawned,
  os_pid}`); other builds always use the held target and the default
  bounds.
  """

  alias SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper
  alias SdrAgent.CalibrationConsole.ProcessProbe

  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)
  @target "printf ready; IFS= read -r _"
  @ready_ms 5_000
  @bound_ms 15_000
  @gone_ms 4_000
  @reaper_ms 10_000
  @check_ms 3_000
  @poll_ms 20
  @hold_ms 100
  @port_opts [:binary, :exit_status]
  @unavailable {:error, :calibration_isolation_unavailable}
  @unconfirmed {:error, :calibration_isolation_cleanup_unconfirmed}

  @doc """
  `:ok`, `{:error, :calibration_isolation_unavailable}` or `{:error,
  :calibration_isolation_cleanup_unconfirmed}` (see the moduledoc).
  """
  def preflight(opts) do
    seams = seams(opts)
    probe = Keyword.get(opts, :probe) || ProcessProbe
    caller = self()
    ref = make_ref()

    {helper, monitor} =
      spawn_monitor(fn -> send(caller, {ref, helper_run(seams, probe, caller, ref)}) end)

    spawn(fn -> watchdog(caller, helper) end)
    seams.observer.({:helper, helper})

    deadline = System.monotonic_time(:millisecond) + seams.ready_ms + seams.bound_ms

    await(ref, helper, monitor, deadline, %{reaper: nil, spawned: nil, seams: seams, probe: probe})
  end

  @doc "`:ok` when `os_pid` is a live root leading its own group; else unavailable."
  def verify_group(os_pid, opts) do
    probe = Keyword.get(opts, :probe) || ProcessProbe

    case root_identity(os_pid, probe) do
      {:ok, _identity} -> :ok
      :error -> @unavailable
    end
  end

  ## The caller side

  defp await(ref, helper, monitor, deadline, known) do
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^ref, {:reaper, pid}} ->
        await(ref, helper, monitor, deadline, %{known | reaper: pid})

      {^ref, {:spawned, os_pid, identity}} ->
        await(ref, helper, monitor, deadline, %{known | spawned: {os_pid, identity}})

      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^helper, _reason} ->
        settle(known)
    after
      wait ->
        # Out of time: the helper's reaper stops the tracked tree.
        Process.demonitor(monitor, [:flush])
        Process.exit(helper, :kill)
        settle(known)
    end
  end

  # After the helper is gone: no reaper means nothing was launched; else
  # the reaper must finish and the root and group must be seen gone.
  defp settle(%{reaper: nil}), do: @unavailable

  defp settle(%{reaper: reaper, spawned: spawned, seams: seams, probe: probe}) do
    with :ok <- reaped(reaper, seams.reaper_ms),
         {os_pid, identity} <- spawned,
         :ok <- bounded(fn -> gone(os_pid, identity, probe) end, seams.check_ms) do
      @unavailable
    else
      _unconfirmed -> @unconfirmed
    end
  end

  defp reaped(reaper, wait) do
    ref = Process.monitor(reaper)

    receive do
      {:DOWN, ^ref, :process, ^reaper, _reason} -> :ok
    after
      wait ->
        Process.demonitor(ref, [:flush])
        :unconfirmed
    end
  end

  # The root no longer its spawned process and its group observed empty.
  defp gone(os_pid, spawned, probe) do
    # A missing or unreadable spawn identity proves nothing about reuse.
    root_gone =
      case {identity(probe, os_pid), spawned} do
        {:absent, _spawned} -> true
        {{:ok, current}, {:ok, at_spawn}} -> current != at_spawn
        _unknown -> false
      end

    if root_gone and observe(fn -> probe.group_members(os_pid) end) == {:ok, []},
      do: :ok,
      else: :unconfirmed
  end

  # A probe that may block runs in an unlinked, monitored process that is
  # killed on timeout; a crash, exit or throw there is unconfirmed.
  defp bounded(fun, wait) do
    caller = self()
    ref = make_ref()
    {pid, monitor} = spawn_monitor(fn -> send(caller, {ref, fun.()}) end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        :unconfirmed
    after
      wait ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        :unconfirmed
    end
  end

  # A dead caller cannot clean up: the helper is killed so its reaper does.
  defp watchdog(caller, helper) do
    caller_ref = Process.monitor(caller)
    helper_ref = Process.monitor(helper)

    receive do
      {:DOWN, ^caller_ref, :process, _caller, _reason} -> Process.exit(helper, :kill)
      {:DOWN, ^helper_ref, :process, _helper, _reason} -> :ok
    end
  end

  ## The helper side

  defp helper_run(seams, probe, caller, ref) do
    with {:ok, workspace} <- workspace() do
      seams.observer.({:workspace, workspace})
      # Every cleanup actor obeys the root signal authority: the reaper's
      # fallback re-reads the root's identity before any signal.
      {:ok, reaper} = Reaper.start(nil, identity: &identity(probe, &1))
      send(caller, {ref, {:reaper, reaper}})
      seams.observer.({:reaper, reaper})
      Reaper.track(reaper, workspace)
      launch(reaper, workspace, seams, probe, {caller, ref})
    end
  end

  # A private directory created exclusively by this preflight: the only
  # path its reaper may ever remove.
  defp workspace do
    name = "sdr-isolation-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    path = Path.join(System.tmp_dir!(), name)

    with :ok <- File.mkdir(path),
         :ok <- File.chmod(path, 0o700) do
      {:ok, path}
    else
      _ -> @unavailable
    end
  end

  defp launch(reaper, workspace, seams, probe, {caller, ref}) do
    deadline = System.monotonic_time(:millisecond) + seams.ready_ms
    spawn = {:spawn_executable, "/bin/sh"}

    case Reaper.open(reaper, workspace, spawn, port_opts(seams.target), deadline) do
      {:ok, port, os_pid} ->
        # The root's identity while it is certainly ours (before any exit
        # can be observed): it bounds which group members may be stopped.
        spawned = identity(probe, os_pid)
        send(caller, {ref, {:spawned, os_pid, spawned}})
        seams.observer.({:spawned, os_pid})
        held(reaper, workspace, port, os_pid, spawned, deadline, probe)

      # Only a failed `Port.open` is a known no-spawn; a pending or unknown
      # receipt may be a launch.
      {:error, {:launch_failed, _reason}} ->
        @unavailable

      _pending_or_unknown ->
        @unconfirmed
    end
  end

  defp port_opts(target), do: {[{:args, ["-c", target]} | @port_opts], {[], []}}

  defp held(reaper, workspace, port, os_pid, spawned, deadline, probe) do
    verified =
      with :ok <- await_ready(port, deadline),
           {:ok, _identity} <- root_identity(os_pid, probe),
           do: still_held(port)

    # EOF on stdin; the launch stays tracked until the cleanup is confirmed.
    close(port)

    case stopped(os_pid, spawned, probe, reaper, workspace) do
      :ok ->
        # A workspace that cannot be removed is reported, not ignored.
        cond do
          File.rmdir(workspace) != :ok -> @unconfirmed
          verified == :ok -> :ok
          true -> @unavailable
        end

      :unconfirmed ->
        @unconfirmed
    end
  end

  defp await_ready(port, deadline), do: await_ready(port, deadline, "")

  defp await_ready(port, deadline, seen) do
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        seen = seen <> data
        if seen == "ready", do: :ok, else: await_ready(port, deadline, seen)

      {^port, {:exit_status, _status}} ->
        :exited
    after
      wait -> :timeout
    end
  end

  # A check, not a lifetime guarantee: the held target exits only on EOF, so
  # an exit within this window means it merely ran briefly.
  defp still_held(port) do
    receive do
      {^port, {:exit_status, _status}} -> :exited
    after
      @hold_ms -> :ok
    end
  end

  defp close(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  ## Cleanup

  # The root is signalled once, only while it still reads as the process
  # spawned; once it is confirmed gone its tracking is released (no reaper
  # fallback re-signals it). The group is then only observed.
  defp stopped(os_pid, spawned, probe, reaper, workspace) do
    case root_stop(os_pid, spawned, probe) do
      :gone ->
        Reaper.done(reaper, workspace)
        empty_group(os_pid, probe, System.monotonic_time(:millisecond) + @gone_ms)

      :alive ->
        # Still verified ours: the reaper keeps it tracked and retries.
        :unconfirmed

      :unverifiable ->
        # Neither provably ours nor provably gone: never signalled, by the
        # preflight or a reaper fallback.
        Reaper.done(reaper, workspace)
        :unconfirmed
    end
  end

  defp root_stop(os_pid, {:ok, spawned}, probe) do
    case identity(probe, os_pid) do
      {:ok, ^spawned} -> if Reaper.kill_tree(os_pid) == :ok, do: :gone, else: :alive
      :absent -> :gone
      {:ok, _reused} -> :gone
      :error -> :unverifiable
    end
  end

  defp root_stop(os_pid, :absent, probe) do
    if identity(probe, os_pid) == :absent, do: :gone, else: :unverifiable
  end

  defp root_stop(_os_pid, _spawned, _probe), do: :unverifiable

  defp empty_group(os_pid, probe, deadline) do
    cond do
      observe(fn -> probe.group_members(os_pid) end) == {:ok, []} ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :unconfirmed

      true ->
        Process.sleep(@poll_ms)
        empty_group(os_pid, probe, deadline)
    end
  end

  ## Observations

  defp root_identity(os_pid, probe) do
    with true <- is_integer(os_pid) and os_pid > 0,
         {:ok, vm} when is_integer(vm) and vm > 0 and vm != os_pid <-
           observe(fn -> probe.self_pid() end),
         {:ok, identity} <- identity(probe, os_pid),
         {:ok, members} when is_list(members) <- observe(fn -> probe.group_members(os_pid) end),
         true <- Enum.all?(members, &(is_integer(&1) and &1 > 0)),
         true <- os_pid in members and vm not in members do
      {:ok, identity}
    else
      _ -> :error
    end
  end

  # `{:ok, identity}` (a non-empty string), `:absent`, or `:error`.
  defp identity(probe, pid) do
    case observe(fn -> probe.start_identity(pid) end) do
      {:ok, identity} when is_binary(identity) and identity != "" -> {:ok, identity}
      :absent -> :absent
      _ -> :error
    end
  end

  defp observe(fun) do
    fun.()
  rescue
    _error -> :error
  end

  if @test_seams do
    defp seams(opts) do
      %{
        target: Keyword.get(opts, :target, @target),
        ready_ms: Keyword.get(opts, :ready_ms, @ready_ms),
        bound_ms: Keyword.get(opts, :bound_ms, @bound_ms),
        reaper_ms: Keyword.get(opts, :reaper_ms, @reaper_ms),
        check_ms: Keyword.get(opts, :check_ms, @check_ms),
        observer: Keyword.get(opts, :observer, fn _event -> :ok end)
      }
    end
  else
    defp seams(_opts) do
      %{
        target: @target,
        ready_ms: @ready_ms,
        bound_ms: @bound_ms,
        reaper_ms: @reaper_ms,
        check_ms: @check_ms,
        observer: fn _ -> :ok end
      }
    end
  end
end
