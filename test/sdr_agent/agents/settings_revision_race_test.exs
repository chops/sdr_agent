defmodule SdrAgent.Agents.SettingsRevisionRaceTest do
  @moduledoc """
  C4-01a (`docs/product/c4/readiness.md`, section 4 and section 5 tests
  24-28; obligation 5), on independent connections: editors lock the
  current revision `FOR NO KEY UPDATE` and then the chain head; a run
  creator takes the head and then reads the revisions, so it binds exactly
  the revisions whose events precede its own; its snapshot FK
  (`FOR KEY SHARE`) never waits on an editor; concurrent first saves and
  concurrent edits produce exactly one revision, and the loser's stale
  number is read after its rollback.

  Every process uses its own non-sandboxed connection; orderings are
  driven with explicit barriers and lock-wait probes, every wait is
  bounded, and committed rows are removed afterwards with triggers
  disabled, as in `SdrAgent.Agents.ModelProfileSwitchRaceTest`.

  Test 27 is the narrowed form: the two later saves are committed by the
  winner's one held transaction (revisions 1-3), because under the section 4
  protocol the loser's post-rollback read is a plain statement that nothing
  can hold, so two *independent* later commits cannot be placed
  deterministically between its rollback and that read. A loser that maps
  the violation to the conflicting row's number, or to `expected_number + 1`,
  reports 1 and fails.

  Every task is shut down and joined before cleanup (`stop_tasks!/0`
  asserts none is alive), and cleanup asserts that no committed C4 row is
  left.

  RED: the functions do not exist; each test fails on its presence guard
  before any task starts.
  """
  use ExUnit.Case, async: false

  import SdrAgent.SettingsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Repo

  @moduletag :c4_01a

  @tables ~w(run_settings_snapshots settings_revisions audit_accesses audit_events
             audit_chain_heads failures operations model_invocations agent_runs
             agent_definitions tokens users payloads provenance_snapshots tenants)

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    cleanup!()
    on_exit(fn -> with_connection(&cleanup!/0) end)

    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    admins = for _ <- 1..2, do: SdrAgent.AuditCase.new_human(:admin, tenant)

    %{
      tenant: tenant,
      admins: admins,
      agent: struct(SdrAgent.Actor, type: :agent_runtime, tenant_id: tenant.id),
      definition: AgentsFixtures.definition!(tenant)
    }
  end

  defp guard! do
    require_module!(revision_resource())
    require_module!(snapshot_resource())

    assert function_exported?(Agents, :create_settings_revision, 2),
           "C4-01a: SdrAgent.Agents.create_settings_revision/2 is not implemented"
  end

  defp save(admin, text, expected) do
    create_revision(
      %{
        kind: :writing_guide,
        content: %{text: text},
        expected_number: expected,
        note: nil,
        confirm_raised: []
      },
      admin
    )
  end

  defp create_run(ctx) do
    attrs = AgentsFixtures.run_attrs(ctx.definition, usage_origin: :reply)
    Agents.create_run(attrs, actor: ctx.agent)
  end

  # The writing-guide revision a run's snapshot binds (`:no_snapshot` when
  # the run has none), read on the calling process's connection.
  defp bound_guide(_ctx, %{settings_snapshot_id: nil}), do: :no_snapshot

  defp bound_guide(ctx, run) do
    case Ash.get(snapshot_resource(), run.settings_snapshot_id, Kernel.opts(ctx.tenant.id)) do
      {:ok, snapshot} -> snapshot.writing_guide_revision_id
      other -> {:unreadable, other}
    end
  end

  # A failed query aborts the transaction, so it is rolled back with the
  # Postgrex error itself: `{:error, %Postgrex.Error{}}` when the row is locked.
  defp lock_nowait(revision_id, mode) do
    Repo.transaction(fn ->
      case Repo.query(
             "SELECT 1 FROM settings_revisions WHERE id = $1 #{mode} NOWAIT",
             [Ecto.UUID.dump!(revision_id)]
           ) do
        {:ok, result} -> {:ok, result}
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  # From a third connection: which row locks on `revision_id` are free now.
  defp probe_revision_lock(revision_id, mode) do
    task = Task.async(fn -> with_connection(fn -> lock_nowait(revision_id, mode) end) end)

    Process.put(:race_tasks, [task | Process.get(:race_tasks, [])])

    case Task.await(task, 10_000) do
      {:ok, {:ok, _}} -> :free
      {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} -> :locked
      other -> {:probe_failed, other}
    end
  end

  defp guide_numbers(ctx), do: revision_numbers(ctx.tenant.id, :writing_guide)

  # These tests commit rows and truncate them afterwards, so cleanup runs
  # only against a test database (see ModelProfileSwitchRaceTest).
  @doc false
  def truncatable?(database) when is_binary(database),
    do: Regex.match?(~r/\Asdr_agent_test[a-z0-9_]*\z/, database)

  def truncatable?(_database), do: false

  ## Lock probes

  defp await_lock_wait!(pid) do
    waiting =
      Enum.find_value(1..250, fn _ ->
        Process.sleep(20)

        case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [pid]).rows do
          [["Lock"]] -> true
          _ -> nil
        end
      end)

    assert waiting, "backend #{pid} never waited on a lock"
  end

  defp lock_waiting?(pid),
    do:
      Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [pid]).rows ==
        [["Lock"]]

  defp blocked_by?(waiter, holder),
    do: Repo.query!("SELECT pg_blocking_pids($1)", [waiter]).rows == [[[holder]]]

  defp holds_head?(pid) do
    Repo.query!(
      "SELECT count(*) FROM pg_locks l JOIN pg_class c ON c.oid = l.relation " <>
        "WHERE l.pid = $1 AND l.granted AND c.relname = 'audit_chain_heads' " <>
        "AND l.mode IN ('RowShareLock', 'RowExclusiveLock')",
      [pid]
    ).rows != [[0]]
  end

  # The backend has inserted into settings_revisions (RowExclusiveLock held).
  defp inserted_revision?(pid) do
    Repo.query!(
      "SELECT count(*) FROM pg_locks l JOIN pg_class c ON c.oid = l.relation " <>
        "WHERE l.pid = $1 AND l.granted AND c.relname = 'settings_revisions' " <>
        "AND l.mode = 'RowExclusiveLock'",
      [pid]
    ).rows != [[0]]
  end

  ## Tasks

  defp on_own_connection(parent, tag, fun) do
    task =
      Task.async(fn ->
        with_connection(fn ->
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {tag, pid})
          fun.()
        end)
      end)

    Process.put(:race_tasks, [task | Process.get(:race_tasks, [])])
    task
  end

  defp backend!(tag) do
    assert_receive {^tag, pid}, 10_000
    pid
  end

  defp await!(task, label) do
    case Task.yield(task, 15_000) || Task.shutdown(task) do
      {:ok, result} -> result
      other -> flunk("#{label} did not finish (deadlock or hang): #{inspect(other)}")
    end
  end

  defp stop_tasks! do
    tasks = Process.get(:race_tasks, [])
    for task <- tasks, do: Task.shutdown(task, 5_000)
    Process.delete(:race_tasks)
    assert Enum.filter(tasks, &Process.alive?(&1.pid)) == [], "a race task was not joined"
  end

  defp blocking_pids(pid) do
    [[pids]] = Repo.query!("SELECT pg_blocking_pids($1)", [pid]).rows
    pids
  end

  defp hold(message) do
    receive do
      ^message -> :ok
    after
      30_000 -> :timeout
    end
  end

  defp head_holder(parent, ctx) do
    on_own_connection(parent, :holder, fn ->
      Repo.transaction(fn ->
        {:ok, _head} = Kernel.lock_head(ctx.tenant.id)
        send(parent, :head_held)
        hold(:release)
      end)
    end)
  end

  ## Test 24

  for order <- [:editor_first, :creator_first] do
    test "test 24: edit in flight, then a snapshot (#{order} takes the head)", ctx do
      guard!()
      [first_admin, editor_admin] = ctx.admins
      {:ok, guide1} = save(first_admin, "Guide one, synthetic.", 0)
      parent = self()
      holder = head_holder(parent, ctx)

      try do
        assert_receive :head_held, 10_000
        editor_fun = fn -> save(editor_admin, "Guide two, synthetic.", 1) end

        holder_pid = backend!(:holder)
        creator_fun = fn -> create_run(ctx) end

        {first_tag, first_fun, second_tag, second_fun} =
          if unquote(order) == :editor_first,
            do: {:editor, editor_fun, :creator, creator_fun},
            else: {:creator, creator_fun, :editor, editor_fun}

        first = on_own_connection(parent, first_tag, first_fun)
        first_pid = backend!(first_tag)
        await_lock_wait!(first_pid)
        second = on_own_connection(parent, second_tag, second_fun)
        second_pid = backend!(second_tag)
        await_lock_wait!(second_pid)

        # The observed queue on the head row: the first waiter is blocked by
        # the holder only; the second waits behind the first.
        assert blocking_pids(first_pid) == [holder_pid]

        assert first_pid in blocking_pids(second_pid),
               "the second waiter is not queued behind the first"

        editor_pid = if first_tag == :editor, do: first_pid, else: second_pid
        assert inserted_revision?(editor_pid), "the editor waits for the head before inserting"

        {editor, creator} =
          if first_tag == :editor, do: {first, second}, else: {second, first}

        send(holder.pid, :release)
        await!(holder, "head holder")
        assert {:ok, guide2} = await!(editor, "editor")
        assert {:ok, run} = await!(creator, "creator")
        assert guide2.number == 2

        revision_seq = event_sequence(ctx.tenant.id, "settings.revision.created", guide2.id)

        snapshot_seq =
          event_sequence(ctx.tenant.id, "settings.snapshot.created", run.settings_snapshot_id)

        bound = bound_guide(ctx, run)

        if unquote(order) == :editor_first do
          assert {bound, revision_seq < snapshot_seq} == {guide2.id, true}
        else
          assert {bound, snapshot_seq < revision_seq} == {guide1.id, true}
        end
      after
        send(holder.pid, :release)
        stop_tasks!()
      end
    end
  end

  test "test 24: the waiting editor has inserted its successor and holds no head", ctx do
    guard!()
    [first_admin, editor_admin] = ctx.admins
    {:ok, guide1} = save(first_admin, "Guide one, synthetic.", 0)
    parent = self()
    holder = head_holder(parent, ctx)

    try do
      assert_receive :head_held, 10_000
      editor = on_own_connection(parent, :editor, fn -> save(editor_admin, "Guide two.", 1) end)
      editor_pid = backend!(:editor)
      await_lock_wait!(editor_pid)
      assert inserted_revision?(editor_pid), "the editor waits for the head before inserting"

      # It holds the predecessor FOR NO KEY UPDATE: FOR UPDATE conflicts,
      # the snapshot FK's FOR KEY SHARE does not.
      assert probe_revision_lock(guide1.id, "FOR UPDATE") == :locked,
             "the editor does not hold the current revision's row lock"

      assert probe_revision_lock(guide1.id, "FOR KEY SHARE") == :free,
             "the editor's lock blocks a FOR KEY SHARE reader"

      send(holder.pid, :release)
      await!(holder, "head holder")
      assert {:ok, %{number: 2}} = await!(editor, "editor")
    after
      send(holder.pid, :release)
      stop_tasks!()
    end
  end

  ## Test 25

  test "test 25: snapshot first; the creator's FK never waits on the editor", ctx do
    guard!()
    [first_admin, editor_admin] = ctx.admins
    {:ok, guide1} = save(first_admin, "Guide one, synthetic.", 0)
    parent = self()

    creator =
      on_own_connection(parent, :creator, fn ->
        Audit.transaction(fn ->
          {:ok, _head} = Kernel.lock_head(ctx.tenant.id)
          send(parent, :head_held)
          hold(:go)
          result = create_run(ctx)
          # Read on the creator's own connection, inside its transaction.
          bound = with {:ok, run} <- result, do: bound_guide(ctx, run)
          send(parent, {:created, result, bound})
          hold(:commit)
          result
        end)
      end)

    try do
      creator_pid = backend!(:creator)
      assert_receive :head_held, 10_000
      editor = on_own_connection(parent, :editor, fn -> save(editor_admin, "Guide two.", 1) end)
      editor_pid = backend!(:editor)
      await_lock_wait!(editor_pid)
      assert inserted_revision?(editor_pid)

      send(creator.pid, :go)
      assert_receive {:created, {:ok, run}, bound}, 5_000
      refute lock_waiting?(creator_pid), "the creator's FK check waited on the editor"
      assert lock_waiting?(editor_pid), "the editor commits only after the creator"
      assert bound == guide1.id

      send(creator.pid, :commit)
      assert {:ok, {:ok, _run}} = await!(creator, "creator")
      assert {:ok, guide2} = await!(editor, "editor")

      snapshot_seq =
        event_sequence(ctx.tenant.id, "settings.snapshot.created", run.settings_snapshot_id)

      assert snapshot_seq < event_sequence(ctx.tenant.id, "settings.revision.created", guide2.id)
    after
      send(creator.pid, :go)
      send(creator.pid, :commit)
      stop_tasks!()
    end
  end

  ## Test 26

  test "test 26: two first saves leave exactly one revision 1", ctx do
    guard!()
    [winner_admin, loser_admin] = ctx.admins
    parent = self()

    winner =
      on_own_connection(parent, :winner, fn ->
        Audit.transaction(fn ->
          result = save(winner_admin, "Winner guide.", 0)
          send(parent, {:winner_saved, result})
          hold(:finish)
          result
        end)
      end)

    try do
      winner_pid = backend!(:winner)
      assert_receive {:winner_saved, {:ok, %{number: 1}}}, 10_000
      loser = on_own_connection(parent, :loser, fn -> save(loser_admin, "Loser guide.", 0) end)
      loser_pid = backend!(:loser)
      await_lock_wait!(loser_pid)
      assert blocked_by?(loser_pid, winner_pid)

      send(winner.pid, :finish)
      assert {:ok, {:ok, _}} = await!(winner, "winner")
      assert await!(loser, "loser") == {:error, {:stale_revision, 1}}
      assert guide_numbers(ctx) == [1]
    after
      send(winner.pid, :finish)
      stop_tasks!()
    end
  end

  ## Test 27

  test "test 27 (narrowed: later saves in the winner's one held transaction): the loser reports the latest committed number",
       ctx do
    guard!()
    [winner_admin, loser_admin] = ctx.admins
    parent = self()

    winner =
      on_own_connection(parent, :winner, fn ->
        Audit.transaction(fn ->
          results = for n <- 0..2, do: save(winner_admin, "Winner guide #{n}.", n)
          send(parent, {:winner_saved, results})
          hold(:finish)
          results
        end)
      end)

    try do
      winner_pid = backend!(:winner)
      assert_receive {:winner_saved, [{:ok, _}, {:ok, _}, {:ok, %{number: 3}}]}, 10_000
      loser = on_own_connection(parent, :loser, fn -> save(loser_admin, "Loser guide.", 0) end)
      loser_pid = backend!(:loser)
      await_lock_wait!(loser_pid)
      assert blocked_by?(loser_pid, winner_pid)

      send(winner.pid, :finish)
      await!(winner, "winner")
      assert await!(loser, "loser") == {:error, {:stale_revision, 3}}
      assert guide_numbers(ctx) == [1, 2, 3]
    after
      send(winner.pid, :finish)
      stop_tasks!()
    end
  end

  ## Test 28

  test "test 28: two editors of one revision: one succeeds, one is stale", ctx do
    guard!()
    [first_admin, second_admin] = ctx.admins
    {:ok, _guide1} = save(first_admin, "Guide one, synthetic.", 0)
    parent = self()

    first =
      on_own_connection(parent, :first, fn ->
        Audit.transaction(fn ->
          result = save(first_admin, "First edit.", 1)
          send(parent, {:first_saved, result})
          hold(:finish)
          result
        end)
      end)

    try do
      first_pid = backend!(:first)
      assert_receive {:first_saved, {:ok, %{number: 2}}}, 10_000
      second = on_own_connection(parent, :second, fn -> save(second_admin, "Second edit.", 1) end)
      second_pid = backend!(:second)
      await_lock_wait!(second_pid)
      assert blocked_by?(second_pid, first_pid)
      refute holds_head?(second_pid), "an editor waiting on the revision held the chain head"

      refute inserted_revision?(second_pid),
             "the second editor inserted before taking the revision lock"

      send(first.pid, :finish)
      assert {:ok, {:ok, _}} = await!(first, "first editor")
      assert await!(second, "second editor") == {:error, {:stale_revision, 2}}
      assert guide_numbers(ctx) == [1, 2]
    after
      send(first.pid, :finish)
      stop_tasks!()
    end
  end

  ## Connections and cleanup

  defp with_connection(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(Repo)
    end
  end

  defp cleanup! do
    database = Repo.config()[:database]

    unless truncatable?(database) do
      raise "refusing to truncate #{inspect(database)}: not a test database"
    end

    existing =
      Enum.filter(@tables, fn table ->
        Repo.query!("SELECT to_regclass($1) IS NOT NULL", [table]).rows == [[true]]
      end)

    Repo.transaction(fn ->
      Repo.query!("SET LOCAL session_replication_role = replica")
      Repo.query!("TRUNCATE #{Enum.join(existing, ", ")} CASCADE")
    end)

    left =
      for table <- existing,
          Repo.query!("SELECT count(*) FROM #{table}").rows != [[0]],
          do: table

    unless left == [], do: raise("race cleanup left committed rows in #{inspect(left)}")
  end
end
