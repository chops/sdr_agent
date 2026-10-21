defmodule SdrAgent.Outreach.WebhookKeysRaceTest do
  @moduledoc """
  C3-02 RED-3, plan r8 section 11 K [P] (T-K4, T-K5): the webhook identity
  keys of section 6.2 on independent physical connections with committed
  synthetic rows, both commit orders, no 40P01.

  - T-K4: two WebhookEvents (different external ids) carry one Message-ID.
    Processed concurrently, the first passes `{reply-message: Message-ID,
    email: from}`, the second waits on an advisory lock (never on a row or
    a transactionid) and then stops at the stored-reply check: one Reply,
    owned by the first event, the second a duplicate no-op; both events
    `processed`. Both orders, plus a variant with another sender, where the
    shared `reply-message` key alone is what the second waits on.
  - T-K5: after `:change_email`, a bounce of the old address (the stored
    recipient of the delivery) and a manual suppression of the old address
    (section 6.2 "O11 inventory correction"; deadlock-prone on main: INSERT
    then head vs head then INSERT on `suppressions_unique_value_index`).
    Both take the value key `{email: stored recipient}` before their row
    locks; the second waits on an advisory lock; one suppression, the
    first writer's; both orders.

  Data: the committed demo tenant built exactly as
  `test/sdr_agent/outreach/webhook_race_test.exs` builds it
  (`Demo.Seed.run/0` with the Clock frozen one day after the demo epoch,
  `SettingsFixtures.save_offering!/1`, lead "01" assigned, worked by
  `AgentWorker.run/2`, approved and delivered through main's APIs), but
  with the C3-02 RED-3 [P] harness instead of a TRUNCATE: the module runs
  in sandbox `:auto` mode, `preflight!/0` checks the guards, the database
  name and that no tenant exists before anything commits, and registers the
  tenant-scoped cleanup. The Clock freeze is process-local (the test
  process's dictionary; contenders read it through `$callers`), so it ends
  with the test process.

  RED form: structural. `preflight!/0` guards
  `IdentityKeys.TestFaults.park_after_pass/2` (the shared RED-3 parking
  seam) and `IdentityKeys.id/3` before anything commits, so on main every
  test fails at a C3-02 presence guard.

  Evidence per schedule (no production seam beyond the shared one):
    * the parked writer: its published ids equal the expected keys
      (`IdentityKeys.id/3`), are physically held (`advisory_ids/1`), equal
      the pass record read inside its transaction (`probe!/2`), and it
      holds no row-level lock on a domain relation yet (`relation_locks/1`);
    * the waiter: blocked by the parked writer on `"advisory"`, its one
      ungranted advisory lock is the expected key, and its statement trace
      shows no chain-head statement and no Reply/Suppression INSERT before
      the wait.

  Interface names chosen here for review:
    * the key kinds `:"reply-message"` (raw Message-ID) and `:email` (raw
      `from`, or the delivery's stored recipient), RED-1/RED-2;
    * the waiter's key is read as its single ungranted advisory lock in
      `pg_locks` (`waiting_key/1`, signed classid/objid as the harness);
      with two shared keys, ascending acquisition makes it the smaller id;
    * the domain relations checked at the park point
      (`@domain_relations`) and the row-level modes (`@row_modes`).
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 300_000

  import SdrAgent.WebhookFixtures, only: [outcome_body: 2, reply_body: 3, signed_headers: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Accounts
  alias SdrAgent.Actor
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Audit
  alias SdrAgent.AuditCase
  alias SdrAgent.Clock
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.InboxConcurrencyFixtures
  alias SdrAgent.Operations.WebhookEvent
  alias SdrAgent.Outreach
  alias SdrAgent.Outreach.Delivery
  alias SdrAgent.Outreach.Webhooks
  alias SdrAgent.OutreachFixtures
  alias SdrAgent.Repo
  alias SdrAgent.Sales
  alias SdrAgent.SalesFixtures
  alias SdrAgent.SDR
  alias SdrAgent.SDR.AgentWorker
  alias SdrAgent.SettingsFixtures
  alias SdrAgent.WebhookFixtures

  require Ash.Query

  @keys SdrAgent.Audit.IdentityKeys
  @guards [
    {SdrAgent.Audit.IdentityKeys.TestFaults, :park_after_pass, 2},
    {SdrAgent.Audit.IdentityKeys, :id, 3}
  ]

  # Domain relations no writer may hold a row-level lock on before its pass
  # (section 2.6; the WebhookEvent row is outside the domain).
  @domain_relations ~w(audit_chain_heads suppressions replies leads campaign_enrollments
                       drafts delivery_operations approvals contacts accounts)
  @row_modes ~w(RowShareLock RowExclusiveLock ShareUpdateExclusiveLock ShareLock
                ShareRowExclusiveLock ExclusiveLock AccessExclusiveLock)

  @record_format ~r/^v1;[0-9a-f]{32};\d+;(-?\d+(,-?\d+)*)?$/

  describe "T-K4 duplicate Message-ID across two events, processed concurrently" do
    test "T-K4 E1 parked after its pass, E2 waits on advisory: one Reply (E1's), E2 a duplicate no-op" do
      preflight!()
      ctx = demo!()
      op = delivered!(ctx)
      message_id = message_id()
      e1 = reply_event!(op, message_id)
      e2 = reply_event!(op, message_id)

      duplicate_race!(ctx, e1, e2, reply_keys(ctx, e1))
    end

    test "T-K4 the other order: E2 parked after its pass, E1 waits on advisory: one Reply (E2's)" do
      preflight!()
      ctx = demo!()
      op = delivered!(ctx)
      message_id = message_id()
      e1 = reply_event!(op, message_id)
      e2 = reply_event!(op, message_id)

      duplicate_race!(ctx, e2, e1, reply_keys(ctx, e2))
    end

    # The second event names another sender, so the reply-message key is the
    # only key the two passes share: the waiter's ungranted lock is exactly it.
    test "T-K4 another sender, same Message-ID: the second waits on the reply-message key itself" do
      preflight!()
      ctx = demo!()
      op = delivered!(ctx)
      message_id = message_id()
      matched = reply_event!(op, message_id)
      stranger = "c302-stranger-#{SalesFixtures.unique()}@unknown.example.test"

      other =
        reply_event!(op, message_id,
          from: stranger,
          in_reply_to: "<nothing@elsewhere.example.test>"
        )

      shared = MapSet.new([key_id(ctx, :"reply-message", message_id)])
      duplicate_race!(ctx, matched, other, shared)
    end

    # C3-02 G6 (plan r8 sections 16.4, 16.13 R-W6; Codex G6-R1): the second
    # event carries the same Message-ID padded with spaces, which
    # `Reply.message_id` stores trimmed, from another sender: it waits on the
    # represented value's reply-message key, then is a duplicate no-op.
    test "T-K4 (G6) a padded Message-ID from another sender waits on the represented reply-message key" do
      preflight!()
      ctx = demo!()
      op = delivered!(ctx)
      message_id = message_id()
      matched = reply_event!(op, message_id)
      stranger = "c302-stranger-#{SalesFixtures.unique()}@unknown.example.test"

      padded =
        reply_event!(op, " " <> message_id <> " ",
          from: stranger,
          in_reply_to: "<nothing@elsewhere.example.test>"
        )

      shared = MapSet.new([key_id(ctx, :"reply-message", message_id)])
      duplicate_race!(ctx, matched, padded, shared)
    end
  end

  describe "T-K5 old-address bounce vs manual suppression after :change_email" do
    test "T-K5 bounce first: the manual suppression waits on the value key; one hard_bounce suppression, no 40P01" do
      preflight!()
      ctx = demo!()
      moved = moved!(ctx)
      sup = supervisor!()

      first = parked!(sup, fn -> bounce(ctx, moved) end)
      assert_parked!(first, MapSet.new([key_id(ctx, :email, moved.old)]))

      second = contender!(sup, fn -> suppress_old(ctx, moved) end)
      assert_waits_on!(second, first, key_id(ctx, :email, moved.old))

      resume!(first)
      bounced = await_result!(first.task)
      suppressed = await_result!(second)
      refute_deadlock!([bounced, suppressed])

      assert bounced == :ok
      assert match?({:ok, _}, suppressed), "C3-02: the manual suppression returns the stored row"
      {:ok, returned} = suppressed
      stored = assert_one_suppression!(ctx, moved, :hard_bounce)
      assert returned.id == stored.id
      assert_bounced!(ctx, moved)
    end

    test "T-K5 manual suppression first: the bounce waits on the value key; one manual suppression, no 40P01" do
      preflight!()
      ctx = demo!()
      moved = moved!(ctx)
      sup = supervisor!()

      first = parked!(sup, fn -> suppress_old(ctx, moved) end)
      assert_parked!(first, MapSet.new([key_id(ctx, :email, moved.old)]))

      second = contender!(sup, fn -> bounce(ctx, moved) end)
      assert_waits_on!(second, first, key_id(ctx, :email, moved.old))

      resume!(first)
      suppressed = await_result!(first.task)
      bounced = await_result!(second)
      refute_deadlock!([suppressed, bounced])

      assert match?({:ok, _}, suppressed), "C3-02: the manual suppression commits"
      {:ok, created} = suppressed
      assert bounced == :ok
      stored = assert_one_suppression!(ctx, moved, :manual)
      assert created.id == stored.id
      assert_bounced!(ctx, moved)
    end
  end

  # ---------------------------------------------------------------------
  # C3-02 RED-3 [P] harness (copy verbatim into each RED-3 file; adapt only
  # the module attributes marked ADAPT). It is the RED-2 r4 pattern Codex
  # approved (definition_bootstrap_physical_test.exs), generalised:
  #
  #   * the module runs in sandbox :auto mode (restored to :manual on exit);
  #     every process owns its own physical connection for its lifetime;
  #   * every contender runs under a test-owned Task.Supervisor with
  #     Task.Supervisor.async_nolink/2: never linked to the test, so a raise
  #     or exit is a returned {:exit, reason}; the test supervisor stops it
  #     when the test ends;
  #   * every contender's termination (kill, then await :DOWN, bounded) is
  #     registered with on_exit as soon as it is spawned, before the test
  #     waits on it; on_exit runs in reverse registration order, so all
  #     contenders die before the tenant cleanup (registered earlier) and
  #     before the sandbox mode restore (registered first);
  #   * every holder and every parked writer monitors the test process and
  #     rolls back (no further database work) on its :DOWN, so none can
  #     outlive the test even before its tracker is registered;
  #   * every wait is bounded (@wait_ms); polling a catalog condition is a
  #     bounded check, never a sleep used as synchronization.
  # ---------------------------------------------------------------------

  # ADAPT: the subjects this file guards before anything commits.
  # @guards [{SdrAgent.SDR, :admit_lead, 2}, ...]

  @wait_ms 10_000
  @faults SdrAgent.Audit.IdentityKeys.TestFaults

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> :ok = Sandbox.mode(Repo, :manual) end)

    handler = "c3-02-red3-trace-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(handler, [:sdr_agent, :repo, :query], &__MODULE__.forward_query/4, nil)

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  @doc false
  # Runs in the process that sent the statement: a contender opts in with
  # Process.put(:c302_trace_to, owner); every other process is ignored.
  def forward_query(_event, _measurements, metadata, _config) do
    case Process.get(:c302_trace_to) do
      owner when is_pid(owner) ->
        send(owner, {:c302_sql, self(), IO.iodata_to_binary(metadata.query)})

      _none ->
        :ok
    end
  end

  ## Preflight and committed-row safety

  # Guards every subject, then the database, then registers the cleanup,
  # all before anything commits. The partition must hold no tenant, so
  # every tenant present at exit (Audit.bootstrap, Demo.Seed) is this
  # test's and is removed, with the Oban jobs inserted after the watermark.
  defp preflight! do
    for {module, function, arity} <- @guards, do: present!(module, function, arity)
    InboxConcurrencyFixtures.assert_test_database!()

    assert match?(%{rows: [[0]]}, Repo.query!("SELECT count(*) FROM tenants")),
           "precondition: the test database holds no committed tenant"

    %{rows: [[watermark]]} = Repo.query!("SELECT coalesce(max(id), 0) FROM oban_jobs")
    on_exit(fn -> cleanup!(watermark) end)
    :ok
  end

  defp cleanup!(watermark) do
    InboxConcurrencyFixtures.assert_test_database!()
    %{rows: rows} = Repo.query!("SELECT id FROM tenants")
    tables = tenant_tables()

    assert {:ok, _} =
             Repo.transaction(fn ->
               Repo.query!("SET LOCAL session_replication_role = replica")

               for [raw] <- rows do
                 Enum.each(tables, &delete_tenant_rows!(&1, raw))
                 Repo.query!("DELETE FROM tenants WHERE id = $1", [raw])
               end

               Repo.query!("DELETE FROM oban_jobs WHERE id > $1", [watermark])
             end)

    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM tenants")
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

  ## Contenders (unlinked, supervised, tracked)

  defp supervisor! do
    start_supervised!(Supervisor.child_spec(Task.Supervisor, id: make_ref()))
  end

  # Runs `fun` in its own process and connection; the process reports its
  # backend first. Its termination is registered before the caller waits.
  defp contender!(supervisor, fun) do
    owner = self()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)
        Process.put(:c302_trace_to, owner)
        send(owner, {:c302_backend, self(), backend()})
        fun.()
      end)

    track!(task.pid)
    receive_backend!(task)
    task
  end

  defp receive_backend!(task) do
    pid = task.pid

    receive do
      {:c302_backend, ^pid, backend} ->
        Process.put({:c302_backend, pid}, backend)
        backend
    after
      @wait_ms -> flunk("C3-02: a contender never reported its backend")
    end
  end

  defp backend_of(task), do: Process.get({:c302_backend, task.pid})

  defp await_result!(task) do
    case Task.yield(task, @wait_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, value} -> value
      {:exit, reason} -> flunk("C3-02: a contender exited: #{short(reason)}")
      nil -> flunk("C3-02: a contender did not return within the bound (hang)")
    end
  end

  # Kill, then await :DOWN (bounded), at test exit; a kill cannot be trapped.
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

  ## Row-lock holders (owner-bound)

  # Holds `lock` (a function running SQL in the holder's transaction) until
  # release!/1; rolls back if the test process dies first.
  defp holder!(supervisor, lock) do
    owner = self()
    tag = make_ref()

    task =
      contender!(supervisor, fn ->
        down = Process.monitor(owner)

        Repo.transaction(fn ->
          lock.()
          send(owner, {tag, :held})

          receive do
            {^tag, :release} -> :released
            {:DOWN, ^down, :process, _pid, _reason} -> Repo.rollback(:owner_down)
          end
        end)
      end)

    receive do
      {^tag, :held} -> :ok
    after
      @wait_ms -> flunk("C3-02: a holder never took its lock")
    end

    %{task: task, tag: tag, backend: backend_of(task)}
  end

  defp release!(holder) do
    send(holder.task.pid, {holder.tag, :release})
    assert await_result!(holder.task) == {:ok, :released}
  end

  ## Writers parked right after their identity pass (test-build seam)

  # ADAPT (open choice, shared by every RED-3 file): the compile-time
  # test-build seam `IdentityKeys.TestFaults.park_after_pass(owner, fun)`.
  # While `fun` runs in the calling process, the first identity pass that
  # publishes its record, right after the publication (keys held, inside
  # the pass's transaction), sends `{:c302_parked, self(), ids}` to `owner`
  # and waits for `{:c302_resume}`; meanwhile it answers
  # `{:c302_probe, from, ref, probe}` by running `probe.()` in-process
  # (inside that transaction) and sending `{ref, result}` to `from`. It
  # monitors `owner` and, on its :DOWN, raises (the transaction rolls back,
  # no further database work). It never changes a decision. Absent from dev
  # and prod builds.
  defp parked!(supervisor, run) do
    owner = self()
    task = contender!(supervisor, fn -> call(@faults, :park_after_pass, [owner, run]) end)
    pid = task.pid

    receive do
      {:c302_parked, ^pid, ids} -> %{task: task, pid: pid, backend: backend_of(task), ids: ids}
    after
      @wait_ms -> flunk("C3-02: not established: the writer never parked after its pass")
    end
  end

  defp probe!(parked, probe) do
    ref = make_ref()
    send(parked.pid, {:c302_probe, self(), ref, probe})

    receive do
      {^ref, result} -> result
    after
      @wait_ms -> flunk("C3-02: the parked writer did not answer a probe")
    end
  end

  defp resume!(parked), do: send(parked.pid, {:c302_resume})

  ## Wait evidence (pg_stat_activity / pg_locks)

  # Bounded: until `waiter` is blocked by `holder` on a lock; returns its
  # wait event (`"advisory"`, `"tuple"`, `"transactionid"`, ...).
  defp await_blocked!(waiter, holder) do
    deadline = System.monotonic_time(:millisecond) + @wait_ms
    poll_blocked(waiter, holder, deadline)
  end

  defp poll_blocked(waiter, holder, deadline) do
    %{rows: [[type, event, blockers]]} =
      Repo.query!(
        "SELECT wait_event_type, wait_event, pg_blocking_pids(pid) " <>
          "FROM pg_stat_activity WHERE pid = $1",
        [waiter]
      )

    cond do
      type == "Lock" and holder in blockers ->
        event

      System.monotonic_time(:millisecond) > deadline ->
        flunk("C3-02: #{waiter} never waited on #{holder} (#{inspect({type, event})})")

      true ->
        Process.sleep(20)
        poll_blocked(waiter, holder, deadline)
    end
  end

  # The granted advisory ExclusiveLock ids of `backend` (signed, classid
  # high and objid low, objsubid 1): physical ownership, independent of any
  # published record.
  defp advisory_ids(backend) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT (classid::bigint << 32) | objid::bigint FROM pg_locks
        WHERE locktype = 'advisory' AND pid = $1 AND objsubid = 1
          AND mode = 'ExclusiveLock' AND granted
        """,
        [backend]
      )

    rows |> List.flatten() |> MapSet.new()
  end

  defp relation_locks(backend) do
    %{rows: rows} =
      Repo.query!(
        "SELECT c.relname, l.mode FROM pg_locks l JOIN pg_class c ON c.oid = l.relation " <>
          "WHERE l.pid = $1 AND l.granted",
        [backend]
      )

    rows
  end

  ## Statement traces of contenders

  # Every statement `pid` sent so far, in order (non-blocking drain of this
  # pid's forwarded statements; others stay in the mailbox).
  defp statements(pid), do: drain_statements(pid, [])

  defp drain_statements(pid, acc) do
    receive do
      {:c302_sql, ^pid, sql} -> drain_statements(pid, [sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp first_index(statements, pattern), do: Enum.find_index(statements, &(&1 =~ pattern))

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

  defp backend do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  defp short(term), do: inspect(term, limit: 12, printable_limit: 300)

  ## T-K4 schedule and outcome

  # `first` parks after its pass; `second` (same Message-ID) must wait on
  # the smallest key of `shared` (ascending acquisition), an advisory lock
  # held by `first`; after the resume, `first` stores the one Reply and
  # `second` is a processed duplicate that wrote nothing.
  defp duplicate_race!(ctx, first, second, shared) do
    sup = supervisor!()
    parked = parked!(sup, fn -> process(ctx, first) end)
    assert_parked!(parked, reply_keys(ctx, first))

    waiter = contender!(sup, fn -> process(ctx, second) end)
    assert_waits_on!(waiter, parked, Enum.min(shared))

    resume!(parked)
    results = [await_result!(parked.task), await_result!(waiter)]
    refute_deadlock!(results)
    assert results == [:ok, :ok], "C3-02: both events process: #{short(results)}"

    assert [stored] = WebhookFixtures.replies!(ctx)
    assert {stored.webhook_event_id, stored.message_id} == {first.event.id, first.message_id}
    assert stored.match_status == :matched

    for reply <- [first, second] do
      assert webhook!(ctx, reply.event).processing_status == :processed
    end

    assert length(AuditCase.events_of_type(ctx.tenant, "outreach.reply.received")) == 1
    assert [_run] = reply_runs(ctx, first.event)
    assert reply_runs(ctx, second.event) == [], "C3-02: the duplicate hands nothing off"
  end

  defp reply_keys(ctx, reply),
    do:
      MapSet.new([
        key_id(ctx, :"reply-message", reply.message_id),
        key_id(ctx, :email, reply.from)
      ])

  defp message_id, do: "<c302-dup-#{SalesFixtures.unique()}@prospect.example.test>"

  ## Shared wait evidence

  # At the park point: the published ids are the expected keys, physically
  # held, equal to the pass record inside the writer's transaction, and no
  # domain relation is row-locked yet (the keys come before every row lock).
  defp assert_parked!(parked, expected) do
    assert MapSet.new(parked.ids) == expected, "C3-02: the pass published other keys"

    assert MapSet.subset?(expected, advisory_ids(parked.backend)),
           "C3-02: a published key is not held by the parked backend"

    # The probe only reads; the record is checked here, in the test process.
    assert parked |> probe!(&pass_setting/0) |> record_ids() == expected

    locked =
      for [relation, mode] <- relation_locks(parked.backend),
          relation in @domain_relations and mode in @row_modes,
          do: {relation, mode}

    assert locked == [], "C3-02: a domain row lock precedes the pass: #{short(locked)}"
  end

  # The waiter is blocked by the parked writer on an advisory lock, its one
  # ungranted advisory lock is `key`, and it sent no chain-head statement and
  # no Reply or Suppression INSERT before the wait.
  defp assert_waits_on!(waiter, parked, key) do
    backend = backend_of(waiter)

    assert await_blocked!(backend, parked.backend) == "advisory",
           "C3-02: the second writer must wait on an advisory key, not a row or transactionid"

    assert waiting_key(backend) == key, "C3-02: the second writer waits on another key"
    sent = statements(waiter.pid)
    assert first_index(sent, ~r/audit_chain_heads/) == nil, "C3-02: the head before the key"

    assert first_index(sent, ~r/INSERT INTO "(replies|suppressions)"/) == nil,
           "C3-02: an INSERT before the key"
  end

  defp waiting_key(backend) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT (classid::bigint << 32) | objid::bigint FROM pg_locks
        WHERE locktype = 'advisory' AND pid = $1 AND objsubid = 1 AND NOT granted
        """,
        [backend]
      )

    assert [[key]] = rows
    key
  end

  defp pass_setting do
    %{rows: [[value]]} = Repo.query!("SELECT current_setting('sdr.identity_pass', true)")
    value
  end

  defp record_ids(value) do
    assert is_binary(value) and value =~ @record_format, "C3-02: no v1 pass record"
    [_version, _token, _pid, ids] = String.split(value, ";")
    if ids == "", do: MapSet.new(), else: MapSet.new(String.split(ids, ","), &String.to_integer/1)
  end

  defp refute_deadlock!(results) do
    for result <- results do
      refute inspect(result) =~ ~r/deadlock|40P01/, "C3-02: 40P01: #{short(result)}"
    end
  end

  defp key_id(ctx, kind, raw), do: call(@keys, :id, [ctx.tenant_id, kind, raw])

  ## T-K5 fixtures and outcome

  # Lead "01" delivered, then its contact moved to a new address
  # (`:change_email`, committed): the delivery's stored recipient is the
  # old address; the bounce event for that delivery is ingested.
  defp moved!(ctx) do
    op = delivered!(ctx)
    {:ok, lead} = Sales.fetch(Sales.Lead, Enum.at(Fixtures.leads(), 0).id, actor: ctx.admin)
    contact = OutreachFixtures.contact!(ctx, lead)
    old = String.downcase(to_string(op.recipient_email))
    assert String.downcase(to_string(contact.email)) == old
    new = "c302-moved-#{SalesFixtures.unique()}@example.test"

    assert {:ok, moved} = Sales.update(contact, :change_email, %{email: new}, actor: ctx.admin)
    assert to_string(moved.email) == new

    body = outcome_body("bounce", op)
    assert {:ok, %{status: :accepted, event: event}} = WebhookFixtures.ingest!("bounce", body)
    %{delivery: op, old: old, new: new, event: event, body: body}
  end

  defp bounce(ctx, moved), do: Webhooks.process(moved.event.id, ctx.tenant_id, moved.body)

  defp suppress_old(ctx, moved),
    do: Outreach.suppress(%{scope: :email, value: moved.old}, actor: ctx.admin)

  defp assert_one_suppression!(ctx, moved, reason) do
    assert [stored] =
             Enum.filter(WebhookFixtures.suppressions!(ctx), &(to_string(&1.value) == moved.old))

    assert {stored.scope, stored.reason} == {:email, reason},
           "C3-02: the first writer's suppression stands"

    created =
      for e <- AuditCase.events_of_type(ctx.tenant, "outreach.suppression.created"),
          e.subject_id == stored.id,
          do: e

    assert [_one] = created
    stored
  end

  defp assert_bounced!(ctx, moved) do
    assert OutreachFixtures.outreach!(ctx, moved.delivery).state == :bounced
    assert webhook!(ctx, moved.event).processing_status == :processed
  end

  ## Committed demo data (as webhook_race_test.exs, without the TRUNCATE)

  defp demo! do
    Clock.freeze(DateTime.add(Fixtures.epoch(), 1, :day))
    assert {:ok, _} = SdrAgent.Demo.Seed.run()
    {:ok, tenant_id} = Audit.Kernel.singleton_tenant_id()
    seeder = Actor.system(:seeder, tenant_id, "race")
    {:ok, admin} = Accounts.get_user(hd(Fixtures.users()).id, actor: seeder)
    # C4-R8: assignments need a saved offering profile (synthetic fixture).
    SettingsFixtures.save_offering!(admin)

    %{
      tenant_id: tenant_id,
      tenant: %{id: tenant_id},
      admin: admin,
      agent: Actor.system(:agent_runtime, tenant_id)
    }
  end

  # Lead "01" worked by the agent, approved by the admin, delivered. In
  # :auto mode the agent's flow steps check out their own connections.
  defp delivered!(ctx) do
    {:ok, lead} = Sales.fetch(Sales.Lead, Enum.at(Fixtures.leads(), 0).id, actor: ctx.admin)

    {:ok, %{job: job}} =
      SDR.assign_lead(lead, campaign_id: Fixtures.campaign().id, actor: ctx.admin)

    :ok = AgentWorker.run(job, model: [])

    {:ok, [draft]} =
      Outreach.list_records(Outreach.Draft, filter: [lead_id: lead.id], actor: ctx.admin)

    revision = OutreachFixtures.revision!(ctx, draft.current_revision_id)

    {:ok, approval} =
      Outreach.approve(draft, OutreachFixtures.approval_input(revision), actor: ctx.admin)

    op = OutreachFixtures.delivery_of!(ctx, approval)
    :ok = Delivery.attempt(op.id, ctx.tenant_id)
    OutreachFixtures.outreach!(ctx, op)
  end

  # A signed reply event to `delivery` carrying `message_id`, ingested;
  # options `:from` and `:in_reply_to` as `reply_body/3`.
  defp reply_event!(delivery, message_id, opts \\ []) do
    id = "evt_c302_" <> Ecto.UUID.generate()

    decoded =
      delivery
      |> reply_body("Interested!", Keyword.put(opts, :id, id))
      |> Jason.decode!()
      |> put_in(["data", "message_id"], message_id)

    body = Jason.encode!(decoded)

    assert {:ok, %{status: :accepted, event: event}} =
             Webhooks.ingest("reply", body, Map.new(signed_headers(body)))

    %{event: event, body: body, message_id: message_id, from: decoded["data"]["from"]}
  end

  defp process(ctx, reply), do: Webhooks.process(reply.event.id, ctx.tenant_id, reply.body)

  defp webhook!(ctx, event) do
    {:ok, event} = Ash.get(WebhookEvent, event.id, actor: ctx.admin)
    event
  end

  defp reply_runs(ctx, event) do
    AgentRun
    |> Ash.Query.filter(tenant_id == ^ctx.tenant_id and correlation_id == ^event.id)
    |> Ash.read!(Audit.Kernel.opts(ctx.tenant_id))
  end

  # The harness's row-lock holders (holder!/2, release!/1) are not used
  # here: T-K4 and T-K5 schedule through the parking seam. This reference
  # keeps the verbatim harness warning-free (Elixir 1.20 ignores `@compile
  # {:nowarn_unused_function, ...}` for `defp`); it is never called.
  @doc false
  def __unused_harness__, do: [&holder!/2, &release!/1]
end
