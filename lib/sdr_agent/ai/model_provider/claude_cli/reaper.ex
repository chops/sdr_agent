defmodule SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper do
  @moduledoc """
  Crash-safe owner of a `SdrAgent.AI.ModelProvider.ClaudeCLI` server's
  external CLI work, and the admission lease of a named server (Q0.1
  review).

  A Port's OS process keeps running when the Port's owner dies, and
  `Process.exit(server, :kill)` runs no cleanup in the server. So every
  server starts one reaper — a separate, unlinked process that monitors the
  server — and launches only through it:

    * `track/2` records a private workspace before anything is written to
      it.
    * `open/4` makes the reaper itself call `Port.open/2`, so the reaper
      knows the OS pid before the launch exists for anyone else (there is
      no hand-off window). The reaper stays the port owner and forwards
      every port message, in order, to the server.
    * `done/2` — sent only once the server has seen the process tree gone
      and removed the workspace — closes the port and forgets the launch.

  When the server dies, for any reason, the reaper kills every tracked tree
  (descendants, then the root: TERM, a short grace, KILL, then waits until
  each is gone or a zombie), removes its workspace, and only then releases
  the lease and exits. A tree it cannot confirm stopped is retried every
  `retry_ms`, with an error logged, and the lease stays held meanwhile.

  ## Admission lease (named servers)

  The lease is a `:persistent_term` entry `{Reaper, name} => {:held,
  reaper_pid}`, written when a reaper starts (once per server start, not
  per call) and erased only by that reaper as its cleanup receipt, or by
  `release/1`. A server whose lease is held by another reaper refuses calls
  (`{:error, :provider_not_quiescent}`):

    * held by a live reaper (still cleaning up) — admitted once it exits;
    * held by a dead reaper — its cleanup was never confirmed (the reaper
      died abnormally), so admission stays closed until an operator who has
      checked that no `claude` process of the previous server is left runs
      `SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper.release(SdrAgent.AI.ModelProvider.ClaudeCLI)`.

  Unnamed servers (tests) have no lease, only the reaper.

  Limitation: descendants that re-parent away from the root before a kill
  are not found (the tree is walked with `pgrep -P`).

  Options (`:reaper` of the server; failure injection for tests):
  `:signal` (`fn os_pid, "-TERM" | "-KILL" -> any end`), `:exit_wait_ms`
  (default 2000), `:retry_ms` (default 1000).
  """

  require Logger

  @exit_wait_ms 2_000
  @retry_ms 1_000

  @doc """
  Starts the calling server's reaper, taking the lease of `name` (nil for an
  unnamed server). Returns `{:ok, reaper}` or `{:blocked, reason}` when the
  lease is held by another reaper (`:previous_cli_not_quiescent` while it
  still runs, `:previous_cleanup_unconfirmed` when it died). `takeover:
  pid` replaces a lease held by that dead reaper — for a server that has
  itself confirmed nothing of its own is left running.
  """
  def start(name, opts \\ []) do
    {takeover, opts} = Keyword.pop(opts, :takeover)

    case lease(name) do
      nil -> {:ok, spawn_reaper(name, opts)}
      {:held, ^takeover} when is_pid(takeover) -> {:ok, spawn_reaper(name, opts)}
      {:held, holder} -> {:blocked, blocked_reason(holder)}
    end
  end

  @doc "Who holds the lease of `name`: `nil` or `{:held, reaper_pid}`."
  def lease(nil), do: nil
  def lease(name), do: :persistent_term.get(key(name), nil)

  @doc """
  Operator release of a lease left by a reaper that died without its
  cleanup receipt. Refused while that reaper still runs. The server
  registered as `name`, if any, is told to re-check its admission.
  """
  def release(name) do
    case lease(name) do
      nil -> :ok
      {:held, holder} -> release(name, holder, Process.alive?(holder))
    end
  end

  defp release(_name, _holder, true = _running), do: {:error, :reaper_running}

  defp release(name, holder, false) do
    erase(name, holder)
    with pid when is_pid(pid) <- Process.whereis(name), do: send(pid, :admission_check)
    :ok
  end

  @doc "Records a launch's private workspace before anything is written to it."
  def track(reaper, workspace), do: send(reaper, {:track, workspace})

  @doc """
  Opens the launch's port in the reaper (`Port.open(spawn, port_opts)`), so
  its OS pid is owned before the process can do anything. Returns `{:ok,
  port, os_pid}`; port messages are forwarded to the caller.
  """
  def open(reaper, workspace, spawn, port_opts) do
    ref = Process.monitor(reaper)
    send(reaper, {:open, ref, workspace, spawn, port_opts})

    receive do
      {^ref, reply} ->
        Process.demonitor(ref, [:flush])
        reply

      {:DOWN, ^ref, :process, ^reaper, _reason} ->
        {:error, :reaper_down}
    end
  end

  @doc "Closes and forgets a launch whose tree is gone and workspace removed."
  def done(reaper, workspace), do: send(reaper, {:done, workspace})

  @doc """
  Terminates the process tree rooted at `os_pid` (descendants first, then
  the root): TERM, a short grace, KILL, then waits until each is gone.
  `:ok`, or `:timeout` when some process is still running.
  """
  def kill_tree(os_pid, opts \\ []) do
    signal = Keyword.get(opts, :signal, &signal/2)
    tree = Enum.reverse(descendants(os_pid)) ++ [os_pid]
    Enum.each(tree, &signal.(&1, "-TERM"))
    Process.sleep(20)
    tree |> Enum.filter(&alive?/1) |> Enum.each(&signal.(&1, "-KILL"))
    wait = Keyword.get(opts, :exit_wait_ms, @exit_wait_ms)
    await_exit(tree, System.monotonic_time(:millisecond) + wait)
  end

  @doc "Whether OS process `pid` is running (a zombie counts as gone)."
  def alive?(pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {stat, 0} -> String.trim(stat) != "" and not String.starts_with?(String.trim(stat), "Z")
      _ -> false
    end
  end

  # The reaper accepts work only from its owner, which sends none before
  # this returns; the lease names it first. If the owner is already gone,
  # the monitor reports it at once and the reaper exits with nothing to do.
  defp spawn_reaper(name, opts) do
    owner = self()
    {pid, _monitor} = spawn_monitor(fn -> watch(owner, name, opts) end)
    if name, do: :persistent_term.put(key(name), {:held, pid})
    pid
  end

  defp blocked_reason(holder) do
    if Process.alive?(holder),
      do: :previous_cli_not_quiescent,
      else: :previous_cleanup_unconfirmed
  end

  defp watch(owner, name, opts) do
    ref = Process.monitor(owner)
    loop(%{ref: ref, owner: owner, name: name, opts: opts, launches: %{}})
  end

  defp loop(state) do
    receive do
      {:track, workspace} ->
        loop(put_in(state.launches[workspace], nil))

      {:open, ref, workspace, spawn, port_opts} ->
        {reply, state} = open_port(state, workspace, spawn, port_opts)
        send(state.owner, {ref, reply})
        loop(state)

      {:done, workspace} ->
        {launch, launches} = Map.pop(state.launches, workspace)
        with {port, _os_pid} <- launch, do: close(port)
        loop(%{state | launches: launches})

      {:DOWN, ref, :process, _owner, _reason} when ref == state.ref ->
        reap(state)

      {port, _message} = message when is_port(port) ->
        send(state.owner, message)
        loop(state)
    end
  end

  defp open_port(state, workspace, spawn, port_opts) do
    port = Port.open(spawn, port_opts)
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {{:ok, port, os_pid}, put_in(state.launches[workspace], {port, os_pid})}
  rescue
    error -> {{:error, {:launch_failed, Exception.message(error)}}, state}
  end

  # Kills every tracked tree and removes its workspace; releases the lease
  # (the cleanup receipt) only when all are confirmed gone, retrying until
  # then.
  defp reap(state) do
    remaining = Enum.reject(state.launches, &stop(&1, state.opts))

    if remaining == [] do
      if state.name, do: erase(state.name, self())
      :ok
    else
      Logger.error(
        "ClaudeCLI reaper could not confirm #{length(remaining)} CLI process tree(s) stopped; " <>
          "calls stay refused until they are gone"
      )

      Process.sleep(Keyword.get(state.opts, :retry_ms, @retry_ms))
      reap(%{state | launches: Map.new(remaining)})
    end
  end

  defp stop({workspace, nil}, _opts) do
    File.rm_rf(workspace)
    true
  end

  defp stop({workspace, {port, os_pid}}, opts) do
    if kill_tree(os_pid, opts) == :ok do
      close(port)
      File.rm_rf(workspace)
      true
    else
      false
    end
  end

  defp close(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp erase(name, holder) do
    with {:held, ^holder} <- lease(name), do: :persistent_term.erase(key(name))
    :ok
  end

  defp key(name), do: {__MODULE__, name}

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
