defmodule SdrAgent.Outreach.WebhookHandoffRaceTest do
  @moduledoc """
  C3-02 RED-3, plan r8 section 11 K (Q-O5) [P] (T-K7p) and section 11 I
  [P] (T-I13): the reply hand-off deferral of section 6.7 and the
  bootstrap-vs-reply race of section 7.4, on independent physical
  connections with committed synthetic rows.

  - T-K7p: T-K7 (`webhook_handoff_test.exs`) on its own connection: a
    matched unsubscribe-bearing reply whose `SDRAgent` definition is
    missing, `WebhookWorker.perform/1` attempt 1 of 3 in a contender,
    returns `{:error, :agent_definition_unavailable}`; afterwards a second
    connection (the test process) sees the Reply, the `unsubscribe_reply`
    Suppression and the stopped lead at once (committed, not merely
    released inside a savepoint), the event still `received`, no hand-off,
    and the contender's backend holds no lock of any kind.
  - T-I13 (listed under section 11 I, `admission_race_test.exs`, but placed
    here because it needs the matched-reply demo data this file builds):
    bootstrap vs a matched reply. In either commit order the reply phase
    commits and the hand-off happens exactly once: in T1 when the
    bootstrap committed first, in a later T2 when the reply committed
    first, never both.

  Data: the committed demo tenant built exactly as
  `test/sdr_agent/outreach/webhook_race_test.exs` builds it
  (`Demo.Seed.run/0` with the Clock frozen one day after the demo epoch,
  `SettingsFixtures.save_offering!/1`, lead "01" assigned, worked by
  `AgentWorker.run/2`, approved and delivered, plus an approved follow-up
  whose delivery is still pending), with the C3-02 RED-3 [P] harness
  (sandbox `:auto`, `preflight!/0` before anything commits, tenant-scoped
  cleanup, unlinked tracked contenders). "No definition" is produced as in
  `webhook_handoff_test.exs` (`hide_definition!/1`: the tenant's
  `SDRAgent` rows renamed, so no `(tenant, "SDRAgent", version)` row
  exists), here as a committed raw write inside a transaction
  (`agent_definitions` has no trigger). The job is driven through
  `WebhookWorker.perform/1` with the event's real job and an explicit
  `attempt`/`max_attempts`, as in `webhook_handoff_test.exs`. The Clock
  freeze is process-local and ends with the test process.

  The two T-I13 schedules, and why the bootstrap is held as it is: an
  in-flight `Agents.register_definition/2` holds its INSERT and then, in
  its `AppendEvent` after_action, the tenant's chain head
  (`Kernel.append/2`, `lock_head/1` `FOR UPDATE`). The reply phase appends
  under that head (Reply `:receive` and the rest) before the hand-off's
  lookup (plan section 8.3, "Webhook reply, T1"), so a held registration
  makes the reply wait at the head; that is the bootstrap-first order, and
  the reply's lookup then sees the committed definition (T1). The
  reply-first order needs the bootstrap in flight before its head: the
  holder holds the bootstrap's INSERT alone, an uncommitted raw copy of
  the hidden code-version row under the name `SDRAgent` (same module,
  version, body and `definition_sha256`), so the reply commits its phase at
  once without waiting on that row, defers, and after the holder commits
  attempt 2 hands off (T2).

  RED form: `@guards` is empty; no test calls a new function.
    * T-K7p is behavioural: on main `ReplyIntake` registers
      (`lib/sdr_agent/sdr/reply_intake.ex:28`) and hands off at once, so
      the job returns `:ok` and the first subject assertion fails.
    * T-I13 reply first is behavioural: on main the reply path's
      registration INSERT waits on the in-flight row's unique-index entry
      (while holding the chain head), so the bounded wait for the reply
      fails with "did not commit at once".
    * T-I13 bootstrap first is a control: passes on main and must stay
      green (main's in-transaction registration finds the committed row
      after the head wait and hands off in T1, as C3-02's lookup does).

  Interface names chosen here for review:
    * `{:error, :agent_definition_unavailable}` from the job (shared RED-2
      decision, `webhook_handoff_test.exs`);
    * "no lock of the first connection remains": no `pg_locks` row of any
      type for the contender's backend after the job returned (an open
      transaction always holds its virtualxid);
    * "the reply path registers no definition": no `INSERT INTO
      "agent_definitions"` in the contender's statement trace;
    * the bootstrap-first wait is a row-lock wait on the holder at the
      chain head (`"transactionid"` or `"tuple"`), not an advisory one.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 300_000

  import Ecto.Query, only: [from: 2]
  import SdrAgent.WebhookFixtures, only: [reply_body: 3, signed_headers: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Accounts
  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.Agents.AgentDefinition
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
  alias SdrAgent.Outreach.WebhookWorker
  alias SdrAgent.OutreachFixtures
  alias SdrAgent.Repo
  alias SdrAgent.Sales
  alias SdrAgent.SalesFixtures
  alias SdrAgent.SDR
  alias SdrAgent.SDR.AgentWorker
  alias SdrAgent.SDR.SDRAgent
  alias SdrAgent.SettingsFixtures
  alias SdrAgent.WebhookFixtures

  require Ash.Query

  # No test of this file calls a new function (see the moduledoc).
  @guards []

  @unavailable {:error, :agent_definition_unavailable}
  @worker "SdrAgent.Outreach.WebhookWorker"
  @reply_worker "SdrAgent.SDR.ReplyWorker"

  describe "T-K7p the reply phase commits on its own connection; only the hand-off waits" do
    # Behavioural RED: main registers the definition in the reply
    # transaction and hands off at once (the job returns :ok).
    test "T-K7p definition missing, attempt 1 of 3: committed reply phase seen elsewhere at once, no lock left" do
      preflight!()
      ctx = demo!()
      matched = matched!(ctx)
      hide_definition!(ctx)
      reply = unsubscribe_reply!(matched)
      sup = supervisor!()

      job = contender!(sup, fn -> perform(reply.event, 1) end)
      result = await_result!(job)
      first = backend_of(job)

      assert result == @unavailable,
             "C3-02: a missing definition must defer the hand-off, not complete the job"

      assert first_index(statements(job.pid), ~r/INSERT INTO "agent_definitions"/) == nil,
             "C3-02: the reply path registers no definition (section 7.2)"

      assert_no_locks!(first)
      refute first == backend(), "C3-02: not established: the reader shares the job's connection"

      assert_reply_phase!(ctx, matched, reply)
      refute_handoff!(ctx, reply.event)
      assert webhook!(ctx, reply.event).processing_status == :received
      assert sdr_definitions(ctx) == [], "C3-02: no AgentDefinition row was created"
    end
  end

  describe "T-I13 bootstrap vs a matched reply (plan sections 7.4 and 6.7)" do
    # Behavioural RED: on main the reply path's registration INSERT waits on
    # the in-flight row's unique-index entry, so the reply does not return.
    test "T-I13 reply first: the in-flight bootstrap does not block the lookup; T1 defers, T2 hands off once" do
      preflight!()
      ctx = demo!()
      matched = matched!(ctx)
      hidden = code_version_row(hide_definition!(ctx))
      reply = unsubscribe_reply!(matched)
      sup = supervisor!()
      in_flight = holder!(sup, fn -> insert_code_definition!(hidden) end)

      t1 = contender!(sup, fn -> perform(reply.event, 1) end)

      assert await_unblocked!(t1, in_flight.backend) == @unavailable,
             "C3-02: the lookup misses the uncommitted row and defers"

      # Committed at once, while the bootstrap is still in flight.
      assert_reply_phase!(ctx, matched, reply)
      refute_handoff!(ctx, reply.event)
      assert webhook!(ctx, reply.event).processing_status == :received
      assert sdr_definitions(ctx) == []
      phase = reply_phase(ctx)

      release!(in_flight)
      assert [%{status: :active}] = sdr_definitions(ctx)

      t2 = contender!(sup, fn -> perform(reply.event, 2) end)
      assert await_result!(t2) == :ok, "C3-02: attempt 2 resumes the hand-off (T2)"
      assert webhook!(ctx, reply.event).processing_status == :processed
      assert_handed_off_once!(ctx, matched, reply)
      assert reply_phase(ctx) == phase, "C3-02: T2 writes nothing of the reply phase again"

      settled = event_counts(ctx)
      t3 = contender!(sup, fn -> perform(reply.event, 3) end)
      assert await_result!(t3) == :ok
      assert event_counts(ctx) == settled
      assert [_run] = reply_runs(ctx, reply.event), "C3-02: never both T1 and T2"
    end

    # Control: passes on main and must stay green (main's registration in
    # the reply transaction finds the committed row after the head wait).
    test "T-I13 (control) bootstrap first: the reply waits at the head, then hands off in T1; attempt 2 writes nothing" do
      preflight!()
      ctx = demo!()
      matched = matched!(ctx)
      hide_definition!(ctx)
      reply = unsubscribe_reply!(matched)
      sup = supervisor!()
      in_flight = audit_holder!(sup, fn -> register_code_definition!(ctx) end)

      t1 = contender!(sup, fn -> perform(reply.event, 1) end)
      wait = await_blocked!(backend_of(t1), in_flight.backend)

      assert wait in ["transactionid", "tuple"],
             "C3-02: the reply waits on the registration's chain head: #{inspect(wait)}"

      assert committed_replies(ctx) == 0, "C3-02: not established: the reply phase did not wait"

      release!(in_flight)
      assert [%{status: :active} = definition] = sdr_definitions(ctx)
      assert definition.definition_sha256 == code_sha()

      assert await_result!(t1) == :ok, "C3-02: T1 finds the committed definition and hands off"
      assert webhook!(ctx, reply.event).processing_status == :processed
      assert_reply_phase!(ctx, matched, reply)
      assert_handed_off_once!(ctx, matched, reply)

      settled = event_counts(ctx)
      t2 = contender!(sup, fn -> perform(reply.event, 2) end)
      assert await_result!(t2) == :ok
      assert event_counts(ctx) == settled, "C3-02: attempt 2 of a processed event writes nothing"
      assert [_run] = reply_runs(ctx, reply.event), "C3-02: never both T1 and T2"
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

  ## Guarded holders (below the harness, same guarantees)

  # holder!/2 with its transaction opened by `Audit.transaction/1`, for a
  # lock function that runs a guarded action: `Audit.Guard.run/3` raises
  # inside any other transaction (guard.ex:35-38), so the plain holder's
  # `Repo.transaction` cannot hold a registration. Same guarantees as
  # holder!/2: a tracked contender, owner-bound (rolls back on the test
  # process's :DOWN), bounded handshake, ended by release!/1. A lock
  # function that raises ends the wait at once with its exit reason.
  defp audit_holder!(supervisor, lock) do
    owner = self()
    tag = make_ref()

    task =
      contender!(supervisor, fn ->
        down = Process.monitor(owner)

        Audit.transaction(fn ->
          lock.()
          send(owner, {tag, :held})

          receive do
            {^tag, :release} -> :released
            {:DOWN, ^down, :process, _pid, _reason} -> Repo.rollback(:owner_down)
          end
        end)
      end)

    ref = task.ref

    receive do
      {^tag, :held} ->
        :ok

      {:DOWN, ^ref, :process, _pid, reason} ->
        flunk("C3-02: not established: a guarded holder exited: #{short(reason)}")
    after
      @wait_ms -> flunk("C3-02: a guarded holder never took its lock")
    end

    %{task: task, tag: tag, backend: backend_of(task)}
  end

  ## Waits and locks (below the harness, same guarantees: bounded, unlinked)

  # Bounded wait for a contender that must not wait on `holder_backend`: on
  # the bound it records what the contender waits on, kills it and fails.
  defp await_unblocked!(task, holder_backend) do
    case Task.yield(task, @wait_ms) do
      {:ok, value} ->
        value

      {:exit, reason} ->
        flunk("C3-02: the reply exited: #{short(reason)}")

      nil ->
        waiting = wait_state(backend_of(task))
        Task.shutdown(task, :brutal_kill)

        flunk(
          "C3-02: the reply did not commit at once: it waits on #{short(waiting)} " <>
            "(the in-flight bootstrap is backend #{holder_backend})"
        )
    end
  end

  defp wait_state(backend) do
    %{rows: [row]} =
      Repo.query!(
        "SELECT wait_event_type, wait_event, pg_blocking_pids(pid) " <>
          "FROM pg_stat_activity WHERE pid = $1",
        [backend]
      )

    row
  end

  # No lock of any type (relation, advisory, transactionid, virtualxid).
  defp assert_no_locks!(backend) do
    assert relation_locks(backend) == [], "C3-02: a relation lock of the job remains"
    assert advisory_ids(backend) == MapSet.new(), "C3-02: an advisory key of the job remains"

    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM pg_locks WHERE pid = $1", [backend])
    assert count == 0, "C3-02: the job's connection still holds a lock (open transaction)"
  end

  ## The definition

  # Test-only: no `(tenant, "SDRAgent", version)` row remains (renamed by a
  # committed raw write; the drafting run keeps its FK by id). Returns the
  # renamed rows' `[id, version]`.
  defp hide_definition!(ctx) do
    assert {:ok, rows} =
             Repo.transaction(fn ->
               %{rows: rows} =
                 Repo.query!(
                   "UPDATE agent_definitions SET name = $1 " <>
                     "WHERE tenant_id = $2 AND name = 'SDRAgent' RETURNING id, version",
                   ["SDRAgent-c302-hidden", Ecto.UUID.dump!(ctx.tenant_id)]
                 )

               rows
             end)

    assert rows != [], "C3-02: not established: the drafting run had no SDRAgent row"
    assert sdr_definitions(ctx) == []
    rows
  end

  defp code_version_row(rows) do
    version = SDRAgent.version()
    assert [id] = for([id, ^version] <- rows, do: id)
    id
  end

  # The bootstrap's INSERT before its append (reply-first holder): an
  # uncommitted copy of the hidden code-version row, named `SDRAgent` again.
  defp insert_code_definition!(hidden_id) do
    assert %{num_rows: 1} =
             Repo.query!(
               "INSERT INTO agent_definitions SELECT (jsonb_populate_record(" <>
                 "NULL::agent_definitions, to_jsonb(t) || $2::jsonb)).* " <>
                 "FROM agent_definitions AS t WHERE t.id = $1",
               [hidden_id, %{"id" => Ecto.UUID.generate(), "name" => "SDRAgent"}]
             )
  end

  # The bootstrap's registration, held uncommitted (bootstrap-first holder,
  # inside `audit_holder!/2`'s `Audit.transaction`): INSERT, then the chain
  # head in its append.
  defp register_code_definition!(ctx) do
    assert {:ok, %AgentDefinition{}} =
             Agents.register_definition(
               %{
                 name: "SDRAgent",
                 version: SDRAgent.version(),
                 module: inspect(SDRAgent),
                 definition: SDRAgent.definition_body()
               },
               actor: Actor.system(:kernel, ctx.tenant_id)
             )
  end

  defp sdr_definitions(ctx) do
    AgentDefinition
    |> Ash.Query.filter(tenant_id == ^ctx.tenant_id and name == "SDRAgent")
    |> Ash.read!(Audit.Kernel.opts(ctx.tenant_id))
  end

  defp code_sha, do: Audit.Canonical.sha256(SDRAgent.definition_body())

  ## Events and jobs

  # An unsubscribe-bearing reply (rule phrases "remove me", "unsubscribe")
  # to the delivered message, with canary Message-ID and body values.
  defp unsubscribe_reply!(matched) do
    canary = "c302canary#{SalesFixtures.unique()}"
    message_id = "<#{canary}@prospect.example.test>"
    text = "Please remove me from your list. Unsubscribe. #{canary}body"

    body =
      matched.delivery
      |> reply_body(text, id: "evt_c302_" <> Ecto.UUID.generate())
      |> Jason.decode!()
      |> put_in(["data", "message_id"], message_id)
      |> Jason.encode!()

    assert {:ok, %{status: :accepted, event: event}} =
             Webhooks.ingest("reply", body, Map.new(signed_headers(body)))

    %{
      event: event,
      message_id: message_id,
      email: String.downcase(to_string(matched.delivery.recipient_email))
    }
  end

  defp job_of(event) do
    Repo.one!(
      from(j in Oban.Job,
        where: j.worker == @worker and fragment("?->>'webhook_event_id' = ?", j.args, ^event.id)
      )
    )
  end

  # The event's real job, run with an explicit attempt (final? is
  # attempt >= max_attempts).
  defp perform(event, attempt),
    do: WebhookWorker.perform(%{job_of(event) | attempt: attempt, max_attempts: 3})

  # The tenant's ReplyWorker jobs (committed partition: scoped by tenant).
  defp reply_worker_jobs(ctx) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM oban_jobs WHERE worker = $1 AND args->>'tenant_id' = $2",
        [@reply_worker, ctx.tenant_id]
      )

    count
  end

  defp webhook!(ctx, event) do
    {:ok, event} = Ash.get(WebhookEvent, event.id, actor: ctx.admin)
    event
  end

  defp event_counts(ctx), do: Enum.frequencies_by(AuditCase.events(ctx.tenant), & &1.event_type)

  defp events_about(ctx, type, subject_id),
    do: for(e <- AuditCase.events_of_type(ctx.tenant, type), e.subject_id == subject_id, do: e)

  # Raw count, no audited read: used while a holder holds the chain head.
  defp committed_replies(ctx) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM replies WHERE tenant_id = $1", [
        Ecto.UUID.dump!(ctx.tenant_id)
      ])

    count
  end

  ## The reply phase

  defp reply_phase(ctx) do
    replies = WebhookFixtures.replies!(ctx)

    %{
      replies: Enum.map(replies, &{&1.id, &1.match_status}),
      suppressions: Enum.map(unsubscribe_suppressions(ctx), & &1.id),
      created: length(AuditCase.events_of_type(ctx.tenant, "outreach.suppression.created")),
      received: length(AuditCase.events_of_type(ctx.tenant, "outreach.reply.received"))
    }
  end

  defp unsubscribe_suppressions(ctx),
    do: Enum.filter(WebhookFixtures.suppressions!(ctx), &(&1.reason == :unsubscribe_reply))

  # Read on the test process's own connection: committed rows only.
  defp assert_reply_phase!(ctx, matched, reply) do
    assert [stored] = WebhookFixtures.replies!(ctx)

    assert {stored.match_status, stored.webhook_event_id, stored.delivery_operation_id} ==
             {:matched, reply.event.id, matched.delivery.id}

    assert [rule] = OutreachFixtures.decisions_about!(ctx, stored.id, :unsubscribe_rule)
    assert {rule.mode, rule.outcome} == {:deterministic, "unsubscribe"}
    assert [suppression] = unsubscribe_suppressions(ctx)
    assert {suppression.scope, to_string(suppression.value)} == {:email, reply.email}

    assert {suppression.decision_id, suppression.reply_id, suppression.webhook_event_id} ==
             {rule.id, stored.id, reply.event.id}

    assert [_one] = events_about(ctx, "outreach.suppression.created", suppression.id)
    assert {:ok, matching} = Outreach.matching_suppressions(reply.email, actor: ctx.admin)
    assert suppression.id in Enum.map(matching, & &1.id)

    assert %{status: :stopped, status_reason: "suppressed: unsubscribe_reply"} =
             OutreachFixtures.reload!(ctx, matched.lead)

    assert OutreachFixtures.reload!(ctx, matched.enrollment).status == :replied
    assert OutreachFixtures.outreach!(ctx, matched.pending).state == :cancelled
  end

  ## The hand-off

  defp reply_runs(ctx, event) do
    AgentRun
    |> Ash.Query.filter(tenant_id == ^ctx.tenant_id and correlation_id == ^event.id)
    |> Ash.read!(Audit.Kernel.opts(ctx.tenant_id))
  end

  defp refute_handoff!(ctx, event) do
    assert reply_runs(ctx, event) == [], "C3-02: no reply AgentRun while the hand-off is owed"
    assert reply_worker_jobs(ctx) == 0
    assert AuditCase.events_of_type(ctx.tenant, "sdr.reply.received") == []
    assert events_about(ctx, "webhook.processed", event.id) == []
  end

  defp assert_handed_off_once!(ctx, matched, reply) do
    assert [stored] = WebhookFixtures.replies!(ctx)
    assert [run] = reply_runs(ctx, reply.event)

    assert {run.correlation_id, run.trigger_signal_type, run.usage_origin} ==
             {reply.event.id, "sdr.reply.received", :reply}

    assert {run.lead_id, run.campaign_id} == {stored.lead_id, matched.delivery.campaign_id}
    assert reply_worker_jobs(ctx) == 1

    assert [_signal] =
             for(
               e <- AuditCase.events_of_type(ctx.tenant, "sdr.reply.received"),
               e.payload["data"]["reply_id"] == stored.id,
               do: e
             )

    assert [_processed] = events_about(ctx, "webhook.processed", reply.event.id)
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

  # Lead "01" worked by the agent, approved by the admin and delivered, plus
  # an approved follow-up whose delivery is still pending. In :auto mode the
  # agent's flow steps check out their own connections.
  defp matched!(ctx) do
    {:ok, lead} = Sales.fetch(Sales.Lead, Enum.at(Fixtures.leads(), 0).id, actor: ctx.admin)

    {:ok, %{job: job}} =
      SDR.assign_lead(lead, campaign_id: Fixtures.campaign().id, actor: ctx.admin)

    :ok = AgentWorker.run(job, model: [])

    {:ok, [draft]} =
      Outreach.list_records(Outreach.Draft, filter: [lead_id: lead.id], actor: ctx.admin)

    revision = OutreachFixtures.revision!(ctx, draft.current_revision_id)
    first = approve!(ctx, draft, revision)
    :ok = Delivery.attempt(first.id, ctx.tenant_id)

    followup = WebhookFixtures.followup_draft!(ctx, %{draft: draft, revision: revision})

    pending =
      approve!(ctx, followup, OutreachFixtures.revision!(ctx, followup.current_revision_id))

    %{
      delivery: OutreachFixtures.outreach!(ctx, first),
      lead: OutreachFixtures.reload!(ctx, lead),
      enrollment: OutreachFixtures.enrollment!(ctx, lead),
      pending: pending
    }
  end

  # The admin approves `draft`'s reviewed revision; its DeliveryOperation.
  defp approve!(ctx, draft, revision) do
    {:ok, approval} =
      Outreach.approve(draft, OutreachFixtures.approval_input(revision), actor: ctx.admin)

    OutreachFixtures.delivery_of!(ctx, approval)
  end

  # The harness's park-after-pass seam (parked!/2, probe!/2, resume!/1, and
  # call/3, also used through parked!/2) is not used here: no test of this
  # file calls a new function. This reference keeps the verbatim harness
  # warning-free (Elixir 1.20 ignores `@compile {:nowarn_unused_function,
  # ...}` for `defp`); it is never called.
  @doc false
  def __unused_harness__, do: [&parked!/2, &probe!/2, &resume!/1, &call/3]
end
