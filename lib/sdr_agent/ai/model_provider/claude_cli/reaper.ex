defmodule SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper do
  @moduledoc """
  Crash-safe owner of a `SdrAgent.AI.ModelProvider.ClaudeCLI` server's
  external CLI work (Q0.1 review).

  A Port closes when its owner dies, but the OS processes behind it keep
  running, and an `Process.exit(server, :kill)` runs no cleanup in the
  server. So every server starts one reaper: a separate, unlinked process
  that monitors the server. Before a launch the server tells it the private
  workspace (`track/2`), then the CLI's OS pid (`launched/3`), and after the
  call — once that process tree is gone and the workspace removed —
  `untrack/2`. Messages from the server arrive before its `:DOWN`, so when
  the server dies for any reason the reaper kills every tracked tree (root
  and descendants: TERM, then KILL, then waits until each is gone or a
  zombie), removes its workspace, and exits.

  A named server's reaper is registered as `name(server)`. A replacement
  server waits in `init/1` until the previous reaper has exited
  (`await_previous/1`), so it admits no call while old work is live
  (concurrency stays one across restarts). The server monitors its reaper
  and stops if it dies.

  Residual window: a kill between `Port.open/2` returning and `launched/3`
  leaves the reaper the workspace but not the OS pid; the workspace is
  still removed. Descendants that re-parent away from the root before the
  kill are not found (as for the timeout path).
  """

  @await_previous_ms 10_000
  @exit_wait_ms 2_000

  @doc "The registered name of a named server's reaper; `nil` for an unnamed server."
  def name(server) when is_atom(server) and not is_nil(server),
    do: Module.concat([server, "Reaper"])

  def name(_server), do: nil

  @doc "Waits until the reaper registered as `name` (if any) has finished and exited."
  def await_previous(nil), do: :ok

  def await_previous(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          @await_previous_ms -> exit(:previous_cli_not_quiescent)
        end
    end
  end

  @doc "Starts the reaper of the calling server (registered as `name` unless nil)."
  def start(name) do
    owner = self()
    {pid, _ref} = spawn_monitor(fn -> watch(owner) end)
    if name, do: Process.register(pid, name)
    pid
  end

  @doc "Records a launch's private workspace before its process starts."
  def track(reaper, workspace), do: send(reaper, {:track, workspace})

  @doc "Records the OS pid of the launch in `workspace`."
  def launched(reaper, workspace, os_pid), do: send(reaper, {:launched, workspace, os_pid})

  @doc "Forgets a launch whose process tree is gone and whose workspace is removed."
  def untrack(reaper, workspace), do: send(reaper, {:untrack, workspace})

  @doc """
  Terminates the process tree rooted at `os_pid` (descendants first, then
  the root): TERM, a short grace, KILL, then waits until each is gone.
  """
  def kill_tree(os_pid) do
    tree = Enum.reverse(descendants(os_pid)) ++ [os_pid]
    Enum.each(tree, &signal(&1, "-TERM"))
    Process.sleep(20)
    tree |> Enum.filter(&alive?/1) |> Enum.each(&signal(&1, "-KILL"))
    await_exit(tree, System.monotonic_time(:millisecond) + @exit_wait_ms)
  end

  @doc "Whether OS process `pid` is running (a zombie counts as gone)."
  def alive?(pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {stat, 0} -> String.trim(stat) != "" and not String.starts_with?(String.trim(stat), "Z")
      _ -> false
    end
  end

  defp watch(owner) do
    ref = Process.monitor(owner)
    loop(ref, %{})
  end

  defp loop(ref, launches) do
    receive do
      {:track, workspace} ->
        loop(ref, Map.put(launches, workspace, nil))

      {:launched, workspace, os_pid} ->
        loop(ref, Map.put(launches, workspace, os_pid))

      {:untrack, workspace} ->
        loop(ref, Map.delete(launches, workspace))

      {:DOWN, ^ref, :process, _owner, _reason} ->
        Enum.each(launches, &reap/1)
    end
  end

  defp reap({workspace, os_pid}) do
    if os_pid, do: kill_tree(os_pid)
    File.rm_rf(workspace)
  end

  defp await_exit(tree, deadline) do
    cond do
      not Enum.any?(tree, &alive?/1) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      true ->
        Process.sleep(10)
        await_exit(tree, deadline)
    end
  end

  defp signal(pid, signal),
    do: System.cmd("kill", [signal, Integer.to_string(pid)], stderr_to_stdout: true)

  defp descendants(pid) do
    children =
      case System.cmd("pgrep", ["-P", Integer.to_string(pid)], stderr_to_stdout: true) do
        {output, 0} -> output |> String.split() |> Enum.map(&String.to_integer/1)
        _ -> []
      end

    children ++ Enum.flat_map(children, &descendants/1)
  end
end
