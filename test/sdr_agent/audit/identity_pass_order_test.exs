defmodule SdrAgent.Audit.IdentityPassOrderTest do
  @moduledoc """
  C3-02 RED-3, plan r8 section 11 O [P] (T-O1, T-O2, T-O3): every identity
  key writer of section 2.6 takes its one pass before any domain row lock
  and before its first append, on independent physical connections with
  committed synthetic rows (sections 2.5, 2.6, 8.3; packet section 6 "One
  pass", lock order and cycle table).

    * T-O1, per entry point of the section 2.6 table that takes a pass:
      `admit_lead/2`; Suppression `:manual`, `:seed`, `:from_classification`
      (the `ReplyAssessment :record` scope, after the model call returned);
      the webhook reply, unsubscribe, bounce and complaint paths; Account
      `:create`, `:seed`, `:update` with a domain change; Contact `:create`,
      `:seed`, `:change_email`; Lead `:seed`, `:reopen`; Qualification
      `:override`. Each writer runs on its own connection and is parked
      right after its pass (`IdentityKeys.TestFaults.park_after_pass/2`):
        - (a) order: in the writer's statement trace, inside the
          transaction that published the pass, the publication
          (`set_config('sdr.identity_pass', ...)`) is the only one and comes
          before the first domain row lock and before the first append
          (`audit_chain_heads ... FOR UPDATE`), and an append follows it;
        - (b) barrier and wait evidence: a contender passing one of the
          same keys in its own transaction waits on the parked backend with
          wait event `advisory`; physical ownership, independent of the
          published record: the parked backend's granted advisory locks
          (`pg_locks`) contain every expected id;
        - (c) the supporting witness `pg_current_xact_id_if_assigned() IS
          NULL`, probed inside the parked transaction (nothing was locked
          or written before the pass). The webhook paths lock their own
          WebhookEvent row first (outside the domain) and use (a) and (b)
          only. The witness is never production code.
      Excluded (no pass of their own): Suppression `:from_webhook` and Lead
      `:create` (`require_held`), `bootstrap_definitions/1` (no key), the
      delivered webhook (no key).
    * T-O1 (control): the xid negative control. A real-row `FOR SHARE`
      assigns an xid that the witness detects, after an unlocked read of
      the same row did not. Passes on main; must stay green (section 10.1).
    * T-O2: every demo seed row (`Demo.Seed.run/0`, "per row through its
      action") that writes an account, contact, lead or suppression takes
      its pass before its domain row locks, over the trace of the seeding
      process; its first pass (the first account) is also parked for (b)
      and (c).
    * T-O3: while a Fake model call is blocked (the reply classification,
      whose `:from_classification` pass follows it), the calling backend
      holds no advisory lock, and no pass precedes the call in its process.

  Committed-row safety, connections and cleanup: the RED-3 [P] harness
  (below the tests, verbatim): sandbox `:auto` mode, every contender
  unlinked under a test-owned `Task.Supervisor` and tracked, holders and
  parked writers bound to the test process, every wait bounded, and every
  tenant present at exit (`Audit.bootstrap`, `Demo.Seed`) removed with the
  Oban jobs inserted after the watermark. The demo data (matched
  deliveries and replies) is built as `webhook_race_test.exs` builds it,
  with the clock frozen one day after the fixture epoch.

  RED form: T-O1 (every entry point) and T-O2 are structural: `preflight!/0`
  guards `IdentityKeys.pass/2`, `id/3`, the park seam, `SDR.admit_lead/2`
  and `SDR.bootstrap_definitions/1` before anything commits. T-O3 calls
  nothing new: it runs `unguarded_preflight!/0` (the same checks and
  cleanup without the guards) and is behavioural: its no-advisory-lock
  assertions hold on main, and it fails at the assertion that the
  classification's suppression publishes a pass after the model call
  returned (main takes none). The xid negative control also runs
  `unguarded_preflight!/0` and passes on main.

  Interface names and choices made here for review:
    * the shared RED-3 seam `IdentityKeys.TestFaults.park_after_pass/2`
      (harness contract); no other seam. T-O3 blocks the Fake call with a
      test responder through main's `config :sdr_agent,
      :fake_model_responder` (as `reply_assessment_test.exs` and
      `retry_run_test.exs` do); `:from_classification` uses main's Fake
      provider with the unsubscribe responder of `reply_assessment_test.exs`
      on a reply the deterministic rule misses;
    * the domain tables of (a) are the packet section 6 identity lock
      domain (users, campaigns, agent_runs, accounts, contacts, leads,
      qualifications, campaign_enrollments, drafts, delivery_operations,
      approvals, agent_definitions; the chain head is the append) plus
      `suppressions` (its value index joins the per-index list, plan
      section 6.2); a domain row lock is an explicit lock clause on one of
      them or an INSERT, UPDATE or DELETE of one (implicit row and
      foreign-key locks; the trace carries SQL only);
    * transactions are delimited in a trace by the `begin` and
      `commit`/`rollback` entries Ecto reports for them;
    * the admission's `admission-ref` key input is not pinned by the plan:
      T-O1 admit_lead asserts the company domain and email ids and a
      published record of exactly three ids (the email's domain is the
      company domain, so the two domain keys are one id);
    * T-O3's backend is the one the blocked call reports from its own
      process. On main that process is a `Jido.Exec` worker the contender
      spawns for the turn (`spawn_monitor/1`, no `$callers`, its own
      connection), so the gate owner is passed through the application env
      (`BlockingResponder.gate_key/0`), the worker opts in to the statement
      trace when it blocks, and the call must be in the contender's run
      (the contender or a process it spawned, `Process.info/2` `:parent`);
      the contender's own backend is checked too.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Accounts
  alias SdrAgent.Actor
  alias SdrAgent.Audit.Kernel, as: AuditKernel
  alias SdrAgent.Audit.Tenant
  alias SdrAgent.AuditCase
  alias SdrAgent.Clock
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Demo.Seed
  alias SdrAgent.InboxConcurrencyFixtures
  alias SdrAgent.Outreach
  alias SdrAgent.Outreach.Webhooks
  alias SdrAgent.OutreachFixtures
  alias SdrAgent.Repo
  alias SdrAgent.Research
  alias SdrAgent.Sales
  alias SdrAgent.SalesFixtures
  alias SdrAgent.SDRCase
  alias SdrAgent.SettingsFixtures
  alias SdrAgent.WebhookFixtures

  @moduletag timeout: 300_000

  @guards [
    {SdrAgent.Audit.IdentityKeys, :pass, 2},
    {SdrAgent.Audit.IdentityKeys, :id, 3},
    {SdrAgent.Audit.IdentityKeys.TestFaults, :park_after_pass, 2},
    {SdrAgent.SDR, :admit_lead, 2},
    {SdrAgent.SDR, :bootstrap_definitions, 1}
  ]

  @keys SdrAgent.Audit.IdentityKeys
  @sdr SdrAgent.SDR

  @publication ~r/set_config\(\s*'sdr\.identity_pass'/
  @begin ~r/^\s*begin\b/i
  @finish ~r/^\s*(commit|rollback)\b/i
  @row_lock ~r/\bFOR (UPDATE|SHARE|NO KEY UPDATE|KEY SHARE)\b/
  @head_lock ~r/FROM "audit_chain_heads".*\bFOR UPDATE\b/s
  # The packet section 6 identity lock domain plus suppressions (moduledoc).
  @domain_from ~r/(FROM|JOIN) "(users|campaigns|agent_runs|accounts|contacts|leads|qualifications|campaign_enrollments|drafts|delivery_operations|approvals|agent_definitions|suppressions)"/
  @domain_write ~r/^\s*(INSERT INTO|UPDATE|DELETE FROM) "(users|campaigns|agent_runs|accounts|contacts|leads|qualifications|campaign_enrollments|drafts|delivery_operations|approvals|agent_definitions|suppressions)"/
  # The demo seed rows that are identity writers (section 2.6).
  @identity_row ~r/^\s*INSERT INTO "(accounts|contacts|leads|suppressions)"/

  # Misses the deterministic unsubscribe rule (reply_assessment_test.exs).
  @missed_by_rule "Please do not write to this address again."

  @entry_points [
    admit_lead: "admit_lead/2",
    suppression_manual: "Suppression :manual",
    suppression_seed: "Suppression :seed",
    suppression_from_classification: "Suppression :from_classification (ReplyAssessment :record)",
    webhook_reply: "webhook reply (event row first; (a) and (b))",
    webhook_unsubscribe: "webhook unsubscribe (event row first; (a) and (b))",
    webhook_bounce: "webhook bounce (event row first; (a) and (b))",
    webhook_complaint: "webhook complaint (event row first; (a) and (b))",
    account_create: "Account :create",
    account_seed: "Account :seed",
    account_update: "Account :update with a domain change",
    contact_create: "Contact :create",
    contact_seed: "Contact :seed",
    contact_change_email: "Contact :change_email",
    lead_seed: "Lead :seed",
    lead_reopen: "Lead :reopen",
    qualification_override: "Qualification :override"
  ]

  defmodule UnsubscribeResponder do
    @moduledoc false
    # The model classifies the reply as unsubscribe, which the deterministic
    # rule missed (the responder of reply_assessment_test.exs).
    def respond("sdr.reply_classification", _input), do: classification()
    def respond(operation, input), do: SdrAgent.SDR.FakeBrain.respond(operation, input)

    def classification do
      %{
        classification: "unsubscribe",
        sentiment: "negative",
        intent: "wants no further contact",
        suggested_next_action: "stop",
        confidence: 0.8,
        reason: "asks not to be contacted"
      }
    end
  end

  defmodule BlockingResponder do
    @moduledoc false
    # T-O3: blocks the reply classification call in its calling process,
    # after reporting that process and its backend to the gate owner, until
    # the owner releases it. On main the call runs in a `Jido.Exec` worker
    # that the ReplyWorker's process spawns with `spawn_monitor/1` (the
    # Runner's finite turn timeout, `lib/sdr_agent/sdr/runner.ex:28` and
    # `:87`; jido_action `Jido.Exec` `execute_with_timeout/6`): it inherits neither the process dictionary
    # nor `$callers`, so the gate owner is read from the application env
    # (`@gate`, set for the test by `OutreachFixtures.put_env!/2`), and the
    # worker opts in to the statement trace itself. Owner-bound and bounded:
    # on the owner's :DOWN, or at the bound, it kills its own process, so no
    # further database work follows in it.
    @gate :c302_t_o3_model_gate
    @wait_ms 10_000

    def gate_key, do: @gate

    def respond("sdr.reply_classification" = operation, input) do
      block!(Application.fetch_env!(:sdr_agent, @gate))
      SdrAgent.Audit.IdentityPassOrderTest.UnsubscribeResponder.respond(operation, input)
    end

    def respond(operation, input), do: SdrAgent.SDR.FakeBrain.respond(operation, input)

    defp block!(owner) when is_pid(owner) do
      ref = Process.monitor(owner)
      Process.put(:c302_trace_to, owner)
      %{rows: [[backend]]} = SdrAgent.Repo.query!("SELECT pg_backend_pid()")
      send(owner, {:c302_model_call, self(), backend})

      receive do
        :c302_model_release -> Process.demonitor(ref, [:flush])
        {:DOWN, ^ref, :process, _pid, _reason} -> Process.exit(self(), :kill)
      after
        @wait_ms -> Process.exit(self(), :kill)
      end
    end
  end

  describe "T-O1 the pass before the first domain row lock and the first append" do
    for {entry, label} <- @entry_points do
      @tag entry: entry
      test "T-O1 #{label}", %{entry: entry} do
        preflight!()
        entry |> entry!() |> assert_entry_point!()
      end
    end

    # Control (plan section 10.1, "the xid negative control"): passes on
    # main; must stay green. It shows that witness (c) detects a locked row.
    test "T-O1 (control) the xid witness: NULL after an unlocked read, assigned after a real-row FOR SHARE" do
      unguarded_preflight!()
      %{tenant: tenant} = tenant!()
      account = SalesFixtures.account!(tenant)
      owner = self()

      holder =
        holder!(supervisor!(), fn -> send(owner, {:c302_xid, xid_witness(account.id)}) end)

      locks = relation_locks(holder.backend)
      release!(holder)

      assert_received {:c302_xid, witness}

      assert witness == %{fresh: true, unlocked_read: true, locked_rows: 1, for_share: false},
             "the witness is NULL until a real row is locked, then assigned: #{short(witness)}"

      assert ["accounts", "RowShareLock"] in locks
    end
  end

  describe "T-O2 demo seed rows" do
    test "T-O2 each demo seed row's writer takes its pass before its domain row locks" do
      preflight!()
      supervisor = supervisor!()
      parked = parked!(supervisor, &Seed.run/0)
      {:ok, tenant_id} = AuditKernel.singleton_tenant_id()
      first = {:domain, hd(Fixtures.accounts()).domain}
      expected = ids(tenant_id, [first])
      witness = probe!(parked, &xid_unassigned?/0)
      held = advisory_ids(parked.backend)
      waiter = key_waiter!(supervisor, tenant_id, first)
      wait = await_blocked!(backend_of(waiter), parked.backend)
      resume!(parked)
      result = await_result!(parked.task)
      waited = await_result!(waiter)

      refute deadlock?(result) or deadlock?(waited), "C3-02: a deadlock: #{short(result)}"
      assert match?({:ok, %{existing: 0}}, result), "the seed must still run: #{short(result)}"
      assert waited == {:ok, :ok}

      assert MapSet.new(parked.ids) == expected,
             "C3-02: the first seeded identity row (the first account) keys its domain"

      assert MapSet.subset?(expected, held),
             "C3-02: the parked seed backend must hold its key (pg_locks)"

      assert wait == "advisory", "C3-02: a same-key contender must wait on the advisory lock"
      assert witness == true, "C3-02: the seed row's pass must precede any row lock or write"

      rows =
        parked.pid |> statements() |> transactions() |> Enum.filter(&identity_row?/1)

      assert length(rows) == seeded_identity_rows(),
             "every seeded account, contact, lead and suppression is its own transaction"

      Enum.each(rows, &assert_pass_first_in!/1)
    end
  end

  describe "T-O3 no key during a model call" do
    # Behavioural RED: calls nothing new. The no-advisory-lock assertions
    # hold on main; the final one (the classification's suppression takes
    # its key after the call returned) fails on main, which takes none.
    test "T-O3 no advisory lock is held while a Fake model call is blocked" do
      unguarded_preflight!()
      ctx = demo!()
      delivery = delivered!(ctx)
      matched_reply!(ctx, delivery, @missed_by_rule)
      OutreachFixtures.put_env!(BlockingResponder.gate_key(), self())
      OutreachFixtures.put_env!(:fake_model_responder, BlockingResponder)
      task = contender!(supervisor!(), &classify/0)

      %{caller: caller, backend: backend} = await_model_call!(task)
      in_run? = descends_from?(caller, task.pid)
      during_ids = advisory_ids(backend)
      during_count = advisory_locks(backend)
      job_count = advisory_locks(backend_of(task))
      during = statements(task.pid)
      send(caller, :c302_model_release)
      result = await_result!(task)
      after_call = statements(caller) ++ statements(task.pid)

      assert in_run?,
             "C3-02: not established: the model call ran outside the contender's run"

      assert during_ids == MapSet.new(),
             "C3-02: the calling backend holds an identity key during a model call"

      assert during_count == 0, "C3-02: the calling backend holds an advisory lock"
      assert job_count == 0, "C3-02: the job's backend holds an advisory lock during the call"
      refute Enum.any?(during, &publishes?/1), "C3-02: a pass preceded the model call"
      refute deadlock?(result), "C3-02: a deadlock: #{short(result)}"
      assert classified?(result), "the classification must still run: #{short(result)}"
      assert [_suppression] = unsubscribe_replies(ctx)

      assert Enum.any?(after_call, &publishes?/1),
             "C3-02: the classification's suppression takes its key after the model call returned"
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

  ## Additional helpers (below the harness, within its guarantees)

  # preflight!/0 without the presence guards, for the two tests that call
  # nothing new (the xid control and T-O3): the same database and tenant
  # checks and the same cleanup registration, before anything commits.
  defp unguarded_preflight! do
    InboxConcurrencyFixtures.assert_test_database!()

    assert match?(%{rows: [[0]]}, Repo.query!("SELECT count(*) FROM tenants")),
           "precondition: the test database holds no committed tenant"

    %{rows: [[watermark]]} = Repo.query!("SELECT coalesce(max(id), 0) FROM oban_jobs")
    on_exit(fn -> cleanup!(watermark) end)
    :ok
  end

  ## T-O1 entry points: committed rows through main's APIs, then the writer

  defp entry!(:admit_lead) do
    %{tenant: tenant, admin: admin} = tenant!()
    campaign = SalesFixtures.active_campaign!(tenant)
    SettingsFixtures.save_offering!(admin)
    definitions!(tenant.id)
    n = SalesFixtures.unique()
    domain = "o1-admit-#{n}.test"
    email = "pat.#{n}@#{domain}"

    input = %{
      source_kind: :manual,
      source_ref: "manual:#{Ecto.UUID.generate()}",
      campaign_id: campaign.id,
      company: %{
        domain: domain,
        name: "O1 Admit #{n}",
        industry: "logistics software",
        employee_count: 120,
        geography: "US"
      },
      person: %{
        email: email,
        first_name: "Pat",
        last_name: "Lee",
        title: "VP Operations",
        timezone: "America/Denver"
      }
    }

    # The admission-ref key's raw input is not pinned (moduledoc): the record
    # holds it as a third id.
    writer(
      tenant.id,
      [{:domain, domain}, {:email, email}],
      fn -> call(@sdr, :admit_lead, [input, [actor: admin]]) end,
      %{published: 3, ok?: &match?({:ok, %{outcome: :admitted}}, &1)}
    )
  end

  defp entry!(:suppression_manual) do
    %{tenant: tenant, admin: admin} = ctx = tenant!()
    email = covered_email!(ctx, "o1-manual")

    writer(tenant.id, [{:email, email}], fn ->
      Outreach.suppress(%{scope: :email, value: email}, actor: admin)
    end)
  end

  defp entry!(:suppression_seed) do
    %{tenant: tenant, seeder: seeder} = ctx = tenant!()
    email = covered_email!(ctx, "o1-seed")
    attrs = %{id: Ecto.UUID.generate(), scope: :email, value: email}

    writer(tenant.id, [{:email, email}], fn -> Outreach.seed_suppression(attrs, actor: seeder) end)
  end

  # The Fake classifies the matched reply as unsubscribe (UnsubscribeResponder);
  # the reply worker's ReplyAssessment :record creates the :from_classification
  # suppression, whose pass is the first in the worker's process.
  defp entry!(:suppression_from_classification) do
    ctx = demo!()
    delivery = delivered!(ctx)
    matched_reply!(ctx, delivery, @missed_by_rule)
    OutreachFixtures.put_env!(:fake_model_responder, UnsubscribeResponder)

    writer(
      ctx.tenant.id,
      [{:email, to_string(delivery.recipient_email)}],
      &classify/0,
      %{ok?: &classified?/1}
    )
  end

  defp entry!(:webhook_reply) do
    ctx = demo!()
    delivery = delivered!(ctx)
    body = WebhookFixtures.reply_body(delivery, "Thanks, this sounds interesting.")
    event = ingest!("reply", body)
    %{"data" => %{"message_id" => message_id, "from" => from}} = Jason.decode!(body)

    writer(
      ctx.tenant.id,
      [{:email, from}, {:"reply-message", message_id}],
      process(ctx, event, body),
      webhook()
    )
  end

  defp entry!(:webhook_unsubscribe) do
    ctx = demo!()
    contact = OutreachFixtures.contact!(ctx, SDRCase.fixture_lead!(ctx, "02"))
    body = WebhookFixtures.unsubscribe_body(contact)
    event = ingest!("unsubscribe", body)

    writer(
      ctx.tenant.id,
      [{:email, to_string(contact.email)}],
      process(ctx, event, body),
      webhook()
    )
  end

  defp entry!(:webhook_bounce), do: outcome_entry!("bounce")
  defp entry!(:webhook_complaint), do: outcome_entry!("complaint")

  defp entry!(:account_create) do
    %{tenant: tenant, admin: admin} = tenant!()
    domain = "o1-account-#{SalesFixtures.unique()}.test"
    attrs = SalesFixtures.account_attrs(%{domain: domain})
    writer(tenant.id, [{:domain, domain}], fn -> Sales.create_account(attrs, actor: admin) end)
  end

  defp entry!(:account_seed) do
    %{tenant: tenant, seeder: seeder} = tenant!()
    domain = "o1-account-seed-#{SalesFixtures.unique()}.test"
    attrs = Map.put(SalesFixtures.account_attrs(%{domain: domain}), :id, Ecto.UUID.generate())
    writer(tenant.id, [{:domain, domain}], fn -> Sales.seed_account(attrs, actor: seeder) end)
  end

  defp entry!(:account_update) do
    %{tenant: tenant, admin: admin} = tenant!()
    n = SalesFixtures.unique()
    old = "o1-old-#{n}.test"
    new = "o1-new-#{n}.test"
    account = SalesFixtures.account!(tenant, %{domain: old})

    writer(tenant.id, [{:domain, old}, {:domain, new}], fn ->
      Sales.update(account, :update, %{domain: new}, actor: admin)
    end)
  end

  defp entry!(:contact_create) do
    %{tenant: tenant, admin: admin} = tenant!()
    n = SalesFixtures.unique()
    account = SalesFixtures.account!(tenant, %{domain: "o1-contact-#{n}.test"})
    email = "jo.#{n}@o1-contact-#{n}.test"
    attrs = SalesFixtures.contact_attrs(account, %{email: email})
    writer(tenant.id, [{:email, email}], fn -> Sales.create_contact(attrs, actor: admin) end)
  end

  defp entry!(:contact_seed) do
    %{tenant: tenant, seeder: seeder} = tenant!()
    n = SalesFixtures.unique()
    account = SalesFixtures.account!(tenant, %{domain: "o1-contact-seed-#{n}.test"})
    email = "jo.#{n}@o1-contact-seed-#{n}.test"

    attrs =
      account
      |> SalesFixtures.contact_attrs(%{email: email})
      |> Map.put(:id, Ecto.UUID.generate())

    writer(tenant.id, [{:email, email}], fn -> Sales.seed_contact(attrs, actor: seeder) end)
  end

  defp entry!(:contact_change_email) do
    %{tenant: tenant, admin: admin} = tenant!()
    n = SalesFixtures.unique()
    account = SalesFixtures.account!(tenant, %{domain: "o1-change-#{n}.test"})
    old = "jo.#{n}@o1-change-#{n}.test"
    contact = SalesFixtures.contact!(tenant, account, %{email: old})
    domain = "mail-o1-#{n}.example"
    new = "jo.#{n}@#{domain}"

    writer(tenant.id, [{:email, old}, {:email, new}, {:domain, domain}], fn ->
      Sales.update(contact, :change_email, %{email: new}, actor: admin)
    end)
  end

  defp entry!(:lead_seed) do
    %{tenant: tenant} = ctx = tenant!()
    n = SalesFixtures.unique()
    domain = "o1-lead-seed-#{n}.test"
    account = SalesFixtures.account!(tenant, %{domain: domain})
    contact = SalesFixtures.contact!(tenant, account, %{email: "jo.#{n}@#{domain}"})
    writer(tenant.id, [{:domain, domain}], fn -> seed_lead(ctx, contact) end)
  end

  defp entry!(:lead_reopen) do
    %{tenant: tenant, admin: admin} = ctx = tenant!()
    %{lead: lead} = SalesFixtures.qualified_lead!(tenant, false)
    assert lead.status == :disqualified

    writer(
      tenant.id,
      [{:domain, account_domain(ctx, lead)}],
      fn -> Sales.update(lead, :reopen, %{}, actor: admin) end,
      %{ok?: &match?({:ok, %{status: :assigned}}, &1)}
    )
  end

  defp entry!(:qualification_override) do
    %{tenant: tenant} = ctx = tenant!()
    subject = SalesFixtures.qualified_lead!(tenant)
    reviewer = AuditCase.human(:reviewer, tenant)
    attrs = override_attrs(subject)

    writer(tenant.id, [{:domain, account_domain(ctx, subject.lead)}], fn ->
      Research.override_qualification(attrs, actor: reviewer)
    end)
  end

  defp outcome_entry!(type) do
    ctx = demo!()
    delivery = delivered!(ctx)
    body = WebhookFixtures.outcome_body(type, delivery)
    event = ingest!(type, body)

    writer(
      ctx.tenant.id,
      [{:email, to_string(delivery.recipient_email)}],
      process(ctx, event, body),
      webhook()
    )
  end

  # A writer spec: its keys (the first is the one the barrier contender
  # requests), the function run in the parked contender, its success shape,
  # whether witness (c) applies, and the published record's size when it
  # holds an id the test does not compute.
  defp writer(tenant_id, keys, run, overrides \\ %{}) do
    Map.merge(
      %{tenant_id: tenant_id, keys: keys, run: run, ok?: &ok?/1, witness?: true, published: nil},
      overrides
    )
  end

  defp webhook, do: %{ok?: &(&1 == :ok), witness?: false}
  defp ok?(result), do: match?({:ok, _}, result)

  defp process(ctx, event, body),
    do: fn -> Webhooks.process(event.id, ctx.tenant.id, body) end

  defp classify, do: Oban.drain_queue(queue: :agent, with_safety: false)
  defp classified?(result), do: match?(%{success: 1, failure: 0}, result)

  ## T-O1 and T-O2 assertions

  # Parks the writer after its pass; samples (c) and the physical locks
  # while parked; shows a same-key contender waiting on `advisory`; resumes
  # and joins both (bounded); then asserts (b), (c) and (a).
  defp assert_entry_point!(spec) do
    supervisor = supervisor!()
    expected = ids(spec.tenant_id, spec.keys)
    parked = parked!(supervisor, spec.run)
    witness = if spec.witness?, do: probe!(parked, &xid_unassigned?/0)
    held = advisory_ids(parked.backend)
    waiter = key_waiter!(supervisor, spec.tenant_id, hd(spec.keys))
    wait = await_blocked!(backend_of(waiter), parked.backend)
    resume!(parked)
    result = await_result!(parked.task)
    waited = await_result!(waiter)
    published = MapSet.new(parked.ids)

    refute deadlock?(result) or deadlock?(waited), "C3-02: a deadlock: #{short(result)}"
    assert spec.ok?.(result), "the writer must still succeed: #{short(result)}"
    assert waited == {:ok, :ok}, "the same-key contender passes once the writer ended"

    assert wait == "advisory", "C3-02: a same-key contender must wait on the advisory lock"

    assert MapSet.subset?(expected, held),
           "C3-02: the parked backend must hold every expected key (pg_locks)"

    assert MapSet.subset?(published, held), "C3-02: a published id is not held"
    assert MapSet.subset?(expected, published), "C3-02: the pass record lacks an expected id"
    assert MapSet.size(published) == (spec.published || MapSet.size(expected))

    if spec.witness? do
      assert witness == true,
             "C3-02: the transaction locked or wrote a row before its pass (an xid was assigned)"
    end

    parked.pid |> statements() |> pass_transaction!() |> assert_pass_first_in!()
  end

  defp key_waiter!(supervisor, tenant_id, key),
    do: contender!(supervisor, fn -> Repo.transaction(fn -> pass(tenant_id, [key]) end) end)

  # (a) inside one transaction of a trace: exactly one publication, no
  # domain row lock and no append before it, an append after it.
  defp assert_pass_first_in!(transaction) do
    at = first_index(transaction, @publication)
    assert at, "C3-02: the transaction published no identity pass: #{short(transaction)}"
    {before, [_publication | rest]} = Enum.split(transaction, at)

    assert Enum.count(transaction, &publishes?/1) == 1,
           "C3-02: one pass per application scope"

    assert Enum.filter(before, &domain_lock?/1) == [],
           "C3-02: a domain row lock preceded the pass: #{short(Enum.filter(before, &domain_lock?/1))}"

    refute Enum.any?(before, &append?/1), "C3-02: an append preceded the pass"

    assert Enum.any?(rest, &append?/1),
           "C3-02: not established: the pass's transaction appended nothing after it"
  end

  defp pass_transaction!(statements) do
    transaction =
      statements |> transactions() |> Enum.find(&Enum.any?(&1, fn sql -> publishes?(sql) end))

    assert transaction, "C3-02: no transaction of the writer published an identity pass"
    transaction
  end

  # The trace split into its transactions, from `begin` to `commit` or
  # `rollback` (statements outside a transaction are dropped).
  defp transactions(statements) do
    {done, _open} = Enum.reduce(statements, {[], nil}, &segment/2)
    Enum.reverse(done)
  end

  defp segment(sql, {done, open}) do
    cond do
      sql =~ @begin -> {done, [sql]}
      is_nil(open) -> {done, nil}
      sql =~ @finish -> {[Enum.reverse([sql | open]) | done], nil}
      true -> {done, [sql | open]}
    end
  end

  defp publishes?(sql), do: sql =~ @publication
  defp append?(sql), do: sql =~ @head_lock

  defp domain_lock?(sql),
    do: (sql =~ @row_lock and sql =~ @domain_from) or sql =~ @domain_write

  defp identity_row?(transaction), do: Enum.any?(transaction, &(&1 =~ @identity_row))

  defp seeded_identity_rows do
    length(Fixtures.accounts()) + length(Fixtures.contacts()) + length(Fixtures.leads()) +
      length(Fixtures.suppressions())
  end

  defp deadlock?(term),
    do: inspect(term, limit: :infinity, printable_limit: :infinity) =~ ~r/deadlock_detected|40P01/

  ## Witnesses

  defp xid_unassigned? do
    %{rows: [[unassigned]]} = Repo.query!("SELECT pg_current_xact_id_if_assigned() IS NULL")
    unassigned
  end

  # Run inside the holder's transaction (the negative control).
  defp xid_witness(account_id) do
    raw = Ecto.UUID.dump!(account_id)
    fresh = xid_unassigned?()
    Repo.query!(~s(SELECT id FROM "accounts" WHERE id = $1), [raw])
    read = xid_unassigned?()

    %{num_rows: locked} =
      Repo.query!(~s(SELECT id FROM "accounts" WHERE id = $1 FOR SHARE), [raw])

    %{fresh: fresh, unlocked_read: read, locked_rows: locked, for_share: xid_unassigned?()}
  end

  # Every advisory lock of `backend`, any mode or form.
  defp advisory_locks(backend) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = $1", [
        backend
      ])

    count
  end

  # Bounded: the blocked call's report, or at once the contender's own end
  # (it returned or exited without the call reaching the gate).
  defp await_model_call!(task) do
    ref = task.ref

    receive do
      {:c302_model_call, caller, backend} ->
        %{caller: caller, backend: backend}

      {^ref, result} ->
        flunk("C3-02: not established: the run ended before its model call: #{short(result)}")

      {:DOWN, ^ref, :process, _pid, reason} ->
        flunk("C3-02: not established: the contender exited before the call: #{short(reason)}")
    after
      @wait_ms -> flunk("C3-02: not established: the Fake model call never reached the gate")
    end
  end

  # `pid` is `ancestor` or was spawned (`Process.info/2` `:parent`), at most
  # a few levels down, by it.
  defp descends_from?(pid, ancestor, depth \\ 4)
  defp descends_from?(pid, pid, _depth), do: true
  defp descends_from?(_pid, _ancestor, 0), do: false

  defp descends_from?(pid, ancestor, depth) when is_pid(pid) do
    case Process.info(pid, :parent) do
      {:parent, parent} when is_pid(parent) -> descends_from?(parent, ancestor, depth - 1)
      _gone_or_root -> false
    end
  end

  defp descends_from?(_other, _ancestor, _depth), do: false

  ## Fixtures (main's APIs; committed after preflight)

  defp tenant! do
    tenant = AuditCase.bootstrap!()

    %{
      tenant: tenant,
      admin: AuditCase.human(:admin, tenant),
      seeder: AuditCase.system_actor(:seeder, tenant)
    }
  end

  # The seeded demo data with the clock frozen one day after the epoch, as
  # webhook_race_test.exs and SDRCase build it.
  defp demo! do
    Clock.freeze(DateTime.add(Fixtures.epoch(), 1, :day))
    on_exit(&Clock.unfreeze/0)
    assert {:ok, _counts} = Seed.run()
    {:ok, tenant_id} = AuditKernel.singleton_tenant_id()
    {:ok, tenant} = Ash.get(Tenant, tenant_id, AuditKernel.opts(tenant_id))
    seeder = Actor.system(:seeder, tenant_id, "c302-red3")
    {:ok, admin} = Accounts.get_user(hd(Fixtures.users()).id, actor: seeder)

    %{
      tenant: tenant,
      admin: admin,
      agent: Actor.system(:agent_runtime, tenant_id),
      campaign_id: Fixtures.campaign().id
    }
  end

  # Lead "01" drafted by the agent, approved and delivered (accepted).
  defp delivered!(ctx) do
    approved = OutreachFixtures.approved!(ctx, "01")
    assert match?(%{success: 1}, OutreachFixtures.deliver!())
    OutreachFixtures.outreach!(ctx, approved.delivery)
  end

  # A matched reply ingested and processed (its classification job queued).
  defp matched_reply!(ctx, delivery, text) do
    body = WebhookFixtures.reply_body(delivery, text)
    event = ingest!("reply", body)
    assert Webhooks.process(event.id, ctx.tenant.id, body) == :ok
  end

  defp ingest!(type, body) do
    assert {:ok, %{status: :accepted, event: event}} = WebhookFixtures.ingest!(type, body)
    event
  end

  defp unsubscribe_replies(ctx),
    do: Enum.filter(WebhookFixtures.suppressions!(ctx), &(&1.reason == :unsubscribe_reply))

  # A contact with an open (seeded) lead, so a suppression of its email has
  # domain rows to lock after its key.
  defp covered_email!(ctx, label) do
    n = SalesFixtures.unique()
    domain = "#{label}-#{n}.test"
    account = SalesFixtures.account!(ctx.tenant, %{domain: domain})
    email = "jo.#{n}@#{domain}"
    contact = SalesFixtures.contact!(ctx.tenant, account, %{email: email})
    assert {:ok, _lead} = seed_lead(ctx, contact)
    email
  end

  # The dev/test :seed boundary (Lead :create is admission-only after G5).
  defp seed_lead(ctx, contact) do
    Sales.seed_lead(
      %{
        id: Ecto.UUID.generate(),
        contact_id: contact.id,
        account_id: contact.account_id,
        source: :fixture
      },
      actor: ctx.seeder
    )
  end

  defp account_domain(ctx, lead) do
    assert {:ok, account} = Sales.fetch(Sales.Account, lead.account_id, actor: ctx.admin)
    to_string(account.domain)
  end

  # A flip override of the current (qualified) row, as override_company_key_test.exs.
  defp override_attrs(%{lead: lead, qualification: qualification, claim: claim}) do
    %{
      lead_id: lead.id,
      icp_definition_id: qualification.icp_definition_id,
      supersedes_id: qualification.id,
      qualified: false,
      score: 30,
      criteria: %{
        company_size: :pass,
        industry: :fail,
        geography: :pass,
        persona: :unknown,
        trigger: :pass
      },
      confidence: 0.9,
      reason: "Industry does not fit after manual review.",
      output_schema_version: "qualification_result/1",
      evidence_claim_ids: [claim.id]
    }
  end

  ## Guarded calls

  defp definitions!(tenant_id) do
    result = call(@sdr, :bootstrap_definitions, [tenant_id])
    assert match?({:ok, _}, result), "C3-02: bootstrap_definitions/1: #{short(result)}"
  end

  defp pass(tenant_id, keys), do: call(@keys, :pass, [tenant_id, keys])
  defp key_id(tenant_id, kind, raw), do: call(@keys, :id, [tenant_id, kind, raw])

  defp ids(tenant_id, keys),
    do: MapSet.new(keys, fn {kind, raw} -> key_id(tenant_id, kind, raw) end)
end
