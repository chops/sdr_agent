defmodule SdrAgent.CalibrationConsole.IsolationTerminationTest do
  @moduledoc """
  R0-07 slice E4c-b code-review evidence (Codex 01a13550): every BEAM
  process a preflight starts — its short-lived owner and the owner's
  unnamed reaper — has terminated once it returns (within a short bound),
  on success and on failure, and no port is left. A port count alone is
  not proof, so this compares the VM's whole process list.

  #151: no result assertion lives inside a run any more, so a surprising
  result can never skip the termination checks. `run_and_check/4` collects
  every observation first — the result, the probe trace, leftover
  processes, leftover ports, the OS root, the workspace — and reports all
  failures together, with the trace. Strict results come only from
  controlled fixtures: a held target, a held target that never prints
  `ready`, a `ready`-emitting target released at the spawned event and
  acknowledged gone before verification starts, and a held target whose
  launch identity read is replaced by a probe error. A genuine instant exit
  is no oracle (it can end `:ok`, unavailable or unconfirmed) and is not
  used. The helper is itself under test, with exactly owned, confirmed-
  disposed fixtures.
  """
  use ExUnit.Case, async: false

  alias SdrAgent.CalibrationConsole.{Isolation, ProcessProbe}

  @bound_ms 3_000
  @ack_ms 2_000
  @unavailable {:error, :calibration_isolation_unavailable}
  @unconfirmed {:error, :calibration_isolation_cleanup_unconfirmed}

  defmodule Recorder do
    @moduledoc false
    # The ordered probe trace, the role markers the observer writes, the
    # release and exit acknowledgement of a phase-released target, and at
    # most one planned fault, spent on its first match. Started before the
    # baseline snapshot of every test, so it is never a leftover.
    use Agent

    def start_link(_opts) do
      Agent.start_link(
        fn ->
          %{
            trace: [],
            helper: nil,
            helper_from_caller: nil,
            reaper: nil,
            spawned: nil,
            workspace: nil,
            release: nil,
            released_at_us: nil,
            exit_ack: nil,
            fault: nil,
            fault_used: false
          }
        end,
        name: __MODULE__
      )
    end

    def put(key, value), do: Agent.update(__MODULE__, &Map.put(&1, key, value))
    def state, do: Agent.get(__MODULE__, & &1)
    def record(entry), do: Agent.update(__MODULE__, &%{&1 | trace: [entry | &1.trace]})
    def trace, do: Agent.get(__MODULE__, &Enum.reverse(&1.trace))

    # `true` exactly once.
    def consume_fault do
      Agent.get_and_update(__MODULE__, fn
        %{fault_used: false} = state -> {true, %{state | fault_used: true}}
        state -> {false, state}
      end)
    end
  end

  defmodule RecordingProbe do
    @moduledoc false
    # `ProcessProbe`, with every call recorded (caller, role, phase, raw
    # reply) and a planned fault replacing the reply of one named phase once.
    # The real probe runs in the calling process, outside the recorder; raw
    # replies are kept exactly as `ProcessProbe` returned them.
    alias SdrAgent.CalibrationConsole.ProcessProbe

    def self_pid, do: record(:self_pid, nil, fn -> ProcessProbe.self_pid() end)

    def start_identity(pid),
      do: record(:start_identity, pid, fn -> ProcessProbe.start_identity(pid) end)

    def group_members(pgid),
      do: record(:group_members, pgid, fn -> ProcessProbe.group_members(pgid) end)

    defp record(fun, arg, call) do
      caller = self()
      state = Recorder.state()
      role = role(caller, state)
      phase = phase(fun, caller, role, state)
      raw = call.()
      {reply, injected} = inject(state.fault, role, phase, raw)

      Recorder.record(%{
        fun: fun,
        arg: arg,
        caller: caller,
        role: role,
        phase: phase,
        raw: raw,
        injected: injected,
        at_us: System.monotonic_time(:microsecond)
      })

      reply
    end

    defp role(caller, %{reaper: caller}), do: :reaper
    defp role(caller, %{helper: caller}), do: :helper
    defp role(_caller, _state), do: :other

    # Phases follow the source, never a global ordinal. A reaper read before
    # any other reaper read is its guard at open (reaper.ex:347-350), a later
    # one its fallback (:451). A helper read before the spawned marker is the
    # launch read (isolation.ex:245); after it, a read right after the
    # helper's own `self_pid` is the verification inside `root_identity`
    # (:375-377) and any other is the stop-time read (:343, :352).
    defp phase(:start_identity, _caller, :reaper, %{trace: trace}) do
      if Enum.any?(trace, &(&1.role == :reaper and &1.fun == :start_identity)),
        do: :fallback,
        else: :open_guard
    end

    defp phase(:start_identity, _caller, :helper, %{spawned: nil}), do: :launch

    defp phase(:start_identity, caller, :helper, %{trace: trace}) do
      case Enum.find(trace, &(&1.caller == caller)) do
        %{fun: :self_pid} -> :verify
        _other -> :stop
      end
    end

    defp phase(:start_identity, _caller, :other, _state), do: :settle
    defp phase(_fun, _caller, _role, _state), do: nil

    defp inject({role, phase, reply}, role, phase, raw) do
      if Recorder.consume_fault(), do: {reply, reply}, else: {raw, nil}
    end

    defp inject(_fault, _role, _phase, raw), do: {raw, nil}
  end

  setup do
    assert Code.ensure_loaded?(Isolation), "SdrAgent.CalibrationConsole.Isolation is not defined"
    start_supervised!(Recorder)

    # An exclusive private directory for the release file: created by this
    # test (a collision fails, nothing is adopted), removed by exact path.
    dir =
      Path.join(
        System.tmp_dir!(),
        "sdr-isolation-151-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
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

    # Role markers, written synchronously in the process that emits each
    # event: the workspace, reaper and spawned events run in the helper
    # (isolation.ex:212, :217, :247), the helper event in the caller (:90).
    # A phase-released target is released at the spawned event, which the
    # helper emits only after its launch identity read, and its exit is then
    # acknowledged before the helper continues into verification.
    observer = fn
      {:workspace, path} ->
        Recorder.put(:helper, self())
        Recorder.put(:workspace, path)

      {:reaper, pid} ->
        Recorder.put(:reaper, pid)

      {:spawned, os_pid} ->
        Recorder.put(:spawned, os_pid)

        case Recorder.state().release do
          nil -> :ok
          path -> release_and_acknowledge(path, os_pid)
        end

      {:helper, pid} ->
        Recorder.put(:helper_from_caller, pid)

      _event ->
        :ok
    end

    %{observer: observer, release: release}
  end

  describe "termination after a preflight" do
    test "T1: a passing preflight leaves no process it started", ctx do
      run_and_check(
        fn -> Isolation.preflight(probe: RecordingProbe, observer: ctx.observer) end,
        :ok,
        premise(
          markers: [:helper, :reaper, :spawned],
          reads: [
            {:reaper, :open_guard, [:ok]},
            {:reaper, :fallback, :none},
            {:helper, :launch, [:ok]},
            {:helper, :verify, [:ok]},
            {:helper, :stop, [:ok_same, :absent]},
            {:other, :settle, :none}
          ],
          injected: 0,
          root: :gone,
          workspace: :removed
        )
      )
    end

    # A held target that never prints `ready`: an ordinary failure whose
    # root identity is read from a live process at every phase. The 1 s also
    # bounds `Reaper.open` and both pre-ready identity reads
    # (isolation.ex:238-248); a launch not observed inside it is a premise
    # failure, reported with the result, never retried.
    test "T2: a failing preflight (no ready within the bound) leaves no process it started",
         ctx do
      run_and_check(
        fn ->
          Isolation.preflight(
            probe: RecordingProbe,
            observer: ctx.observer,
            target: "IFS= read -r _",
            ready_ms: 1_000
          )
        end,
        @unavailable,
        premise(
          markers: [:helper, :reaper, :spawned],
          reads: [
            {:reaper, :open_guard, [:ok]},
            {:reaper, :fallback, :none},
            {:helper, :launch, [:ok]},
            {:helper, :verify, :none},
            {:helper, :stop, [:ok_same, :absent]},
            {:other, :settle, :none}
          ],
          injected: 0,
          root: :gone,
          workspace: :removed
        )
      )
    end

    # An early exit under test control: the target prints `ready`, then
    # exits when the observer releases it at the spawned event, which
    # follows the launch identity read (isolation.ex:245-247); the observer
    # waits, bounded, until the probe no longer lists the root, so the
    # helper enters verification only after the exit. `ready` is still seen
    # (:291-293, the data message precedes the exit status); the verification
    # read finds the root absent (:373-377); the stop-time read confirms it
    # (:342-346): unavailable. An unacknowledged exit is a premise failure.
    test "T3: a target released to exit right after its launch is unavailable and leaves nothing",
         ctx do
      Recorder.put(:release, ctx.release)

      run_and_check(
        fn ->
          Isolation.preflight(
            probe: RecordingProbe,
            observer: ctx.observer,
            target: released_target(ctx.release)
          )
        end,
        @unavailable,
        premise(
          markers: [:helper, :reaper, :spawned, :released_at_us, :exit_ack],
          reads: [
            {:reaper, :open_guard, [:ok]},
            {:reaper, :fallback, :none},
            {:helper, :launch, [:ok]},
            {:helper, :verify, [:absent]},
            {:helper, :stop, [:absent]},
            {:other, :settle, :none}
          ],
          released_after: {:helper, :launch},
          exit_ack: :absent,
          injected: 0,
          root: :gone,
          workspace: :removed
        )
      )
    end

    # The exact cleanup_unconfirmed control: a held target whose launch
    # identity read is replaced by a probe error. `root_stop/3` then reads
    # nothing (isolation.ex:355), the tree is never signalled, the cleanup is
    # unconfirmed and the workspace is deliberately left (:280-281). The
    # shell still ends on EOF, so nothing of it may remain either. The test
    # removes the retained workspace only once the root is confirmed gone and
    # the helper and reaper have ended; otherwise it is kept and reported.
    test "T4: an unverifiable launch identity is an unconfirmed cleanup that still leaves no process",
         ctx do
      Recorder.put(:fault, {:helper, :launch, {:error, :injected_launch_read}})

      run_and_check(
        fn -> Isolation.preflight(probe: RecordingProbe, observer: ctx.observer) end,
        @unconfirmed,
        premise(
          markers: [:helper, :reaper, :spawned],
          reads: [
            {:reaper, :open_guard, [:ok]},
            {:reaper, :fallback, :none},
            {:helper, :launch, [:ok]},
            {:helper, :verify, [:ok]},
            {:helper, :stop, :none},
            {:other, :settle, :none}
          ],
          injected: 1,
          root: :gone,
          workspace: :present_then_removed
        )
      )
    end
  end

  describe "run_and_check/4 (the helper itself)" do
    @short_bound_ms 200

    test "P1: a result mismatch and both leftovers are reported from one run" do
      parent = self()

      run = fn ->
        pid = sleeper(parent)
        port = cat_port()
        send(parent, {:fixtures, pid, port})
        {:error, :controlled}
      end

      error =
        assert_raise(ExUnit.AssertionError, fn ->
          run_and_check(run, :ok, &no_premise/3, @short_bound_ms)
        end)

      assert_received {:fixtures, pid, port}

      checking_then_disposing([{:sleeper, pid}, {:port, port}], fn ->
        assert error.message =~ "expected :ok, got {:error, :controlled}"
        assert error.message =~ inspect(pid), "the leftover process is not reported"
        assert error.message =~ inspect(port), "the leftover port is not reported"
      end)
    end

    test "P2: a result mismatch alone reports only the result" do
      error =
        assert_raise(ExUnit.AssertionError, fn ->
          run_and_check(fn -> {:error, :controlled} end, :ok, &no_premise/3, @short_bound_ms)
        end)

      assert error.message =~ "expected :ok, got {:error, :controlled}"
      refute error.message =~ "still alive"
      refute error.message =~ "still open"
    end

    test "P3a: a leftover process alone is reported, with the correct result" do
      parent = self()

      run = fn ->
        send(parent, {:fixture, sleeper(parent)})
        :ok
      end

      error =
        assert_raise(ExUnit.AssertionError, fn ->
          run_and_check(run, :ok, &no_premise/3, @short_bound_ms)
        end)

      assert_received {:fixture, pid}

      checking_then_disposing([{:sleeper, pid}], fn ->
        assert error.message =~ inspect(pid)
        refute error.message =~ "result mismatch"
        refute error.message =~ "still open"
      end)
    end

    test "P3b: a leftover port alone is reported, even when every process is gone" do
      parent = self()

      run = fn ->
        send(parent, {:fixture, cat_port()})
        :ok
      end

      error =
        assert_raise(ExUnit.AssertionError, fn ->
          run_and_check(run, :ok, &no_premise/3, @short_bound_ms)
        end)

      assert_received {:fixture, port}

      checking_then_disposing([{:port, port}], fn ->
        assert error.message =~ inspect(port)
        refute error.message =~ "result mismatch"
        refute error.message =~ "still alive"
      end)
    end

    test "P4: a clean run with the expected result returns it" do
      assert run_and_check(fn -> :ok end, :ok, &no_premise/3, @short_bound_ms) == :ok
    end

    test "P5: a run that raises keeps its exception and stack beside the leftover" do
      parent = self()

      run = fn ->
        send(parent, {:fixture, sleeper(parent)})
        raise "controlled raise"
      end

      error =
        assert_raise(ExUnit.MultiError, fn ->
          run_and_check(run, :ok, &no_premise/3, @short_bound_ms)
        end)

      assert_received {:fixture, pid}

      checking_then_disposing([{:sleeper, pid}], fn ->
        assert [{:error, %RuntimeError{message: "controlled raise"}, stack} | rest] = error.errors
        assert stack != [], "the original stacktrace was dropped"

        assert Enum.any?(rest, fn {_kind, failure, _stack} ->
                 Exception.message(failure) =~ inspect(pid)
               end),
               "the leftover process is not reported beside the exception"
      end)

      # Exception-only: nothing left behind and no failing premise. The raise
      # is the failure, so the trace still comes with the original error, as
      # exactly one further entry, and no leftover diagnostic.
      error =
        assert_raise(ExUnit.MultiError, fn ->
          run_and_check(
            fn -> raise "controlled raise, nothing left behind" end,
            :ok,
            &no_premise/3,
            @short_bound_ms
          )
        end)

      assert [
               {:error, %RuntimeError{message: "controlled raise, nothing left behind"}, stack}
               | rest
             ] =
               error.errors

      assert stack != [], "the original stacktrace was dropped"
      assert [{:error, %ExUnit.AssertionError{message: trace_text}, []}] = rest
      assert trace_text =~ ~r/\Atrace: /, "the trace is missing (the entry's own text)"
      refute trace_text =~ "still alive"
      refute trace_text =~ "still open"
    end
  end

  ## The helper under test

  # Runs `run`, then observes everything — leftover processes, leftover
  # ports, whether the helper and reaper have ended (otherwise the trace is
  # PARTIAL), the premise (which includes the OS root and the workspace) —
  # on every path, and only then judges. Any failure carries the trace once.
  # `expected` is a value or a one-argument predicate. A run that raises or
  # throws is re-raised as an `ExUnit.MultiError` carrying the original
  # exception and stack together with every other failure; it is never a
  # return.
  defp run_and_check(run, expected, premise, bound_ms \\ @bound_ms) do
    before = MapSet.new(Process.list())
    ports = MapSet.new(Port.list())

    outcome =
      try do
        {:returned, run.()}
      rescue
        exception -> {:raised, :error, exception, __STACKTRACE__}
      catch
        kind, value -> {:raised, kind, value, __STACKTRACE__}
      end

    leftover =
      await(
        fn -> Enum.reject(Process.list(), &MapSet.member?(before, &1)) end,
        now() + bound_ms
      )

    left_ports = Enum.reject(Port.list(), &MapSet.member?(ports, &1))

    # Producer quiescence is established BEFORE the trace snapshot: if the
    # helper or its reaper is still alive at that check, the trace is
    # labelled PARTIAL (conservatively, even if the producer ends a moment
    # later), and an absent event is never taken as "never happened". Only
    # a snapshot taken after both were seen ended is called complete.
    producers_alive =
      [Recorder.state().helper, Recorder.state().reaper]
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&Process.alive?/1)

    recorded = Recorder.state()
    trace = Recorder.trace()

    state =
      Map.merge(recorded, %{producers_alive: producers_alive, partial: producers_alive != []})

    teardown =
      Enum.reject(
        [
          leftover != [] && "processes still alive: #{inspect(describe_pids(leftover))}",
          left_ports != [] && "ports still open: #{inspect(left_ports)}",
          producers_alive != [] &&
            "trace is PARTIAL: producers still alive #{inspect(producers_alive)}"
        ],
        &(&1 == false)
      )

    case outcome do
      {:raised, kind, value, stack} ->
        # The raise is itself the failure, so the trace is attached even when
        # no secondary failure exists.
        failures =
          with_trace(teardown ++ premise.(:raised, trace, state), trace, state, :always)

        raise ExUnit.MultiError,
          errors: [
            {kind, value, stack}
            | Enum.map(failures, &{:error, %ExUnit.AssertionError{message: &1}, []})
          ]

      {:returned, result} ->
        mismatch =
          if expected?(result, expected),
            do: [],
            else: ["result mismatch: expected #{inspect(expected)}, got #{inspect(result)}"]

        failures =
          with_trace(mismatch ++ teardown ++ premise.(result, trace, state), trace, state)

        if failures != [] do
          flunk(
            Enum.join(
              ["#{length(failures)} failure(s) observed in one run:" | failures],
              "\n  - "
            )
          )
        end

        result
    end
  end

  defp expected?(result, predicate) when is_function(predicate, 1), do: predicate.(result)
  defp expected?(result, expected), do: result == expected

  defp no_premise(_result, _trace, _state), do: []

  # The available trace, once, on any failure (or always, for a run that
  # raised); PARTIAL when producers were alive at the quiescence check.
  defp with_trace(failures, trace, state, mode \\ :on_failure)
  defp with_trace([], _trace, _state, :on_failure), do: []

  defp with_trace(failures, trace, state, _mode) do
    label =
      if state.partial,
        do: "trace (PARTIAL, producers alive: #{inspect(state.producers_alive)})",
        else: "trace"

    failures ++ ["#{label}: " <> inspect(trace, limit: :infinity, printable_limit: :infinity)]
  end

  ## Premises, read off the trace after the run

  # Each spec line that does not hold is one failure. In a PARTIAL trace an
  # expected absence or a missing read cannot be concluded and is reported
  # as such, never as "never happened".
  defp premise(spec), do: fn _result, trace, state -> premise_failures(spec, trace, state) end

  defp premise_failures(spec, trace, state) do
    root = root_status(state, Keyword.get(spec, :root))

    Enum.flat_map(Keyword.get(spec, :markers, []), &marker_failure(state, &1)) ++
      Enum.flat_map(Keyword.get(spec, :reads, []), fn {role, phase, allowed} ->
        read_failure(trace, state, role, phase, allowed)
      end) ++
      released_after_failure(trace, state, Keyword.get(spec, :released_after)) ++
      exit_ack_failure(state, Keyword.get(spec, :exit_ack)) ++
      injected_failure(trace, Keyword.get(spec, :injected)) ++
      root_failure(root) ++
      workspace_failure(state, Keyword.get(spec, :workspace), root)
  end

  defp marker_failure(state, key) do
    if Map.get(state, key), do: [], else: ["premise: the #{key} marker was never observed"]
  end

  defp read_failure(trace, state, role, phase, :none) do
    case {reads(trace, role, phase), state.partial} do
      {[], false} ->
        []

      {[], true} ->
        [
          "premise: no #{role} #{phase} identity read seen, but the trace is PARTIAL, so this cannot be concluded"
        ]

      {found, _partial} ->
        ["premise: no #{role} #{phase} identity read expected, found #{length(found)}"]
    end
  end

  defp read_failure(trace, state, role, phase, allowed) do
    case reads(trace, role, phase) do
      [%{raw: raw}] ->
        class = classify(raw, launch_identity(trace))

        if class in allowed or (class == :ok_same and :ok in allowed),
          do: [],
          else: [
            "premise: the #{role} #{phase} identity read returned #{inspect(raw)} (#{class}), " <>
              "expected one of #{inspect(allowed)}"
          ]

      [] ->
        if state.partial,
          do: [
            "premise: the #{role} #{phase} identity read is missing from a PARTIAL trace (cannot be concluded)"
          ],
          else: ["premise: the #{role} #{phase} identity read is missing"]

      many ->
        ["premise: #{length(many)} #{role} #{phase} identity reads, expected exactly one"]
    end
  end

  defp reads(trace, role, phase),
    do: Enum.filter(trace, &(&1.fun == :start_identity and &1.role == role and &1.phase == phase))

  defp launch_identity(trace) do
    case reads(trace, :helper, :launch) do
      [%{raw: raw}] -> normalize(raw)
      _other -> :none
    end
  end

  # Exactly `Isolation.identity/2`'s normalization (isolation.ex:388-394).
  defp normalize({:ok, identity}) when is_binary(identity) and identity != "", do: {:ok, identity}
  defp normalize(:absent), do: :absent
  defp normalize(_other), do: :error

  defp classify(raw, launch) do
    case {normalize(raw), launch} do
      {{:ok, same}, {:ok, same}} -> :ok_same
      {{:ok, _identity}, _launch} -> :ok
      {other, _launch} -> other
    end
  end

  # The dependent pair of a phase-released target: the release request was
  # recorded after the named read.
  defp released_after_failure(_trace, _state, nil), do: []

  defp released_after_failure(trace, state, {role, phase}) do
    case {reads(trace, role, phase), state.released_at_us} do
      {[%{at_us: read_at}], released_at} when is_integer(released_at) and read_at < released_at ->
        []

      {[%{at_us: read_at}], released_at} ->
        [
          "premise: the release (#{inspect(released_at)}) did not follow the #{role} #{phase} read (#{read_at})"
        ]

      {_reads, _released} ->
        ["premise: the release cannot be ordered against the #{role} #{phase} read"]
    end
  end

  # The release request and the exit acknowledgement are kept apart: only an
  # acknowledgement that the probe no longer listed the exact owned root,
  # before verification, satisfies the premise. The polling budget is not a
  # strict bound: a late `:absent` read is accepted and marked `late: true`.
  defp exit_ack_failure(_state, nil), do: []

  defp exit_ack_failure(%{exit_ack: nil}, _expected),
    do: ["premise: the released root's exit was never acknowledged (no exit_ack marker)"]

  defp exit_ack_failure(%{exit_ack: %{result: :absent}}, :absent), do: []

  defp exit_ack_failure(%{exit_ack: ack}, :absent),
    do: [
      "premise: the released root's exit was not acknowledged within #{@ack_ms} ms: #{inspect(ack)}"
    ]

  defp injected_failure(_trace, nil), do: []

  defp injected_failure(trace, expected) do
    case Enum.count(trace, &(&1.injected != nil)) do
      ^expected -> []
      count -> ["premise: #{count} injected replies, expected #{expected}"]
    end
  end

  # The root's disposition, observed independently through the real probe:
  # `:gone` (absent), `{:listed, raw}` (still listed after the bound),
  # `{:uncertain, raw}` (the probe itself failed), `:unknown` (no pid).
  defp root_status(_state, nil), do: nil
  defp root_status(%{spawned: nil}, :gone), do: :unknown

  defp root_status(%{spawned: os_pid}, :gone) do
    deadline = now() + @bound_ms

    Stream.repeatedly(fn -> ProcessProbe.start_identity(os_pid) end)
    |> Enum.reduce_while(nil, fn raw, _last ->
      cond do
        raw == :absent ->
          {:halt, :gone}

        now() >= deadline ->
          {:halt, if(match?({:ok, _}, raw), do: {:listed, raw}, else: {:uncertain, raw})}

        true ->
          Process.sleep(20)
          {:cont, raw}
      end
    end)
  end

  defp root_failure(nil), do: []
  defp root_failure(:gone), do: []

  defp root_failure(:unknown),
    do: ["premise: no spawned marker, so the root's disposition is unknown"]

  defp root_failure({:listed, raw}),
    do: ["the launched root is still listed by the OS: #{inspect(raw)}"]

  defp root_failure({:uncertain, raw}),
    do: ["the root's disposition is uncertain: the probe answered #{inspect(raw)}"]

  defp workspace_failure(_state, nil, _root), do: []

  defp workspace_failure(%{workspace: nil}, _rule, _root),
    do: ["premise: the workspace marker was never observed"]

  defp workspace_failure(%{workspace: path}, :removed, _root) do
    if File.exists?(path), do: ["the workspace #{path} was not removed"], else: []
  end

  # Left behind by design on an unconfirmed cleanup. The test removes the
  # empty directory it caused, by its exact path, only when the root is
  # confirmed gone and the helper and reaper have ended; otherwise the path
  # is retained and the reason reported.
  defp workspace_failure(%{workspace: path} = state, :present_then_removed, root) do
    cond do
      not File.dir?(path) ->
        ["the workspace #{path} was expected to be left behind"]

      root != :gone or state.partial ->
        [
          "retained #{path}: not removed because the root's disposition is #{inspect(root)} " <>
            "and producers alive are #{inspect(state.producers_alive)}"
        ]

      File.rmdir(path) != :ok ->
        ["the workspace #{path} could not be removed by the test"]

      true ->
        []
    end
  end

  ## Fixtures

  # A `ready`-emitting target that exits only when its release file appears
  # or after its own 500-poll bound (about 10 s), never on an elapsed sleep.
  defp released_target(release) do
    "printf ready; i=0; until [ -e '#{release}' ] || [ \"$i\" -ge 500 ]; do sleep 0.02; i=$((i+1)); done"
  end

  # Runs in the helper at the spawned event: records the release request,
  # releases the target, then polls the real probe until it no longer lists
  # the exact owned root, and records that acknowledgement apart from the
  # request. The helper continues into verification only afterwards. The
  # `@ack_ms` budget bounds the polling, not the probe's own synchronous
  # `ps` call: an `:absent` read that lands after the nominal deadline is
  # still accepted and marked `late: true`. An unacknowledged exit is
  # recorded as such, never retried.
  defp release_and_acknowledge(path, os_pid) do
    File.touch!(path)
    Recorder.put(:released_at_us, System.monotonic_time(:microsecond))
    Recorder.put(:exit_ack, acknowledge(os_pid, now() + @ack_ms, 0))
  end

  defp acknowledge(os_pid, deadline, reads) do
    raw = ProcessProbe.start_identity(os_pid)
    reads = reads + 1
    at_us = System.monotonic_time(:microsecond)

    cond do
      raw == :absent ->
        %{result: :absent, reads: reads, at_us: at_us, late: now() > deadline}

      now() >= deadline ->
        %{result: {:timeout, raw}, reads: reads, at_us: at_us, late: true}

      true ->
        Process.sleep(10)
        acknowledge(os_pid, deadline, reads)
    end
  end

  # The helper's own fixtures, acquired one at a time; each registers its
  # confirmed-disposal fallback the moment it exists, so partial creation
  # and a failure before any in-test disposal are both covered. The sleeper
  # also ends on its owner's death or after 5 s; a `cat` port dies with its
  # owner. Nothing here ever signals a process it did not create.
  defp sleeper(owner) do
    pid =
      spawn(fn ->
        ref = Process.monitor(owner)

        receive do
          :stop -> :ok
          {:DOWN, ^ref, :process, ^owner, _reason} -> :ok
        after
          5_000 -> :ok
        end
      end)

    on_exit(fn -> fallback_disposal({:sleeper, pid}) end)
    pid
  end

  defp cat_port do
    port = Port.open({:spawn_executable, "/bin/cat"}, [:binary])
    on_exit(fn -> fallback_disposal({:port, port}) end)
    port
  end

  defp fallback_disposal(fixture) do
    case safe_dispose(fixture) do
      [] ->
        :ok

      failures ->
        raise ExUnit.AssertionError,
          message: "fallback disposal failed: " <> Enum.join(failures, "; ")
    end
  end

  # Every disposal yields a recorded result, even when it raises, exits or
  # throws; the remaining fixtures are still disposed afterwards.
  defp safe_dispose(fixture) do
    dispose(fixture)
  rescue
    exception -> ["disposal of #{inspect(fixture)} raised: " <> Exception.message(exception)]
  catch
    kind, value -> ["disposal of #{inspect(fixture)} #{kind}: #{inspect(value)}"]
  end

  # Confirmed disposal of exactly one owned fixture: `:stop`, a monitored
  # wait of 500 ms, one escalation to a kill, another 500 ms; an already
  # ended fixture counts as disposed. Returns the failures.
  defp dispose({:sleeper, pid}) do
    ref = Process.monitor(pid)
    send(pid, :stop)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> []
    after
      500 ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> []
        after
          500 -> ["the sleeper #{inspect(pid)} could not be disposed"]
        end
    end
  end

  # `Port.close/1` raises for a port closed in between (a check/use race);
  # such a port counts as disposed only once this exact port is confirmed
  # absent.
  defp dispose({:port, port}) do
    try do
      if Port.info(port), do: Port.close(port)
    rescue
      ArgumentError -> :closed_concurrently
    end

    if Port.info(port) == nil,
      do: [],
      else: ["the port #{inspect(port)} is still open after close"]
  end

  # Runs the checks, then disposes every listed fixture with confirmation,
  # and reports the checks' failure and any disposal failure together: the
  # original exception and stack are kept, and no disposal is skipped
  # because an earlier one failed.
  defp checking_then_disposing(fixtures, check) do
    outcome =
      try do
        check.()
        :ok
      rescue
        exception -> {:error, exception, __STACKTRACE__}
      catch
        kind, value -> {kind, value, __STACKTRACE__}
      end

    cleanup = Enum.flat_map(fixtures, &safe_dispose/1)

    case {outcome, cleanup} do
      {:ok, []} ->
        :ok

      {:ok, failures} ->
        flunk("disposal: " <> Enum.join(failures, "; "))

      {{kind, value, stack}, []} ->
        :erlang.raise(kind, value, stack)

      {{kind, value, stack}, failures} ->
        raise ExUnit.MultiError,
          errors: [
            {kind, value, stack}
            | Enum.map(
                failures,
                &{:error, %ExUnit.AssertionError{message: "disposal: " <> &1}, []}
              )
          ]
    end
  end

  defp await(list, deadline) do
    case list.() do
      [] ->
        []

      left ->
        if now() >= deadline do
          left
        else
          Process.sleep(20)
          await(list, deadline)
        end
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp describe_pids(pids), do: Enum.map(pids, &{&1, Process.info(&1, [:current_function])})
end
