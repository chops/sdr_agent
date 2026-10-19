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
  absent), with a probe error never read as gone.

  #198 repair (plan r2, Codex PASS 84010d41). Every identified test owns a
  control entry under `tmp/reaper-198-control/` (outside every ExUnit
  `tmp_dir` reset) holding its FIFO and an append-only journal of attempts.
  The subject cleanup runs from the body or from on_exit and journals each
  attempt; an exit proof (no launch, this port's own exit status, or the
  captured identity gone) is required before a lease held by this test's
  dead reaper is released. An independent recovery, registered before
  launch and run last, ends an unresolved child through its own controls
  (EXIT for a receipt, or a FIFO line and teardown with a live-captured
  identity read as gone) and journals a separate recovery event; it never
  signals and never relabels the subject attempt. A module collector,
  registered in `setup_all` (its failure is not masked by failed tests),
  writes a retained per-run report under `tmp/reaper-198-reports/`, verifies
  it, deletes only resolved entries' exact files, and fails on anything
  unresolved or any unexpected incomplete attempt; an unresolved entry left
  by an earlier run fails `setup_all`. Limits stated, not hidden: identities
  are read with `ProcessProbe`, a synchronous `/bin/ps` whose calls no bound
  here covers; an identity is captured only while the port is open before
  and after the read, assuming no outside party signals the child.
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
  @identified {:spawn_executable, "/bin/sh"}
  @fixture Path.expand("../../support/held_handshake.sh", __DIR__)

  # #198 repair: durable roots outside every ExUnit tmp_dir reset subtree
  # (`/tmp/` is gitignored). Controls are disposable once resolved; reports
  # are never removed by a test.
  @project Path.expand("../../..", __DIR__)
  @control_root Path.join(@project, "tmp/reaper-198-control")
  @reports_root Path.join(@project, "tmp/reaper-198-reports")
  @selftest_root Path.join(@project, "tmp/reaper-198-control-selftest")
  @proofs [:no_launch, :exit_receipt, :identity_gone, :identity_gone_after_fifo_release]

  setup_all do
    run = start_run!()
    on_exit(fn -> finish_run!(run) end)
    %{run: run}
  end

  setup tags do
    name = :"reaper_unidentified_#{System.unique_integer([:positive])}"
    if tags[:lease] != :proof_gated, do: on_exit(fn -> Reaper.release(name) end)
    %{name: name}
  end

  setup tags do
    if tags[:lease] == :proof_gated, do: identified_setup(tags), else: :ok
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
    {owner, reaper, result} = launch_identified(ctx, [], os_pid: late_lookup(ctx.registry))

    assert {:ok, port, os_pid} = result
    assert Map.get(get(ctx.registry), :late_lookup) == :observed
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

  # The M5 shape without a mutant: the existing nil `:os_pid` seam makes the
  # launch unidentified, and the relay gate keeps its port unknown to the
  # cleanup's first snapshot (released only by the cleanup's own hook).
  @tag lease: :proof_gated
  test "an unidentified held launch is ended through its own controls and journalled complete",
       %{name: name} = ctx do
    fifo = make_fifo!(ctx)

    {owner, reaper, result} =
      launch_identified(ctx, [fifo], [os_pid: recovery_seam(ctx.registry)], relay_gate: true)

    assert result == {:unknown, :post_spawn_failure}
    capture_recovery_identity!(ctx)
    assert cleanup(ctx, on_first_snapshot: fn -> send(owner, {:relay_go, self()}) end) == :clean

    state = get(ctx.registry)
    assert is_port(state.port) and Map.get(state, :exit_sent_to) == state.port
    assert valid_receipt?(state)
    refute Process.alive?(owner) or Process.alive?(reaper)
    assert Reaper.lease(name) == nil
    assert state.helpers.mkfifo.state == {:exited, 0}
    assert {:error, :enoent} = File.lstat(fifo)
    assert {:ok, journal} = read_journal(ctx.entry)
    assert {:resolved, :exit_receipt} = last_outcome(journal.events)
    assert_retained_receipt!(journal, state.port)
  end

  # The deliberate incomplete attempt: journalled, visible to the collector's
  # classification, then recovered by the subject's own cleanup.
  @tag lease: :proof_gated
  test "an unproven cleanup is journalled incomplete, reported by the collector, and recoverable",
       %{name: name} = ctx do
    fifo = make_fifo!(ctx)

    {owner, reaper, result} =
      launch_identified(ctx, [fifo], [os_pid: recovery_seam(ctx.registry)], relay_gate: true)

    assert result == {:unknown, :post_spawn_failure}
    capture_recovery_identity!(ctx)

    assert {:incomplete, :no_exit_receipt, details} =
             cleanup(ctx, control_window: 300, expected_incomplete: true)

    assert %{port_known?: false, fifo_preloaded?: true} = details
    assert Process.alive?(owner) and Process.alive?(reaper)
    assert Reaper.lease(name) == {:held, reaper}
    assert {:ok, %File.Stat{type: :other}} = File.lstat(fifo)
    assert {:unresolved, _} = classify(entry_facts(ctx.entry))

    send(owner, {:relay_go, self()})
    assert cleanup(ctx) == :clean
    assert {:ok, journal} = read_journal(ctx.entry)
    assert {:resolved, :exit_receipt} = last_outcome(journal.events)
    assert_retained_receipt!(journal, get(ctx.registry).port)
    assert classify(entry_facts(ctx.entry)) == :resolved
  end

  test "the collector classifies journals and fails closed on anything unproven" do
    root = Path.join(@selftest_root, "#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    clean = {:subject_cleanup, {:clean, resolved_details()}, attempt_meta(false, 2)}
    incomplete = {:subject_cleanup, {:incomplete, :synthetic, %{}}, attempt_meta(false, 1)}
    expected = {:subject_cleanup, {:incomplete, :synthetic, %{}}, attempt_meta(true, 1)}
    recovered = {:recovery, {:resolved, resolved_details()}, %{at: utc()}}
    no_evidence = Map.delete(resolved_details(), :evidence)
    alive_actor = put_in(resolved_details(), [:evidence, :actors, :owner], {self(), true})

    helper_running =
      put_in(resolved_details(), [:evidence, :helpers], %{mkfifo: %{state: :running}})

    meta_missing = {:subject_cleanup, {:incomplete, :synthetic, %{}}, %{at: utc(), attempt: 1}}

    meta_invalid =
      {:subject_cleanup, {:incomplete, :synthetic, %{}},
       %{expected_incomplete: :maybe, at: utc(), attempt: 1}}

    cases = [
      resolved: {[clean], false, :resolved},
      flagged_recovered: {[incomplete, recovered], false, :flagged},
      flagged_after_expected: {[expected, incomplete, clean], false, :flagged},
      expected_then_clean: {[expected, clean], false, :resolved},
      pending_only: {[], false, :unresolved},
      incomplete_last: {[incomplete], false, :unresolved},
      unresolved_recovery:
        {[incomplete, {:recovery, {:unresolved, %{}}, %{at: utc()}}], false, :unresolved},
      fifo_still_present: {[clean], true, :unresolved},
      unreadable: {:garbage, false, :unresolved},
      missing: {:missing, false, :unresolved},
      trailing_unknown_event: {[clean, {:unexpected, :event}], false, :unresolved},
      malformed_terminal:
        {[{:subject_cleanup, :clean, attempt_meta(false, 1)}], false, :unresolved},
      expected_meta_missing: {[meta_missing, recovered], false, :unresolved},
      expected_meta_invalid: {[meta_invalid, recovered], false, :unresolved},
      two_expected_attempts: {[expected, expected, clean], false, :unresolved},
      expected_on_clean:
        {[{:subject_cleanup, {:clean, resolved_details()}, attempt_meta(true, 1)}], false,
         :unresolved},
      resolved_without_evidence:
        {[{:subject_cleanup, {:clean, no_evidence}, attempt_meta(false, 1)}], false, :unresolved},
      resolved_actor_alive:
        {[{:subject_cleanup, {:clean, alive_actor}, attempt_meta(false, 1)}], false, :unresolved},
      resolved_helper_running:
        {[{:subject_cleanup, {:clean, helper_running}, attempt_meta(false, 1)}], false,
         :unresolved},
      symlinked_entry: {:symlink, false, :unresolved}
    ]

    entries =
      Enum.map(cases, fn {label, spec} -> {label, write_selftest_entry!(root, label, spec)} end)

    for {label, entry} <- entries do
      {_events, _fifo?, want} = Keyword.fetch!(cases, label)
      facts = entry_facts(entry)
      got = classify(facts)
      assert class_kind(got) == want, "#{label}: got #{inspect(got)}"
      # Anything not resolved is never deletable.
      assert deletable?({facts, got}) == (want != :unresolved), "#{label}: deletable mismatch"
    end

    Enum.each(entries, fn {_label, entry} -> remove_selftest_entry!(entry) end)
    File.rmdir!(root)
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

  # The Reaper's workspace (`ws`, in tmp_dir, removed by the Reaper) and the
  # test's control entry (outside tmp_dir) are separate. The recovery is
  # registered first, so it runs after the subject cleanup (LIFO).
  defp identified_setup(%{tmp_dir: tmp, name: name, run: run, test: test}) do
    ws = Path.join(tmp, "ws")
    File.mkdir_p!(ws)
    entry = Path.join(@control_root, "#{run.id}-#{System.unique_integer([:positive])}")
    File.write!(run.ledger, "created #{entry}\n", [:append, :sync])
    File.mkdir!(entry)
    File.chmod!(entry, 0o700)
    write_journal!(entry, %{run: run.id, test: test, entry: entry, events: [{:pending, utc()}]})
    {:ok, registry} = Agent.start(fn -> %{helpers: %{}, ports_seen: []} end)
    ctx = %{registry: registry, ws: ws, ctl: entry, entry: entry, name: name}
    on_exit(fn -> recover!(ctx) end)
    on_exit(fn -> subject_on_exit!(ctx) end)
    ctx
  end

  # The owner registers itself, its reaper and the open before each reply
  # that depends on them, then relays the reaper's forwarded port messages
  # (reaper.ex:280-282), writing an exit status into the registry first. With
  # `relay_gate: true` it relays only after `{:relay_go, from}`.
  defp launch_identified(ctx, extra_args, reaper_opts, opts \\ []) do
    %{registry: reg, ws: ws, name: name, entry: entry} = ctx
    test = self()
    gate? = Keyword.get(opts, :relay_gate, false)
    port_opts = {[:binary, :exit_status, args: [@fixture | extra_args]], {[], []}}
    launch = {name, ws, port_opts, reaper_opts, gate?}
    owner = spawn(fn -> identified_owner(reg, test, launch) end)
    assert_receive {:opened, ^owner, reaper, result}, 10_000
    journal_event!(entry, {:launch, %{owner: owner, reaper: reaper, result: result}})
    {owner, reaper, result}
  end

  defp identified_owner(reg, test, {name, ws, port_opts, reaper_opts, gate?}) do
    put(reg, owner: self())
    {:ok, reaper} = Reaper.start(name, reaper_opts)
    put(reg, reaper: reaper)
    Reaper.track(reaper, ws)
    put(reg, open_called?: true)
    deadline = System.monotonic_time(:millisecond) + 5_000
    result = Reaper.open(reaper, ws, @identified, port_opts, deadline)
    put(reg, opened(result))
    if gate?, do: put(reg, relay_gate: :closed)
    send(test, {:opened, self(), reaper, result})
    if gate?, do: await_relay_go(reg, test), else: relay(reg, test)
  end

  defp await_relay_go(reg, test) do
    receive do
      {:relay_go, _from} ->
        put(reg, relay_gate: :open)
        relay(reg, test)

      :exit ->
        :ok
    end
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
  defp live_before!(%{registry: reg, entry: entry}, port, os_pid) do
    assert {:ok, ^os_pid} = fixture_line(port, "READY", 5_000)
    assert {:ok, identity} = capture_identity(port, os_pid)
    put(reg, identity: identity, identity_pid: os_pid)
    journal_event!(entry, {:recovery_route, %{port: port, pid: os_pid, identity: identity}})
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
    pid |> observe_gone_read(identity, reader, within) |> elem(0)
  end

  # The same observation, also returning the final raw read it rests on.
  defp observe_gone_read(pid, identity, reader, within) do
    observe_until(pid, identity, reader, now() + within)
  end

  defp observe_until(pid, identity, reader, deadline) do
    read = reader.(pid)
    outcome = observation(read, identity)

    cond do
      outcome == :gone ->
        {:gone, read}

      now() >= deadline ->
        {outcome, read}

      true ->
        Process.sleep(20)
        observe_until(pid, identity, reader, deadline)
    end
  end

  defp observation(:absent, _identity), do: :gone
  defp observation({:ok, identity}, identity), do: :still_present
  defp observation({:ok, _other}, _identity), do: :gone
  defp observation(_error, _identity), do: :unverified

  # The `:os_pid` lookup for :63c. It runs inside the reaper (the port
  # owner): it waits, bounded, for a complete line in the reaper's own
  # mailbox (peek only), records whether that line was `:observed` or the
  # wait hit `:timeout` (the test asserts `:observed`, so the lookup really
  # came after READY), then performs exactly the lookup of reaper.ex:366 and
  # returns its result unchanged. The 2_000 ms bound is a new bound for this
  # new state; it stays below the existing 5_000 ms open deadline, so the
  # open still answers in time, and no existing deadline is enlarged.
  defp late_lookup(reg) do
    fn port ->
      put(reg, late_lookup: await_line(port, now() + 2_000))
      Port.info(port, :os_pid)
    end
  end

  # The recovery route for :63e/:63f: the existing nil `:os_pid` seam shape
  # (the launch stays unidentified), which also records, under a key the
  # subject cleanup never reads, this port and the pid its READY line names
  # (waited for, bounded at 2_000 ms, in the reaper's own mailbox).
  defp recovery_seam(reg) do
    fn port ->
      observed = await_line(port, now() + 2_000)
      put(reg, recovery: %{port: port, ready_pid: queued_ready_pid(port), observed: observed})
      nil
    end
  end

  defp queued_ready_pid(port) do
    with [line | _] <- port |> queued_data() |> String.split("\n"),
         {:ok, pid} <- parse_line(line, "READY") do
      pid
    else
      _other -> nil
    end
  end

  # Captured in the body, before any subject cleanup: the port is open
  # before and after the read, and nothing has sent EXIT yet.
  defp capture_recovery_identity!(%{registry: reg, entry: entry}) do
    %{port: port, ready_pid: pid} = recovery = Map.fetch!(get(reg), :recovery)
    assert is_integer(pid), "recovery route: no READY pid (#{inspect(recovery)})"
    assert {:ok, identity} = capture_identity(port, pid)
    put(reg, recovery: Map.put(recovery, :identity, identity))
    journal_event!(entry, {:recovery_route, %{port: port, pid: pid, identity: identity}})
    {pid, identity}
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

  defp line_queued?(port), do: port |> queued_data() |> String.contains?("\n")

  defp queued_data(port) do
    {:messages, messages} = Process.info(self(), :messages)

    messages
    |> Enum.flat_map(fn
      {^port, {:data, data}} -> [data]
      _other -> []
    end)
    |> Enum.join()
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

  ## The subject cleanup (from the body or on_exit; every attempt journalled)

  defp cleanup(ctx, opts \\ []) do
    outcome = subject_cleanup(ctx, opts)

    expected? = Keyword.get(opts, :expected_incomplete, false)
    meta = attempt_meta(expected?, subject_attempts(ctx.entry) + 1)

    journal_event!(ctx.entry, {:subject_cleanup, outcome, meta})

    case outcome do
      {:clean, _details} -> :clean
      {:incomplete, reason, details} -> {:incomplete, reason, details}
    end
  end

  defp subject_cleanup(%{registry: reg, name: name}, opts) do
    with :ok <- await_open_result(reg),
         {:ok, early} <- early_proof(reg, get(reg), opts),
         :ok <- teardown(get(reg)),
         {:ok, proof, proof_evidence} <- exit_proof(get(reg), early),
         :ok <- helpers_ended(get(reg)),
         {:ok, lease} <- settle_lease(get(reg), name),
         {:ok, fifo} <- remove_fifo(get(reg)) do
      {:clean, completed(get(reg), name, {proof, proof_evidence}, lease, fifo)}
    else
      {:incomplete, reason} ->
        {:incomplete, reason, %{state: get(reg), lease: Reaper.lease(name)}}

      {:incomplete, :no_exit_receipt, details} ->
        {:incomplete, :no_exit_receipt,
         Map.merge(details, %{state: get(reg), lease: Reaper.lease(name)})}
    end
  end

  # The on_exit subject attempt: skipped when the body already resolved it.
  # A test-held relay gate is released first (after its first snapshot).
  defp subject_on_exit!(%{registry: reg} = ctx) do
    with {:ok, %{events: events}} <- read_journal(ctx.entry),
         {:resolved, _proof} <- last_outcome(events) do
      :ok
    else
      _unresolved ->
        raise_unless_clean!(cleanup(ctx, on_first_snapshot: fn -> release_gate(get(reg)) end))
    end
  end

  defp raise_unless_clean!(:clean), do: :ok

  defp raise_unless_clean!(incomplete) do
    raise "#198 subject cleanup incomplete (journalled; recovery runs next): " <>
            inspect(incomplete, limit: :infinity, printable_limit: :infinity)
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
  # unarmed launch goes through the control phase. The `on_first_snapshot`
  # hook runs after `state` was read.
  defp early_proof(reg, state, opts) do
    Keyword.get(opts, :on_first_snapshot, fn -> :ok end).()

    cond do
      not Map.get(state, :open_called?, false) -> {:ok, :no_launch}
      Map.get(state, :armed?, false) -> {:ok, :pending}
      true -> control_phase(reg, Keyword.get(opts, :control_window, 5_000))
    end
  end

  # The unarmed control phase, before any teardown, for at most the window
  # (5 000 ms; only :63f's cleanup option changes it). Each iteration reads a
  # fresh snapshot: this entry's single port's own exit status ends it; EXIT
  # goes at most once to each port the relay learned (never the recovery
  # route's); an unknown port is waited for; a dead owner or reaper ends the
  # route. No receipt: no teardown, an eof-hold FIFO preloaded with one line
  # (a control action, not a proof), and the actors, lease and entry kept.
  defp control_phase(reg, window) do
    case control_loop(reg, now() + window) do
      :exit_receipt -> {:ok, :exit_receipt}
      ending -> no_exit_receipt(get(reg), ending)
    end
  end

  defp control_loop(reg, deadline) do
    state = get(reg)
    port = Map.get(state, :port)

    cond do
      valid_receipt?(state) ->
        :exit_receipt

      not (alive?(Map.get(state, :owner)) and alive?(Map.get(state, :reaper))) ->
        :route_lost

      now() >= deadline ->
        :window_elapsed

      is_port(port) and Map.get(state, :exit_sent_to) != port ->
        ask_exit(port)
        put(reg, exit_sent_to: port)
        control_loop(reg, deadline)

      true ->
        Process.sleep(10)
        control_loop(reg, deadline)
    end
  end

  defp no_exit_receipt(state, ending) do
    {:incomplete, :no_exit_receipt,
     %{
       port_known?: is_port(Map.get(state, :port)),
       exit_sent_to: Map.get(state, :exit_sent_to),
       route_lost?: ending == :route_lost,
       fifo_preloaded?: preload_held_child(state)
     }}
  end

  defp preload_held_child(%{fifo: fifo}) when is_binary(fifo), do: release_fifo(fifo) == :ok
  defp preload_held_child(_state), do: false

  defp ask_exit(port) when is_port(port) do
    if Port.info(port), do: Port.command(port, "EXIT\n")
    :ok
  rescue
    ArgumentError -> :ok
  end

  # This entry's single port, and only it, reported `{:exit_status, status}`.
  defp valid_receipt?(state) do
    case {Map.get(state, :exit_receipt), Map.get(state, :port), Map.get(state, :ports_seen)} do
      {{port, status}, port, [port]} when is_port(port) and is_integer(status) -> true
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

  defp exit_proof(_state, :no_launch), do: {:ok, :no_launch, :no_launch}
  defp exit_proof(state, :exit_receipt), do: receipt_proof(state)

  defp exit_proof(state, _early) do
    cond do
      is_binary(Map.get(state, :identity)) -> identity_proof(state)
      valid_receipt?(state) -> receipt_proof(state)
      true -> {:incomplete, :no_child_exit_proof}
    end
  end

  # The exact receipt itself: this entry's single port and its exit status.
  defp receipt_proof(%{exit_receipt: {port, status}}),
    do: {:ok, :exit_receipt, {:exit_receipt, {port, status}}}

  defp receipt_proof(_state), do: {:incomplete, :exit_receipt_not_retained}

  # The real probe only; an eof-hold child still present is released
  # through its FIFO (no signal), then observed again.
  defp identity_proof(state) do
    %{identity_pid: pid, identity: identity} = state

    case observe_gone_read(pid, identity, &ProcessProbe.start_identity/1, 5_000) do
      {:gone, read} -> {:ok, :identity_gone, identity_evidence(pid, identity, read)}
      {outcome, _read} -> fifo_proof(state, outcome)
    end
  end

  defp fifo_proof(%{fifo: fifo, identity_pid: pid, identity: identity}, _outcome) do
    with :ok <- release_fifo(fifo) do
      case observe_gone_read(pid, identity, &ProcessProbe.start_identity/1, 5_000) do
        {:gone, read} ->
          {:ok, :identity_gone_after_fifo_release, identity_evidence(pid, identity, read)}

        {outcome, _read} ->
          {:incomplete, {:child_not_proven_gone, pid, identity, fifo, outcome}}
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
      nil -> {:ok, :none}
      {:held, ^reaper} when is_pid(reaper) -> release_dead_holder(reaper, name)
      {:held, other} -> {:incomplete, {:lease_not_ours, other}}
    end
  end

  defp release_dead_holder(reaper, name) do
    with false <- Process.alive?(reaper),
         :ok <- Reaper.release(name),
         nil <- Reaper.lease(name) do
      {:ok, :released}
    else
      _other -> {:incomplete, {:lease_not_released, reaper}}
    end
  end

  # After an exit proof: this entry's FIFO, exactly, if it has one.
  defp remove_fifo(state) do
    case Map.get(state, :fifo) do
      nil -> {:ok, :none}
      fifo -> fifo_removed(File.rm(fifo))
    end
  end

  defp fifo_removed(:ok), do: {:ok, :removed}
  defp fifo_removed({:error, :enoent}), do: {:ok, :none}
  defp fifo_removed({:error, reason}), do: {:incomplete, {:fifo_remove_failed, reason}}

  ## The independent no-signal recovery (on_exit, registered first: runs last)

  defp recover!(%{registry: reg, entry: entry, name: name}) do
    with {:ok, %{events: events}} <- read_journal(entry),
         {:resolved, _proof} <- last_outcome(events) do
      Agent.stop(reg)
    else
      _unresolved ->
        outcome = recover(reg, name)
        journal_event!(entry, {:recovery, outcome, %{at: utc()}})
        finish_recovery!(reg, outcome)
    end
  end

  defp finish_recovery!(reg, {:resolved, _details}), do: Agent.stop(reg)

  defp finish_recovery!(_reg, outcome) do
    raise "#198 recovery unresolved (controls retained; STOP): " <>
            inspect(outcome, limit: :infinity, printable_limit: :infinity)
  end

  defp recover(reg, name) do
    release_gate(get(reg))

    case recovery_receipt(reg) do
      :exit_receipt -> settle_recovery(reg, name, receipt_proof(get(reg)))
      :none -> recovery_identity(reg, name)
    end
  end

  defp release_gate(state) do
    owner = Map.get(state, :owner)

    if Map.get(state, :relay_gate) == :closed and alive?(owner),
      do: send(owner, {:relay_go, self()})

    :ok
  end

  # The receipt route, while the relay and the reaper live: a fresh snapshot
  # each time, EXIT once to each learned port, this port's own exit status.
  defp recovery_receipt(reg) do
    state = get(reg)

    cond do
      valid_receipt?(state) -> :exit_receipt
      alive?(state[:owner]) and alive?(state[:reaper]) -> receipt_loop(reg, nil, now() + 5_000)
      true -> :none
    end
  end

  defp receipt_loop(reg, sent_to, deadline) do
    state = get(reg)
    port = Map.get(state, :port) || get_in(state, [:recovery, :port])

    cond do
      valid_receipt?(state) ->
        :exit_receipt

      now() >= deadline ->
        :none

      is_port(port) and port != sent_to ->
        recovery_exit(port)
        receipt_loop(reg, port, deadline)

      true ->
        Process.sleep(10)
        receipt_loop(reg, sent_to, deadline)
    end
  end

  defp recovery_exit(port) do
    if Port.info(port), do: Port.command(port, "EXIT\n")
    :ok
  rescue
    ArgumentError -> :ok
  end

  # The identity route: only with an identity captured while the child was
  # provably live; FIFO line, ordered teardown, then the real probe.
  defp recovery_identity(reg, name) do
    state = get(reg)
    preload = preload_fifo(state)

    case recovery_anchor(state) do
      {pid, identity} -> identity_route(reg, name, {pid, identity}, preload)
      nil -> {:unresolved, %{reason: :no_receipt_no_live_identity, fifo: preload}}
    end
  end

  defp identity_route(reg, name, {pid, identity}, preload) do
    with :ok <- recovery_teardown(get(reg)),
         {:gone, read} <- observe_gone_read(pid, identity, &ProcessProbe.start_identity/1, 5_000) do
      settle_recovery(reg, name, {:ok, :identity_gone, identity_evidence(pid, identity, read)})
    else
      other -> {:unresolved, %{reason: {:identity_route, other}, fifo: preload}}
    end
  end

  defp recovery_anchor(%{identity: identity, identity_pid: pid}) when is_binary(identity),
    do: {pid, identity}

  defp recovery_anchor(%{recovery: %{identity: identity, ready_pid: pid}})
       when is_binary(identity),
       do: {pid, identity}

  defp recovery_anchor(_state), do: nil

  defp preload_fifo(%{fifo: fifo}) when is_binary(fifo), do: release_fifo(fifo)
  defp preload_fifo(_state), do: :no_fifo

  defp recovery_teardown(state) do
    with :ok <- kill_exact(Map.get(state, :reaper), :reaper) do
      kill_exact(Map.get(state, :owner), :owner)
    end
  end

  defp settle_recovery(reg, name, {:ok, proof, proof_evidence}) do
    with :ok <- recovery_teardown(get(reg)),
         :ok <- helpers_ended(get(reg)),
         {:ok, lease} <- settle_lease(get(reg), name),
         {:ok, fifo} <- remove_fifo(get(reg)) do
      {:resolved, completed(get(reg), name, {proof, proof_evidence}, lease, fifo)}
    else
      other -> {:unresolved, %{reason: other, proof: proof, lease: Reaper.lease(name)}}
    end
  end

  defp settle_recovery(_reg, name, {:incomplete, reason}),
    do: {:unresolved, %{reason: reason, lease: Reaper.lease(name)}}

  ## Evidence retained with every completed attempt (content-free facts)

  defp completed(state, name, {proof, proof_evidence}, lease, fifo) do
    %{
      proof: proof,
      actors: :down,
      helpers: :ended,
      lease: lease,
      fifo: fifo,
      evidence: %{
        proof: proof_evidence,
        helpers: helper_records(Map.get(state, :helpers, %{})),
        actors: %{
          owner: {Map.get(state, :owner), alive?(Map.get(state, :owner))},
          reaper: {Map.get(state, :reaper), alive?(Map.get(state, :reaper))}
        },
        lease: %{outcome: lease, after: Reaper.lease(name)}
      }
    }
  end

  defp identity_evidence(pid, identity, read),
    do: {:identity, %{pid: pid, identity: identity, final_read: read}}

  defp helper_records(helpers) when map_size(helpers) == 0, do: :none

  defp helper_records(helpers),
    do:
      Map.new(helpers, fn {key, h} ->
        {key, Map.take(h, [:path, :args, :port, :state, :os_pid_report])}
      end)

  defp assert_retained_receipt!(journal, port) do
    assert {_kind, {_done, %{evidence: evidence}}, _meta} = List.last(journal.events)
    assert {:exit_receipt, {^port, 0}} = evidence.proof
    assert %{mkfifo: %{state: {:exited, 0}}} = evidence.helpers
    assert %{owner: {_owner, false}, reaper: {_reaper, false}} = evidence.actors
    assert %{after: nil} = evidence.lease
  end

  ## Journal (per entry; append-only, written atomically)

  defp journal_path(entry), do: Path.join(entry, "journal.term")

  defp journal_event!(entry, event) do
    case read_journal(entry) do
      {:ok, journal} -> write_journal!(entry, %{journal | events: journal.events ++ [event]})
      other -> raise "#198 journal write failed: cannot read #{entry}: #{inspect(other)}"
    end
  end

  defp write_journal!(entry, journal) do
    path = journal_path(entry)
    next = path <> ".next"

    with :ok <- File.write(next, :erlang.term_to_binary(journal), [:sync]),
         :ok <- File.rename(next, path) do
      :ok
    else
      other -> raise "#198 journal write failed: #{entry}: #{inspect(other)}"
    end
  end

  defp read_journal(entry) do
    case File.read(journal_path(entry)) do
      {:ok, binary} -> decode_journal(binary)
      {:error, reason} -> {:error, {:unreadable, reason}}
    end
  end

  defp decode_journal(binary) do
    case :erlang.binary_to_term(binary) do
      %{events: events} = journal when is_list(events) -> {:ok, journal}
      other -> {:error, {:malformed, other}}
    end
  rescue
    ArgumentError -> {:error, :corrupt}
  end

  defp subject_attempts(entry) do
    case read_journal(entry) do
      {:ok, %{events: events}} -> Enum.count(events, &match?({:subject_cleanup, _, _}, &1))
      _other -> 0
    end
  end

  defp attempt_meta(expected?, attempt),
    do: %{expected_incomplete: expected?, attempt: attempt, at: utc()}

  ## Classification (pure) and the module collector

  defp entry_facts(entry) do
    case File.lstat(entry) do
      {:ok, %File.Stat{type: :directory}} ->
        fifo? = match?({:ok, _}, File.lstat(Path.join(entry, "release.fifo")))
        %{entry: entry, kind: :directory, journal: read_journal(entry), fifo?: fifo?}

      other ->
        %{entry: entry, kind: other, journal: :not_read, fifo?: false}
    end
  end

  # :resolved, :flagged (resolved, but with an unexpected incomplete attempt
  # or recovery) or {:unresolved, why}. `expected_incomplete` exempts only
  # the one attempt that carries it.
  defp classify(%{kind: kind}) when kind != :directory, do: {:unresolved, {:entry_kind, kind}}

  defp classify(%{journal: {:ok, %{events: events}}, fifo?: fifo?}) do
    case validate_events(events) do
      :ok -> classify_valid(events, fifo?)
      {:invalid, why} -> {:unresolved, why}
    end
  end

  defp classify(%{journal: other}), do: {:unresolved, {:journal, other}}

  defp classify_valid(events, fifo?) do
    case {last_outcome(events), fifo?} do
      {{:resolved, _proof}, true} ->
        {:unresolved, :fifo_still_present}

      {{:resolved, _proof}, false} ->
        if unexpected_attempt?(events), do: :flagged, else: :resolved

      {other, _fifo?} ->
        {:unresolved, other}
    end
  end

  # Every event must be known and well formed (the history starts pending);
  # at most one attempt may carry expected_incomplete, and only an
  # incomplete one. Anything else fails closed.
  defp validate_events([{:pending, %DateTime{}} | rest]) do
    expected = Enum.count(rest, &match?({:subject_cleanup, _, %{expected_incomplete: true}}, &1))

    case Enum.reject(rest, &valid_event?/1) do
      [] when expected <= 1 -> :ok
      [] -> {:invalid, :more_than_one_expected_incomplete}
      [bad | _] -> {:invalid, {:unknown_or_malformed_event, bad}}
    end
  end

  defp validate_events(_events), do: {:invalid, :history_must_start_pending}

  defp valid_event?({:launch, %{}}), do: true

  defp valid_event?({:recovery_route, %{pid: pid, identity: identity}}),
    do: is_integer(pid) and is_binary(identity)

  defp valid_event?({:subject_cleanup, outcome, meta}),
    do: valid_attempt_meta?(meta) and valid_subject_outcome?(outcome, meta)

  defp valid_event?({:recovery, outcome, %{at: %DateTime{}}}),
    do: valid_recovery_outcome?(outcome)

  defp valid_event?(_event), do: false

  defp valid_attempt_meta?(%{expected_incomplete: expected?, attempt: n, at: %DateTime{}}),
    do: is_boolean(expected?) and is_integer(n) and n > 0

  defp valid_attempt_meta?(_meta), do: false

  defp valid_subject_outcome?({:clean, %{}}, %{expected_incomplete: false}), do: true
  defp valid_subject_outcome?({:incomplete, _reason, %{}}, _meta), do: true
  defp valid_subject_outcome?(_outcome, _meta), do: false

  defp valid_recovery_outcome?({:resolved, %{}}), do: true
  defp valid_recovery_outcome?({:unresolved, %{}}), do: true
  defp valid_recovery_outcome?(_outcome), do: false

  defp class_kind({:unresolved, _why}), do: :unresolved
  defp class_kind(kind), do: kind

  defp last_outcome(events) do
    events
    |> Enum.filter(&match?({kind, _, _} when kind in [:subject_cleanup, :recovery], &1))
    |> List.last()
    |> terminal()
  end

  defp terminal({:subject_cleanup, {:clean, details}, _meta}), do: resolved(details)
  defp terminal({:recovery, {:resolved, details}, _meta}), do: resolved(details)
  defp terminal(nil), do: :no_terminal_event
  defp terminal({kind, _outcome, _meta}), do: {:last_attempt_unresolved, kind}

  defp resolved(%{proof: proof, actors: :down, helpers: :ended, lease: lease, evidence: evidence})
       when proof in @proofs and lease in [:none, :released] do
    if valid_evidence?(proof, evidence),
      do: {:resolved, proof},
      else: {:evidence_missing_or_invalid, evidence}
  end

  defp resolved(details), do: {:incomplete_details, details}

  # The retained facts must actually show the proof: the exact receipt, or a
  # final read that is absent or another start identity; every helper
  # exited; both owned actors observed down; the lease observed nil.
  defp valid_evidence?(proof, %{
         proof: proof_evidence,
         helpers: helpers,
         actors: actors,
         lease: lease
       }) do
    proof_shown?(proof, proof_evidence) and helpers_shown?(helpers) and
      match?(%{owner: {_, false}, reaper: {_, false}}, actors) and match?(%{after: nil}, lease)
  end

  defp valid_evidence?(_proof, _evidence), do: false

  defp proof_shown?(:no_launch, :no_launch), do: true

  defp proof_shown?(:exit_receipt, {:exit_receipt, {port, status}}),
    do: is_port(port) and is_integer(status)

  defp proof_shown?(proof, {:identity, %{pid: pid, identity: identity, final_read: read}})
       when proof in [:identity_gone, :identity_gone_after_fifo_release],
       do: is_integer(pid) and is_binary(identity) and observation(read, identity) == :gone

  defp proof_shown?(_proof, _evidence), do: false

  defp helpers_shown?(:none), do: true

  defp helpers_shown?(helpers) when is_map(helpers),
    do:
      Enum.all?(helpers, &match?({_key, %{state: {:exited, status}}} when is_integer(status), &1))

  defp helpers_shown?(_helpers), do: false

  defp unexpected_attempt?(events) do
    Enum.any?(events, fn
      {:subject_cleanup, {:incomplete, _reason, _details}, %{expected_incomplete: false}} -> true
      {:recovery, {:unresolved, _details}, _meta} -> true
      _other -> false
    end)
  end

  defp resolved_details do
    %{
      proof: :identity_gone,
      actors: :down,
      helpers: :ended,
      lease: :none,
      fifo: :none,
      evidence: %{
        proof:
          {:identity, %{pid: 4_242, identity: "Mon Oct 19 06:00:00 2026", final_read: :absent}},
        helpers: %{mkfifo: %{state: {:exited, 0}}},
        actors: %{owner: {nil, false}, reaper: {nil, false}},
        lease: %{outcome: :none, after: nil}
      }
    }
  end

  defp start_run! do
    refuse_unresolved_controls!()
    File.mkdir_p!(@control_root)
    File.chmod!(@control_root, 0o700)
    File.mkdir_p!(@reports_root)
    id = "#{utc_stamp()}-#{System.pid()}-#{System.unique_integer([:positive])}"
    ledger = Path.join(@control_root, id <> ".ledger")
    File.write!(ledger, "", [:exclusive, :sync])
    %{id: id, ledger: ledger, head: git_head(), started: utc()}
  end

  # An unresolved entry (or ledger) from an earlier run fails setup_all; its
  # artifacts stay for recovery and are never removed to unblock a run.
  defp refuse_unresolved_controls! do
    case File.ls(@control_root) do
      {:ok, []} ->
        :ok

      {:error, :enoent} ->
        :ok

      {:ok, names} ->
        raise "#198 setup_all: unresolved control artifacts from an earlier run in " <>
                "#{@control_root}: #{inspect(Enum.sort(names))}; reports in #{@reports_root}. " <>
                "Recover each entry first (write one line to its release.fifo, confirm its " <>
                "journalled identity gone or its exit receipt), then remove only its exact files."

      {:error, reason} ->
        raise "#198 setup_all: cannot read #{@control_root}: #{inspect(reason)}"
    end
  end

  # The module collector (setup_all's on_exit, not masked by failed tests):
  # validate, classify, finalise and verify the report, then delete only
  # resolved entries' exact files, then fail on anything left or flagged.
  defp finish_run!(run) do
    classified =
      run
      |> read_ledger!()
      |> Enum.map(fn entry ->
        facts = entry_facts(entry)
        {facts, classify(facts)}
      end)

    report = finalize_report!(run, classified)
    leftovers = classified |> Enum.filter(&deletable?/1) |> Enum.flat_map(&delete_entry/1)

    unresolved =
      Enum.filter(classified, fn {_facts, class} -> class_kind(class) == :unresolved end)

    flagged = Enum.filter(classified, fn {_facts, class} -> class == :flagged end)
    if unresolved == [] and leftovers == [], do: :ok = File.rm(run.ledger)
    raise_collector!(report, unresolved, flagged, leftovers)
  end

  defp read_ledger!(%{id: id, ledger: ledger}) do
    case File.read(ledger) do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.map(&ledger_entry!(&1, id))
        |> unique_entries!()

      {:error, reason} ->
        raise "#198 collector: ledger unreadable #{ledger}: #{inspect(reason)}"
    end
  end

  defp ledger_entry!("created " <> path, id) do
    expanded = Path.expand(path)

    if Path.dirname(expanded) == @control_root and
         String.starts_with?(Path.basename(expanded), id <> "-"),
       do: expanded,
       else: raise("#198 collector: foreign ledger entry #{inspect(path)}")
  end

  defp ledger_entry!(line, _id), do: raise("#198 collector: corrupt ledger line #{inspect(line)}")

  defp unique_entries!(entries) do
    if length(Enum.uniq(entries)) == length(entries),
      do: entries,
      else: raise("#198 collector: duplicate ledger entries #{inspect(entries)}")
  end

  defp finalize_report!(run, classified) do
    base = Path.join(@reports_root, run.id <> ".report")

    report = %{
      run: run.id,
      head: run.head,
      started: run.started,
      finished: utc(),
      entries: Enum.map(classified, &report_entry/1)
    }

    with :ok <- write_new(base <> ".term", :erlang.term_to_binary(report)),
         :ok <- write_new(base <> ".txt", inspect(report, pretty: true, limit: :infinity)),
         :ok <- verify_report(base <> ".term", report) do
      base <> ".term"
    else
      other -> raise "#198 report finalisation failed (no control deleted): #{inspect(other)}"
    end
  end

  defp report_entry({facts, class}) do
    %{
      entry: facts.entry,
      kind: facts.kind,
      class: class,
      fifo_present: facts.fifo?,
      journal: facts.journal
    }
  end

  defp write_new(path, data) do
    next = path <> ".next"

    with false <- File.exists?(path),
         :ok <- File.write(next, data, [:exclusive, :sync]),
         :ok <- File.rename(next, path) do
      :ok
    else
      true -> {:error, {:exists, path}}
      other -> {:error, {path, other}}
    end
  end

  defp verify_report(path, report) do
    with {:ok, binary} <- File.read(path),
         ^report <- :erlang.binary_to_term(binary),
         true <- Enum.all?(report.entries, &reclassified?/1) do
      :ok
    else
      other -> {:error, {:report_verify, other}}
    end
  rescue
    error -> {:error, {:report_verify, error}}
  end

  # The read-back entry, classified again from its retained journal alone,
  # must give the class recorded for it (so its evidence really is there).
  defp reclassified?(%{kind: kind, class: class, fifo_present: fifo?, journal: journal}),
    do: classify(%{kind: kind, journal: journal, fifo?: fifo?}) == class

  defp deletable?({_facts, class}), do: class in [:resolved, :flagged]

  defp delete_entry({%{entry: entry}, _class}) do
    with :ok <- remove_if_present(Path.join(entry, "journal.term.next")),
         :ok <- File.rm(journal_path(entry)),
         :ok <- File.rmdir(entry) do
      []
    else
      other -> [{entry, other}]
    end
  end

  defp remove_if_present(path) do
    case File.rm(path) do
      {:error, :enoent} -> :ok
      other -> other
    end
  end

  defp raise_collector!(_report, [], [], []), do: :ok

  defp raise_collector!(report, unresolved, flagged, leftovers) do
    raise "#198 collector: #{length(unresolved)} unresolved, #{length(flagged)} flagged, " <>
            "#{length(leftovers)} not deleted; report #{report}; retained: " <>
            inspect(Enum.map(unresolved, &elem(&1, 0).entry) ++ leftovers, limit: :infinity)
  end

  ## The collector self-test fixtures (an exact-owned scratch root)

  defp write_selftest_entry!(root, label, {:symlink, _fifo?, _want}) do
    target = Path.join(root, "symlink-target")
    File.mkdir!(target)
    write_selftest_journal!(target, [])
    entry = Path.join(root, Atom.to_string(label))
    File.ln_s!(target, entry)
    entry
  end

  defp write_selftest_entry!(root, label, {events, fifo?, _want}) do
    entry = Path.join(root, Atom.to_string(label))
    File.mkdir!(entry)
    write_selftest_journal!(entry, events)
    if fifo?, do: File.write!(Path.join(entry, "release.fifo"), "")
    entry
  end

  defp write_selftest_journal!(_entry, :missing), do: :ok

  defp write_selftest_journal!(entry, :garbage),
    do: File.write!(journal_path(entry), "not an erlang term")

  defp write_selftest_journal!(entry, events),
    do: write_journal!(entry, %{entry: entry, events: [{:pending, utc()} | events]})

  defp remove_selftest_entry!(entry) do
    case File.lstat(entry) do
      {:ok, %File.Stat{type: :symlink}} -> remove_selftest_symlink!(entry)
      _directory -> remove_selftest_dir!(entry)
    end
  end

  defp remove_selftest_symlink!(link) do
    {:ok, target} = File.read_link(link)
    File.rm!(link)
    remove_selftest_dir!(Path.expand(target, Path.dirname(link)))
  end

  defp remove_selftest_dir!(entry) do
    :ok = remove_if_present(Path.join(entry, "release.fifo"))
    :ok = remove_if_present(journal_path(entry))
    File.rmdir!(entry)
  end

  ## Small helpers

  defp git_head do
    with {:ok, git_dir} <- git_dir(Path.join(@project, ".git")),
         {:ok, head} <- File.read(Path.join(git_dir, "HEAD")) do
      resolve_head(String.trim(head), git_dir)
    else
      other -> {:unknown, other}
    end
  end

  defp git_dir(dot_git) do
    case File.read(dot_git) do
      {:ok, "gitdir: " <> rest} -> {:ok, Path.expand(String.trim(rest), @project)}
      {:error, :eisdir} -> {:ok, dot_git}
      other -> {:error, other}
    end
  end

  defp resolve_head("ref: " <> ref, git_dir) do
    common =
      case File.read(Path.join(git_dir, "commondir")) do
        {:ok, dir} -> Path.expand(String.trim(dir), git_dir)
        _none -> git_dir
      end

    Enum.find_value([git_dir, common], {:unknown, {:ref, ref}}, &read_ref(&1, ref))
  end

  defp resolve_head(sha, _git_dir), do: sha

  defp read_ref(dir, ref) do
    case File.read(Path.join(dir, ref)) do
      {:ok, sha} -> String.trim(sha)
      _missing -> nil
    end
  end

  defp alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp alive?(_pid), do: false

  defp utc, do: DateTime.utc_now()
  defp utc_stamp, do: Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")

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
