defmodule SdrAgent.Audit.IdentityPassOrderTest do
  @moduledoc """
  C3-02 RED-3, plan r8 section 11 O [P] (T-O1, T-O2, T-O3): every identity
  key writer of section 2.6 takes its one pass before any domain row lock
  and before its first append, on independent physical connections with
  committed synthetic rows (sections 2.5, 2.6, 8.3; packet section 6 "One
  pass", lock order and cycle table).

    * T-O1, per entry point of the section 2.6 table that takes a pass:
      `admit_lead/2`; Suppression `:manual`, `:seed`, `:from_classification`
      (the `ReplyAssessment :record` scope, after the model call returned:
      `Outreach.record_assessment/2` driven synchronously in the parked
      contender after a genuine Fake call and its LLM Decision, Codex
      65ca9c0 R3-2);
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
    * T-O3: the reply's real ReplyWorker job, run in a contender, is
      blocked at its Fake reply-classification call (whose
      `:from_classification` pass follows it). The blocked call is bound
      to this execution (the reply canary in its input, its process in the
      contender's run tree, the run's one in-flight classification
      invocation); a test-scoped trace of the whole run tree, attached
      before the contender exists, is split by the gate's own monotonic
      stamps into before the call, the blocked call and after the release.
      While blocked: no advisory lock on the caller's or the job's backend
      or anywhere in the database, and no key statement before the call in
      any process of the run; the pass comes after the release.

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
      process. On main that process is two hops from the contender (the
      ReplyWorker's process): the Runner's finite turn timeout
      (`lib/sdr_agent/sdr/runner.ex:28`, `:87`) makes `Jido.Exec` run the
      turn in a `spawn_monitor/1` worker W1 (jido_action
      `lib/jido_exec.ex:497-519`; parent the contender, no `$callers`), and
      the Action runner runs the action in a `Jido.Exec.TaskSupervisor`
      child W2 (`lib/jido_exec/action/runner.ex:30-47`, `:295-316`;
      `lib/jido_exec/runtime.ex:13`, `:25-28`), whose parent is that
      supervisor and whose `$callers` is `[W1]` (Elixir
      `Task.Supervisor.start_child/3`, `task/supervisor.ex:540-543`,
      `:603-608`; `task/supervised.ex:69-73`, `:87-89`). Neither inherits
      the process dictionary, so the gate owner is passed through the
      application env (`BlockingResponder.gate_key/0`), and T-O3 traces
      the run tree with a test-scoped telemetry handler
      (`collect_run_tree!/0`, detached at exit) instead of the harness's
      opt-in. At exit the whole run tree is killed and awaited before the
      tenant cleanup (`stop_run_tree_on_exit!/1`); the blocked caller is
      also tracked as soon as it reports.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Accounts
  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Audit.Kernel, as: AuditKernel
  alias SdrAgent.Audit.Tenant
  alias SdrAgent.AuditCase
  alias SdrAgent.Clock
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Demo.Seed
  alias SdrAgent.InboxConcurrencyFixtures
  alias SdrAgent.Outreach
  alias SdrAgent.Outreach.ReplyAssessment
  alias SdrAgent.Outreach.Webhooks
  alias SdrAgent.OutreachFixtures
  alias SdrAgent.Repo
  alias SdrAgent.Research
  alias SdrAgent.Sales
  alias SdrAgent.SalesFixtures
  alias SdrAgent.SDR.Context, as: SDRContext
  alias SdrAgent.SDR.Model, as: SDRModel
  alias SdrAgent.SDR.ReplyWorker
  alias SdrAgent.SDRCase
  alias SdrAgent.SettingsFixtures
  alias SdrAgent.WebhookFixtures

  require Ash.Query

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
    # after reporting that process, its backend and the classified reply
    # text to the gate owner, until the owner releases it. On main that
    # process is a `Jido.Exec.TaskSupervisor` child two hops from the
    # contender (see the moduledoc): it inherits no process dictionary, so
    # the gate owner is read from the application env (`@gate`, set for the
    # test by `OutreachFixtures.put_env!/2`); its SQL, from its first
    # statement, is in T-O3's test-scoped tree trace (`collect_run_tree!/0`).
    # Owner-bound and bounded: on the owner's :DOWN, or at the bound, it
    # kills its own process, so no further database work follows in it.
    @gate :c302_t_o3_model_gate
    @wait_ms 10_000

    def gate_key, do: @gate

    def respond("sdr.reply_classification" = operation, input) do
      block!(Application.fetch_env!(:sdr_agent, @gate), get_in(input, [:reply, :text]))
      SdrAgent.Audit.IdentityPassOrderTest.UnsubscribeResponder.respond(operation, input)
    end

    def respond(operation, input), do: SdrAgent.SDR.FakeBrain.respond(operation, input)

    # `entered` and `released` are strictly monotonic stamps (the same
    # clock as the T-O3 tree trace): they split the trace into before the
    # call, the blocked call and after the release.
    defp block!(owner, text) when is_pid(owner) do
      ref = Process.monitor(owner)
      entered = :erlang.unique_integer([:monotonic])
      %{rows: [[backend]]} = SdrAgent.Repo.query!("SELECT pg_backend_pid()")
      send(owner, {:c302_model_call, self(), backend, text, entered})

      receive do
        :c302_model_release ->
          Process.demonitor(ref, [:flush])
          send(owner, {:c302_model_released, self(), :erlang.unique_integer([:monotonic])})

        {:DOWN, ^ref, :process, _pid, _reason} ->
          Process.exit(self(), :kill)
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
      canary = "c302canary#{SalesFixtures.unique()}"
      event = matched_reply!(ctx, delivery, "#{@missed_by_rule} Ref #{canary}.")
      run = reply_run!(ctx, event)
      job = reply_job!(ctx, run)
      OutreachFixtures.put_env!(BlockingResponder.gate_key(), self())
      OutreachFixtures.put_env!(:fake_model_responder, BlockingResponder)
      tag = collect_run_tree!()
      task = contender!(supervisor!(), fn -> ReplyWorker.perform(job) end)
      stop_run_tree_on_exit!(task.pid)

      # Blocked: the caller is tracked; every sample below is taken while
      # the call waits at the gate.
      call = await_model_call!(task)
      in_run? = descends_from?(call.caller, task.pid)
      in_flight = in_flight_invocations(ctx, run)
      caller_ids = advisory_ids(call.backend)
      caller_locks = advisory_locks(call.backend)
      job_locks = advisory_locks(backend_of(task))
      database_locks = database_advisory_locks()
      send(call.caller, :c302_model_release)
      released = await_released!(call.caller)
      result = await_result!(task)
      trace = phases(tree_trace(tag), call.entered, released)

      # The blocked call is this test's one execution: its reply, its run's
      # process tree, its run's one in-flight classification invocation.
      assert is_binary(call.text) and call.text =~ canary,
             "C3-02: not established: the blocked call classifies another reply: #{short(call.text)}"

      assert in_run?, "C3-02: not established: the model call ran outside the contender's run"

      assert [invocation] = in_flight,
             "C3-02: not established: one in-flight invocation of the run: #{short(in_flight)}"

      assert {invocation.purpose, invocation.idempotency_key} ==
               {:reply_classification, "#{run.id}:reply_classification:#{run.trigger_signal_id}"},
             "C3-02: not established: the in-flight call is the run's classification"

      # The trace saw the caller before its call, and nothing ran while it
      # was blocked but the gate's own report.
      assert Enum.any?(
               trace.before,
               &(&1.pid == call.caller and &1.sql =~ ~r/model_invocations/)
             ),
             "C3-02: not established: the caller's pre-call SQL was not observed"

      assert Enum.map(trace.blocked, &{&1.pid, &1.sql}) ==
               [{call.caller, "SELECT pg_backend_pid()"}],
             "C3-02: not established: the run did database work while blocked: " <>
               short(trace.blocked)

      # No key is held while the model call waits.
      assert caller_ids == MapSet.new(),
             "C3-02: the calling backend holds an identity key during a model call"

      assert caller_locks == 0, "C3-02: the calling backend holds an advisory lock"
      assert job_locks == 0, "C3-02: the job's backend holds an advisory lock during the call"
      assert database_locks == 0, "C3-02: an advisory lock is held during the model call"

      before_keys = Enum.filter(trace.before, &(publishes?(&1.sql) or &1.sql =~ ~r/pg_advisory/))

      assert before_keys == [],
             "C3-02: a key was taken before the model call: #{short(before_keys)}"

      refute deadlock?(result), "C3-02: a deadlock: #{short(result)}"
      assert result == :ok, "the classification must still run: #{short(result)}"
      assert [_suppression] = unsubscribe_replies(ctx)

      assert Enum.any?(trace.after, &publishes?(&1.sql)),
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

  # Codex 65ca9c0 R3-2: the approved entry point's own scope, ReplyAssessment
  # `:record` (`Outreach.record_assessment/2`), run synchronously in the
  # parked contender, so the caller-scoped seam and the harness trace see
  # it. The model call comes first, outside the parked scope and in the
  # test process: the reply's queued run is started, the Fake classifies
  # the matched reply as unsubscribe through main's `SDR.Model.call/4`
  # (a genuine completed, validated invocation), and the LLM
  # `reply_classification` Decision is recorded through `SDR.Context.decide/4`
  # with ClassifyReply's exact values (`classify_reply.ex:33-58`, `:64-87`).
  # Then `record_assessment/2` (actor and values as ClassifyReply's) makes
  # AssessmentRules create the :from_classification suppression inside that
  # outer transaction (`assessment_rules.ex:41`, `:140-158`). No assessment
  # or Decision is fabricated, no policy or released-output check bypassed.
  defp entry!(:suppression_from_classification) do
    ctx = demo!()
    delivery = delivered!(ctx)
    event = matched_reply!(ctx, delivery, @missed_by_rule)

    assert unsubscribe_replies(ctx) == [],
           "precondition: no unsubscribe suppression before the assessment"

    attrs = classified!(ctx, event)

    writer(
      ctx.tenant.id,
      [{:email, to_string(delivery.recipient_email)}],
      fn -> Outreach.record_assessment(attrs, actor: ctx.agent) end,
      %{
        ok?: &match?({:ok, %ReplyAssessment{classification: :unsubscribe}}, &1),
        after: fn -> assert_classification_suppression!(ctx, attrs) end
      }
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
      %{
        tenant_id: tenant_id,
        keys: keys,
        run: run,
        ok?: &ok?/1,
        witness?: true,
        published: nil,
        after: nil
      },
      overrides
    )
  end

  defp webhook, do: %{ok?: &(&1 == :ok), witness?: false}
  defp ok?(result), do: match?({:ok, _}, result)

  defp process(ctx, event, body),
    do: fn -> Webhooks.process(event.id, ctx.tenant.id, body) end

  # The matched reply classified by the Fake outside any parked scope, as
  # ClassifyReply does before its assessment: the reply's queued run started,
  # the model call, the LLM Decision. Returns ClassifyReply's assessment
  # attributes.
  defp classified!(ctx, event) do
    run = reply_run!(ctx, event)
    assert {:ok, run} = Agents.start_run(run, actor: ctx.agent)
    reply = reply_of!(ctx, event)
    OutreachFixtures.put_env!(:fake_model_responder, UnsubscribeResponder)

    sdr = %SDRContext{
      actor: ctx.agent,
      tenant_id: ctx.tenant.id,
      run_id: run.id,
      correlation_id: run.correlation_id,
      signal_id: run.trigger_signal_id,
      signal_type: run.trigger_signal_type
    }

    input = %{reply: %{subject: reply.subject || "", text: reply.body_text}}

    assert {:ok, output, invocation} =
             SDRModel.call(sdr, :reply_classification, input, reply.lead_id)

    assert {invocation.status, invocation.validation_status} == {:completed, :valid},
           "precondition: a genuine completed, validated invocation"

    assert {:ok, decision} =
             SDRContext.decide(
               sdr,
               %{
                 kind: :reply_classification,
                 mode: :llm,
                 subject_resource: inspect(Outreach.Reply),
                 subject_id: reply.id,
                 model_invocation_id: invocation.id,
                 output_pointer: "/classification",
                 inputs: %{
                   "reply_id" => reply.id,
                   "body_sha256" => Base.encode16(reply.body_sha256, case: :lower)
                 },
                 outcome: output.classification,
                 outcome_detail: %{
                   "sentiment" => output.sentiment,
                   "suggested_next_action" => output.suggested_next_action
                 },
                 rationale: output.reason,
                 confidence: output.confidence
               },
               "classify:#{reply.id}",
               [reply]
             )

    %{
      reply_id: reply.id,
      classification: output.classification,
      sentiment: output.sentiment,
      intent: output.intent,
      suggested_next_action: output.suggested_next_action,
      confidence: output.confidence,
      reason: output.reason,
      agent_run_id: run.id,
      decision_id: decision.id,
      model_invocation_id: invocation.id
    }
  end

  defp reply_of!(ctx, event) do
    assert [stored] =
             Enum.filter(WebhookFixtures.replies!(ctx), &(&1.webhook_event_id == event.id))

    assert {:ok, reply} = Outreach.fetch(Outreach.Reply, stored.id, actor: ctx.agent)
    reply
  end

  # The assessment's one :from_classification suppression, cited to its
  # Decision and reply.
  defp assert_classification_suppression!(ctx, attrs) do
    assert [suppression] = unsubscribe_replies(ctx)

    assert {suppression.decision_id, suppression.reply_id} ==
             {attrs.decision_id, attrs.reply_id},
           "C3-02: the assessment's own suppression"
  end

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
    if spec.after, do: spec.after.()
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

  # Bounded: the blocked call's report (its process, backend, the reply
  # text it classifies and its entry stamp), or at once the contender's own
  # end (it returned or exited without the call reaching the gate).
  defp await_model_call!(task) do
    ref = task.ref

    receive do
      {:c302_model_call, caller, backend, text, entered} ->
        # Tracked before any assertion: killed and awaited at test exit.
        track!(caller)
        %{caller: caller, backend: backend, text: text, entered: entered}

      {^ref, result} ->
        flunk("C3-02: not established: the run ended before its model call: #{short(result)}")

      {:DOWN, ^ref, :process, _pid, reason} ->
        flunk("C3-02: not established: the contender exited before the call: #{short(reason)}")
    after
      @wait_ms -> flunk("C3-02: not established: the Fake model call never reached the gate")
    end
  end

  # `pid` is `ancestor` or was started on its behalf: `ancestor` is
  # reachable from `pid` through each process's spawner (`Process.info/2`
  # `:parent`) or its `$callers` (set by Elixir's Task), at most `depth`
  # hops. Read while the chain is blocked, so every hop is alive. On main:
  # W2 -$callers-> W1 -parent-> the contender (moduledoc). An unrelated
  # process reaches only supervisors and other callers.
  defp descends_from?(pid, ancestor, depth \\ 6)
  defp descends_from?(pid, pid, _depth), do: true
  defp descends_from?(_pid, _ancestor, 0), do: false

  defp descends_from?(pid, ancestor, depth) when is_pid(pid),
    do: Enum.any?(spawners(pid), &descends_from?(&1, ancestor, depth - 1))

  defp descends_from?(_other, _ancestor, _depth), do: false

  defp spawners(pid) do
    case Process.info(pid, [:parent, :dictionary]) do
      [parent: parent, dictionary: dictionary] ->
        callers =
          case List.keyfind(dictionary, :"$callers", 0) do
            {_key, list} when is_list(list) -> list
            _none -> []
          end

        [parent | callers] |> Enum.filter(&is_pid/1) |> Enum.uniq()

      nil ->
        []
    end
  end

  defp await_released!(caller) do
    receive do
      {:c302_model_released, ^caller, released} -> released
    after
      @wait_ms -> flunk("C3-02: the released model call never resumed")
    end
  end

  # The run's invocations not yet settled (reserved or sent), as the agent.
  defp in_flight_invocations(ctx, run) do
    {:ok, invocations} = Agents.list_model_invocations(run.id, actor: ctx.agent)
    Enum.filter(invocations, &(&1.status in [:reserved, :sent]))
  end

  # Every advisory lock of this database, any backend, mode or form.
  defp database_advisory_locks do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND database = " <>
          "(SELECT oid FROM pg_database WHERE datname = current_database())"
      )

    count
  end

  ## T-O3: a test-scoped trace and stop of the contender's run tree

  # Attached by T-O3 only, before its contender exists, and detached at
  # exit (no production instrumentation changes): every statement of a
  # process that is, or reaches through spawners and `$callers`
  # (`spawners/1`), a process opted in to the harness trace for this test
  # (`:c302_trace_to` == the test process, i.e. the contender) is sent to
  # the test process with a strictly monotonic stamp taken in the sending
  # process when the statement's telemetry fires. It sees Jido's turn and
  # action workers from their first statement. A handler error drops the
  # event (telemetry would otherwise detach the handler); a dropped
  # pre-call event fails the precondition that the caller's pre-call SQL
  # was observed.
  defp collect_run_tree! do
    tag = make_ref()
    handler = "c3-02-t-o3-tree-#{System.unique_integer([:positive])}"
    config = %{owner: self(), tag: tag}

    :ok =
      :telemetry.attach(
        handler,
        [:sdr_agent, :repo, :query],
        &__MODULE__.collect_tree_query/4,
        config
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    tag
  end

  @doc false
  def collect_tree_query(_event, _measurements, metadata, %{owner: owner, tag: tag}) do
    if in_run_tree?(self(), owner, 6) do
      stamp = :erlang.unique_integer([:monotonic])
      send(owner, {tag, stamp, self(), IO.iodata_to_binary(metadata.query)})
    end

    :ok
  rescue
    _error -> :ok
  end

  defp in_run_tree?(pid, owner, depth) do
    traced_for?(pid, owner) or
      (depth > 0 and Enum.any?(spawners(pid), &in_run_tree?(&1, owner, depth - 1)))
  end

  defp traced_for?(pid, owner) when pid == self(), do: Process.get(:c302_trace_to) == owner

  defp traced_for?(pid, owner) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        List.keyfind(dictionary, :c302_trace_to, 0) == {:c302_trace_to, owner}

      nil ->
        false
    end
  end

  # The tree trace so far (non-blocking drain), in stamp order.
  defp tree_trace(tag), do: tag |> drain_tree([]) |> Enum.sort_by(& &1.stamp)

  defp drain_tree(tag, acc) do
    receive do
      {^tag, stamp, pid, sql} -> drain_tree(tag, [%{stamp: stamp, pid: pid, sql: sql} | acc])
    after
      0 -> acc
    end
  end

  # Split by the gate's stamps: before the call, while blocked, after the
  # release.
  defp phases(trace, entered, released) do
    %{
      before: Enum.filter(trace, &(&1.stamp < entered)),
      blocked: Enum.filter(trace, &(&1.stamp > entered and &1.stamp < released)),
      after: Enum.filter(trace, &(&1.stamp > released))
    }
  end

  # Registered right after the contender starts, so at exit it runs before
  # the contender's own tracker: the contender and every live process
  # started on its behalf (spawner or `$callers` chain to it: Jido's turn
  # and action workers and their guards) are killed and awaited (bounded),
  # then the scan is repeated from all of them for any process started
  # meanwhile. No run-tree process survives into the tenant cleanup.
  defp stop_run_tree_on_exit!(root) do
    on_exit(fn ->
      first = run_tree(MapSet.new([root]))
      stop_all!(first)
      first |> run_tree() |> MapSet.difference(first) |> stop_all!()
    end)
  end

  defp run_tree(set) do
    grown =
      for pid <- Process.list(),
          not MapSet.member?(set, pid),
          Enum.any?(spawners(pid), &MapSet.member?(set, &1)),
          into: set,
          do: pid

    if MapSet.size(grown) == MapSet.size(set), do: set, else: run_tree(grown)
  end

  defp stop_all!(pids) do
    monitors = for pid <- pids, do: {pid, Process.monitor(pid)}
    Enum.each(monitors, fn {pid, _ref} -> Process.exit(pid, :kill) end)

    for {pid, ref} <- monitors do
      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        @wait_ms -> flunk("C3-02: a run-tree process did not terminate")
      end
    end
  end

  # The reply's queued AgentRun (ReplyIntake, correlated by the event) and
  # its ReplyWorker job (by the run id).
  defp reply_run!(ctx, event) do
    assert [run] =
             AgentRun
             |> Ash.Query.filter(tenant_id == ^ctx.tenant.id and correlation_id == ^event.id)
             |> Ash.read!(AuditKernel.opts(ctx.tenant.id))

    assert run.status == :queued
    run
  end

  defp reply_job!(ctx, run) do
    job =
      Repo.one!(
        from(j in Oban.Job,
          where:
            j.worker == "SdrAgent.SDR.ReplyWorker" and
              fragment("?->>'run_id' = ?", j.args, ^run.id)
        )
      )

    assert job.args["tenant_id"] == ctx.tenant.id
    job
  end

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

  # A matched reply ingested and processed (its classification run and job
  # queued); returns its WebhookEvent.
  defp matched_reply!(ctx, delivery, text) do
    body = WebhookFixtures.reply_body(delivery, text)
    event = ingest!("reply", body)
    assert Webhooks.process(event.id, ctx.tenant.id, body) == :ok
    event
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
