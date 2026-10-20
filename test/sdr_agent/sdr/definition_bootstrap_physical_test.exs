defmodule SdrAgent.SDR.DefinitionBootstrapPhysicalTest do
  @moduledoc """
  C3-02 RED-2, plan r8 section 11 N [P] (T-N10, T-N11): the definition
  bootstrap on independent physical connections with committed synthetic
  rows (sections 7.2 and 7.3). Kept apart from
  `definition_bootstrap_test.exs` because these tests commit.

  - T-N10: a retained committed tenant gets its definition from
    `DefinitionBootstrap.run/1`; a tenant created after boot (boot saw no
    tenant) gets it from `SDR.bootstrap_definitions/1`; a deadline gives
    `{:error, {:definition_bootstrap_failed, :timeout}}`, then a second run
    converges (idempotent). The test does not assert that nothing
    committed: the kill can race the commit (section 7.3).
  - T-N11: a different-hash winner committed while the bootstrap's INSERT
    waits on the unique index makes the post-violation re-read (outside a
    transaction) return `{:error, :definition_conflict}`.

  Connections: the module runs in sandbox `:auto` mode (the pattern of
  `test/sdr_agent/inbox/count_pool_test.exs:20-21` and
  `agents/profile_switch_resolve_race_test.exs:57-61`), restored to
  `:manual` on exit, because `start_link/1` runs its work in a process it
  spawns (`spawn_monitor`), which a `Sandbox.checkout(Repo, sandbox:
  false)` owner could not share; every process checks out its own physical
  connection.

  Committed-row safety (`InboxConcurrencyFixtures.assert_test_database!/0`
  and the tenant-scoped cleanup pattern of
  `test/support/inbox_concurrency_fixtures.ex:48-81`): every subject is
  guarded and the database name checked before anything commits; the
  database must hold no tenant before the test bootstraps its own, and the
  cleanup deletes only rows whose `tenant_id` is that tenant, then the
  tenant row. Provenance snapshots are global and are not touched.

  Failure-safe cleanup: every task and every observed worker is tracked;
  its termination (kill, then await `:DOWN`) is registered after the
  tenant's cleanup, so it runs first, then the tenant rows are deleted, then
  the sandbox mode is restored.

  RED form: structural (every subject is new); interface names as in
  `SdrAgent.SDR.DefinitionBootstrapTest` (`run/1`, `start_link/1` with
  `deadline_ms:`, `disposition/1`, `bootstrap_definitions/1`,
  `fetch_definition/1`), plus the compile-time test-build option
  `test_barrier: pid` of `start_link/1` (Codex 480e1baf MF6, choice 3
  accepted): the worker, once its work has started and before its first
  database write, monitors `pid` (the barrier owner), sends
  `{:c302_bootstrap_started, worker_pid}` to it and waits for a release
  that never comes; it ends only when the child kills it at the deadline,
  or, on the owner's `:DOWN`, by terminating with no database work after
  it (Codex b3f8d053 R3-1), so it cannot outlive its owner. Absent from
  dev and prod builds.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.Agents.AgentDefinition
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Audit.Kernel, as: AuditKernel
  alias SdrAgent.InboxConcurrencyFixtures
  alias SdrAgent.Repo
  alias SdrAgent.SDR.SDRAgent

  @sdr SdrAgent.SDR
  @bootstrap SdrAgent.SDR.DefinitionBootstrap
  @lookup SdrAgent.SDR.SDRAgent
  @wait_ms 10_000

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> :ok = Sandbox.mode(Repo, :manual) end)
    :ok
  end

  describe "T-N10" do
    test "T-N10 a retained committed tenant gets its committed definition from run/1, once" do
      preflight!()
      tenant = commit_tenant!()
      first = run_bootstrap([])

      assert match?({:ok, [%AgentDefinition{}]}, first),
             "C3-02: run/1 registers for the retained tenant: #{short(first)}"

      {:ok, [definition]} = first
      assert_valid!(definition, tenant.id)
      assert elsewhere(fn -> ids(definitions(tenant.id)) end) == [definition.id]
      assert {:ok, [again]} = run_bootstrap([])
      assert again.id == definition.id
      assert registered_events(tenant.id) == 1, "C3-02: a second run writes nothing"
    end

    test "T-N10 a tenant created after boot gets its committed definition" do
      preflight!()
      assert run_bootstrap([]) == :no_tenant, "C3-02: boot with no tenant"
      assert start_child([]) == :ignore
      tenant = commit_tenant!()
      result = bootstrap_definitions(tenant.id)
      assert match?({:ok, %AgentDefinition{}}, result), "C3-02: got #{short(result)}"
      {:ok, definition} = result
      assert_valid!(definition, tenant.id)
      assert elsewhere(fn -> ids(definitions(tenant.id)) end) == [definition.id]
    end

    # MF6 (Codex 480e1baf): a worker held at a test-build barrier after its
    # work started, a positive bounded deadline, the sanitized :timeout, and
    # the monitored worker gone (killed and its :DOWN awaited by the child)
    # before start_link/1 returns, so before any retry or cleanup. No
    # scheduler race: the worker never proceeds past the barrier.
    #
    # Cleanup (Codex f4ac4874 R2-1, b3f8d053 R3-1): the synchronous
    # start_link/1 runs in a controller under a test-owned Task.Supervisor
    # (start_supervised!/1), not linked to the test, so a caller raise or
    # exit arrives as a value and cannot kill the test before the announced
    # worker is received and its termination registered (track!/1); the
    # test-supervised controller cannot outlive the test. The worker is
    # bound to its barrier owner (this test process) by the barrier
    # contract (moduledoc), so it cannot outlive the test either, even
    # before registration. Every wait is bounded.
    test "T-N10 a blocked worker past a positive deadline is killed; :timeout; then a run converges" do
      preflight!()
      tenant = commit_tenant!()
      parent = self()
      deadline_ms = 300

      controller = start_controller!(deadline_ms: deadline_ms, test_barrier: parent)
      worker = await_announcement!(controller)
      {elapsed_us, result} = await_controller!(controller)

      assert result == {:error, {:definition_bootstrap_failed, :timeout}},
             "C3-02: a blocked worker past the deadline gives the sanitized :timeout class"

      refute Process.alive?(worker), "C3-02: the child kills the worker and awaits its :DOWN"
      assert elapsed_us >= deadline_ms * 1_000, "C3-02: the child waited for the deadline"
      assert elapsed_us < @wait_ms * 1_000, "C3-02: the wait is bounded"

      # Not asserted: that nothing committed (`:timeout` means "not confirmed").
      converged = run_bootstrap([])

      assert match?({:ok, [%AgentDefinition{}]}, converged),
             "C3-02: the next run converges: #{short(converged)}"

      {:ok, [definition]} = converged
      assert_valid!(definition, tenant.id)
      assert registered_events(tenant.id) == 1
    end

    # The barrier contract (Codex b3f8d053 R3-1 (2)): a barrier-held worker
    # monitors its owner and terminates on the owner's :DOWN, with no
    # database work after it. The owner here is a separate process, killed
    # while the child's deadline is still far away, so the deadline is not
    # what ends the worker.
    test "T-N10 a barrier-held worker exits when its barrier owner dies, writing nothing" do
      preflight!()
      tenant = commit_tenant!()
      owner = barrier_owner!()
      deadline_ms = 5_000

      controller = start_controller!(deadline_ms: deadline_ms, test_barrier: owner)
      worker = await_announcement!(controller)
      ref = Process.monitor(worker)
      Process.exit(owner, :kill)

      assert_receive {:DOWN, ^ref, :process, ^worker, _reason},
                     div(deadline_ms, 2),
                     "C3-02: the barrier-held worker must exit on its owner's :DOWN"

      {_elapsed_us, result} = await_controller!(controller)
      refute match?({:ok, _}, result), "C3-02: a worker that exited is not a success"
      assert definitions(tenant.id) == [], "C3-02: no database work after the owner died"
      assert registered_events(tenant.id) == 0

      assert match?({:ok, [%AgentDefinition{}]}, run_bootstrap([])),
             "C3-02: a later run still converges"
    end

    test "T-N10 a deadline is :timeout, then a second run converges" do
      preflight!()
      tenant = commit_tenant!()

      assert start_child(deadline_ms: 0) == {:error, {:definition_bootstrap_failed, :timeout}},
             "C3-02: the deadline gives the sanitized :timeout class"

      # Not asserted: that nothing committed (`:timeout` means "not confirmed").
      converged = run_bootstrap([])

      assert match?({:ok, [%AgentDefinition{}]}, converged),
             "C3-02: the next run converges: #{short(converged)}"

      {:ok, [definition]} = converged
      assert_valid!(definition, tenant.id)
      assert {:ok, [again]} = run_bootstrap([])
      assert again.id == definition.id
      assert elsewhere(fn -> ids(definitions(tenant.id)) end) == [definition.id]
      assert registered_events(tenant.id) == 1
    end
  end

  # G3-2 (Codex 944d822 review): plan r8 section 7.3, "each DB call uses
  # timeout: min(remaining, 5_000)". An owned blocker holds the tenants
  # table ACCESS EXCLUSIVE in an open transaction on its own connection, so
  # the tenant enumeration of run/1 (caller mode, no supervising child)
  # blocks; its client timeout, not the blocker, must end it, well before
  # the default 15 s query timeout and before the blocker would release.
  describe "T-N10 (G3-2) a blocked tenant read" do
    test "T-N10 (G3-2) run/1's blocked tenant enumeration ends at its budget as :timeout" do
      preflight!()
      blocker = table_blocker!("tenants")
      {elapsed_us, result} = :timer.tc(fn -> run_bootstrap(deadline_ms: 1_000) end)

      assert result == {:error, :timeout},
             "C3-02: a blocked tenant read must end at the budget: " <> shape(result)

      assert elapsed_us < 4_000_000,
             "C3-02: the tenant read waited #{div(elapsed_us, 1000)} ms, past its 1 000 ms budget"

      assert Process.alive?(blocker.pid), "C3-02: not established: the blocker released first"
      release!(blocker)
      assert run_bootstrap([]) == :no_tenant
    end
  end

  # G3-2b (Codex 9d5c5c2 review): the client driver's own retry. A read
  # blocked in its prepare phase (`prepare: :unnamed`: every execution
  # parses, and the parse waits on the blocker's lock) that times out on the
  # client is disconnected; when the client's pending receive ends with
  # reason `:closed`, Postgrex marks it retriable and DBConnection checks out
  # another connection with a fresh relative timeout (`checkout_retries`,
  # default 3). One window is one client-timeout disconnect of the caller,
  # logged by its connection.
  #
  # G3-2b RED r2 (coordinator run at abfe524: the control raised
  # Postgrex.Error after 308 ms): the disconnect sends a CancelRequest before
  # it closes the socket, and the blocked backend's answer to it can reach
  # the client first, which ends the call without a retry; which comes
  # first is a race. These reads therefore go through a test-owned pool
  # (`SdrAgent.Repo` as a dynamic repo in the test process) whose
  # connections pass through `SdrAgent.CancelWithholdingProxy`, which drops
  # every CancelRequest: the blocked backend never answers, so every window
  # ends in `:closed`, the retriable path. The proxy's count of withheld
  # cancels equals the windows, one per client-timeout disconnect.
  describe "T-N10 (G3-2b) the driver's checkout retry" do
    test "T-N10 (G3-2b) (control) a blocked unnamed read with a relative timeout opens more than one window" do
      preflight!()
      proxied = proxied_repo!()
      blocker = table_blocker!("tenants")

      {{elapsed_us, raised}, log} =
        with_log(fn ->
          :timer.tc(fn ->
            via_proxy(proxied, fn ->
              try do
                Repo.query!("SELECT count(*) FROM tenants", [], prepare: :unnamed, timeout: 300)
                :returned
              rescue
                error in Postgrex.Error -> {Postgrex.Error, pg_code(error)}
                error -> error.__struct__
              end
            end)
          end)
        end)

      windows = timeout_windows(log, self())

      assert raised == DBConnection.ConnectionError,
             "not established: the read ended with #{inspect(raised)} after " <>
               "#{div(elapsed_us, 1000)} ms (#{windows} window(s))"

      assert windows >= 2,
             "not established: the driver did not retry (#{windows} window(s), #{div(elapsed_us, 1000)} ms)"

      assert withheld(proxied) == windows,
             "not established: #{withheld(proxied)} cancel(s) withheld for #{windows} window(s)"

      assert elapsed_us >= windows * 300 * 1_000
      assert Process.alive?(blocker.pid), "not established: the blocker released first"
      release!(blocker)
    end

    test "T-N10 (G3-2b) run/1's blocked tenant read gets one window that ends at the deadline, no retry" do
      preflight!()
      proxied = proxied_repo!()
      blocker = table_blocker!("tenants")
      hooks = [repo_opts: [prepare: :unnamed]]

      {{elapsed_us, result}, log} =
        with_log(fn ->
          :timer.tc(fn ->
            via_proxy(proxied, fn -> run_bootstrap(deadline_ms: 1_000, test_hooks: hooks) end)
          end)
        end)

      windows = timeout_windows(log, self())

      assert windows == 1,
             "C3-02: the driver opened #{windows} windows against a 1 000 ms deadline " <>
               "(#{div(elapsed_us, 1000)} ms); another window after the budget's deadline"

      assert withheld(proxied) == windows,
             "not established: #{withheld(proxied)} cancel(s) withheld for #{windows} window(s)"

      assert result == {:error, :timeout}, "C3-02: got " <> shape(result)

      assert elapsed_us < 1_500_000,
             "C3-02: the read took #{div(elapsed_us, 1000)} ms against a 1 000 ms deadline"

      assert Process.alive?(blocker.pid), "C3-02: not established: the blocker released first"
      release!(blocker)
    end
  end

  # G3-2b (Codex d47c9d0, addition (a)): the registration transaction's
  # client checkout. The proxied pool has one connection (and a queue
  # target past the test, so the pool never drops the request early); as
  # soon as the tenant read returned (`after_call: :tenant`), a holder
  # process takes that connection and keeps it, so the registration's
  # checkout waits in the queue. That wait must end at the run's one
  # deadline (the bounds observed inside the call are that deadline with
  # no driver retry), with `:timeout`, nothing registered and no event,
  # while the holder still holds; after the holder releases, a run
  # converges.
  describe "T-N10 (G3-2b) the registration's checkout" do
    test "T-N10 (G3-2b) a registration queued for its checkout ends at the deadline; no late success" do
      preflight!()
      tenant = commit_tenant!()
      proxied = proxied_repo!(pool_size: 1, queue_target: 5_000, queue_interval: 5_000)
      parent = self()

      occupy = fn
        :tenant -> send(parent, {:c302_holder, occupy!(proxied)})
        _step -> :ok
      end

      deadline = System.monotonic_time(:millisecond) + 1_000

      {elapsed_us, result} =
        :timer.tc(fn ->
          via_proxy(proxied, fn ->
            run_bootstrap(deadline: deadline, test_hooks: [observer: parent, after_call: occupy])
          end)
        end)

      assert_received {:c302_holder, holder}, "not established: the tenant read did not run"

      assert_received {:c302_bootstrap_bounds, :registration, bounds},
                      "not established: the registration did not start"

      assert Enum.sort(bounds) == [checkout_retries: 0, deadline: deadline],
             "C3-02: the registration's checkout got #{inspect(bounds)}"

      assert result == {:error, :timeout}, "C3-02: got " <> shape(result)

      assert elapsed_us < 1_500_000,
             "C3-02: the registration waited #{div(elapsed_us, 1000)} ms against a 1 000 ms deadline"

      assert Process.alive?(holder.task.pid), "not established: the holder released first"
      assert elsewhere(fn -> definitions(tenant.id) end) == [], "C3-02: a late registration"
      assert registered_events(tenant.id) == 0
      release_holder!(holder)

      assert match?({:ok, [%AgentDefinition{}]}, run_bootstrap([])),
             "C3-02: a later run converges"
    end
  end

  describe "T-N11" do
    test "T-N11 the post-violation re-read rejects a different-hash winner" do
      preflight!()
      tenant = commit_tenant!()
      holder = hold_winner!(tenant)
      loser = Task.async(fn -> bootstrap_definitions(tenant.id) end)
      track!(loser.pid)
      await_waiter!(holder.backend)
      send(holder.task.pid, {holder.tag, :release})
      assert Task.await(holder.task, @wait_ms) == {:ok, holder.winner_id}

      lost = Task.await(loser, @wait_ms)

      assert lost == {:error, :definition_conflict},
             "C3-02: a different-hash winner is rejected after the unique violation: " <>
               shape(lost)

      assert [winner] = definitions(tenant.id)
      assert winner.id == holder.winner_id
      refute winner.definition_sha256 == code_sha()
      assert fetch_definition(tenant.id) == {:error, :agent_definition_unavailable}
      assert registered_events(tenant.id) == 1, "C3-02: the loser appended no event"
    end
  end

  ## Committed rows

  # Guards every subject, then the database, before anything commits.
  defp preflight! do
    present!(@sdr, :bootstrap_definitions, 1)
    present!(@lookup, :fetch_definition, 1)
    present!(@bootstrap, :run, 1)
    present!(@bootstrap, :start_link, 1)
    present!(@bootstrap, :disposition, 1)
    InboxConcurrencyFixtures.assert_test_database!()

    assert match?(%{rows: [[0]]}, Repo.query!("SELECT count(*) FROM tenants")),
           "precondition: the test database holds no committed tenant"
  end

  defp commit_tenant! do
    assert {:ok, tenant} = Audit.bootstrap(slug: "c302-bootstrap", name: "Synthetic C3-02")
    on_exit(fn -> cleanup!(tenant.id) end)
    tenant
  end

  defp cleanup!(tenant_id) do
    InboxConcurrencyFixtures.assert_test_database!()
    raw = Ecto.UUID.dump!(tenant_id)

    assert {:ok, _} =
             Repo.transaction(fn ->
               Repo.query!("SET LOCAL session_replication_role = replica")
               Enum.each(tenant_tables(), &delete_tenant_rows!(&1, raw))

               assert %{num_rows: 1} =
                        Repo.query!("DELETE FROM tenants WHERE id = $1", [raw])
             end)

    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM tenants WHERE id = $1", [raw])
  end

  defp tenant_tables do
    %{rows: rows} =
      Repo.query!("""
      SELECT c.table_name
      FROM information_schema.columns c
      JOIN information_schema.tables t
        ON t.table_schema = c.table_schema AND t.table_name = c.table_name
      WHERE c.table_schema = 'public' AND c.column_name = 'tenant_id'
        AND t.table_type = 'BASE TABLE' AND c.table_name <> 'tenants'
      """)

    List.flatten(rows)
  end

  defp delete_tenant_rows!(table, raw),
    do: Repo.query!(~s(DELETE FROM "#{table}" WHERE tenant_id = $1), [raw])

  # Registers a different-hash SDRAgent row of the code's version inside an
  # open transaction on its own connection, holding the unique index entry.
  defp hold_winner!(tenant) do
    parent = self()
    tag = make_ref()

    task =
      Task.async(fn ->
        Audit.transaction(fn ->
          {:ok, winner} = Agents.register_definition(different(), actor: kernel(tenant))
          send(parent, {tag, :held, backend(), winner.id})
          await_release(tag, winner.id)
        end)
      end)

    track!(task.pid)
    assert_receive {^tag, :held, backend, winner_id}, @wait_ms
    %{task: task, tag: tag, backend: backend, winner_id: winner_id}
  end

  # G3-2: holds `table` ACCESS EXCLUSIVE in an open transaction on its own
  # connection until released (then rolls back), or for at most @wait_ms;
  # it monitors the test process and rolls back on its :DOWN.
  defp table_blocker!(table) do
    parent = self()
    tag = make_ref()

    task =
      Task.async(fn ->
        ref = Process.monitor(parent)

        Repo.transaction(fn ->
          Repo.query!(~s(LOCK TABLE "#{table}" IN ACCESS EXCLUSIVE MODE))
          send(parent, {tag, :held})

          receive do
            {^tag, :release} -> Repo.rollback(:released)
            {:DOWN, ^ref, :process, ^parent, _reason} -> Repo.rollback(:owner_down)
          after
            @wait_ms -> Repo.rollback(:blocker_timeout)
          end
        end)
      end)

    track!(task.pid)
    assert_receive {^tag, :held}, @wait_ms
    %{task: task, pid: task.pid, tag: tag}
  end

  # G3-2b: client-timeout disconnects of `client` in a captured log, one per
  # checkout window ("client #PID<...> timed out because it queued and
  # checked out the connection for longer than <n>ms").
  defp timeout_windows(log, client) do
    pid = String.replace_prefix(inspect(client), "#PID", "")

    ~r/client #PID#{Regex.escape(pid)}[^\n]*timed out because it queued and checked out/
    |> Regex.scan(log)
    |> length()
  end

  # G3-2b RED r2: a test-owned `SdrAgent.Repo` instance (unnamed, a plain
  # connection pool, not the sandbox) whose connections go through a
  # `SdrAgent.CancelWithholdingProxy` in front of the configured server;
  # both are test-supervised (the pool, started second, stops first). Its
  # first query, before any blocker, checks it reaches the same database.
  defp proxied_repo!(pool_opts \\ []) do
    config = Repo.config()
    host = Keyword.get(config, :hostname, "localhost")
    port = Keyword.get(config, :port) || String.to_integer(System.get_env("PGPORT") || "5432")
    proxy = start_supervised!({SdrAgent.CancelWithholdingProxy, upstream: {host, port}})

    repo =
      start_supervised!(
        Supervisor.child_spec(
          {Repo,
           Keyword.merge(
             [
               name: nil,
               pool: DBConnection.ConnectionPool,
               pool_size: 5,
               hostname: "127.0.0.1",
               port: SdrAgent.CancelWithholdingProxy.port(proxy)
             ],
             pool_opts
           )},
          id: :c302_proxied_repo
        )
      )

    %{rows: [[database]]} = Repo.query!("SELECT current_database()")
    proxied = %{repo: repo, proxy: proxy}

    assert via_proxy(proxied, fn -> Repo.query!("SELECT current_database()").rows end) ==
             [[database]],
           "precondition: the proxied pool reaches the test database"

    assert withheld(proxied) == 0
    proxied
  end

  # Runs `fun` with `SdrAgent.Repo` calls of this process on the proxied
  # pool, restoring the previous dynamic repo on every exit path.
  defp via_proxy(%{repo: repo}, fun) do
    previous = Repo.put_dynamic_repo(repo)

    try do
      fun.()
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  # G3-2b: a holder that checks out a connection of the proxied pool and
  # keeps it until released (or for at most @wait_ms); tracked, so it is
  # killed and awaited on any test exit.
  defp occupy!(%{repo: repo}) do
    parent = self()
    tag = make_ref()

    task =
      Task.async(fn ->
        Repo.put_dynamic_repo(repo)

        Repo.checkout(
          fn ->
            send(parent, {tag, :held})

            receive do
              {^tag, :release} -> :released
            after
              @wait_ms -> :holder_timeout
            end
          end,
          timeout: @wait_ms * 2
        )
      end)

    track!(task.pid)
    assert_receive {^tag, :held}, @wait_ms
    %{task: task, tag: tag}
  end

  defp release_holder!(holder) do
    send(holder.task.pid, {holder.tag, :release})
    assert Task.await(holder.task, @wait_ms) == :released
  end

  defp withheld(%{proxy: proxy}), do: SdrAgent.CancelWithholdingProxy.withheld(proxy)

  # The SQLSTATE of a server error, for a failure message (codes only).
  defp pg_code(%Postgrex.Error{postgres: %{code: code}}), do: code
  defp pg_code(_error), do: nil

  defp release!(blocker) do
    send(blocker.pid, {blocker.tag, :release})
    assert {:error, :released} = Task.await(blocker.task, @wait_ms)
  end

  defp await_release(tag, winner_id) do
    receive do
      {^tag, :release} -> winner_id
    after
      @wait_ms -> Repo.rollback(:holder_not_released)
    end
  end

  defp different do
    %{
      name: "SDRAgent",
      version: SDRAgent.version(),
      module: inspect(SDRAgent),
      definition: %{"c302" => "different-hash-winner"}
    }
  end

  defp kernel(tenant), do: Actor.system(:kernel, tenant.id)

  ## Waits

  defp await_waiter!(holder_backend) do
    poll_waiter(holder_backend, System.monotonic_time(:millisecond) + @wait_ms)
  end

  defp poll_waiter(holder_backend, deadline) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT pid FROM pg_stat_activity
        WHERE datname = current_database() AND wait_event_type = 'Lock'
          AND $1 = ANY(pg_blocking_pids(pid))
        """,
        [holder_backend]
      )

    cond do
      rows != [] ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("C3-02: the bootstrap never waited on the winner's uncommitted row")

      true ->
        Process.sleep(20)
        poll_waiter(holder_backend, deadline)
    end
  end

  defp backend do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  defp elsewhere(fun) do
    task = Task.async(fun)
    track!(task.pid)
    Task.await(task, @wait_ms)
  end

  # Failure-safe termination: registered after the tenant's cleanup, so
  # (on_exit runs in reverse order) every contender or worker is killed and
  # its :DOWN awaited before the tenant rows are deleted and before the
  # sandbox mode is restored, even when a barrier assertion fails.
  defp track!(pid) when is_pid(pid) do
    on_exit(fn ->
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        @wait_ms -> flunk("C3-02: a tracked process did not terminate")
      end
    end)
  end

  defp track!(_other), do: :ok

  # The bootstrap caller in a test-supervised, unlinked task: a raise or an
  # exit of start_link/1 is a returned `{:exit, reason}`, never a link
  # signal to the test; the test supervisor stops it when the test ends.
  defp start_controller!(opts) do
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        :timer.tc(fn -> start_child(opts) end)
      end)

    track!(task.pid)
    task
  end

  # Receives and registers the announced worker before the caller's outcome
  # is handled (bounded).
  defp await_announcement!(controller) do
    receive do
      {:c302_bootstrap_started, worker} when is_pid(worker) ->
        track!(worker)
        assert worker not in [self(), controller.pid]
        worker
    after
      @wait_ms -> flunk("C3-02: not established: the worker never reached the test barrier")
    end
  end

  defp await_controller!(controller) do
    case Task.yield(controller, @wait_ms) || Task.shutdown(controller, :brutal_kill) do
      {:ok, value} -> value
      {:exit, reason} -> flunk("C3-02: the bootstrap caller exited: #{short(reason)}")
      nil -> flunk("C3-02: the bootstrap caller did not return within the bound")
    end
  end

  # A barrier owner that is not the test: forwards the worker's announcement
  # to the test and otherwise only waits (bounded) to be killed.
  defp barrier_owner! do
    test = self()

    owner =
      spawn(fn ->
        receive do
          {:c302_bootstrap_started, worker} -> send(test, {:c302_bootstrap_started, worker})
        after
          @wait_ms -> :ok
        end

        Process.sleep(@wait_ms)
      end)

    track!(owner)
    owner
  end

  ## Reads and assertions

  defp definitions(tenant_id) do
    code_version = SDRAgent.version()

    AgentDefinition
    |> Ash.Query.for_read(:read, %{}, AuditKernel.opts(tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^tenant_id and name == "SDRAgent" and version == ^code_version
    )
    |> Ash.read!()
    |> Enum.sort_by(& &1.id)
  end

  defp ids(definitions), do: Enum.map(definitions, & &1.id)

  defp registered_events(tenant_id) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM audit_events
        WHERE tenant_id = $1 AND event_type = 'agents.definition.registered'
        """,
        [Ecto.UUID.dump!(tenant_id)]
      )

    count
  end

  defp assert_valid!(definition, tenant_id) do
    assert {definition.tenant_id, definition.name, definition.version, definition.status} ==
             {tenant_id, "SDRAgent", SDRAgent.version(), :active}

    assert definition.definition_sha256 == code_sha(), "C3-02: the hash of current code"
  end

  defp code_sha, do: Canonical.sha256(SDRAgent.definition_body())

  ## Presence guards and calls

  defp present!(module, function, arity) do
    assert Code.ensure_loaded?(module), "C3-02: #{inspect(module)} is not available"

    assert function_exported?(module, function, arity),
           "C3-02: #{inspect(module)}.#{function}/#{arity} is not implemented"

    module
  end

  defp call(module, function, args) do
    present!(module, function, length(args))
    apply(module, function, args)
  end

  defp bootstrap_definitions(tenant_id), do: call(@sdr, :bootstrap_definitions, [tenant_id])
  defp fetch_definition(tenant_id), do: call(@lookup, :fetch_definition, [tenant_id])
  defp run_bootstrap(opts), do: call(@bootstrap, :run, [opts])

  # start_link/1 links the child to the caller: trap exits around it so a
  # refused start reaches the assertion as a value.
  defp start_child(opts) do
    previous = Process.flag(:trap_exit, true)

    try do
      call(@bootstrap, :start_link, [opts])
    after
      Process.flag(:trap_exit, previous)
      flush_exits()
    end
  end

  defp flush_exits do
    receive do
      {:EXIT, _pid, _reason} -> flush_exits()
    after
      0 -> :ok
    end
  end

  defp short(term), do: inspect(term, limit: 12, printable_limit: 300)

  # A bounded, value-free shape of a bootstrap result (G3 diagnostic): the
  # sanitized class, or the returned struct's module and status only.
  defp shape({:error, class}) when is_atom(class), do: "{:error, #{inspect(class)}}"

  defp shape({:ok, %module{} = row}),
    do: "{:ok, %#{inspect(module)}{status: #{inspect(Map.get(row, :status))}}}"

  defp shape({tag, _other}) when is_atom(tag), do: "{#{inspect(tag)}, <term>}"
  defp shape(_other), do: "<term>"
end
