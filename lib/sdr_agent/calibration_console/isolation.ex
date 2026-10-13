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

  **Cleanup.** The root's tree is stopped through `Reaper.kill_tree/1`,
  then the root's group is observed until empty. A member left behind by
  an exiting root (re-parented, still in the group) is stopped only after
  its own start identity is re-read and shows it started no earlier than
  the root (whose identity was read at spawn), while the root pid is absent
  or still the root: never a blind signal to an unverified group or a
  reused pid. A tree that cannot be confirmed gone within the bound is
  `{:error, :calibration_isolation_cleanup_unconfirmed}`, never "stopped".

  **Bounds.** The caller waits at most `ready_ms + bound_ms`. On timeout,
  or when the caller itself dies (a watchdog process), the helper is
  killed, so its reaper stops the tracked tree and removes the directory;
  the caller then waits (bounded) for that reaper to finish.

  Any other timeout, probe error, early exit or crash is `{:error,
  :calibration_isolation_unavailable}`. This is the observed process-group
  scope: a descendant that changes its group escapes it (OQ-E3).

  `probe:` names the OS probe (default
  `SdrAgent.CalibrationConsole.ProcessProbe`). Only test-seam builds honour
  `target:` (the shell script), `ready_ms:`, `bound_ms:` and `observer:`
  (`fn event -> any end`, called with `{:helper, pid}`, `{:workspace,
  path}` and `{:spawned, os_pid}`); other builds always use the held target
  and the default bounds.
  """

  alias SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper
  alias SdrAgent.CalibrationConsole.ProcessProbe

  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)
  @target "printf ready; IFS= read -r _"
  @ready_ms 5_000
  @bound_ms 15_000
  @gone_ms 4_000
  @reaper_ms 10_000
  @poll_ms 20
  @hold_ms 100
  @port_opts [:binary, :exit_status]
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
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

    await(
      ref,
      helper,
      monitor,
      System.monotonic_time(:millisecond) + seams.ready_ms + seams.bound_ms,
      nil
    )
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

  defp await(ref, helper, monitor, deadline, reaper) do
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^ref, {:reaper, pid}} ->
        await(ref, helper, monitor, deadline, pid)

      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^helper, _reason} ->
        reaped(reaper)
        @unavailable
    after
      wait ->
        # Out of time: the helper's reaper stops the tracked tree.
        Process.demonitor(monitor, [:flush])
        Process.exit(helper, :kill)
        reaped(reaper)
        @unavailable
    end
  end

  # Waits (bounded) for the helper's reaper to finish its cleanup.
  defp reaped(nil), do: :ok

  defp reaped(reaper) do
    ref = Process.monitor(reaper)

    receive do
      {:DOWN, ^ref, :process, ^reaper, _reason} -> :ok
    after
      @reaper_ms -> Process.demonitor(ref, [:flush])
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
      {:ok, reaper} = Reaper.start(nil)
      send(caller, {ref, {:reaper, reaper}})
      Reaper.track(reaper, workspace)
      launch(reaper, workspace, seams, probe)
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

  defp launch(reaper, workspace, seams, probe) do
    deadline = System.monotonic_time(:millisecond) + seams.ready_ms
    spawn = {:spawn_executable, "/bin/sh"}

    case Reaper.open(reaper, workspace, spawn, port_opts(seams.target), deadline) do
      {:ok, port, os_pid} ->
        # The root's identity while it is certainly ours (before any exit
        # can be observed): it bounds which group members may be stopped.
        spawned = identity(probe, os_pid)
        seams.observer.({:spawned, os_pid})
        held(reaper, workspace, port, os_pid, spawned, deadline, probe)

      _not_opened_or_unknown ->
        @unavailable
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

    case stopped(os_pid, spawned, probe) do
      :ok ->
        Reaper.done(reaper, workspace)
        File.rmdir(workspace)
        if verified == :ok, do: :ok, else: @unavailable

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

  defp stopped(os_pid, spawned, probe) do
    case Reaper.kill_tree(os_pid) do
      :ok -> empty_group(os_pid, spawned, probe, System.monotonic_time(:millisecond) + @gone_ms)
      _timeout -> :unconfirmed
    end
  end

  # Observed until empty; a verified left-behind member is stopped.
  defp empty_group(os_pid, spawned, probe, deadline) do
    case observe(fn -> probe.group_members(os_pid) end) do
      {:ok, []} ->
        :ok

      {:ok, members} when is_list(members) ->
        Enum.each(members, &stop_member(&1, os_pid, spawned, probe))
        retry(os_pid, spawned, probe, deadline)

      _unavailable ->
        retry(os_pid, spawned, probe, deadline)
    end
  end

  defp retry(os_pid, spawned, probe, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      :unconfirmed
    else
      Process.sleep(@poll_ms)
      empty_group(os_pid, spawned, probe, deadline)
    end
  end

  # Only with the root's spawn identity known, the root pid absent or still
  # the root, and the member's own identity re-read and no earlier than it.
  defp stop_member(member, os_pid, {:ok, root}, probe) when is_integer(member) and member > 0 do
    with {:ok, root_start} <- instant(root),
         true <- identity(probe, os_pid) in [:absent, {:ok, root}],
         {:ok, own} <- identity(probe, member),
         {:ok, own_start} <- instant(own),
         true <- own_start >= root_start do
      Reaper.kill_tree(member)
    end
  end

  defp stop_member(_member, _os_pid, _spawned, _probe), do: :skipped

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

  # `lstart` in the C locale (`Tue Oct 13 13:00:00 2026`) as a comparable
  # tuple; anything else is not an instant.
  defp instant(identity) do
    with [_day, month, date, time, year] <- String.split(identity),
         month when is_integer(month) <- month_number(month),
         [hour, minute, second] <- String.split(time, ":"),
         {:ok, at} <-
           NaiveDateTime.new(
             String.to_integer(year),
             month,
             String.to_integer(date),
             String.to_integer(hour),
             String.to_integer(minute),
             String.to_integer(second)
           ) do
      {:ok, NaiveDateTime.to_erl(at)}
    else
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp month_number(name) do
    case Enum.find_index(@months, &(&1 == name)) do
      nil -> nil
      index -> index + 1
    end
  end

  if @test_seams do
    defp seams(opts) do
      %{
        target: Keyword.get(opts, :target, @target),
        ready_ms: Keyword.get(opts, :ready_ms, @ready_ms),
        bound_ms: Keyword.get(opts, :bound_ms, @bound_ms),
        observer: Keyword.get(opts, :observer, fn _event -> :ok end)
      }
    end
  else
    defp seams(_opts),
      do: %{target: @target, ready_ms: @ready_ms, bound_ms: @bound_ms, observer: fn _ -> :ok end}
  end
end
