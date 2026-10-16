defmodule SdrAgent.Test.ResolverRehearsal.Fixture do
  @moduledoc """
  The rehearsal's fixture (test builds only; see `SdrAgent.Test.ResolverRehearsal`):
  `SdrAgent.Test.ResolveHarness.survivor!/1` adapted without ExUnit, plus an
  owned-process lifecycle.

  **Build** (`start!/2`): the profile tree (non-manual), linked to the
  caller, with the harness's fake CLI (`test/support/fake_claude_cli.exs`
  under `elixir`, `test_launcher: true`) and a refusal-only launch
  admission recorder; the fake-launcher check before any fault; a real
  switch request (`Coordinator.request_switch/2`); the switch worker paused
  at the b2α `:drained` stage; fail-closed ownership checks; a kill of only
  this tree's coordinator; the next boot re-holds and adopts the old server
  and blocks the switch (`coordinator_restarted`). Nothing is written raw:
  no SQL write, no resource struct write, no forged status, no lease
  release.

  **Owned processes.** A tracker records every owned process as it is
  acquired: the tree, and every server registered under the ClaudeCLI name
  with its reaper and the lease holder, sampled every 100 ms and at stop (so
  a server or reaper that replaced the fixture's, e.g. after a browser
  switch, is joined too; a server that lived less than one sample and left
  no lease is not seen, and its reaper would still hold the lease, which
  `stop/2` checks).

  **Stop** (`stop/2`) releases any paused worker, detaches the barrier,
  stops the tree (bounded), joins every tracked process (bounded), restores
  the model provider and reads the recorder. Its outcome lists every
  unconfirmed item in `problems`: a tree that did not stop, a process that
  did not exit, a registered server or a lease left behind, an unavailable
  recorder. It never releases a lease and never touches the database. A
  failed build runs the same stop on what it acquired and raises with the
  original error (and the cleanup problems, when there are any).
  """

  alias SdrAgent.Accounts
  alias SdrAgent.Agents
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper
  alias SdrAgent.AI.ModelProvider.Coordinator
  alias SdrAgent.AI.ModelProvider.ProfileSupervisor
  alias SdrAgent.Repo
  alias SdrAgent.Test.LaunchAdmission
  alias SdrAgent.Test.ResolveHarness

  @fake Path.expand("../fake_claude_cli.exs", __DIR__)
  @stage [:sdr_agent, :model_coordinator, :stage]
  @refusal {:error, :rehearsal_no_calls}
  @counted ~w(model_invocations model_call_grants model_call_allocations model_result_releases
              wire_witness_links tool_invocations agent_runs oban_jobs)
  @sample_ms 100

  @doc "The fake CLI script every fixture server runs (the harness's)."
  def fake_script, do: @fake

  ## Counters (read-only)

  @doc "Read-only row counts of every call, charge and witness table, plus Oban jobs."
  def counters, do: Map.new(@counted, &{&1, Repo.aggregate(&1, :count)})

  ## The admin

  @doc """
  The singleton tenant (bootstrapped if absent) and its first admin,
  through `Accounts.bootstrap_admin/2` (refused when the tenant has users).
  A refusal names only the error's type: no input value reaches the message.
  """
  def create_admin!(email, password) do
    {:ok, tenant} = SdrAgent.Audit.bootstrap(slug: "rehearsal", name: "Resolver Rehearsal")

    attrs = %{
      email: email,
      display_name: "Rehearsal Admin (synthetic)",
      password: password,
      password_confirmation: password
    }

    case Accounts.bootstrap_admin(attrs) do
      {:ok, admin} -> %{tenant: tenant, admin: admin}
      {:error, error} -> raise "first-admin bootstrap refused (#{inspect(error.__struct__)})"
    end
  end

  ## The fake-launcher check

  @doc """
  The fake-launcher check, before any fault: `state` is the running server's
  state (`:sys.get_state/1`), `attestation` its `ClaudeCLI.attestation/1`.
  The command must be this build's `elixir` running exactly the harness's
  fake CLI script in `ready` mode, under the test launcher, with no pinned
  executable, no real CLI binary configured and every admission to the
  driver's refusing recorder.
  """
  def check_launcher(state, attestation, admission) do
    elixir = System.find_executable("elixir")

    checks = [
      {is_binary(elixir) and state.command == elixir, "the command is not this build's elixir"},
      {state.command_args == [@fake, "ready"], "the arguments are not the fake CLI script"},
      {File.regular?(@fake), "the fake CLI script is missing"},
      {state.test_launcher == true, "the server is not under the test launcher"},
      {is_nil(state.executable), "a pinned CLI executable is set"},
      {state.launch_admission == admission, "launch admission is not the driver's recorder"},
      {Map.get(attestation, :test_launcher?) == true, "the attestation is not a test launcher"},
      {is_nil(Map.get(attestation, :executable)), "the attestation names an executable"},
      {is_nil(System.get_env("SDR_CLAUDE_CLI_BIN")), "SDR_CLAUDE_CLI_BIN is set"}
    ]

    case for({false, why} <- checks, do: why) do
      [] -> :ok
      failures -> {:error, "not the fake launcher: " <> Enum.join(failures, "; ")}
    end
  end

  ## Session

  @doc """
  A new session (no process of the profile tree yet): the refusing
  recorder, the barrier's paused-process list and the tracker, all owned by
  the caller's session. `before` is the counters baseline.
  """
  def session(before) do
    recorder = spawn(fn -> sink(0) end)
    {:ok, paused} = Agent.start(fn -> [] end)
    tracker = spawn(fn -> track(MapSet.new()) end)

    %{
      recorder: recorder,
      paused: paused,
      tracker: tracker,
      handler: "r005-rehearsal-#{System.unique_integer([:positive])}",
      admission: LaunchAdmission.recording(recorder, @refusal),
      previous_provider: Application.fetch_env!(:sdr_agent, :model_provider),
      tree: nil,
      before: before
    }
  end

  @doc """
  Builds the blocked switch for `ctx` (`%{admin, tenant}`) and returns the
  session (`stop/2` it). Sets the app's model provider to ClaudeCLI for this
  VM (restored by `stop/2`). Any failure stops what it acquired and raises
  the original error; when that cleanup is also unconfirmed, the raise names
  both. `opts` are `stop/2`'s.
  """
  def start!(ctx, opts \\ []) do
    if Process.whereis(ProfileSupervisor), do: fail!("a profile tree is already running")
    if ClaudeCLI.running?(ClaudeCLI.server()), do: fail!("a ClaudeCLI server is already running")
    session = session(counters())

    try do
      build!(session, ctx)
    catch
      kind, reason ->
        stack = __STACKTRACE__
        outcome = stop(%{session | tree: owned_tree()}, opts)

        case outcome.problems do
          [] ->
            :erlang.raise(kind, reason, stack)

          problems ->
            raise "rehearsal fixture: #{describe(kind, reason)}; cleanup also unconfirmed: " <>
                    Enum.join(problems, "; ")
        end
    end
  end

  @doc "A one-line description of a caught `kind`/`reason`."
  def describe(:error, reason), do: Exception.message(Exception.normalize(:error, reason, []))
  def describe(kind, reason), do: "#{kind} #{inspect(reason)}"

  # The registered profile tree, only when this process started (is linked
  # to) it: a failed build stops its own tree and nothing else.
  defp owned_tree do
    tree = Process.whereis(ProfileSupervisor)
    {:links, links} = Process.info(self(), :links)
    if is_pid(tree) and tree in links, do: tree
  end

  # The recorder: counts every admission (each answered with the refusal,
  # so the launch never happens) and answers `launches/1`.
  defp sink(count) do
    receive do
      {:launch_admission, _id, _profile, _opts} ->
        sink(count + 1)

      {:count, from, ref} ->
        send(from, {ref, count})
        sink(count)

      :stop ->
        :ok
    end
  end

  @doc "The recorder's admission count (nil when it no longer runs or does not answer)."
  def launches(recorder), do: ask(recorder, :count)

  # The tracker: every owned process seen, sampled every 100 ms.
  defp track(pids) do
    receive do
      {:add, pid} ->
        track(MapSet.put(pids, pid))

      {:pids, from, ref} ->
        send(from, {ref, pids})
        track(pids)

      :stop ->
        :ok
    after
      @sample_ms -> track(MapSet.union(pids, observed()))
    end
  end

  @doc "The owned processes the tracker has seen (nil when it does not answer)."
  def tracked(tracker), do: ask(tracker, :pids)

  @doc "Adds `pid` to the session's owned processes."
  def own(session, pid), do: send(session.tracker, {:add, pid})

  # The server registered under the ClaudeCLI name, its reaper and the
  # lease holder (non-blocking reads: registry, ETS, persistent_term).
  defp observed do
    holder =
      case Reaper.lease(ClaudeCLI.server()) do
        {:held, pid} -> pid
        _ -> nil
      end

    [Process.whereis(ClaudeCLI.server()), ClaudeCLI.reaper(ClaudeCLI.server()), holder]
    |> Enum.filter(&is_pid/1)
    |> MapSet.new()
  end

  defp ask(pid, what) do
    ref = Process.monitor(pid)
    send(pid, {what, self(), ref})

    receive do
      {^ref, value} ->
        Process.demonitor(ref, [:flush])
        value

      {:DOWN, ^ref, :process, _, _} ->
        nil
    after
      5_000 ->
        Process.demonitor(ref, [:flush])
        nil
    end
  end

  defp build!(session, ctx) do
    Application.put_env(:sdr_agent, :model_provider, ClaudeCLI)
    admission = session.admission

    server = fn _profile_id ->
      [
        command: System.find_executable("elixir"),
        test_launcher: true,
        launch_admission: admission,
        command_args: [@fake, "ready"]
      ]
    end

    {:ok, tree} = ProfileSupervisor.start_link(server: server)
    own(session, tree)
    session = %{session | tree: tree}
    first = await_status!(&(&1.hold == :released), "the first server never released")
    server_pid = Process.whereis(ClaudeCLI.server()) || fail!("no first server runs")
    own(session, server_pid)

    with {:error, why} <-
           check_launcher(
             :sys.get_state(server_pid),
             ClaudeCLI.attestation(server_pid),
             admission
           ),
         do: fail!(why)

    blocked = induce!(session, ctx, first)
    survivor!(session, ctx, blocked, first)
  end

  defp induce!(session, ctx, first) do
    attach_pause!(session)
    switch = request_switch!(ctx)

    worker =
      receive do
        {:stage_paused, :drained, worker} -> worker
      after
        20_000 -> fail!("the switch worker never paused at :drained")
      end

    :telemetry.detach(session.handler)
    coordinator = Process.whereis(Coordinator)
    check_owned!(session.tree, coordinator, worker)

    match?(%{status: :pending}, switch!(ctx, switch.id)) ||
      fail!("the switch is not pending at the barrier: #{inspect(switch!(ctx, switch.id))}")

    first.boot_id == Coordinator.status().boot_id || fail!("the coordinator rebooted early")
    kill!(coordinator)
    blocked = await_switch!(ctx, switch.id, :blocked)

    blocked.failure_reason =~ "coordinator_restarted" ||
      fail!("blocked for #{inspect(blocked.failure_reason)}, not coordinator_restarted")

    blocked
  end

  defp survivor!(session, ctx, blocked, first) do
    status =
      await_status!(
        &(&1.boot_id != first.boot_id and &1.hold == :held and &1.generation == 2),
        "the next boot never re-held generation 2"
      )

    :sys.get_state(Coordinator, 30_000)
    for pid <- Agent.get(session.paused, & &1), do: send(pid, :continue)
    server = Process.whereis(ClaudeCLI.server()) || fail!("no surviving server")
    reaper = ClaudeCLI.reaper(server)
    for pid <- [server, reaper], is_pid(pid), do: own(session, pid)

    checks = [
      is_pid(reaper) and Process.alive?(reaper),
      Reaper.lease(ClaudeCLI.server()) == {:held, reaper},
      ClaudeCLI.admission(server).admission == :open,
      ClaudeCLI.held?(server)
    ]

    Enum.all?(checks) || fail!("the survivor differs from the fixture: #{inspect(checks)}")

    Map.merge(session, %{
      switch: blocked,
      first: first,
      status: status,
      server: server,
      reaper: reaper,
      coordinator: Process.whereis(Coordinator),
      starts: starts!(ctx),
      after: counters(),
      launches: launches(session.recorder),
      tenant_id: ctx.tenant.id
    })
  end

  defp attach_pause!(session) do
    :ok =
      :telemetry.attach(
        session.handler,
        @stage,
        &ResolveHarness.stage_handler/4,
        %{parent: self(), stage: :drained, paused: session.paused}
      )
  end

  defp request_switch!(ctx) do
    {:ok, setting} = Agents.get_profile_setting(actor: ctx.admin)

    {desired, revision} =
      if setting, do: {setting.desired_profile_id, setting.revision}, else: {:claude_cli_opus, 1}

    to = if desired == :claude_cli_opus, do: :claude_cli_sonnet, else: :claude_cli_opus

    case Coordinator.request_switch(%{to_profile_id: to, expected_revision: revision},
           actor: ctx.admin
         ) do
      {:ok, switch} -> switch
      other -> fail!("the switch request was refused: #{inspect(other)}")
    end
  end

  # The coordinator is this driver's tree's child, and the paused worker is
  # that tree's operation supervisor's child: nothing else is killed.
  defp check_owned!(tree, coordinator, worker) do
    children = Supervisor.which_children(tree)
    ours = for {Coordinator, pid, _, _} <- children, do: pid
    workers = Task.Supervisor.children(SdrAgent.AI.ModelProvider.OperationSupervisor)

    (is_pid(coordinator) and ours == [coordinator]) ||
      fail!("the registered coordinator is not this driver's tree's")

    worker in workers || fail!("the paused worker is not this tree's switch worker")
  end

  defp kill!(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      5_000 -> fail!("the coordinator did not exit")
    end
  end

  @doc "The tenant's switch `id` as stored (read as the admin)."
  def switch!(ctx, id) do
    {:ok, switches} = Agents.list_profile_switches(actor: ctx.admin)
    Enum.find(switches, &(&1.id == id))
  end

  @doc "The tenant's starts as `{generation, id, profile_id, status}`."
  def starts!(ctx) do
    {:ok, starts} = Agents.list_server_starts(actor: ctx.admin)

    starts
    |> Enum.sort_by(& &1.generation)
    |> Enum.map(&{&1.generation, &1.id, &1.profile_id, &1.status})
  end

  defp await_switch!(ctx, id, status) do
    await!(fn -> match?(%{status: ^status}, switch!(ctx, id)) end, 20_000, fn ->
      "the switch never reached #{status}; last #{inspect(switch!(ctx, id))}"
    end)

    switch!(ctx, id)
  end

  defp await_status!(predicate, message) do
    await!(
      fn ->
        status = Coordinator.status()
        is_map(status) and predicate.(status)
      end,
      15_000,
      fn -> "#{message}; last #{inspect(Coordinator.status())}" end
    )

    Coordinator.status()
  end

  defp await!(fun, timeout, message) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(fun, deadline, message)
  end

  defp poll(fun, deadline, message) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        fail!(message.())

      true ->
        Process.sleep(20)
        poll(fun, deadline, message)
    end
  end

  defp fail!(message), do: raise("rehearsal fixture: #{message}")

  ## Stop

  @doc """
  Stops and joins everything the session owns; returns `%{problems,
  launches, joined, named_server, lease}`, `problems` empty only when every
  item is confirmed. Options: `stop_timeout:` (the tree, default 30 s),
  `join_timeout:` (each owned process, default 10 s). Never releases a
  lease and never touches the database.
  """
  def stop(session, opts \\ []) do
    stop_timeout = Keyword.get(opts, :stop_timeout, 30_000)
    join_timeout = Keyword.get(opts, :join_timeout, 10_000)

    safe(fn -> :telemetry.detach(session.handler) end, :ok)
    for pid <- safe(fn -> Agent.get(session.paused, & &1) end, []), do: send(pid, :continue)

    before_stop = owned(session)
    tree_problems = stop_tree(session.tree, stop_timeout)
    owned = MapSet.union(before_stop, MapSet.union(owned(session), observed()))
    join_problems = Enum.flat_map(owned, &join(&1, join_timeout))

    named = Process.whereis(ClaudeCLI.server())
    lease = Reaper.lease(ClaudeCLI.server())
    Application.put_env(:sdr_agent, :model_provider, session.previous_provider)
    launches = launches(session.recorder)
    tracker_ok? = not is_nil(tracked(session.tracker))

    for pid <- [session.recorder, session.tracker], do: send(pid, :stop)
    safe(fn -> Agent.stop(session.paused) end, :ok)

    problems =
      tree_problems ++
        join_problems ++
        if(named, do: ["a server is still registered (#{inspect(named)})"], else: []) ++
        if(lease, do: ["the ClaudeCLI lease is still #{inspect(lease)}"], else: []) ++
        if(is_nil(launches), do: ["the launch recorder is unavailable"], else: []) ++
        if(tracker_ok?, do: [], else: ["the process tracker is unavailable"])

    %{
      problems: problems,
      launches: launches,
      joined: MapSet.size(owned),
      named_server: named,
      lease: lease
    }
  end

  defp owned(session) do
    known =
      Enum.filter([session.tree, Map.get(session, :server), Map.get(session, :reaper)], &is_pid/1)

    MapSet.union(tracked(session.tracker) || MapSet.new(), MapSet.new(known))
  end

  defp stop_tree(tree, timeout) when is_pid(tree) do
    if Process.alive?(tree) do
      # Unlinked first: the caller is not taken down by the tree's exit.
      Process.unlink(tree)

      try do
        Supervisor.stop(tree, :normal, timeout)
        []
      catch
        :exit, reason -> ["the profile tree did not stop: #{inspect(reason)}"]
      end
    else
      []
    end
  end

  defp stop_tree(_tree, _timeout), do: []

  defp join(pid, timeout) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> []
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        ["#{inspect(pid)} did not exit within #{timeout} ms"]
    end
  end

  defp safe(fun, default) do
    fun.()
  catch
    :exit, _ -> default
  end
end
