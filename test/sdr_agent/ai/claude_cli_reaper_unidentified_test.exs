defmodule SdrAgent.AI.ClaudeCLIReaperUnidentifiedTest do
  @moduledoc """
  R0-07 slice E integration review (Codex, 75f275d): an opened launch whose
  OS pid cannot be read is unidentified, not "never launched". When the
  owner dies the reaper cannot confirm it stopped, so it exits **without**
  erasing the admission lease: a replacement server stays blocked
  (`:previous_cleanup_unconfirmed`) until an operator who has checked the
  machine runs `Reaper.release/1`. A workspace that was only tracked (never
  opened) still releases the lease as before. The pid lookup is forced
  unavailable through the reaper's `:os_pid` failure-injection option; those
  two tests launch a harmless `/usr/bin/true`.

  #198 (fix plan r4, Codex PASS 602d0890): the identified-launch subject must
  hold the identified state until it is observed. Its tests launch through
  the default, unguarded Reaper and prove the child live before owner death
  (READY, identity, PING/PONG) and gone after it (lease nil, identity
  absent), with a probe error never read as gone. They keep their own
  cleanup, registered before any launch, which works from registered state
  only: an exit proof (no launch, this port's own exit status, or the
  captured identity gone) is required before a lease held by this test's
  dead reaper is released, and an unproven child or helper is retained and
  reported, never signalled. A FIFO lives outside the Reaper's workspace,
  which the Reaper removes. Limits stated, not hidden: identities are read
  with `ProcessProbe`, a synchronous `/bin/ps` whose calls no bound here
  covers; an identity is captured only while the port is open before and
  after the read, assuming no outside party signals the child.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper
  alias SdrAgent.CalibrationConsole.ProcessProbe
  alias SdrAgent.ChildEnv

  @spawn {:spawn_executable, "/usr/bin/true"}
  @port_opts {[:binary, :exit_status], {[], []}}

  # #198: the identified-launch subject and its held-handshake fixture
  # (READY, PING/PONG, EXIT; stdin EOF ends it unless a FIFO holds it).
  @identified {:spawn_executable, "/usr/bin/true"}
  @fixture Path.expand("../../support/held_handshake.sh", __DIR__)

  setup tags do
    name = :"reaper_unidentified_#{System.unique_integer([:positive])}"
    if tags[:lease] != :proof_gated, do: on_exit(fn -> Reaper.release(name) end)
    %{name: name}
  end

  setup %{tmp_dir: tmp, name: name} = tags do
    if tags[:lease] == :proof_gated, do: identified_setup(tmp, name), else: :ok
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

  @tag lease: :proof_gated
  test "an identified launch is still reaped and releases the lease", %{name: name} = ctx do
    {owner, reaper, result} = launch_identified(ctx, [], [])

    assert {:ok, port, os_pid} = result
    identity = live_before!(ctx, port, os_pid)
    stop_subject!(ctx, owner, reaper)
    assert Reaper.lease(name) == nil
    assert observe_gone(os_pid, identity, &ProcessProbe.start_identity/1, 5_000) == :gone
  end

  @tag lease: :proof_gated
  test "an identified launch that ignores stdin EOF is still stopped by the reaper",
       %{name: name} = ctx do
    fifo = make_fifo!(ctx)
    {owner, reaper, result} = launch_identified(ctx, [fifo], [])

    assert {:ok, port, os_pid} = result
    identity = live_before!(ctx, port, os_pid)
    stop_subject!(ctx, owner, reaper)
    assert Reaper.lease(name) == nil
    assert observe_gone(os_pid, identity, &ProcessProbe.start_identity/1, 5_000) == :gone
  end

  @tag lease: :proof_gated
  test "a late pid lookup still finds the held launch identified", %{name: name} = ctx do
    {owner, reaper, result} = launch_identified(ctx, [], os_pid: &late_lookup/1)

    assert {:ok, port, os_pid} = result
    identity = live_before!(ctx, port, os_pid)
    stop_subject!(ctx, owner, reaper)
    assert Reaper.lease(name) == nil
    assert observe_gone(os_pid, identity, &ProcessProbe.start_identity/1, 5_000) == :gone
  end

  @tag lease: :proof_gated
  test "a probe error after owner death is never read as gone", %{name: name} = ctx do
    {owner, reaper, result} = launch_identified(ctx, [], [])

    assert {:ok, port, os_pid} = result
    identity = live_before!(ctx, port, os_pid)
    stop_subject!(ctx, owner, reaper)

    assert observe_gone(os_pid, identity, fn _pid -> {:error, :ps_failed} end, 1_000) ==
             :unverified

    assert observe_gone(os_pid, identity, &ProcessProbe.start_identity/1, 5_000) == :gone
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

  ## #198: the identified-launch subject

  # The Reaper's workspace (`ws`, removed by the Reaper) and the test's
  # private control directory (`ctl`, its sibling) are separate; the only
  # lease-releasing callback is the proof-gated cleanup below.
  defp identified_setup(tmp, name) do
    ws = Path.join(tmp, "ws")
    ctl = Path.join(tmp, "ctl")
    File.mkdir_p!(ws)
    File.mkdir_p!(ctl)
    File.chmod!(ctl, 0o700)
    {:ok, registry} = Agent.start(fn -> %{helpers: %{}, ports_seen: []} end)

    on_exit(fn ->
      case cleanup(registry, name, ctl) do
        :clean ->
          Agent.stop(registry)

        incomplete ->
          raise "#198 cleanup incomplete (state retained): " <>
                  inspect(incomplete, limit: :infinity, printable_limit: :infinity)
      end
    end)

    %{registry: registry, ws: ws, ctl: ctl}
  end

  # The owner registers itself, its reaper and the open before each reply
  # that depends on them, then relays the reaper's forwarded port messages
  # (reaper.ex:280-282), writing an exit status into the registry first.
  defp launch_identified(%{registry: reg, ws: ws, name: name}, extra_args, reaper_opts) do
    test = self()
    port_opts = {[:binary, :exit_status, args: [@fixture | extra_args]], {[], []}}
    owner = spawn(fn -> identified_owner(reg, test, name, ws, port_opts, reaper_opts) end)
    assert_receive {:opened, ^owner, reaper, result}, 10_000
    {owner, reaper, result}
  end

  defp identified_owner(reg, test, name, ws, port_opts, reaper_opts) do
    put(reg, owner: self())
    {:ok, reaper} = Reaper.start(name, reaper_opts)
    put(reg, reaper: reaper)
    Reaper.track(reaper, ws)
    put(reg, open_called?: true)
    deadline = System.monotonic_time(:millisecond) + 5_000
    result = Reaper.open(reaper, ws, @identified, port_opts, deadline)
    put(reg, opened(result))
    send(test, {:opened, self(), reaper, result})
    relay(reg, test)
  end

  defp opened({:ok, port, os_pid} = result), do: [open_result: result, port: port, os_pid: os_pid]
  defp opened(result), do: [open_result: result]

  defp relay(reg, test) do
    receive do
      {port, {:exit_status, status}} when is_port(port) ->
        note_port(reg, port)
        put(reg, exit_receipt: {port, status})
        send(test, {:fixture, port, {:exit_status, status}})
        relay(reg, test)

      {port, message} when is_port(port) ->
        note_port(reg, port)
        send(test, {:fixture, port, message})
        relay(reg, test)

      :exit ->
        :ok
    end
  end

  # Live-before: READY and PONG from `os_pid` itself, and its start identity
  # read while its port is open (it cannot leave before EOF or EXIT).
  defp live_before!(%{registry: reg}, port, os_pid) do
    assert {:ok, ^os_pid} = fixture_line(port, "READY", 5_000)
    assert {:ok, identity} = capture_identity(port, os_pid)
    put(reg, identity: identity, identity_pid: os_pid)
    assert Port.command(port, "PING\n")
    assert {:ok, ^os_pid} = fixture_line(port, "PONG", 5_000)
    assert ProcessProbe.start_identity(os_pid) == {:ok, identity}
    put(reg, armed?: true)
    identity
  end

  defp stop_subject!(%{registry: reg}, owner, reaper) do
    put(reg, subject_stop: :requested)
    stop_owner(owner, reaper)
    put(reg, subject_stop: :confirmed)
  end

  defp capture_identity(port, pid) do
    open_before? = Port.info(port) != nil
    read = ProcessProbe.start_identity(pid)
    open_after? = Port.info(port) != nil

    case {open_before?, read, open_after?} do
      {true, {:ok, identity}, true} -> {:ok, identity}
      other -> {:error, {:not_provably_alive, other}}
    end
  end

  # `:gone` only for an absent pid or another start identity; a read error
  # is `:unverified` and the same identity `:still_present` (at the bound).
  defp observe_gone(pid, identity, reader, within) do
    observe_until(pid, identity, reader, now() + within)
  end

  defp observe_until(pid, identity, reader, deadline) do
    outcome = observation(reader.(pid), identity)

    cond do
      outcome == :gone ->
        :gone

      now() >= deadline ->
        outcome

      true ->
        Process.sleep(20)
        observe_until(pid, identity, reader, deadline)
    end
  end

  defp observation(:absent, _identity), do: :gone
  defp observation({:ok, identity}, identity), do: :still_present
  defp observation({:ok, _other}, _identity), do: :gone
  defp observation(_error, _identity), do: :unverified

  # Runs inside the reaper (the port owner): waits, bounded, for a complete
  # line in the reaper's own mailbox (peek only), then performs exactly the
  # lookup of reaper.ex:366 and returns its result unchanged.
  defp late_lookup(port) do
    await_line(port, now() + 2_000)
    Port.info(port, :os_pid)
  end

  defp await_line(port, deadline) do
    cond do
      line_queued?(port) ->
        :observed

      now() >= deadline ->
        :timeout

      true ->
        Process.sleep(1)
        await_line(port, deadline)
    end
  end

  defp line_queued?(port) do
    {:messages, messages} = Process.info(self(), :messages)

    messages
    |> Enum.flat_map(fn
      {^port, {:data, data}} -> [data]
      _other -> []
    end)
    |> Enum.join()
    |> String.contains?("\n")
  end

  defp fixture_line(port, tag, within), do: take_line(port, tag, now() + within)

  defp take_line(port, tag, deadline) do
    buffer = Process.get({:fixture_buffer, port}, "")

    case String.split(buffer, "\n", parts: 2) do
      [line, rest] ->
        Process.put({:fixture_buffer, port}, rest)
        parse_line(line, tag)

      [_partial] ->
        receive do
          {:fixture, ^port, {:data, data}} ->
            Process.put({:fixture_buffer, port}, buffer <> data)
            take_line(port, tag, deadline)

          {:fixture, ^port, {:exit_status, status}} ->
            {:error, {:exited, status}}
        after
          max(deadline - now(), 0) -> {:error, :timeout}
        end
    end
  end

  defp parse_line(line, tag) do
    with [^tag, digits] <- String.split(line, " "),
         {pid, ""} when pid > 0 <- Integer.parse(digits) do
      {:ok, pid}
    else
      _other -> {:error, {:unexpected_line, line}}
    end
  end

  ## The FIFO (eof-hold) and its one external helper

  defp make_fifo!(%{registry: reg, ctl: ctl}) do
    fifo = Path.join(ctl, "release.fifo")
    assert run_helper(reg, :mkfifo, "mkfifo", ["-m", "600", fifo], 5_000) == {:exited, 0}
    assert {:ok, %File.Stat{type: :other}} = File.lstat(fifo)
    put(reg, fifo: fifo)
    fifo
  end

  # The helper's port is registered as the very next step after it opens;
  # its pid is a report only. Its exit status is the only proof it ended. It
  # is never signalled: an unconfirmed helper stays registered.
  defp run_helper(reg, key, exe, args, bound) do
    path = System.find_executable(exe) || flunk("#{exe} not found")
    env = ChildEnv.port([], [])

    port =
      Port.open({:spawn_executable, path}, [:binary, :exit_status, {:args, args}, {:env, env}])

    put_helper(reg, key, %{port: port, path: path, args: args, owner: self(), state: :running})
    put_helper(reg, key, %{os_pid_report: Port.info(port, :os_pid)})

    receive do
      {^port, {:exit_status, status}} ->
        put_helper(reg, key, %{state: {:exited, status}})
        {:exited, status}
    after
      bound ->
        put_helper(reg, key, %{state: :unconfirmed})
        :unconfirmed
    end
  end

  # No extra process: refuses anything but an existing FIFO, then writes one
  # line to it from a bounded task (opening a FIFO read-write never blocks).
  defp release_fifo(fifo) do
    case File.lstat(fifo) do
      {:ok, %File.Stat{type: :other}} -> bounded_fifo_write(fifo)
      other -> {:incomplete, {:fifo_unavailable, other}}
    end
  end

  defp bounded_fifo_write(fifo) do
    task = Task.async(fn -> write_fifo(fifo) end)

    case Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} -> :ok
      other -> {:incomplete, {:fifo_release, other}}
    end
  end

  defp write_fifo(fifo) do
    with {:ok, fd} <- :file.open(fifo, [:read, :write, :raw, :binary]) do
      result = :file.write(fd, "EXIT\n")
      :ok = :file.close(fd)
      result
    end
  end

  ## Cleanup from registered state (on_exit only, after every assertion)

  defp cleanup(reg, name, ctl) do
    with :ok <- await_open_result(reg),
         {:ok, early} <- early_proof(reg, get(reg)),
         :ok <- teardown(get(reg)),
         {:ok, _proof} <- exit_proof(get(reg), early),
         :ok <- helpers_ended(get(reg)),
         :ok <- settle_lease(get(reg), name) do
      File.rm_rf!(ctl)
      :clean
    else
      {:incomplete, reason} -> {:incomplete, reason, get(reg), Reaper.lease(name)}
    end
  end

  # A launch whose open was called but whose result is not yet registered:
  # wait for it (the open deadline is 5 000 ms) before acting.
  defp await_open_result(reg) do
    state = get(reg)

    cond do
      not Map.get(state, :open_called?, false) -> :ok
      Map.has_key?(state, :open_result) -> :ok
      wait_until(fn -> Map.has_key?(get(reg), :open_result) end, 6_000) -> :ok
      true -> {:incomplete, :open_result_missing}
    end
  end

  # Before any teardown, while the reaper still forwards its port: an
  # unarmed launch's exit status (asking a held child to EXIT first).
  defp early_proof(reg, state) do
    cond do
      not Map.get(state, :open_called?, false) -> {:ok, :no_launch}
      Map.get(state, :armed?, false) -> {:ok, :pending}
      valid_receipt?(state) -> {:ok, :exit_receipt}
      true -> await_receipt(reg, state)
    end
  end

  defp await_receipt(reg, state) do
    ask_exit(Map.get(state, :port))

    if wait_until(fn -> valid_receipt?(get(reg)) end, 5_000),
      do: {:ok, :exit_receipt},
      else: {:ok, :none}
  end

  defp ask_exit(port) when is_port(port) do
    if Port.info(port), do: Port.command(port, "EXIT\n")
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp ask_exit(_port), do: :ok

  # This entry's single port, and only it, reported an exit status.
  defp valid_receipt?(state) do
    case {Map.get(state, :exit_receipt), Map.get(state, :port), Map.get(state, :ports_seen)} do
      {{port, _status}, port, [port]} when is_port(port) -> true
      _other -> false
    end
  end

  # Unarmed: the exact reaper process first, the owner only after its DOWN.
  # Armed: the owner's exit runs the reaper's own reap; a reaper still alive
  # after the bound is stopped as a process. Unconfirmed: retained.
  defp teardown(%{armed?: true} = state) do
    with :ok <- armed_owner(Map.get(state, :owner)) do
      armed_reaper(Map.get(state, :reaper))
    end
  end

  defp teardown(state) do
    with :ok <- kill_exact(Map.get(state, :reaper), :reaper) do
      kill_exact(Map.get(state, :owner), :owner)
    end
  end

  defp armed_owner(owner) when is_pid(owner) do
    if Process.alive?(owner) do
      ref = Process.monitor(owner)
      send(owner, :exit)
      if down?(ref, owner, 10_000), do: :ok, else: kill_exact(owner, :owner)
    else
      :ok
    end
  end

  defp armed_owner(_owner), do: :ok

  defp armed_reaper(reaper) when is_pid(reaper) do
    ref = Process.monitor(reaper)
    if down?(ref, reaper, 10_000), do: :ok, else: kill_exact(reaper, :reaper)
  end

  defp armed_reaper(_reaper), do: :ok

  defp kill_exact(pid, who) when is_pid(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    if down?(ref, pid, 5_000), do: :ok, else: {:incomplete, {who, :kill_unconfirmed}}
  end

  defp kill_exact(_pid, _who), do: :ok

  defp down?(ref, pid, within) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> true
    after
      within ->
        Process.demonitor(ref, [:flush])
        false
    end
  end

  defp exit_proof(_state, early) when early in [:no_launch, :exit_receipt], do: {:ok, early}

  defp exit_proof(state, _early) do
    cond do
      is_binary(Map.get(state, :identity)) -> identity_proof(state)
      valid_receipt?(state) -> {:ok, :exit_receipt}
      true -> {:incomplete, :no_child_exit_proof}
    end
  end

  # The real probe only; an eof-hold child still present is released
  # through its FIFO (no signal), then observed again.
  defp identity_proof(state) do
    %{identity_pid: pid, identity: identity} = state

    case observe_gone(pid, identity, &ProcessProbe.start_identity/1, 5_000) do
      :gone -> {:ok, :identity_gone}
      outcome -> fifo_proof(state, outcome)
    end
  end

  defp fifo_proof(%{fifo: fifo, identity_pid: pid, identity: identity}, _outcome) do
    with :ok <- release_fifo(fifo) do
      case observe_gone(pid, identity, &ProcessProbe.start_identity/1, 5_000) do
        :gone -> {:ok, :identity_gone_after_fifo_release}
        outcome -> {:incomplete, {:child_not_proven_gone, pid, identity, fifo, outcome}}
      end
    end
  end

  defp fifo_proof(%{identity_pid: pid, identity: identity}, outcome),
    do: {:incomplete, {:child_not_proven_gone, pid, identity, outcome}}

  defp helpers_ended(state) do
    case Enum.reject(Map.get(state, :helpers, %{}), &match?({_key, %{state: {:exited, _}}}, &1)) do
      [] -> :ok
      pending -> {:incomplete, {:helpers_not_proven_ended, pending}}
    end
  end

  # Nil: nothing to release. This test's exact dead reaper (with the exit
  # proof already established): released. Anything else: retained.
  defp settle_lease(state, name) do
    reaper = Map.get(state, :reaper)

    case Reaper.lease(name) do
      nil -> :ok
      {:held, ^reaper} when is_pid(reaper) -> release_dead_holder(reaper, name)
      {:held, other} -> {:incomplete, {:lease_not_ours, other}}
    end
  end

  defp release_dead_holder(reaper, name) do
    with false <- Process.alive?(reaper),
         :ok <- Reaper.release(name),
         nil <- Reaper.lease(name) do
      :ok
    else
      _other -> {:incomplete, {:lease_not_released, reaper}}
    end
  end

  ## Registry and time

  defp put(reg, fields), do: Agent.update(reg, &Map.merge(&1, Map.new(fields)))

  defp put_helper(reg, key, fields) do
    Agent.update(reg, fn state ->
      helper = Map.merge(Map.get(state.helpers, key, %{}), fields)
      %{state | helpers: Map.put(state.helpers, key, helper)}
    end)
  end

  defp note_port(reg, port) do
    Agent.update(reg, fn state ->
      state
      |> Map.update(:ports_seen, [port], &Enum.uniq([port | &1]))
      |> Map.update(:port, port, &(&1 || port))
    end)
  end

  defp get(reg), do: Agent.get(reg, & &1)

  defp wait_until(check, within), do: poll(check, now() + within)

  defp poll(check, deadline) do
    cond do
      check.() ->
        true

      now() >= deadline ->
        false

      true ->
        Process.sleep(10)
        poll(check, deadline)
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
