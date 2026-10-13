defmodule SdrAgent.CalibrationConsole.Isolation do
  @moduledoc """
  The calibration console's process-group isolation check (R0-07 slice
  E4c-1, packet 8.12; entity PASS at 25c1b18). An Erlang Port child is
  already the leader of its own process group, so no wrapper is used: the
  harness verifies the group instead.

    * `preflight/1` — a capability check that launches no CLI. Through the
      existing `Reaper.start/track/open` + `SdrAgent.ChildEnv` shape it
      opens a held synthetic target (`/bin/sh -c 'printf ready; IFS= read
      -r _'`), waits (bounded) for `ready`, requires the root's start
      identity and its own group (`verify_group/2`), closes the port (EOF
      on stdin), and confirms the tree gone through the reaper and an
      observed empty group. It runs in a short-lived owner process, so its
      unnamed reaper (no admission lease) ends with it.
    * `verify_group/2` — a launched root has a start identity, is not this
      VM, and is listed in its own group (`pgid == root pid`).

  Any timeout, probe error, early exit or unconfirmed cleanup is `{:error,
  :calibration_isolation_unavailable}`, never a pass; the target is stopped
  either way. This is the observed process-group scope: a descendant that
  changes its group escapes it (OQ-E3).

  `probe:` names the OS probe (default
  `SdrAgent.CalibrationConsole.ProcessProbe`). Only test-seam builds honour
  `target:` (the shell script), `ready_ms:` and `observer:` (`fn {:spawned,
  os_pid} -> any end`); other builds always use the held target and the
  default bounds.
  """

  alias SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper
  alias SdrAgent.CalibrationConsole.ProcessProbe

  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)
  @target "printf ready; IFS= read -r _"
  @ready_ms 5_000
  @gone_ms 2_000
  @poll_ms 20
  @hold_ms 100
  @port_opts [:binary, :exit_status]
  @unavailable {:error, :calibration_isolation_unavailable}

  @doc "`:ok` or `{:error, :calibration_isolation_unavailable}` (see the moduledoc)."
  def preflight(opts) do
    parent = self()
    ref = make_ref()

    {owner, monitor} =
      spawn_monitor(fn -> send(parent, {ref, run(seams(opts), Keyword.get(opts, :probe))}) end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        @unavailable
    end
  end

  @doc "`:ok` when `os_pid` is a live root leading its own group; else unavailable."
  def verify_group(os_pid, opts) do
    probe = Keyword.get(opts, :probe) || ProcessProbe

    with true <- is_integer(os_pid) and os_pid > 0,
         {:ok, vm} when vm != os_pid <- probe.self_pid(),
         {:ok, identity} when is_binary(identity) <- probe.start_identity(os_pid),
         {:ok, members} when is_list(members) <- probe.group_members(os_pid),
         true <- os_pid in members and vm not in members do
      :ok
    else
      _ -> @unavailable
    end
  rescue
    _error -> @unavailable
  end

  # In the owner process: the reaper is unnamed and exits with it.
  defp run(seams, probe) do
    probe = probe || ProcessProbe
    workspace = "isolation-preflight-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, reaper} = Reaper.start(nil)
    Reaper.track(reaper, workspace)
    deadline = System.monotonic_time(:millisecond) + seams.ready_ms
    spawn = {:spawn_executable, "/bin/sh"}

    case Reaper.open(reaper, workspace, spawn, port_opts(seams.target), deadline) do
      {:ok, port, os_pid} ->
        seams.observer.({:spawned, os_pid})
        held(reaper, workspace, port, os_pid, deadline, probe)

      _not_opened_or_unknown ->
        @unavailable
    end
  end

  defp port_opts(target), do: {[{:args, ["-c", target]} | @port_opts], {[], []}}

  defp held(reaper, workspace, port, os_pid, deadline, probe) do
    verified =
      with :ok <- await_ready(port, deadline),
           :ok <- verify_group(os_pid, probe: probe),
           do: still_held(port)

    # EOF on stdin, then the tree confirmed gone (by the reaper, then an
    # observed empty group) exactly once, whatever the verification found.
    Reaper.done(reaper, workspace)
    cleanup = stopped(os_pid, probe)

    if verified == :ok and cleanup == :ok, do: :ok, else: @unavailable
  end

  # The held target exits only on EOF: an exit before the close means it
  # merely ran briefly, which proves nothing about isolation.
  defp still_held(port) do
    receive do
      {^port, {:exit_status, _status}} -> :exited
    after
      @hold_ms -> :ok
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

  defp stopped(os_pid, probe) do
    with :ok <- Reaper.kill_tree(os_pid) do
      empty_group(os_pid, probe, System.monotonic_time(:millisecond) + @gone_ms)
    end
  end

  defp empty_group(os_pid, probe, deadline) do
    cond do
      probe.group_members(os_pid) == {:ok, []} ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      true ->
        Process.sleep(@poll_ms)
        empty_group(os_pid, probe, deadline)
    end
  end

  if @test_seams do
    defp seams(opts) do
      %{
        target: Keyword.get(opts, :target, @target),
        ready_ms: Keyword.get(opts, :ready_ms, @ready_ms),
        observer: Keyword.get(opts, :observer, fn _event -> :ok end)
      }
    end
  else
    defp seams(_opts), do: %{target: @target, ready_ms: @ready_ms, observer: fn _ -> :ok end}
  end
end
