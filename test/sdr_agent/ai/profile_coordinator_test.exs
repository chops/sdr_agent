defmodule SdrAgent.AI.ProfileCoordinatorTest do
  @moduledoc """
  C2-02b2α RED (interface and entity PASS at `c00ed69`, sections 2, 2a and
  3; binding obligations 3, 4 and 5): the coordinator-owned server
  lifecycle, end to end, with the fake CLI under the test launcher.

    * **The tree:** `ProfileSupervisor` (`:rest_for_one`) runs the
      `ServerSupervisor`, the `Coordinator` and the `OperationSupervisor`.
      Every server is started through the allocator, and **held** until a
      reconciled read releases it.
    * **The normal branch:** a cold boot (no setting, no switch) and a
      coordinator restart with no open switch (adoption, `:adopted`) both
      end released, so a newly admitted call runs. A call in flight across
      the restart keeps running.
    * **A switch:** drain → veto → stop the old server (acknowledged
      receipt) → candidate (held) → no-call preflight → `complete` → the
      release. A failed candidate preflight rolls back to the old profile
      and `fail`s. An unconfirmed old cleanup blocks before any stop.
    * **Crashes and uncertainty:** a pending switch at a coordinator
      restart is blocked (`:coordinator_restarted`) and the server stays
      held. A worker death blocks (`:operation_died`). A lost `complete`
      reply with an unreadable reconciliation keeps the candidate held
      (ordinary, resolved and direct-pid calls are all refused), until a
      readable reconciliation releases it.

  The R4 consumer cases pause the coordinator at `:old_stopping` (after
  the subscription is acknowledged, before the stop). `cleanup_wait_ms:`
  shortens the per-wait bound (at most the accepted 10 s).

  The `ProfileSupervisor` `server:` option maps a profile to the ClaudeCLI
  start options (configuration, not a seam). The test-build-only
  coordinator option `faults:` loses a finalization reply and gates the
  reconciliation read. Stages are observed through the telemetry event
  `[:sdr_agent, :model_coordinator, :stage]` (`%{stage: atom, switch_id:
  id | nil}`). No model call: `LaunchAdmission.recording/1` reports every
  launch admission, and none happens during a switch.

  #235: `await_switch!/4`'s observation path, through its injected reader
  (`await_switch_with!/4`) with a scripted reader and no database in the
  subject (the module setup still runs). The exact shared-sandbox queue drop
  CI saw here (run 40460413797) is transient under one deadline; every other
  error fails on its first read; the matching observation is returned with no
  further read, and a match that arrives after the deadline is not accepted.
  This proves the handling of that observed error shape, not the inferred
  contention behind it.
  """
  use SdrAgent.AuditCase, async: false

  alias Ash.Error.Unknown.UnknownError
  alias SdrAgent.Agents
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.Runtime
  alias SdrAgent.Test.LaunchAdmission

  @coordinator SdrAgent.AI.ModelProvider.Coordinator
  @profile_supervisor SdrAgent.AI.ModelProvider.ProfileSupervisor
  @stage [:sdr_agent, :model_coordinator, :stage]
  @schema Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()})
  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)
  # #235: verbatim from the CI failure (run 40460413797, attempt 1), with its PIDs.
  @queue_drop "** (DBConnection.ConnectionError) could not checkout the connection owned by " <>
                "#PID<0.1292974.0> ({:sql_sandbox_owner, %{started_by: #PID<0.1292973.0>}}). " <>
                "When using the sandbox, connections are shared, so this may imply another " <>
                "process is using a connection. Reason: connection not available and request " <>
                "was dropped from queue after 255ms. You can configure how long requests wait " <>
                "in the queue using :queue_target and :queue_interval. See " <>
                "DBConnection.start_link/2 for more information"
  @observed %{id: "sw-235", status: :failed}
  @other_switch %{id: "sw-other", status: :failed}
  @wrong_status %{id: "sw-235", status: :pending}

  setup do
    tenant = bootstrap!()
    # A lease left by a test's last reaper is released only once that reaper
    # has exited (a live holder refuses the release), so it never leaks into
    # the next test's boot.
    on_exit(fn ->
      with {:held, holder} <- SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper.lease(ClaudeCLI.server()),
           do: join_bounded(holder, 10_000)

      SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper.release(ClaudeCLI.server())
    end)

    %{tenant: tenant, admin: human(:admin, tenant)}
  end

  ## The normal branch

  describe "boot and adoption" do
    test "a cold boot allocates, starts held, preflights and releases; no setting", ctx do
      tree!(ctx)
      status = await_status!(&(&1.hold == :released))

      assert {status.generation, status.profile_id} == {1, :claude_cli_opus}

      assert [%{reason: :boot, status: :ready, ready_evidence: :spawn_preflight} = start] =
               starts!(ctx)

      server = GenServer.whereis(ClaudeCLI.server())

      assert {start.pid, start.reaper_pid} == {inspect(server), inspect(ClaudeCLI.reaper(server))},
             "start_started records the exact live child and its own reaper"

      assert {:ok, nil} = Agents.get_profile_setting(actor: ctx.admin)
      assert %{status: :pending} = ClaudeCLI.attestation(), "the attestation is not reset"

      assert {:ok, %{model: "claude-opus-5-5"}} = call()
    end

    test "a restart with no switch adopts the server; in-flight work continues", ctx do
      tree!(ctx, slow: true)
      %{boot_id: first_boot} = await_status!(&(&1.hold == :released))
      server = GenServer.whereis(ClaudeCLI.server())

      in_flight = Task.async(fn -> call() end)
      assert_receive {:launch_admission, _, _, _}, 10_000

      kill_coordinator!()

      # The re-hold waits behind the in-flight call: not acknowledged, so
      # not reported as held, and never released.
      pending = await_status!(&(&1.boot_id != first_boot), 5_000)
      assert pending.hold == :pending, "a hold is reported only on its acknowledgement"

      status = await_status!(&(&1.boot_id != first_boot and &1.hold == :released), 20_000)

      assert GenServer.whereis(ClaudeCLI.server()) == server,
             "the server was adopted, not restarted"

      assert status.generation == 2

      assert {:ok, _} = Task.await(in_flight, 20_000), "the in-flight call keeps running"
      assert {:ok, _} = call(), "a newly admitted call runs: the hold was released"

      assert [%{reason: :replacement, ready_evidence: :adopted}, %{reason: :boot}] =
               Enum.sort_by(starts!(ctx), & &1.generation, :desc)
    end

    test "a restart after a completed switch adopts at the desired profile", ctx do
      tree!(ctx)
      await_status!(&(&1.hold == :released))
      assert {:ok, switch} = request(ctx)
      await_switch!(ctx, switch, :completed)
      # Killed once idle, as the rolled-back case below: a client killed
      # mid-query breaks the test's shared sandbox connection (a database
      # would roll its transaction back), which is not what this case tests.
      await_status!(&(&1.hold == :released and &1.generation == 2))

      kill_coordinator!()

      status = await_status!(&(&1.hold == :released and &1.generation == 3), 20_000)
      assert status.profile_id == :claude_cli_sonnet
      assert {:ok, %{model: "claude-sonnet-5-5"}} = call()
    end

    test "a restart after a rolled-back switch adopts at the old profile", ctx do
      tree!(ctx, failing_preflight: :claude_cli_sonnet)
      await_status!(&(&1.hold == :released))
      assert {:ok, switch} = request(ctx)
      await_switch!(ctx, switch, :failed)
      before = await_status!(&(&1.hold == :released))

      kill_coordinator!()

      status =
        await_status!(&(&1.hold == :released and &1.generation == before.generation + 1), 20_000)

      assert status.profile_id == :claude_cli_opus
      assert {:ok, %{model: "claude-opus-5-5"}} = call()
    end
  end

  ## The switch

  describe "a switch" do
    test "activates the new profile with no model call, then releases the candidate", ctx do
      tree!(ctx)
      await_status!(&(&1.hold == :released))
      old = GenServer.whereis(ClaudeCLI.server())

      assert {:ok, switch} = request(ctx)
      assert %{status: :completed} = await_switch!(ctx, switch, :completed)
      refute_received {:launch_admission, _, _, _}, "no model call during the switch"

      status = await_status!(&(&1.hold == :released))
      assert status.profile_id == :claude_cli_sonnet
      refute GenServer.whereis(ClaudeCLI.server()) == old

      assert {:ok, %{desired_profile_id: :claude_cli_sonnet}} =
               Agents.get_profile_setting(actor: ctx.admin)

      reasons = ctx |> starts!() |> Enum.sort_by(& &1.generation) |> Enum.map(& &1.reason)
      assert reasons == [:boot, :activation]
      assert {:ok, %{model: "claude-sonnet-5-5"}} = call()
    end

    test "a failed candidate preflight rolls back and fails the switch", ctx do
      tree!(ctx, failing_preflight: :claude_cli_sonnet)
      await_status!(&(&1.hold == :released))

      assert {:ok, switch} = request(ctx)
      assert %{status: :failed} = await_switch!(ctx, switch, :failed)
      refute_received {:launch_admission, _, _, _}

      reasons =
        ctx |> starts!() |> Enum.sort_by(& &1.generation) |> Enum.map(&{&1.reason, &1.status})

      assert reasons == [boot: :ready, activation: :failed, rollback: :ready]

      assert {:ok, %{desired_profile_id: :claude_cli_opus}} =
               Agents.get_profile_setting(actor: ctx.admin)

      assert await_status!(&(&1.hold == :released)).profile_id == :claude_cli_opus
      assert {:ok, %{model: "claude-opus-5-5"}} = call()
    end

    test "unconfirmed old work blocks before any stop or start", ctx do
      tree!(ctx, unidentified: :claude_cli_opus)
      await_status!(&(&1.hold == :released))
      old = GenServer.whereis(ClaudeCLI.server())
      assert {:unknown, _} = call()
      assert %{admission: :blocked} = ClaudeCLI.admission()

      assert {:ok, switch} = request(ctx)
      assert %{status: :blocked} = await_switch!(ctx, switch, :blocked)

      assert GenServer.whereis(ClaudeCLI.server()) == old, "never stopped over unconfirmed work"
      assert [%{reason: :boot}] = starts!(ctx), "no candidate was allocated"
    end
  end

  ## Crashes and uncertainty

  describe "crashes and uncertainty" do
    test "a pending switch at a coordinator restart is blocked, and the server held", ctx do
      tree!(ctx)
      await_status!(&(&1.hold == :released))
      pause_at!(:drained)
      assert {:ok, switch} = request(ctx)
      assert_receive {:stage_paused, :drained, _pid}, 20_000

      kill_coordinator!()
      assert %{status: :blocked} = await_switch!(ctx, switch, :blocked)
      assert switch_failure(ctx, switch) =~ "coordinator_restarted"

      status = await_status!(&(&1.hold == :held))
      assert status.hold == :held
      assert {:error, :provider_held} = Runtime.resolve(provider: ClaudeCLI)
    end

    test "a worker death blocks the switch", ctx do
      tree!(ctx)
      await_status!(&(&1.hold == :released))
      pause_at!(:drained)
      assert {:ok, switch} = request(ctx)
      assert_receive {:stage_paused, :drained, worker}, 20_000

      Process.exit(worker, :kill)

      assert %{status: :blocked} = await_switch!(ctx, switch, :blocked)
      assert switch_failure(ctx, switch) =~ "operation_died"
    end

    test "a lost complete reply with an unreadable reconciliation keeps the candidate held",
         ctx do
      {:ok, gate} = Agent.start_link(fn -> :unavailable end)
      tree!(ctx, faults: [lose_reply: [:complete], reconcile: fn -> Agent.get(gate, & &1) end])
      await_status!(&(&1.hold == :released))

      assert {:ok, switch} = request(ctx)
      assert %{status: :completed} = await_switch!(ctx, switch, :completed)
      Process.sleep(300)

      assert %{hold: :held} = status!()
      candidate = GenServer.whereis(ClaudeCLI.server())
      assert {:error, :provider_held} = Runtime.resolve(provider: ClaudeCLI)
      assert {:error, :provider_held} = ClaudeCLI.complete(request_map(), server: candidate)
      assert {:error, :provider_held} = ClaudeCLI.complete(request_map(), [])
      refute_received {:launch_admission, _, _, _}

      Agent.update(gate, fn _ -> :read end)
      await_status!(&(&1.hold == :released), 20_000)
      assert {:ok, %{model: "claude-sonnet-5-5"}} = call()
    end

    test "status never exposes a raw ref and answers while the coordinator is busy", ctx do
      tree!(ctx)
      await_status!(&(&1.hold == :released))
      pause_at!(:finalizing)
      assert {:ok, _switch} = request(ctx)
      assert_receive {:stage_paused, :finalizing, _pid}, 20_000

      started = System.monotonic_time(:millisecond)
      status = status!()
      assert System.monotonic_time(:millisecond) - started < 100
      refute inspect(status) =~ "#Reference<"
    end
  end

  ## The cleanup receipt, consumed by the coordinator (R4)

  describe "the cleanup receipt, as the coordinator validates it" do
    test "a forged ref is ignored, and a reaper DOWN without the receipt blocks", ctx do
      tree!(ctx)
      await_status!(&(&1.hold == :released))
      pause_at!(:old_stopping)
      assert {:ok, switch} = request(ctx)
      assert_receive {:stage_paused, :old_stopping, coordinator}, 20_000

      reaper = ClaudeCLI.reaper(ClaudeCLI.server())
      forged = %{name: ClaudeCLI.server(), tracked: 0}
      send(coordinator, {:reaper_cleanup_confirmed, make_ref(), forged})
      Process.exit(reaper, :kill)
      send(coordinator, :continue)

      assert %{status: :blocked} = await_switch!(ctx, switch, :blocked)
      assert switch_failure(ctx, switch) =~ "old_cleanup_unconfirmed"
      assert [%{reason: :boot}] = starts!(ctx), "no candidate after an unconfirmed cleanup"
    end

    test "a missing lease without the receipt blocks, with no minimum wait", ctx do
      tree!(ctx, cleanup_wait_ms: 600)
      await_status!(&(&1.hold == :released))
      pause_at!(:old_stopping)
      assert {:ok, switch} = request(ctx)
      assert_receive {:stage_paused, :old_stopping, coordinator}, 20_000

      # Withhold the receipt (a suspended reaper), then erase the lease by
      # hand: an absence the reaper didn't certify.
      suspend!(ClaudeCLI.reaper(ClaudeCLI.server()))
      :persistent_term.erase({SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper, ClaudeCLI.server()})

      started = System.monotonic_time(:millisecond)
      send(coordinator, :continue)

      assert %{status: :blocked} = await_switch!(ctx, switch, :blocked)
      elapsed = System.monotonic_time(:millisecond) - started

      assert switch_failure(ctx, switch) =~ "old_cleanup_unconfirmed"
      assert elapsed < 1_100, "blocked within the bound (fail-fast allowed): #{elapsed} ms"
      assert [%{reason: :boot}] = starts!(ctx), "no candidate"
      refute_received {:launch_admission, _, _, _}
      assert %{hold: :held} = status!()
    end

    test "a withheld receipt with a held lease waits one bound; stray refs don't reset it",
         ctx do
      tree!(ctx, cleanup_wait_ms: 600)
      await_status!(&(&1.hold == :released))
      pause_at!(:old_stopping)
      assert {:ok, switch} = request(ctx)
      assert_receive {:stage_paused, :old_stopping, coordinator}, 20_000

      # The lease stays validly held by the live, suspended reaper; only
      # its receipt is withheld.
      reaper = ClaudeCLI.reaper(ClaudeCLI.server())
      suspend!(reaper)

      assert {:held, ^reaper} =
               SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper.lease(ClaudeCLI.server())

      started = System.monotonic_time(:millisecond)
      send(coordinator, :continue)

      stray =
        Task.async(fn ->
          for _ <- 1..8 do
            send(
              coordinator,
              {:reaper_cleanup_confirmed, make_ref(), %{name: ClaudeCLI.server()}}
            )

            Process.sleep(100)
          end
        end)

      assert %{status: :blocked} = await_switch!(ctx, switch, :blocked)
      elapsed = System.monotonic_time(:millisecond) - started
      Task.await(stray, 5_000)

      assert switch_failure(ctx, switch) =~ "old_cleanup_unconfirmed"
      assert elapsed >= 550 and elapsed < 1_100, "one 600 ms bound took #{elapsed} ms"
      assert [%{reason: :boot}] = starts!(ctx)
    end
  end

  ## The suspension fixture (Codex 34dcf0b4 MF1)

  describe "the suspension fixture" do
    test "outlives the test process that asked for it, then resumes and is joined" do
      target = spawn(fn -> receive do: (:stop -> :ok) end)
      parent = self()

      # A stand-in test process asks for the suspension, then dies.
      {asker, ref} = spawn_monitor(fn -> send(parent, {:suspender, start_suspender(target)}) end)
      assert_receive {:suspender, suspender}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^asker, _}, 5_000

      assert Process.info(target, :status) == {:status, :suspended},
             "the suspension survived its asker's death"

      assert :ok = stop_suspender(suspender)
      refute Process.info(target, :status) == {:status, :suspended}
      refute Process.alive?(suspender)
      send(target, :stop)
    end
  end

  ## The switch observation (#235)

  describe "the switch observation (#235)" do
    test "two sandbox queue drops, then the matching row: that row, after exactly three reads" do
      {read, script} = scripted([queue_drop(), queue_drop(), {:ok, [@other_switch, @observed]}])

      outcome =
        try do
          {:returned, await_observed(read, 2_000)}
        rescue
          error -> {:raised, error}
        end

      assert outcome == {:returned, @observed},
             "#235: a sandbox queue drop is transient; got #{inspect(outcome, limit: 4, printable_limit: 120)}"

      assert reads(script) == 3, "#235: no fourth read after the match"
    end

    test "a persistent sandbox queue drop flunks at the deadline, naming it" do
      {read, _script} = scripted([queue_drop()])

      error = assert_raise ExUnit.AssertionError, fn -> await_observed(read, 200) end
      assert error.message =~ "sandbox_queue_drop"
    end

    test "a matching row that arrives after the deadline is not accepted" do
      {read, script} = scripted([{:after, 300, {:ok, [@observed]}}])

      assert_raise ExUnit.AssertionError, fn -> await_observed(read, 100) end
      assert reads(script) == 1
    end

    test "a wrong status and then an absent row stay pending until the matching row" do
      {read, script} =
        scripted([{:ok, [@wrong_status]}, {:ok, [@other_switch]}, {:ok, [@observed]}])

      assert await_observed(read, 2_000) == @observed
      assert reads(script) == 3, "#235: the matching observation is returned, not re-read"
    end

    test "a non-matching answer past the deadline ends the wait with no further read" do
      {read, script} = scripted([{:after, 300, {:ok, []}}, {:ok, [@observed]}])

      error = assert_raise ExUnit.AssertionError, fn -> await_observed(read, 100) end
      assert error.message =~ "never reached failed"

      assert reads(script) == 1,
             "#235: the timeout reports the held observation, with no new read"
    end

    test "a persistent wrong status flunks at the deadline" do
      {read, _script} = scripted([{:ok, [@wrong_status]}])

      error = assert_raise ExUnit.AssertionError, fn -> await_observed(read, 200) end
      assert error.message =~ "never reached failed"
    end

    # Controls: each already fails at once under the old strict match. They
    # pin the refusal boundaries against widening; the first four are the CI
    # drop with exactly one required part changed (`from` must occur in it).
    near_miss = fn from, to ->
      true = String.contains?(@queue_drop, from)
      String.replace(@queue_drop, from, to)
    end

    reason = "connection not available and request was dropped from queue after 255ms"
    prefix = "** (DBConnection.ConnectionError) could not checkout the connection owned by "

    refused = [
      {"the CI drop without the sandbox-owner marker", "dropped from queue",
       {:unknown, near_miss.(" ({:sql_sandbox_owner, %{started_by: #PID<0.1292973.0>}})", "")}},
      {"the CI drop with an owner exit as its reason", "exited",
       {:unknown, near_miss.(reason, "owner #PID<0.1292974.0> exited")}},
      {"the CI drop with a disabled queue as its reason", "queuing is disabled",
       {:unknown, near_miss.(reason, "connection not available and queuing is disabled")}},
      {"the CI drop under a different error prefix", "OwnershipError",
       {:unknown,
        near_miss.(prefix, "** (DBConnection.OwnershipError) cannot find ownership process for ")}},
      {"the CI drop under another Ash wrapper", "Ash.Error.Invalid", :invalid_wrapper},
      {"a Postgrex error", "deadlock_detected",
       {:unknown, "** (Postgrex.Error) ERROR 40P01 (deadlock_detected) deadlock detected"}},
      {"two causes, both the CI drop", "sql_sandbox_owner", :two_drops},
      {"the CI drop as a bare connection error", "DBConnection.ConnectionError", :bare}
    ]

    for {name, token, shape} <- refused do
      test "control: #{name} fails on the first read" do
        {read, script} =
          scripted([refused_read(unquote(Macro.escape(shape))), {:ok, [@observed]}])

        raised =
          try do
            await_observed(read, 2_000)
            :returned
          rescue
            error -> error
          end

        refute raised == :returned, "#{unquote(name)} must not be retried into a match"
        assert Exception.message(raised) =~ unquote(token)
        assert reads(script) == 1
      end
    end
  end

  ## Helpers

  # A dedicated, unlinked suspender owns each suspension (a BEAM suspension
  # is dropped when its suspending process exits), so a failed test can't
  # leave it to an on_exit that doesn't own it. on_exit asks the suspender
  # to resume, joins it, then joins the target's own cleanup.
  defp suspend!(target) do
    suspender = start_suspender(target)

    on_exit(fn ->
      :ok = stop_suspender(suspender)
      join_bounded(target, 10_000)
    end)

    suspender
  end

  defp start_suspender(target) do
    parent = self()

    suspender =
      spawn(fn ->
        true = :erlang.suspend_process(target)
        send(parent, {:suspended, self(), target})

        receive do
          {:resume, from} ->
            try do
              :erlang.resume_process(target)
            after
              send(from, {:resumed, self()})
            end
        end
      end)

    receive do
      {:suspended, ^suspender, ^target} -> suspender
    after
      5_000 -> flunk("the reaper was never suspended")
    end
  end

  defp stop_suspender(suspender) do
    ref = Process.monitor(suspender)
    send(suspender, {:resume, self()})

    receive do
      {:DOWN, ^ref, :process, ^suspender, _} -> :ok
    after
      5_000 -> {:error, :suspender_stuck}
    end
  end

  defp join_bounded(pid, timeout) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      timeout -> Process.demonitor(ref, [:flush])
    end
  end

  defp tree!(ctx, opts \\ []) do
    for module <- [@profile_supervisor, @coordinator] do
      assert Code.ensure_loaded?(module), "C2-02b2α: #{inspect(module)} is not implemented"
    end

    parent = self()
    _ = ctx

    server = fn profile_id ->
      args = if opts[:slow], do: ["env_dump", dump_path(), "1500"], else: ["ready"]

      base = [
        command: System.find_executable("elixir"),
        test_launcher: true,
        launch_admission: LaunchAdmission.recording(parent),
        command_args: [@fake | args]
      ]

      base
      |> then(
        &if(opts[:failing_preflight] == profile_id, do: Keyword.put(&1, :command, nil), else: &1)
      )
      |> then(
        &if(opts[:unidentified] == profile_id,
          do: Keyword.put(&1, :reaper, os_pid: fn _port -> nil end),
          else: &1
        )
      )
    end

    tree_opts = [server: server] ++ Keyword.take(opts, [:faults, :cleanup_wait_ms])
    start_supervised!({@profile_supervisor, tree_opts})
  end

  defp dump_path,
    do: Path.join(System.tmp_dir!(), "sdr-coord-#{System.unique_integer([:positive])}")

  defp status!, do: apply(@coordinator, :status, [])

  defp await_status!(predicate, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_status(predicate, deadline)
  end

  defp await_status(predicate, deadline) do
    status = status!()

    cond do
      is_map(status) and predicate.(status) ->
        status

      System.monotonic_time(:millisecond) > deadline ->
        flunk("coordinator status never matched; last #{inspect(status)}")

      true ->
        Process.sleep(20)
        await_status(predicate, deadline)
    end
  end

  defp request(ctx) do
    apply(@coordinator, :request_switch, [
      %{to_profile_id: :claude_cli_sonnet, expected_revision: 1},
      [actor: ctx.admin]
    ])
  end

  defp await_switch!(ctx, switch, status, timeout \\ 20_000) do
    await_switch_with!(
      fn -> Agents.list_profile_switches(actor: ctx.admin) end,
      switch.id,
      status,
      timeout
    )
  end

  # #235 seam: `await_switch!/4` with the switch read injected, so its
  # observation path is testable without a database.
  defp await_switch_with!(read, id, status, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_switch(read, id, status, deadline)
  end

  defp await_switch(read, id, status, deadline) do
    {:ok, switches} = read.()
    current = Enum.find(switches, &(&1.id == id))

    cond do
      current && current.status == status ->
        current

      System.monotonic_time(:millisecond) > deadline ->
        flunk("switch never reached #{status}; last #{inspect(current && current.status)}")

      true ->
        Process.sleep(20)
        await_switch(read, id, status, deadline)
    end
  end

  defp switch_failure(ctx, switch) do
    {:ok, switches} = Agents.list_profile_switches(actor: ctx.admin)
    Enum.find(switches, &(&1.id == switch.id)).failure_reason || ""
  end

  # #235: the observation tests' scripted reader. Each call counts one read
  # and takes the next response (the last one repeats); `{:after, ms,
  # response}` answers late. The script is supervised by the test.
  defp scripted(responses) do
    script = start_supervised!({Agent, fn -> %{left: responses, reads: 0} end})

    read = fn ->
      script
      |> Agent.get_and_update(fn %{left: left, reads: reads} = state ->
        {next, rest} = take(left)
        {next, %{state | left: rest, reads: reads + 1}}
      end)
      |> answer()
    end

    {read, script}
  end

  defp take([only]), do: {only, [only]}
  defp take([next | rest]), do: {next, rest}

  defp answer({:after, ms, late}) do
    Process.sleep(ms)
    late
  end

  defp answer(response), do: response

  defp reads(script), do: Agent.get(script, & &1.reads)

  defp await_observed(read, timeout),
    do: await_switch_with!(read, @observed.id, @observed.status, timeout)

  defp unknown(causes), do: {:error, %Ash.Error.Unknown{errors: causes}}
  defp queue_drop, do: unknown([%UnknownError{error: @queue_drop}])

  defp refused_read({:unknown, message}), do: unknown([%UnknownError{error: message}])

  defp refused_read(:invalid_wrapper),
    do: {:error, %Ash.Error.Invalid{errors: [%UnknownError{error: @queue_drop}]}}

  defp refused_read(:two_drops),
    do: unknown([%UnknownError{error: @queue_drop}, %UnknownError{error: @queue_drop}])

  defp refused_read(:bare), do: {:error, %DBConnection.ConnectionError{message: @queue_drop}}

  defp starts!(ctx) do
    assert {:ok, starts} = Agents.list_server_starts(actor: ctx.admin)
    starts
  end

  defp kill_coordinator! do
    coordinator = Process.whereis(@coordinator)
    ref = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^ref, :process, ^coordinator, _}, 5_000
  end

  defp pause_at!(stage) do
    id = "c202b2a-pause-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        id,
        @stage,
        fn _event, _measurements, meta, _config ->
          if meta.stage == stage do
            send(parent, {:stage_paused, stage, self()})

            receive do
              :continue -> :ok
            after
              30_000 -> :ok
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp call, do: ClaudeCLI.complete(request_map(), [])

  defp request_map do
    trace = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    span = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    %{
      id: "coordinator-test",
      operation: "model.complete",
      prompt: "qualify",
      schema: @schema,
      witness: %{
        model_invocation_id: Ash.UUIDv7.generate(),
        traceparent: "00-#{trace}-#{span}-01"
      }
    }
  end
end
