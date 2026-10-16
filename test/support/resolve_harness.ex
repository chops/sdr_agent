defmodule SdrAgent.Test.ResolveHarness do
  @moduledoc """
  C2-02b2β test support (`docs/product/r0/c2-02b2b-interface.md`, section 8):
  real blocked switches built through the b2α coordinator, never by a raw
  write, plus presence-guarded calls of the resolver and the barriers its
  tests need. Zero model calls: every server runs the fake CLI under the test
  launcher, and every launch admission is reported to the test process as
  `{:launch_admission, id, profile, opts}`.

  **The fixtures** (each starts the whole profile tree, non-manual, and
  returns the blocked switch), named by the lease kind the resolver observes:

    * `survivor!/1` — a switch paused after its drain, then a coordinator
      kill: the next boot re-holds and adopts the old server and blocks the
      switch (`coordinator_restarted`). A live, held, bound server with open
      admission, whose own live reaper holds the lease.
    * `dead_holder!/1` — the old server and its reaper are killed (both
      suspended first) while the stop protocol awaits the receipt: the
      switch blocks
      (`old_cleanup_unconfirmed`), no named server is left, and the lease is
      held by the dead reaper.
    * `none!/1` — `dead_holder!/1`, then a test-side operator
      `Reaper.release/1`: no named server and no lease.
    * `admission_blocked!/1` — an unidentified fake launch blocks admission,
      then the switch's veto blocks it (`old_cli_not_quiescent`).
    * `partial!/1` — a `:survivor` whose range holds a start allocated, then
      failed with no recorded identity.

  **The calls** `facts/2` (`Agents.blocked_switch_facts/2`) and `resolve/4`
  (`Agents.resolve_blocked_switch/3`) first assert that the function is
  exported, so a missing b2β function fails as an assertion after the
  fixtures; they run bounded in a task (`:no_reply_within_bound` instead of a
  test timeout; a raise is `{:raised, exception}`).

  **The barriers:** `pause_stage!/1` (the b2α stage telemetry) and
  `query_pause!/2` with the matcher factories `coordinator_precommit/0`
  (the coordinator's resolve transaction after its switch update and its
  final budget step, before `COMMIT`), `coordinator_commit/0` (just after
  that `COMMIT`), `coordinator_event_append/0` (inside the write, before its
  last budget step) and `caller_replay_read/1` (a caller's stored read by
  `attestation_id`, in a process marked by `mark_caller/1`); `query_log!/1`
  records queries.
  `trace_release!/0` records every `Reaper.release/1` call and its caller.
  """
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]

  alias SdrAgent.Agents
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper
  alias SdrAgent.AI.ModelProvider.Coordinator
  alias SdrAgent.AI.ModelProvider.ProfileSupervisor
  alias SdrAgent.AI.ModelProvider.Runtime
  alias SdrAgent.Repo
  alias SdrAgent.Test.LaunchAdmission

  @fake Path.expand("fake_claude_cli.exs", __DIR__)
  @stage [:sdr_agent, :model_coordinator, :stage]
  @query [:sdr_agent, :repo, :query]
  @caller {__MODULE__, :caller}
  @schema Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()})

  ## The tree

  @doc """
  Starts the profile tree (non-manual) with the fake CLI. Options: `faults:`
  and `cleanup_wait_ms:` (passed to the coordinator), `unidentified:` (a
  profile whose launches get no OS pid), `failing_preflight:` (a profile
  whose server fails the no-call preflight), `start_failure:` (a profile
  whose server never starts, so its start is allocated, then failed with no
  recorded identity).
  """
  def tree!(opts \\ []) do
    parent = self()

    server = fn profile_id ->
      base = [
        command: System.find_executable("elixir"),
        test_launcher: true,
        launch_admission: LaunchAdmission.recording(parent),
        command_args: [@fake, "ready"]
      ]

      base
      |> then(
        &if(opts[:unidentified] == profile_id,
          do: Keyword.put(&1, :reaper, os_pid: fn _port -> nil end),
          else: &1
        )
      )
      |> then(
        &if(opts[:failing_preflight] == profile_id, do: Keyword.put(&1, :command, nil), else: &1)
      )
      |> then(&if(opts[:start_failure] == profile_id, do: Keyword.put(&1, :timeout, 1), else: &1))
    end

    tree_opts = [server: server] ++ Keyword.take(opts, [:faults, :cleanup_wait_ms])
    start_supervised!({ProfileSupervisor, tree_opts})
  end

  @doc """
  Registers the lease cleanup (call it first in `setup`): a lease left by a
  live reaper is released only once that reaper has exited, so it never
  leaks into the next test. Test-side operator release, never the
  coordinator's.
  """
  def lease_cleanup! do
    on_exit(fn ->
      with {:held, holder} <- Reaper.lease(ClaudeCLI.server()), do: join(holder, 10_000)
      Reaper.release(ClaudeCLI.server())
    end)
  end

  @doc "The coordinator's published status (nil when none runs)."
  def status, do: Coordinator.status()

  @doc "Waits (bounded) for a published status matching `predicate`."
  def await_status!(predicate, timeout \\ 15_000) do
    await!(
      fn ->
        status = status()
        is_map(status) and predicate.(status)
      end,
      timeout,
      fn -> "coordinator status never matched; last #{inspect(status())}" end
    )

    status()
  end

  @doc "Polls `fun` until it is truthy, or flunks with `message` after `timeout` ms."
  def await!(fun, timeout \\ 10_000, message \\ "condition never held") do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(fun, deadline, message)
  end

  defp poll(fun, deadline, message) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk(if is_function(message, 0), do: message.(), else: message)

      true ->
        Process.sleep(20)
        poll(fun, deadline, message)
    end
  end

  @doc "Waits for the coordinator to handle everything already in its mailbox."
  def sync, do: :sys.get_state(Coordinator, 30_000)

  @doc """
  A bounded join of the coordinator's queued work: it handles everything
  already in its mailbox, its mailbox is then empty, and it handles any
  message that arrived meanwhile. Flunks if the mailbox never empties.
  """
  def drain!(timeout \\ 10_000) do
    sync()

    await!(
      fn ->
        pid = Process.whereis(Coordinator)
        is_pid(pid) and Process.info(pid, :message_queue_len) == {:message_queue_len, 0}
      end,
      timeout,
      "the coordinator's mailbox never drained"
    )

    sync()
  end

  @doc """
  Blocks the coordinator inside `Coordinator.test_run/2` (no database
  connection held) until `release_coordinator!/1`; returns `{task,
  coordinator}`. Released on exit.
  """
  def block_coordinator! do
    parent = self()

    task =
      Task.async(fn ->
        Coordinator.test_run(
          fn _binding ->
            send(parent, {:coordinator_blocked, self()})

            receive do
              :go -> :ok
            after
              60_000 -> :ok
            end
          end,
          65_000
        )
      end)

    assert_receive {:coordinator_blocked, coordinator}, 5_000
    on_exit(fn -> send(coordinator, :go) end)
    {task, coordinator}
  end

  @doc "Releases a `block_coordinator!/0` block and joins it."
  def release_coordinator!({task, coordinator}) do
    send(coordinator, :go)
    Task.await(task, 10_000)
  end

  @doc "Kills the coordinator (call only when it is idle or on its own connection)."
  def kill_coordinator! do
    coordinator = Process.whereis(Coordinator)
    ref = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^ref, :process, ^coordinator, _}, 5_000
    coordinator
  end

  @doc "Kills `pid` and waits for its exit."
  def kill!(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    :ok
  end

  @doc "Waits (bounded) for `pid` to exit."
  def join(pid, timeout) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      timeout -> Process.demonitor(ref, [:flush])
    end
  end

  ## Switches and starts

  @doc "Requests a switch away from the desired profile through the coordinator."
  def request_switch!(ctx) do
    {:ok, setting} = Agents.get_profile_setting(actor: ctx.admin)

    {desired, revision} =
      if setting, do: {setting.desired_profile_id, setting.revision}, else: {:claude_cli_opus, 1}

    to = if desired == :claude_cli_opus, do: :claude_cli_sonnet, else: :claude_cli_opus

    assert {:ok, switch} =
             Coordinator.request_switch(
               %{to_profile_id: to, expected_revision: revision},
               actor: ctx.admin
             )

    switch
  end

  @doc "The tenant's switch `id` as stored (read as the admin)."
  def switch!(ctx, id) do
    {:ok, switches} = Agents.list_profile_switches(actor: ctx.admin)
    Enum.find(switches, &(&1.id == id))
  end

  @doc "Waits (bounded) for switch `id` to reach `status`."
  def await_switch!(ctx, id, status, timeout \\ 20_000) do
    await!(
      fn -> match?(%{status: ^status}, switch!(ctx, id)) end,
      timeout,
      fn -> "switch never reached #{status}; last #{inspect(switch!(ctx, id))}" end
    )

    switch!(ctx, id)
  end

  @doc "The tenant's starts, by generation."
  def starts!(ctx) do
    {:ok, starts} = Agents.list_server_starts(actor: ctx.admin)
    Enum.sort_by(starts, & &1.generation)
  end

  @doc "The tenant's latest start."
  def latest_start!(ctx), do: List.last(starts!(ctx))

  @doc "The tenant's `model.profile.switch_resolved` events."
  def resolved_events(ctx),
    do: SdrAgent.AuditCase.events_of_type(ctx.tenant, "model.profile.switch_resolved")

  @doc "A snapshot of everything a no-effect replay must leave unchanged."
  def effects(ctx) do
    {:ok, setting} = Agents.get_profile_setting(actor: ctx.admin)

    %{
      events: length(SdrAgent.AuditCase.events(ctx.tenant)),
      starts: Enum.map(starts!(ctx), &{&1.id, &1.status}),
      setting: setting && {setting.desired_profile_id, setting.revision, setting.updated_at},
      status: status(),
      server: Process.whereis(ClaudeCLI.server())
    }
  end

  ## Fixtures (a real blocked switch, per observed lease kind)

  @doc "A blocked switch whose server survived a coordinator restart (`:survivor`)."
  def survivor!(ctx) do
    tree!()
    first = await_status!(&(&1.hold == :released))
    pause = pause_stage!(:drained)
    switch = request_switch!(ctx)
    assert_receive {:stage_paused, :drained, _worker}, 20_000
    :telemetry.detach(pause)
    # Killed while idle: the worker is paused after its drain.
    kill_coordinator!()

    blocked = await_switch!(ctx, switch.id, :blocked)
    assert blocked.failure_reason =~ "coordinator_restarted"
    await_status!(&(&1.boot_id != first.boot_id and &1.hold == :held and &1.generation == 2))
    sync()

    server = Process.whereis(ClaudeCLI.server())
    assert is_pid(server), "fixture: the survivor runs"
    reaper = ClaudeCLI.reaper(server)
    assert is_pid(reaper) and Process.alive?(reaper)
    assert Reaper.lease(ClaudeCLI.server()) == {:held, reaper}
    assert ClaudeCLI.admission(server).admission == :open
    assert ClaudeCLI.held?(server)
    blocked
  end

  @doc "A blocked switch whose old reaper died without its receipt (`:dead_holder`)."
  def dead_holder!(ctx, opts \\ []) do
    tree!(opts)
    await_status!(&(&1.hold == :released))
    pause = pause_stage!(:old_stopping)
    switch = request_switch!(ctx)
    assert_receive {:stage_paused, :old_stopping, coordinator}, 20_000
    :telemetry.detach(pause)

    # Both suspended, then killed: the reaper never runs its cleanup (no
    # receipt, the lease stays held) and the server never takes the lease
    # over from its dead reaper.
    server = Process.whereis(ClaudeCLI.server())
    reaper = ClaudeCLI.reaper(server)
    true = :erlang.suspend_process(server)
    true = :erlang.suspend_process(reaper)
    kill!(server)
    kill!(reaper)
    send(coordinator, :continue)

    blocked = await_switch!(ctx, switch.id, :blocked)
    assert blocked.failure_reason =~ "old_cleanup_unconfirmed"
    await!(fn -> Process.whereis(ClaudeCLI.server()) == nil end, 10_000, "fixture: server left")
    sync()

    assert Reaper.lease(ClaudeCLI.server()) == {:held, reaper}, "fixture: a dead holder"
    refute Process.alive?(reaper)
    blocked
  end

  @doc "A blocked switch with no server and no lease (`:none`), after an operator release."
  def none!(ctx, opts \\ []) do
    blocked = dead_holder!(ctx, opts)
    # The test-side operator path (never the coordinator's).
    assert :ok = Reaper.release(ClaudeCLI.server())
    assert Reaper.lease(ClaudeCLI.server()) == nil
    blocked
  end

  @doc "A blocked switch whose live, held server has blocked admission."
  def admission_blocked!(ctx) do
    tree!(unidentified: :claude_cli_opus)
    await_status!(&(&1.hold == :released))
    assert {:unknown, _} = ClaudeCLI.complete(request_map(), [])
    assert %{admission: :blocked} = ClaudeCLI.admission()

    switch = request_switch!(ctx)
    blocked = await_switch!(ctx, switch.id, :blocked)
    assert blocked.failure_reason =~ "old_cli_not_quiescent"
    sync()
    blocked
  end

  @doc """
  A blocked switch (`:survivor`) whose covered range holds a start that was
  allocated, then failed with no recorded identity: the candidate never
  starts, the rollback is paused after its preflight, then a coordinator
  kill; the next boot adopts the rollback server and blocks the switch.
  """
  def partial!(ctx) do
    tree!(start_failure: :claude_cli_sonnet)
    first = await_status!(&(&1.hold == :released))
    pause = pause_stage!(:preflighted)
    switch = request_switch!(ctx)
    assert_receive {:stage_paused, :preflighted, _worker}, 20_000
    :telemetry.detach(pause)
    kill_coordinator!()

    blocked = await_switch!(ctx, switch.id, :blocked)
    assert blocked.failure_reason =~ "coordinator_restarted"

    await_status!(
      &(&1.boot_id != first.boot_id and &1.hold == :held and is_integer(&1.generation))
    )

    sync()
    blocked
  end

  @doc "Builds the fixture of lease kind `kind`."
  def blocked!(ctx, :survivor), do: survivor!(ctx)
  def blocked!(ctx, :dead_holder), do: dead_holder!(ctx)
  def blocked!(ctx, :none), do: none!(ctx)

  @doc "A fake-CLI request (only the `admission_blocked!/1` fixture launches one)."
  def request_map do
    trace = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    span = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    %{
      id: "c202b2b-resolve-test",
      operation: "model.complete",
      prompt: "qualify",
      schema: @schema,
      witness: %{
        model_invocation_id: Ash.UUIDv7.generate(),
        traceparent: "00-#{trace}-#{span}-01"
      }
    }
  end

  @doc """
  Asserts that the held server refuses ordinary, prepared (resolved through
  the runtime) and direct-pid calls (`label` names the moment).
  """
  def assert_held_refusals!(label) do
    server = Process.whereis(ClaudeCLI.server())
    assert is_pid(server), "a held server runs (#{label})"
    assert Runtime.resolve(provider: ClaudeCLI) == {:error, :provider_held}, label
    assert ClaudeCLI.complete(request_map(), []) == {:error, :provider_held}, label
    assert ClaudeCLI.complete(request_map(), server: server) == {:error, :provider_held}, label
  end

  ## The attestation and the calls

  @doc """
  The section 2 attestation for `switch`, bound to `start` (the latest start
  in the facts) and lease `kind`, with `overrides` merged in.
  """
  def attestation(switch, start, kind, overrides \\ %{}) do
    Map.merge(
      %{
        attestation_id: Ecto.UUID.generate(),
        switch_id: switch.id,
        attested_start_id: start.id,
        attested_generation: start.generation,
        attested_lease_kind: kind,
        outcome: :failed,
        confirmation: "STOPPED " <> switch.id
      },
      Map.new(overrides)
    )
  end

  @doc "`Agents.blocked_switch_facts/2`, presence-guarded and bounded."
  def facts(switch, actor) do
    assert function_exported?(Agents, :blocked_switch_facts, 2),
           "C2-02b2β: SdrAgent.Agents.blocked_switch_facts/2 is not implemented"

    bounded(fn -> apply(Agents, :blocked_switch_facts, [switch, [actor: actor]]) end, 15_000)
  end

  @doc "The facts' observed lease kind."
  def facts_kind(facts), do: Map.fetch!(facts, :lease_kind)

  @doc "The facts' latest start."
  def facts_latest(facts), do: Map.fetch!(facts, :latest_start)

  @doc "Asserts that the resolver exists (before a fixture that needs its columns)."
  def require_resolver! do
    assert function_exported?(Agents, :resolve_blocked_switch, 3),
           "C2-02b2β: SdrAgent.Agents.resolve_blocked_switch/3 is not implemented"
  end

  @doc "`Agents.resolve_blocked_switch/3`, presence-guarded and bounded."
  def resolve(switch, attestation, actor, opts \\ []) do
    task = resolve_task(switch, attestation, actor, opts)
    await_task(task, 25_000)
  end

  @doc """
  Starts the resolver's caller in a task (the caller is that task): `init:`
  (a 0-arity function) runs in it first, before the call.
  """
  def resolve_task(switch, attestation, actor, opts \\ []) do
    require_resolver!()

    {init, opts} = Keyword.pop(opts, :init, fn -> :ok end)

    Task.async(fn ->
      init.()

      observe(fn ->
        apply(Agents, :resolve_blocked_switch, [switch, attestation, [actor: actor] ++ opts])
      end)
    end)
  end

  @doc "Awaits a task bounded: its result, or `:no_reply_within_bound`."
  def await_task(task, timeout) do
    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:exited, reason}
      nil -> :no_reply_within_bound
    end
  end

  @doc "Runs `fun` bounded in a task."
  def bounded(fun, timeout), do: await_task(Task.async(fn -> observe(fun) end), timeout)

  @doc "Runs `fun`, returning `{:raised, exception}` or `{:caught, kind, reason}` instead."
  def observe(fun) do
    fun.()
  rescue
    exception -> {:raised, exception}
  catch
    kind, reason -> {:caught, kind, reason}
  end

  @doc "A stored field of a switch that may not exist before GREEN."
  def field(switch, key), do: Map.get(switch, key)

  ## Barriers

  @doc """
  Pauses the stage `stage` of the b2α stage telemetry: the emitting process
  sends `{:stage_paused, stage, pid}` and waits for `:continue` (30 s).
  Returns the handler id (detach it once used).
  """
  def pause_stage!(stage) do
    id = "c202b2b-stage-#{System.unique_integer([:positive])}"
    {:ok, paused} = Agent.start(fn -> [] end)

    :ok =
      :telemetry.attach(
        id,
        @stage,
        &__MODULE__.stage_handler/4,
        %{parent: self(), stage: stage, paused: paused}
      )

    # Never leaves a paused process behind, even after a failure.
    on_exit(fn ->
      :telemetry.detach(id)
      for pid <- Agent.get(paused, & &1), do: send(pid, :continue)
      Agent.stop(paused)
    end)

    id
  end

  @doc false
  def stage_handler(_event, _measurements, %{stage: stage}, %{stage: stage} = config) do
    me = self()
    Agent.update(config.paused, &[me | &1])
    send(config.parent, {:stage_paused, stage, self()})

    receive do
      :continue -> :ok
    after
      30_000 -> :ok
    end
  end

  def stage_handler(_event, _measurements, _meta, _config), do: :ok

  @doc """
  Pauses the first repo query for which `matcher.(meta)` is true (evaluated
  in the querying process, after the query): that process sends `{tag,
  pid}` and waits for `{:resume, tag}` (60 s). Returns the handler id.
  """
  def query_pause!(tag, matcher) do
    id = "c202b2b-query-#{System.unique_integer([:positive])}"
    once = :atomics.new(1, [])
    {:ok, paused} = Agent.start(fn -> [] end)

    :ok =
      :telemetry.attach(id, @query, &__MODULE__.query_handler/4, %{
        parent: self(),
        tag: tag,
        matcher: matcher,
        once: once,
        paused: paused
      })

    # Never leaves a paused process behind, even after a failure.
    on_exit(fn ->
      :telemetry.detach(id)
      for pid <- Agent.get(paused, & &1), do: resume(pid, tag)
      Agent.stop(paused)
    end)

    id
  end

  @doc false
  def query_handler(_event, _measurements, meta, config) do
    if config.matcher.(meta) and :atomics.compare_exchange(config.once, 1, 0, 1) == :ok do
      me = self()
      Agent.update(config.paused, &[me | &1])
      send(config.parent, {config.tag, me})
      tag = config.tag

      receive do
        {:resume, ^tag} -> :ok
      after
        60_000 -> :ok
      end
    end

    :ok
  end

  @doc "Resumes a process paused by `query_pause!/2`."
  def resume(pid, tag), do: send(pid, {:resume, tag})

  @doc """
  Matcher factory: in the coordinator, after a switch row update in the
  current transaction, its final timeout restore (after LedgerCall's last
  budget step): the last query before `COMMIT`.
  """
  def coordinator_precommit, do: coordinator_switch_write(&final_restore?/1)

  @doc "Matcher factory: in the coordinator, the `COMMIT` of a transaction that updated a switch."
  def coordinator_commit, do: coordinator_switch_write(&(to_string(&1.query) == "commit"))

  @doc """
  Matcher factory: in the coordinator, the audit event append that follows a
  switch row update (inside the write, before its last budget step).
  """
  def coordinator_event_append,
    do:
      coordinator_switch_write(
        &String.starts_with?(to_string(&1.query), "INSERT INTO \"audit_events\"")
      )

  # Each matcher keeps its own flag in the coordinator's process dictionary.
  defp coordinator_switch_write(point?) do
    key = {__MODULE__, :switch_written, make_ref()}

    fn meta ->
      query = to_string(meta.query)

      cond do
        self() != Process.whereis(Coordinator) ->
          false

        String.starts_with?(query, "UPDATE \"model_profile_switches\"") ->
          Process.put(key, true)
          false

        Process.get(key) == true and point?.(meta) ->
          true

        query in ["commit", "rollback"] ->
          Process.delete(key)
          false

        true ->
          false
      end
    end
  end

  defp final_restore?(meta) do
    String.contains?(to_string(meta.query), "set_config('lock_timeout'") and
      not Enum.any?(meta.params || [], &(is_binary(&1) and Regex.match?(~r/\A\d+ms\z/, &1)))
  end

  @doc "Marks the calling process as the resolver caller `tag` (for `caller_replay_read/1`)."
  def mark_caller(tag), do: Process.put(@caller, tag)

  @doc "Matcher factory: caller `tag`'s stored switch read filtered by `attestation_id`."
  def caller_replay_read(tag) do
    fn meta ->
      Process.get(@caller) == tag and
        Regex.match?(~r/FROM "model_profile_switches".*WHERE.*"attestation_id"/s, meta.query)
    end
  end

  @doc "Matcher: any query of a process marked as caller `tag`."
  def caller_query(tag), do: fn _meta -> Process.get(@caller) == tag end

  @doc "Matcher: any query of the registered coordinator."
  def coordinator_query(_meta), do: self() == Process.whereis(Coordinator)

  @doc """
  Logs every repo query for which `matcher.(meta)` is true (in the querying
  process); `logged/1` returns them in order.
  """
  def query_log!(matcher) do
    {:ok, log} = Agent.start_link(fn -> [] end)
    id = "c202b2b-log-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(id, @query, &__MODULE__.log_handler/4, %{log: log, matcher: matcher})

    on_exit(fn -> :telemetry.detach(id) end)
    log
  end

  @doc false
  def log_handler(_event, _measurements, meta, %{log: log, matcher: matcher}) do
    if matcher.(meta) do
      status = if match?({:ok, _}, meta.result), do: :ok, else: :error
      Agent.update(log, &[{to_string(meta.query), status} | &1])
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  @doc "The `{query, :ok | :error}` entries a `query_log!/1` recorded, in order."
  def logged(log), do: log |> Agent.get(& &1) |> Enum.reverse()

  @doc """
  Records every `Reaper.release/1` call system-wide, with its caller and
  name. Positive control: a test-side release of a probe name is seen before
  this returns. Tracing is disabled and the collector joined on exit.
  """
  def trace_release! do
    collector = spawn(fn -> collect([]) end)
    :erlang.trace_pattern({Reaper, :release, 1}, true, [:global])
    :erlang.trace(:all, true, [:call, {:tracer, collector}])

    on_exit(fn ->
      :erlang.trace(:all, false, [:call])
      :erlang.trace_pattern({Reaper, :release, 1}, false, [:global])
      ref = Process.monitor(collector)
      send(collector, :stop)

      receive do
        {:DOWN, ^ref, :process, ^collector, _} -> :ok
      after
        5_000 -> Process.exit(collector, :kill)
      end
    end)

    :ok = Reaper.release(:c202b2b_trace_probe)

    assert release_callers(collector, :c202b2b_trace_probe) == [self()],
           "trace control: the test-side probe release was not seen"

    collector
  end

  defp collect(calls) do
    receive do
      {:trace, pid, :call, {Reaper, :release, [name]}} ->
        collect([{pid, name} | calls])

      {:calls, from, ref} ->
        send(from, {:release_calls, ref, Enum.reverse(calls)})
        collect(calls)

      :stop ->
        :ok
    end
  end

  @doc """
  The pids that called `Reaper.release(name)` (default: the named server's
  lease) since `trace_release!/0`. Every trace message already generated is
  delivered first (`:erlang.trace_delivered/1`), then the collector answers.
  """
  def release_callers(collector, name \\ ClaudeCLI.server()) do
    delivered = :erlang.trace_delivered(:all)

    receive do
      {:trace_delivered, :all, ^delivered} -> :ok
    after
      5_000 -> flunk("trace messages were never delivered")
    end

    ref = make_ref()
    send(collector, {:calls, self(), ref})

    receive do
      {:release_calls, ^ref, calls} -> for {pid, ^name} <- calls, do: pid
    after
      5_000 -> flunk("the release trace collector did not answer")
    end
  end

  ## Independent connections (auto-mode modules only)

  @doc """
  Holds `fun`'s row locks in a transaction on its own connection until
  `release_holder/1`; returns `{task, backend_pid}`.
  """
  def hold!(fun) do
    parent = self()

    task =
      Task.async(fn ->
        Repo.transaction(
          fn ->
            [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
            fun.()
            send(parent, {:holding, self(), backend})

            receive do
              :release -> :ok
            after
              60_000 -> :ok
            end
          end,
          timeout: 90_000
        )
      end)

    assert_receive {:holding, _pid, backend}, 10_000
    on_exit(fn -> send(task.pid, :release) end)
    {task, backend}
  end

  @doc "Ends a `hold!/1` transaction (commit) and joins it."
  def release_holder(%Task{} = task) do
    send(task.pid, :release)
    Task.await(task, 10_000)
  end

  @doc "Locks the tenant's setting row `FOR UPDATE` (inside `hold!/1`)."
  def lock_setting!(tenant_id),
    do:
      Repo.query!("SELECT 1 FROM model_profile_settings WHERE tenant_id = $1 FOR UPDATE", [
        Ecto.UUID.dump!(tenant_id)
      ])

  @doc "Waits (bounded) until some backend waits on `holder`'s locks."
  def await_blocked_by!(holder, timeout \\ 10_000, message \\ nil) do
    await!(fn -> waiters(holder) != [] end, timeout, message || "no backend waited on #{holder}")
    waiters(holder)
  end

  @doc "The `[pid, query]` of every backend blocked by `holder`."
  def waiters(holder),
    do:
      Repo.query!(
        "SELECT pid, query FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid))",
        [holder]
      ).rows

  @doc "The granted relation locks of backend `pid`, as `[relname, mode]`."
  def relation_locks(pid),
    do:
      Repo.query!(
        "SELECT c.relname, l.mode FROM pg_locks l JOIN pg_class c ON c.oid = l.relation " <>
          "WHERE l.pid = $1 AND l.granted",
        [pid]
      ).rows

  @doc "The backend that holds an uncommitted switch-row write (nil if none)."
  def switch_writer do
    Repo.query!("""
    SELECT l.pid FROM pg_locks l JOIN pg_class c ON c.oid = l.relation
    WHERE c.relname = 'model_profile_switches' AND l.mode = 'RowExclusiveLock'
      AND l.granted AND l.pid <> pg_backend_pid()
    """).rows
    |> case do
      [[pid] | _] -> pid
      [] -> nil
    end
  end

  @doc "The stored status of switch `id`, read raw on this connection."
  def raw_status(id) do
    [[status]] =
      Repo.query!("SELECT status FROM model_profile_switches WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ]).rows

    status
  end
end
