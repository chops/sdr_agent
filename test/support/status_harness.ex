defmodule SdrAgent.Test.StatusHarness do
  @moduledoc """
  C2-02c test support (`docs/product/r0/c2-02c-interface.md` draft 3, PASS
  at `401df6f`): restart forms, bounded status observations with their
  side-effect evidence, and the status shape matchers. It builds on the b2α
  and b2β harnesses (`SdrAgent.Test.ResolveHarness`): their fixtures,
  barriers and bounded calls are reused, not copied.

  **The tree** `tree!/1` starts the profile tree (non-manual) with the fake
  CLI under the test launcher, like `ResolveHarness.tree!/1`, plus
  `server:` (extra ClaudeCLI start options, such as a pinned `:executable`)
  and `fail_start:` (an `:atomics` gate; while it is 1, every start fails
  before the server's init returns, so the start is a known failed start).

  **Restart forms** (contract section 1):

    * A — `kill_coordinator!/0`: the coordinator only; `:rest_for_one`
      restarts it;
    * B — `stop_tree!/0`, then the caller's tree start: the profile tree is
      stopped and started again; a retained lease (`:persistent_term`) is
      untouched;
    * C — B plus `simulate_vm_local_loss!/1` between the stop and the
      start. That is a **simulated** loss of VM-local state, not a BEAM
      restart and not evidence of OS cleanup (OQ-2): it runs only after
      every fixture-owned server, reaper, worker and supervisor has been
      stopped and joined, and erases only a lease held by one of this
      test's own joined reapers.

  The lease name is `ClaudeCLI.server()`: the coordinator and the b2α/b2β
  harnesses support no other name. In the test VM the provider is the Fake,
  so no application tree runs and that lease belongs to the test's fixture.

  **Observations** run the subject (`Runtime.status/0` by default) in a
  bounded task that is the only traced process: its sends and calls of the
  forbidden functions are traced (delivered with `:erlang.trace_delivered/1`,
  then the collector acknowledges), and its repo queries are counted by
  query telemetry scoped to that task. `status!/0` records each
  observation's effects; `assert_no_status_effects!/0` checks every
  recorded one (test 11, scoped per binding interpretation 5).

  **The sample seam** (test builds only; specified here for GREEN):
  `Runtime.status/0` emits `[:sdr_agent, :runtime_status, :sample]`
  (`%{}`, `%{point: :c1 | :s1 | :eligibility | :s2 | :c2, attempt: 1..3}`)
  in the calling process right after each step of an attempt, every point
  once per attempt whether or not that step read anything, behind
  `@test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams,
  false)` like the other test seams. `start_observation/2` with `pause:`
  pauses the subject at `{point, attempt}`.
  """
  import ExUnit.Assertions

  import ExUnit.Callbacks,
    only: [on_exit: 1, start_supervised!: 1, start_supervised!: 2, stop_supervised!: 1]

  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.ClaudeCLI.PinnedExecutable
  alias SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper
  alias SdrAgent.AI.ModelProvider.Coordinator
  alias SdrAgent.AI.ModelProvider.ProfileSupervisor
  alias SdrAgent.AI.ModelProvider.Runtime
  alias SdrAgent.Repo
  alias SdrAgent.Test.LaunchAdmission
  alias SdrAgent.Test.ResolveHarness

  @fake Path.expand("fake_claude_cli.exs", __DIR__)
  @sample [:sdr_agent, :runtime_status, :sample]
  @query [:sdr_agent, :repo, :query]
  @subject {__MODULE__, :subject}
  @effects {__MODULE__, :effects}
  @tracked {__MODULE__, :tracked}
  @server_supervisor SdrAgent.AI.ModelProvider.ServerSupervisor
  @operation_supervisor SdrAgent.AI.ModelProvider.OperationSupervisor
  @names [
    Coordinator,
    ProfileSupervisor,
    @server_supervisor,
    @operation_supervisor,
    SdrAgent.AI.ModelProvider.ClaudeCLI
  ]
  @traced [
    {Runtime, :resolve, :_},
    {ClaudeCLI, :hold, :_},
    {ClaudeCLI, :release_hold, :_},
    {ClaudeCLI, :complete, :_},
    {Reaper, :release, :_},
    {PinnedExecutable, :verify, :_},
    {PinnedExecutable, :sha256, :_},
    {PinnedExecutable, :check, :_},
    {System, :cmd, :_},
    {:erlang, :open_port, :_}
  ]
  @aliases %{claude_cli_opus: "opus", claude_cli_sonnet: "sonnet"}
  # Pin file metadata (`PinnedExecutable.check/1`) is the only permitted read.
  @permitted_calls [{PinnedExecutable, :check, 1}]

  ## Provider selection

  @doc "Selects ClaudeCLI as the configured provider for this test (restored on exit)."
  def select_claude_cli!, do: select!(ClaudeCLI)

  @doc "Selects the Fake as the configured provider for this test (restored on exit)."
  def select_fake!, do: select!(SdrAgent.AI.ModelProvider.Fake)

  defp select!(provider) do
    previous = Application.fetch_env!(:sdr_agent, :model_provider)
    Application.put_env(:sdr_agent, :model_provider, provider)
    on_exit(fn -> Application.put_env(:sdr_agent, :model_provider, previous) end)
    :ok
  end

  ## The tree and restart forms

  @doc "Starts the profile tree (see the moduledoc for `server:` and `fail_start:`)."
  def tree!(opts \\ []) do
    parent = self()
    gate = opts[:fail_start]

    server = fn profile_id ->
      [
        command: System.find_executable("elixir"),
        test_launcher: true,
        launch_admission: LaunchAdmission.recording(parent),
        command_args: [@fake, "ready"]
      ]
      |> Keyword.merge(Keyword.get(opts, :server, []))
      |> then(
        &if(opts[:unidentified] == profile_id,
          do: Keyword.put(&1, :reaper, os_pid: fn _port -> nil end),
          else: &1
        )
      )
      |> then(&if(failing?(gate), do: Keyword.put(&1, :timeout, 1), else: &1))
    end

    start_supervised!({ProfileSupervisor, [server: server] ++ Keyword.take(opts, [:faults])})
  end

  defp failing?(nil), do: false
  defp failing?(gate), do: :atomics.get(gate, 1) == 1

  @doc "A new start-failure gate for `tree!/1` (`fail_start:`), initially passing."
  def start_gate, do: :atomics.new(1, [])

  @doc "Form A: kills the coordinator (idle, or paused outside any query) and waits for its exit."
  def kill_coordinator!, do: ResolveHarness.kill_coordinator!()

  @doc """
  Form B (its stop half): stops the profile tree and joins every process
  it owned, with the reaper of the server it ran. Returns the joined
  reapers.
  """
  def stop_tree! do
    server = Process.whereis(ClaudeCLI.server())
    reapers = Enum.filter([server && ClaudeCLI.reaper(server)], &is_pid/1)

    owned =
      [Coordinator, ProfileSupervisor, @server_supervisor, @operation_supervisor]
      |> Enum.map(&Process.whereis/1)
      |> Kernel.++([server | operation_workers()])
      |> Enum.filter(&is_pid/1)

    :ok = stop_supervised!(ProfileSupervisor)
    for pid <- owned ++ reapers, do: join!(pid, "a fixture process outlived the tree stop")
    assert Process.whereis(ClaudeCLI.server()) == nil, "fixture: no named server after the stop"
    reapers
  end

  defp operation_workers do
    @operation_supervisor
    |> Task.Supervisor.children()
  catch
    :exit, _ -> []
  end

  @doc """
  Form C (its middle): a simulated loss of VM-local state. Not a BEAM
  restart and not proof of OS cleanup (OQ-2). Asserts that no tree process
  runs, that both status tables went with their owners, that every reaper
  in `owned` (this test's own, already joined) is dead, and that the lease
  is absent or held by one of them; only then erases it.
  """
  def simulate_vm_local_loss!(owned) do
    for name <- [Coordinator, ProfileSupervisor, @server_supervisor, @operation_supervisor] do
      assert Process.whereis(name) == nil, "simulated loss: #{inspect(name)} still runs"
    end

    assert Process.whereis(ClaudeCLI.server()) == nil, "simulated loss: a named server runs"
    assert :ets.whereis(Coordinator) == :undefined, "simulated loss: the coordinator table exists"
    assert :ets.whereis(ClaudeCLI.server()) == :undefined, "simulated loss: a server table exists"
    for pid <- owned, do: refute(Process.alive?(pid), "simulated loss: an owned reaper is alive")

    case Reaper.lease(ClaudeCLI.server()) do
      nil ->
        :ok

      {:held, holder} ->
        assert holder in owned, "simulated loss: the lease is not this test's own"
        refute Process.alive?(holder)
    end

    # The VM-local lease goes with the simulated VM; no Reaper.release/1 call.
    :persistent_term.erase({Reaper, ClaudeCLI.server()})
    assert Reaper.lease(ClaudeCLI.server()) == nil
    :ok
  end

  @doc """
  Restarts in `form` (`:A`, `:B` or `:C`); `start` starts the tree again
  (B and C). `owned` are reapers this test owns besides the current
  server's (a fixture's dead holder). Returns every owned reaper.
  """
  def restart!(form, start, owned \\ [])

  def restart!(:A, _start, owned) do
    kill_coordinator!()
    owned
  end

  def restart!(:B, start, owned) do
    owned = owned ++ stop_tree!()
    start.()
    owned
  end

  def restart!(:C, start, owned) do
    owned = owned ++ stop_tree!()
    simulate_vm_local_loss!(owned)
    start.()
    owned
  end

  @doc "Waits for a published status of a boot other than `old_boot` matching `predicate`."
  def await_boot!(old_boot, predicate, timeout \\ 20_000),
    do: ResolveHarness.await_status!(&(&1.boot_id != old_boot and predicate.(&1)), timeout)

  @doc "Waits (bounded) for `pid` to exit, or flunks with `message`."
  def join!(pid, message \\ "process did not exit", timeout \\ 10_000) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      timeout -> flunk("#{message}: #{inspect(pid)}")
    end
  end

  @doc """
  A named ClaudeCLI server outside the profile tree (the test's own child,
  id `:c202c_bare`) at `profile`: a process that holds the name with no
  coordinator binding.
  """
  def start_bare_server!(profile) do
    start_supervised!(
      {ClaudeCLI,
       name: ClaudeCLI.server(),
       profile: profile,
       command: System.find_executable("elixir"),
       test_launcher: true,
       launch_admission: LaunchAdmission.recording(self()),
       command_args: [@fake, "ready"]},
      id: :c202c_bare
    )
  end

  @doc "Stops `start_bare_server!/1`'s server and joins its reaper (its lease is released)."
  def stop_bare_server! do
    reaper = ClaudeCLI.reaper(ClaudeCLI.server())
    :ok = stop_supervised!(:c202c_bare)
    if is_pid(reaper), do: join!(reaper, "the bare server's reaper did not exit")
    :ok
  end

  @doc """
  Replaces the coordinator's table with a forged copy of `rows`, owned by
  a test process (registered as the coordinator when `register?`). Call
  only with no tree running. Returns the forger (killed on exit).
  """
  def forge_coordinator_table!(rows, register?) do
    parent = self()

    forger =
      spawn(fn ->
        :ets.new(Coordinator, [:named_table, :protected, :set, read_concurrency: true])
        :ets.insert(Coordinator, rows)
        if register?, do: Process.register(self(), Coordinator)
        send(parent, {:c202c_forged, self()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:c202c_forged, ^forger}, 5_000
    on_exit(fn -> Process.exit(forger, :kill) end)
    forger
  end

  @doc "Stops a forger and waits until its table is gone."
  def stop_forger!(forger) do
    send(forger, :stop)
    join!(forger, "the forger did not exit")
  end

  ## Test-only database faults (rolled back with the sandbox)

  @doc """
  Renames `table` inside the test's shared sandbox transaction, so every
  read of it fails until `restore_table!/1` (a test-only fault; queries run
  under savepoints, so the failure does not abort the sandbox).
  """
  def break_table!(table) when table in ["model_profile_settings", "model_profile_switches"] do
    Repo.query!("ALTER TABLE #{table} RENAME TO #{table}_c202c_fault")
    :ok
  end

  @doc "Undoes `break_table!/1`."
  def restore_table!(table) when table in ["model_profile_settings", "model_profile_switches"] do
    Repo.query!("ALTER TABLE #{table}_c202c_fault RENAME TO #{table}")
    :ok
  end

  @doc "Row counts of every table a status read must never write (raw SQL; no audit read)."
  def counts! do
    for table <-
          ~w(audit_events model_server_starts model_profile_switches model_profile_settings model_invocations),
        into: %{} do
      [[n]] = Repo.query!("SELECT count(*) FROM #{table}").rows
      {table, n}
    end
  end

  @doc "Waits until the coordinator logged a failed query on `table` (a `query_log!/1` log)."
  def await_failed_read!(log, table) do
    ResolveHarness.await!(
      fn -> Enum.any?(ResolveHarness.logged(log), &failed_on?(&1, table)) end,
      10_000,
      "fixture: the coordinator never failed a read of #{table}"
    )
  end

  @doc "How many failed coordinator queries on `table` a `query_log!/1` log holds."
  def failed_reads(log, table),
    do: log |> ResolveHarness.logged() |> Enum.count(&failed_on?(&1, table))

  defp failed_on?({query, status}, table), do: status == :error and query =~ table

  ## Observations

  @doc "The status, read bounded in a task (no tracing; restart tests)."
  def status_now!, do: ResolveHarness.bounded(fn -> Runtime.status() end, 5_000)

  @doc "Observes one `Runtime.status/0` (see the moduledoc), records its effects and returns it."
  def status!(opts \\ []) do
    {status, effects} = observe(fn -> Runtime.status() end, opts)
    record_effects!(effects)
    status
  end

  @doc "Observes `fun` as the subject; returns `{result, effects}`."
  def observe(fun, opts \\ []), do: fun |> start_observation(opts) |> finish()

  @doc """
  Starts observing `fun` (default `Runtime.status/0`) in a traced subject
  task; `pause:` is a list of `{point, attempt}` sample points to pause at
  (see `await_pause!/3` and `continue!/1`). Returns the handle.
  """
  def start_observation(fun \\ fn -> Runtime.status() end, opts \\ []) do
    track!()
    parent = self()
    tag = make_ref()
    queries = :counters.new(1, [])
    points = :ets.new(:c202c_points, [:public, :ordered_set])
    collector = spawn(fn -> collect(%{sends: [], calls: []}) end)
    ids = ["c202c-query-#{tag_id()}", "c202c-sample-#{tag_id()}"]
    [query_id, sample_id] = ids

    :ok =
      :telemetry.attach(query_id, @query, &__MODULE__.query_counter/4, %{tag: tag, n: queries})

    :ok =
      :telemetry.attach(sample_id, @sample, &__MODULE__.sample_handler/4, %{
        tag: tag,
        parent: parent,
        points: points,
        pause: Keyword.get(opts, :pause, [])
      })

    task =
      Task.async(fn ->
        Process.put(@subject, tag)

        receive do
          {:c202c_go, ^tag} -> :ok
        end

        ResolveHarness.observe(fun)
      end)

    for {m, f, a} <- @traced, do: :erlang.trace_pattern({m, f, a}, true, [:local])
    :erlang.trace(task.pid, true, [:send, :call, {:tracer, collector}])

    handle = %{
      tag: tag,
      task: task,
      collector: collector,
      queries: queries,
      points: points,
      ids: ids
    }

    on_exit(fn -> cleanup(handle) end)
    send(task.pid, {:c202c_go, tag})
    handle
  end

  defp tag_id, do: System.unique_integer([:positive])

  @doc """
  Asserts that the subject paused at `{point, attempt}`. The first pause of
  an observation is the seam guard; a later attempt's is the retry.
  """
  def await_pause!(%{tag: tag}, point, attempt, message \\ nil) do
    message =
      message ||
        if attempt == 1,
          do:
            "C2-02c seam: Runtime.status/0 emitted no #{inspect(@sample)} point " <>
              "#{inspect({point, attempt})} (test builds; see SdrAgent.Test.StatusHarness)",
          else:
            "C2-02c 2a: a changed attempt must be retried; no point " <>
              "#{inspect({point, attempt})} was emitted"

    assert_receive {:c202c_paused, ^tag, ^point, ^attempt}, 5_000, message
  end

  @doc "Resumes a paused subject."
  def continue!(%{task: task, tag: tag}), do: send(task.pid, {:c202c_continue, tag})

  @doc "Finishes an observation: `{result, effects}` (the result bounded, never accepted as status)."
  def finish(handle) do
    result = ResolveHarness.await_task(handle.task, 10_000)
    delivered = :erlang.trace_delivered(:all)

    receive do
      {:trace_delivered, :all, ^delivered} -> :ok
    after
      5_000 -> flunk("trace messages were never delivered")
    end

    ref = make_ref()
    send(handle.collector, {:c202c_report, self(), ref})

    report =
      receive do
        {:c202c_report, ^ref, report} -> report
      after
        5_000 -> flunk("the trace collector did not answer")
      end

    effects =
      Map.merge(report, %{
        queries: :counters.get(handle.queries, 1),
        points: handle.points |> :ets.tab2list() |> Enum.map(fn {_, p, a} -> {p, a} end)
      })

    cleanup(handle)
    track!()
    {result, effects}
  end

  defp cleanup(handle) do
    Enum.each(handle.ids, &:telemetry.detach/1)
    for {m, f, a} <- @traced, do: :erlang.trace_pattern({m, f, a}, false, [:local])
    send(handle.task.pid, {:c202c_continue, handle.tag})
    send(handle.collector, :stop)

    try do
      :erlang.trace(handle.task.pid, false, [:send, :call])
    rescue
      ArgumentError -> :ok
    end

    if :ets.info(handle.points) != :undefined, do: :ets.delete(handle.points)
    :ok
  end

  defp collect(acc) do
    receive do
      {:trace, _pid, :send, _msg, to} ->
        collect(%{acc | sends: [to | acc.sends]})

      {:trace, _pid, :send_to_non_existing_process, _msg, to} ->
        collect(%{acc | sends: [to | acc.sends]})

      {:trace, _pid, :call, {m, f, args}} ->
        collect(%{acc | calls: [{m, f, length(args)} | acc.calls]})

      {:c202c_report, from, ref} ->
        report(from, ref, acc)

      :stop ->
        :ok

      _other ->
        collect(acc)
    end
  end

  defp report(from, ref, acc) do
    send(
      from,
      {:c202c_report, ref, %{sends: Enum.reverse(acc.sends), calls: Enum.reverse(acc.calls)}}
    )

    collect(acc)
  end

  @doc false
  def query_counter(_event, _measurements, _meta, %{tag: tag, n: counter}) do
    if Process.get(@subject) == tag, do: :counters.add(counter, 1, 1)
    :ok
  end

  @doc false
  def sample_handler(_event, _measurements, %{point: point, attempt: attempt}, config) do
    if Process.get(@subject) == config.tag do
      :ets.insert(config.points, {System.unique_integer([:monotonic]), point, attempt})
      if {point, attempt} in config.pause, do: pause(config, point, attempt)
    end

    :ok
  end

  def sample_handler(_event, _measurements, _meta, _config), do: :ok

  defp pause(%{tag: tag, parent: parent}, point, attempt) do
    send(parent, {:c202c_paused, tag, point, attempt})

    receive do
      {:c202c_continue, ^tag} -> :ok
    after
      30_000 -> :ok
    end
  end

  @doc "Whether the observation reached a second attempt (the retry, 2a)."
  def retried?(effects), do: Enum.any?(effects.points, &match?({_point, 2}, &1))

  @doc "The number of attempts the observation began."
  def attempts(effects),
    do: effects.points |> Enum.filter(&match?({:c1, _}, &1)) |> length()

  # Every coordinator, server, reaper and tree supervisor seen around an
  # observation is a forbidden recipient of the subject's messages.
  defp track! do
    server = Process.whereis(ClaudeCLI.server())

    seen =
      [server && ClaudeCLI.reaper(server) | Enum.map(@names, &Process.whereis/1)]
      |> Enum.filter(&is_pid/1)

    Process.put(@tracked, Enum.uniq(seen ++ Process.get(@tracked, [])))
  end

  @doc "Also forbids messages to `pids` (instances replaced during an observation)."
  def track_pids!(pids), do: Process.put(@tracked, Enum.uniq(pids ++ Process.get(@tracked, [])))

  @doc "The subject's messages to a coordinator, server, reaper or tree supervisor."
  def forbidden_sends(effects) do
    tracked = Process.get(@tracked, [])
    Enum.filter(effects.sends, &(&1 in tracked or &1 in @names))
  end

  @doc "The subject's calls of anything but pin file metadata among the traced functions."
  def forbidden_calls(effects), do: Enum.reject(effects.calls, &(&1 in @permitted_calls))

  defp record_effects!(effects), do: Process.put(@effects, [effects | Process.get(@effects, [])])

  @doc """
  Test 11 across 8–10: every status observation of this test made no
  query, sent nothing to a coordinator, server, reaper or tree supervisor,
  and called no forbidden function (`Runtime.resolve/1`, a hold or its
  release, a call, `Reaper.release/1`, a pin content read, a CLI run).
  """
  def assert_no_status_effects!(opts \\ []) do
    effects = Process.get(@effects, [])
    assert effects != [], "no status observation was recorded"

    for e <- effects do
      assert_no_effects!(e, "a status observation", opts)
    end

    :ok
  end

  @doc """
  Asserts one observation's effects are all zero (`label` names it).
  `allow:` lists traced calls permitted for this observation (the Fake's
  `Runtime.resolve/1` pass-through: 2a's no-resolve rule binds ClaudeCLI).
  """
  def assert_no_effects!(effects, label, opts \\ []) do
    allowed = Keyword.get(opts, :allow, [])
    calls = Enum.reject(forbidden_calls(effects), &(&1 in allowed))

    assert effects.queries == 0,
           "C2-02c test 11 (#{label}): status made #{effects.queries} database queries"

    assert forbidden_sends(effects) == [],
           "C2-02c test 11 (#{label}): status sent to #{inspect(forbidden_sends(effects))}"

    assert calls == [],
           "C2-02c test 11 / 2a (#{label}): status called #{inspect(calls)}"
  end

  ## Shapes (contract 2 and 2b)

  @doc """
  Asserts `status` has every `{key, expected}` of `expected` (a keyword
  list; a value, or a matcher from this module), reporting every mismatch
  at once. A missing key is reported as missing (RED).
  """
  def assert_status!(status, expected, label) do
    assert is_map(status) and not is_struct(status),
           "C2-02c #{label}: Runtime.status/0 returned #{inspect(status)}"

    mismatches =
      for {key, want} <- expected,
          got = Map.get(status, key, :__missing__),
          not matches?(want, got),
          do: "#{key}: expected #{describe(want)}, got #{inspect(got)}"

    assert mismatches == [], "C2-02c #{label}:\n  " <> Enum.join(mismatches, "\n  ")
  end

  defp matches?({:matcher, _description, fun}, got), do: fun.(got) == true
  defp matches?(want, got), do: want == got

  defp describe({:matcher, description, _fun}), do: description
  defp describe(want), do: inspect(want)

  defp matcher(description, fun), do: {:matcher, description, fun}

  @doc "A confirmed desired-profile observation `%{profile_id, source, confirmed_at}`."
  def confirmed(profile, source) do
    matcher(
      "%{profile_id: #{inspect(profile)}, source: #{inspect(source)}, confirmed_at: DateTime}",
      fn
        %{profile_id: ^profile, source: ^source, confirmed_at: %DateTime{}} = got ->
          map_size(got) == 3

        _ ->
          false
      end
    )
  end

  @doc "A confirmed no-switch observation `%{state: :none, confirmed_at}`."
  def none_switch do
    matcher("%{state: :none, confirmed_at: DateTime}", fn
      %{state: :none, confirmed_at: %DateTime{}} = got -> map_size(got) == 2
      _ -> false
    end)
  end

  @doc """
  A confirmed open-switch observation of `switch` at `status`, with a
  `failure_reason` containing `reason` (nil: no reason).
  """
  def open_switch(switch, status, reason) do
    from = switch.from_profile_id
    to = switch.to_profile_id
    id = switch.id

    matcher(
      "%{state: :open, id: #{id}, from: #{from}, to: #{to}, status: #{status}, " <>
        "failure_reason: ~ #{inspect(reason)}, confirmed_at: DateTime}",
      fn
        %{state: :open, id: ^id, from_profile_id: ^from, to_profile_id: ^to, status: ^status} =
            got ->
          map_size(got) == 7 and match?(%DateTime{}, got[:confirmed_at]) and
            reason?(got[:failure_reason], reason)

        _ ->
          false
      end
    )
  end

  defp reason?(nil, nil), do: true
  defp reason?(got, want) when is_binary(got) and is_binary(want), do: got =~ want
  defp reason?(_got, _want), do: false

  @doc "Any `%DateTime{}`."
  def timestamp, do: matcher("a DateTime", &match?(%DateTime{}, &1))

  @doc "`:unknown`, or any confirmed value (a fresh boot before its first read)."
  def unknown_or_confirmed,
    do:
      matcher(
        ":unknown or a confirmed map",
        &(&1 == :unknown or match?(%{confirmed_at: %DateTime{}}, &1))
      )

  @doc "Exactly the coordinator row's current public `key` (read when asserted)."
  def row(key) do
    matcher("the coordinator row's #{key}", fn got ->
      got == Map.get(Coordinator.status() || %{}, key, :__missing__)
    end)
  end

  @doc "The coordinator row's current `published_at`, which must be a DateTime."
  def row_published_at do
    matcher("the coordinator row's published_at (a DateTime)", fn got ->
      match?(%DateTime{}, got) and got == Map.get(Coordinator.status() || %{}, :published_at)
    end)
  end

  @doc "Anything but `value`."
  def other_than(value), do: matcher("anything but #{inspect(value)}", &(&1 != value))

  @doc "2b: no coordinator, an invalid one, or a coordinator that keeps changing."
  def unavailable_row do
    [
      ledger_observation: :unavailable,
      runtime_observation: :unavailable,
      desired_profile: :unknown,
      switch: :unknown,
      observed_profile: :unknown,
      hold: :unknown,
      stage: :unknown,
      effective_profile: nil,
      effective: nil,
      refusal: :status_unavailable,
      published_at: nil,
      profile_id: nil,
      model_alias: nil,
      model_id: nil,
      reviewed_version: nil
    ]
  end

  @doc "2b: consistent, released and eligible at `profile`, with `desired`."
  def released_row(profile, desired) do
    [
      ledger_observation: :valid,
      runtime_observation: :consistent,
      desired_profile: desired,
      switch: none_switch(),
      observed_profile: profile,
      hold: :released,
      effective_profile: profile,
      effective: ClaudeCLI,
      refusal: nil,
      published_at: timestamp(),
      profile_id: profile,
      model_alias: Map.fetch!(@aliases, profile)
    ]
  end

  @doc "2b: consistent with hold `:held` at `profile`, with `desired` and `switch`."
  def held_row(profile, desired, switch) do
    [
      ledger_observation: :valid,
      runtime_observation: :consistent,
      desired_profile: desired,
      switch: switch,
      observed_profile: profile,
      hold: :held,
      effective_profile: nil,
      effective: nil,
      refusal: :provider_held,
      published_at: timestamp(),
      profile_id: profile
    ]
  end

  @doc """
  The ledger fields of a quiescent coordinator are exactly its row's public
  `desired`, `switch` and `published_at` (the last confirmed observations).
  """
  def assert_ledger_is_row!(status, label) do
    assert_status!(
      status,
      [desired_profile: row(:desired), switch: row(:switch), published_at: row_published_at()],
      label <> " (the ledger fields are the coordinator row's)"
    )
  end

  @doc "Whether `term` holds a pid, ref, port or function anywhere."
  def raw?(term) when is_pid(term) or is_reference(term) or is_port(term) or is_function(term),
    do: true

  def raw?(term) when is_map(term), do: term |> Map.to_list() |> raw?()
  def raw?(term) when is_list(term), do: Enum.any?(term, &raw?/1)
  def raw?(term) when is_tuple(term), do: term |> Tuple.to_list() |> raw?()
  def raw?(_term), do: false
end
