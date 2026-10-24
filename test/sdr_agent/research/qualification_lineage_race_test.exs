defmodule SdrAgent.Research.QualificationLineageRaceTest do
  @moduledoc """
  C3-02 RED-3, plan r8 section 11 L [P] (T-L7, T-L9, T-L10): Qualification
  `:record` takes the lead `FOR UPDATE` before its Supersedes and
  QualificationRules reads and its INSERT
  (`SdrAgent.Research.Changes.RecordLeadLock`, section 4.6.4), so no writer
  holds a qualification index entry while it waits for the lead, and a
  successor or root `:record` racing an override of the same lead
  serializes on the lead row with exactly one committed writer (sections
  4.6.3-4.6.4, 8.3).

  T-L7 is listed in section 11 L with `qualification_record_lock_test.exs`
  (RED-2, not [P]) and this file; it needs a row-lock holder on its own
  physical connection, so it lives here.

  Committed synthetic rows built with main's APIs only (`Audit.bootstrap`,
  `AuditCase.human/2` and `system_actor/2`, `SalesFixtures`, Lead `:seed`
  with source `fixture` and the qualification path of `admit_lead_test.exs`
  `qualified!/3`, so the setup stays valid after the G5 cutover). T-L9's
  and T-L10 (i)'s state is `research_test.exs:484-509`'s: a reopened
  `qualifying` lead whose current qualification X (R0) is disqualified.

  Schedules (the RED-3 [P] harness, no production seam; section 11 L
  "schedule mechanics", with the unlinked, owner-bound holder and contender
  pattern in place of the linked `Task.async` of `ResolveHarness`,
  `InboxConcurrencyFixtures` and `settings_revision_race_test.exs`):
    * (a) parked after the INSERT: a holder takes the tenant row
      `FOR UPDATE`; the first writer is awaited blocked by it holding
      `RowExclusiveLock` on `qualifications` (its tenant FK check, which
      fires before the lead's); the second writer is then awaited blocked
      by the first;
    * (b) both parked before the lead: a holder takes the lead
      `FOR UPDATE`; the first writer is awaited blocked by the holder, the
      second blocked by the first (`pg_blocking_pids`).
  "Parked before the lead" is asserted from `pg_locks` (no granted lock on
  `qualifications` or its indexes), `pg_stat_activity` (the waiting
  statement is the lead `FOR UPDATE`) and the waiter's statement trace (no
  completed statement touched `qualifications`).

  Every result is joined within the bound; no result is a deadlock
  (`40P01`, `:deadlock_detected`); the refused writer's result is a typed
  refusal of the section 4.6.4 set, asserted at class level
  (`Ash.Error.Invalid`), no constraint pinned; lineage, lead state and
  exact event deltas show the loser wrote no qualification,
  `QualificationEvidence`, event or lead change.

  RED form: no new API is called and `@guards` is empty
  (`Research.record_qualification/2` and `override_qualification/2` exist
  on main), so every test is behavioural or a section 10.1 control:
    * behavioural: T-L7 (both), T-L9 (a) (all four), T-L10 (all six). On
      main every writer inserts before it touches the lead, so a waiter
      blocked by a lead holder or by the first writer is the INSERT holding
      `RowExclusiveLock` on `qualifications`; and an invalid T-L10 writer is
      refused by its unlocked reads without ever waiting (T-L10 (i) (a),
      (i) (b) R first, (ii) (a), (ii) (b) O first: `await_waiting!/3`
      fails as soon as that writer returns, "returned without waiting",
      with its refusal and its qualifications statements);
    * control (passes on main; must stay green): T-L9 (b) (all four). Its
      plan schedule assertion (first blocked by the holder, second behind
      the first) and its outcome oracle already hold on main, where the
      second writer waits on the first's uncommitted `unique_supersedes`
      entry instead of the lead.

  Not a committed test (section 11 L GREEN negative control, a mutation):
  with `RecordLeadLock` removed and `OverrideCompanyLock` present, T-L9 (a)
  with R first must fail by `40P01` or by its schedule assertion; its
  precondition (O blocked by R at O's INSERT, which relies on the tenant FK
  check firing before the lead's, PostgreSQL trigger order) is asserted,
  and if it fails the control is reported "not established", never a pass.

  Interface names chosen here for review: none new. Choices: the typed
  refusal is `{:error, %Ash.Error.Invalid{}}`; the lead lock is recognised
  by `FROM "leads" ... FOR UPDATE` in the waiter's `pg_stat_activity.query`;
  "no qualifications lock" includes the table's indexes; the harness's
  park-after-pass helpers are unused here (referenced once, never called,
  by `__unused_harness__/0`, because Elixir 1.20 ignores `@compile
  {:nowarn_unused_function, ...}` for `defp`).
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Audit
  alias SdrAgent.AuditCase
  alias SdrAgent.InboxConcurrencyFixtures
  alias SdrAgent.Repo
  alias SdrAgent.Research
  alias SdrAgent.Research.Qualification
  alias SdrAgent.Sales
  alias SdrAgent.Sales.Lead
  alias SdrAgent.SalesFixtures

  @moduletag timeout: 300_000

  # The harness's ADAPT attribute: no new subject is called here (every
  # test is behavioural or a control), so nothing is guarded.
  @guards []

  @lead_lock ~r/\bFROM\s+"?leads\b"?.*\bFOR UPDATE\b/is
  @qualifications ~r/"qualifications"/
  @qualification_relation ~r/\Aqualifications(_|\z)/
  @recorded "research.qualification.recorded"
  @lead_qualified "sales.lead.qualified"

  describe "T-L7 :record takes the lead first" do
    test "T-L7 root: :record waits at the lead FOR UPDATE, no qualifications lock; commits" do
      preflight!()
      ctx = world!()
      lead = qualifying_lead!(ctx)
      attrs = record_attrs(ctx, lead, evidence!(ctx, lead))
      row = record_behind_lead_holder!(ctx, lead, attrs)
      assert row.supersedes_id == nil
      assert qualification_ids(lead) == [row.id]
      assert current(lead) == row.id
      assert status(lead) == "qualified"
    end

    test "T-L7 successor: :record waits at the lead FOR UPDATE, no qualifications lock; commits" do
      preflight!()
      ctx = world!()
      subject = reopened!(ctx)
      attrs = record_attrs(ctx, subject.lead, subject.evidence, %{supersedes_id: subject.x.id})
      row = record_behind_lead_holder!(ctx, subject.lead, attrs)
      assert row.supersedes_id == subject.x.id
      assert successors(subject.x.id) == [row.id]
      assert current(subject.lead) == row.id
      assert status(subject.lead) == "qualified"
    end
  end

  describe "T-L9 (a) successor R vs override O, parked after the INSERT" do
    test "T-L9 (a) R first, same-outcome O: R commits, O is refused" do
      l9!(:a, :r_first, :same)
    end

    test "T-L9 (a) same-outcome O first, R second: O commits, R is refused" do
      l9!(:a, :o_first, :same)
    end

    test "T-L9 (a) R first, flip O: R commits, O is refused" do
      l9!(:a, :r_first, :flip)
    end

    test "T-L9 (a) flip O first, R second: O is refused by the qualifying state, R commits" do
      l9!(:a, :o_first, :flip)
    end
  end

  # (control): the plan's (b) schedule assertion and the outcome oracle
  # already hold on main. Passes on main; must stay green.
  describe "T-L9 (b) successor R vs override O, both parked before the lead (control)" do
    test "T-L9 (b) R first, same-outcome O: R commits, O is refused (control)" do
      l9!(:b, :r_first, :same)
    end

    test "T-L9 (b) same-outcome O first, R second: O commits, R is refused (control)" do
      l9!(:b, :o_first, :same)
    end

    test "T-L9 (b) R first, flip O: R commits, O is refused (control)" do
      l9!(:b, :r_first, :flip)
    end

    test "T-L9 (b) flip O first, R second: O is refused, R commits (control)" do
      l9!(:b, :o_first, :flip)
    end
  end

  describe "T-L10 (i) root R vs same-outcome override O of a current R0" do
    test "T-L10 (i) (a) O first, parked after its INSERT: O commits, root R is refused" do
      preflight!()
      ctx = world!()
      case_i = case_i!(ctx)
      before = snapshot(case_i.subject.lead)
      {o, r} = schedule_a!(ctx, case_i.o, case_i.r)
      assert_outcome!(case_i.subject, before, %{r: r, o: o}, case_i.oracle)
    end

    test "T-L10 (i) (b) O first in the lead queue: O commits, root R is refused" do
      preflight!()
      ctx = world!()
      case_i = case_i!(ctx)
      before = snapshot(case_i.subject.lead)
      {o, r} = schedule_b!(case_i.subject.lead, case_i.o, case_i.r, :parked)
      assert_outcome!(case_i.subject, before, %{r: r, o: o}, case_i.oracle)
    end

    test "T-L10 (i) (b) root R first in the lead queue: R is refused early, O commits" do
      preflight!()
      ctx = world!()
      case_i = case_i!(ctx)
      before = snapshot(case_i.subject.lead)
      {r, o} = schedule_b!(case_i.subject.lead, case_i.r, case_i.o, :parked)
      assert_outcome!(case_i.subject, before, %{r: r, o: o}, case_i.oracle)
    end
  end

  describe "T-L10 (ii) root R vs override O naming another lead's row" do
    test "T-L10 (ii) (a) R first, parked after its INSERT: R commits, O is refused" do
      preflight!()
      ctx = world!()
      case_ii = case_ii!(ctx)
      before = snapshot(case_ii.subject.lead)
      {r, o} = schedule_a!(ctx, case_ii.r, case_ii.o)
      assert_outcome!(case_ii.subject, before, %{r: r, o: o}, case_ii.oracle)
      assert successors(case_ii.other.id) == [], "C3-02: O wrote no successor of the other row"
    end

    test "T-L10 (ii) (b) R first in the lead queue: R commits, O is refused" do
      preflight!()
      ctx = world!()
      case_ii = case_ii!(ctx)
      before = snapshot(case_ii.subject.lead)
      {r, o} = schedule_b!(case_ii.subject.lead, case_ii.r, case_ii.o, :parked)
      assert_outcome!(case_ii.subject, before, %{r: r, o: o}, case_ii.oracle)
      assert successors(case_ii.other.id) == [], "C3-02: O wrote no successor of the other row"
    end

    test "T-L10 (ii) (b) O first in the lead queue: O is refused early, R commits" do
      preflight!()
      ctx = world!()
      case_ii = case_ii!(ctx)
      before = snapshot(case_ii.subject.lead)
      {o, r} = schedule_b!(case_ii.subject.lead, case_ii.o, case_ii.r, :parked)
      assert_outcome!(case_ii.subject, before, %{r: r, o: o}, case_ii.oracle)
      assert successors(case_ii.other.id) == [], "C3-02: O wrote no successor of the other row"
    end
  end

  ## T-L7

  # The holder takes the lead FOR UPDATE; :record is awaited blocked by it,
  # parked before the lead; after the release it commits, and its trace
  # shows the lead FOR UPDATE before any qualifications statement.
  defp record_behind_lead_holder!(ctx, lead, attrs) do
    supervisor = supervisor!()
    holder = lead_holder!(supervisor, lead)
    writer = contender!(supervisor, record_fun(ctx, attrs))
    assert_parked_before_lead!(writer, holder.backend, ":record")
    release!(holder)
    result = await_result!(writer)
    refute_deadlock!(result)

    assert match?({:ok, %Qualification{}}, result),
           "C3-02: after the release :record commits: #{short(result)}"

    trace = statements(writer.pid)
    lock_at = first_index(trace, @lead_lock)
    touched_at = first_index(trace, @qualifications)
    assert lock_at, "C3-02: :record takes the lead FOR UPDATE"
    assert touched_at
    assert lock_at < touched_at, "C3-02: the lead FOR UPDATE precedes every qualifications read"
    {:ok, row} = result
    row
  end

  ## T-L9

  defp l9!(schedule, order, variant) do
    preflight!()
    ctx = world!()
    subject = reopened!(ctx)
    r = record_fun(ctx, successor_attrs(ctx, subject))
    o = override_fun(ctx, override_attrs(subject.lead, subject.x, subject.evidence, variant))
    before = snapshot(subject.lead)
    results = run_schedule!(ctx, subject.lead, schedule, order, {r, o})
    assert_outcome!(l9_subject(subject), before, results, l9_oracle(subject, order, variant))
  end

  defp run_schedule!(ctx, _lead, :a, :r_first, {r, o}), do: by_role(schedule_a!(ctx, r, o), :r)
  defp run_schedule!(ctx, _lead, :a, :o_first, {r, o}), do: by_role(schedule_a!(ctx, o, r), :o)

  defp run_schedule!(_ctx, lead, :b, :r_first, {r, o}),
    do: by_role(schedule_b!(lead, r, o, :queued), :r)

  defp run_schedule!(_ctx, lead, :b, :o_first, {r, o}),
    do: by_role(schedule_b!(lead, o, r, :queued), :o)

  defp by_role({first, second}, :r), do: %{r: first, o: second}
  defp by_role({first, second}, :o), do: %{o: first, r: second}

  defp l9_subject(subject),
    do: %{lead: subject.lead, prior: [subject.x.id], superseded: subject.x}

  # A same-outcome override commits when first (the second writer's lineage
  # is then stale); a flip override is refused in both orders (by the
  # qualifying state when first, by stale lineage when second), so R wins.
  defp l9_oracle(_subject, :o_first, :same),
    do: %{winner: :o, status: "qualifying", events: %{@recorded => 1}}

  defp l9_oracle(_subject, _order, _variant),
    do: %{winner: :r, status: "qualified", events: %{@recorded => 1, @lead_qualified => 1}}

  ## T-L10

  # (i): a reopened qualifying lead with a committed current R0; O, a
  # same-outcome override of R0, is insert-capable; the root R names no
  # row while R0 is current.
  defp case_i!(ctx) do
    subject = reopened!(ctx)

    %{
      subject: l9_subject(subject),
      r: record_fun(ctx, record_attrs(ctx, subject.lead, subject.evidence)),
      o: override_fun(ctx, override_attrs(subject.lead, subject.x, subject.evidence, :same)),
      oracle: %{winner: :o, status: "qualifying", events: %{@recorded => 1}}
    }
  end

  # (ii): a qualifying lead with no qualification; the root R is
  # insert-capable; O names a committed qualification of another synthetic
  # lead in the same tenant.
  defp case_ii!(ctx) do
    lead = qualifying_lead!(ctx)
    other_lead = qualifying_lead!(ctx)
    other_evidence = evidence!(ctx, other_lead)

    assert {:ok, other} =
             Research.record_qualification(
               record_attrs(ctx, other_lead, other_evidence, %{qualified: false}),
               actor: ctx.agent
             )

    evidence = evidence!(ctx, lead)

    %{
      subject: %{lead: lead, prior: [], superseded: nil},
      other: other,
      r: record_fun(ctx, record_attrs(ctx, lead, evidence)),
      o: override_fun(ctx, override_attrs(lead, other, nil, :same)),
      oracle: %{winner: :r, status: "qualified", events: %{@recorded => 1, @lead_qualified => 1}}
    }
  end

  ## Schedules

  # (a): the first writer parked after its INSERT at its tenant FK check
  # (tenant-row holder); the second awaited blocked by the first, parked
  # before the lead; then the holder is released. Returns the results in
  # start order.
  defp schedule_a!(ctx, first_fun, second_fun) do
    supervisor = supervisor!()
    holder = tenant_holder!(supervisor, ctx.tenant)
    first = contender!(supervisor, first_fun)
    assert_parked_after_insert!(first, holder.backend)
    second = contender!(supervisor, second_fun)
    assert_parked_before_lead!(second, backend_of(first), "the second writer")
    release!(holder)
    {await_result!(first), await_result!(second)}
  end

  # (b): a lead holder; the first writer awaited blocked by it, the second
  # behind the first; `park` is the per-writer assertion. Returns the
  # results in start order.
  defp schedule_b!(lead, first_fun, second_fun, mode) do
    supervisor = supervisor!()
    holder = lead_holder!(supervisor, lead)
    first = contender!(supervisor, first_fun)
    park!(mode, first, holder.backend, "the first writer")
    second = contender!(supervisor, second_fun)
    park!(mode, second, backend_of(first), "the second writer")
    still_parked!(mode, first)
    release!(holder)
    {await_result!(first), await_result!(second)}
  end

  # :parked (T-L10 (b)): the subject assertion for each writer; :queued
  # (T-L9 (b), control): only the plan's schedule assertion, the wait.
  defp park!(:parked, task, blocker, label), do: assert_parked_before_lead!(task, blocker, label)
  defp park!(:queued, task, blocker, _label), do: await_blocked!(backend_of(task), blocker)

  # T-L10 (b): while both are parked before the lead, each holds no
  # qualifications lock (re-checked for the first after the second parks).
  defp still_parked!(:queued, _first), do: :ok

  defp still_parked!(:parked, first) do
    held = qualification_locks(backend_of(first))

    assert held == [],
           "C3-02: the first writer still holds no qualifications lock: #{short(held)}"
  end

  # Row-lock holders (raw SQL inside the harness holder's transaction).
  defp lead_holder!(supervisor, lead) do
    holder!(supervisor, fn ->
      assert %{num_rows: 1} =
               Repo.query!("SELECT 1 FROM leads WHERE id = $1 FOR UPDATE", [dump(lead.id)])
    end)
  end

  defp tenant_holder!(supervisor, tenant) do
    holder!(supervisor, fn ->
      assert %{num_rows: 1} =
               Repo.query!("SELECT 1 FROM tenants WHERE id = $1 FOR UPDATE", [dump(tenant.id)])
    end)
  end

  # Schedule precondition, not the subject: the first writer waits on the
  # tenant holder after its INSERT.
  defp assert_parked_after_insert!(task, holder_backend) do
    backend = backend_of(task)
    await_blocked!(backend, holder_backend)

    assert ["qualifications", "RowExclusiveLock"] in relation_locks(backend),
           "C3-02: not established: the first writer is not parked after its INSERT"
  end

  # The subject of T-L7, T-L9 (a) and T-L10: the waiter, blocked by
  # `blocker`, holds no lock on the qualifications relation or its indexes,
  # waits at the lead FOR UPDATE, and completed no qualifications statement
  # (neither the Supersedes read nor the INSERT). On main the waiter is the
  # INSERT holding RowExclusiveLock on qualifications.
  defp assert_parked_before_lead!(task, blocker, label) do
    backend = backend_of(task)
    await_waiting!(task, blocker, label)
    held = qualification_locks(backend)

    assert held == [],
           "C3-02: #{label} waits holding no qualifications lock (no read, no INSERT): " <>
             short(held)

    query = waiting_statement(backend)
    assert query =~ @lead_lock, "C3-02: #{label} waits at the lead FOR UPDATE: #{short(query)}"
    touched = Enum.filter(statements(task.pid), &(&1 =~ @qualifications))

    assert touched == [],
           "C3-02: #{label} sent no qualifications statement before the lead: #{short(touched)}"
  end

  ## Outcome oracle

  # Bounded joins happened in the schedule; here: no deadlock, exactly one
  # writer commits, the other is a typed refusal (no constraint pinned),
  # lineage, lead state, and exact deltas (the loser wrote nothing).
  defp assert_outcome!(subject, before, results, oracle) do
    Enum.each(Map.values(results), &refute_deadlock!/1)
    loser = if oracle.winner == :r, do: :o, else: :r
    won = Map.fetch!(results, oracle.winner)
    lost = Map.fetch!(results, loser)

    assert match?({:ok, %Qualification{}}, won),
           "C3-02: exactly one writer commits (#{oracle.winner}): #{short(results)}"

    assert match?({:error, %Ash.Error.Invalid{}}, lost),
           "C3-02: #{loser} gets a typed refusal (section 4.6.4 set): #{short(lost)}"

    {:ok, row} = won
    assert_lineage!(subject, row)
    assert status(subject.lead) == oracle.status, "C3-02: the lead outcome is atomic"

    assert evidence_count(subject.lead) == before.evidence + 1,
           "C3-02: only the winner's evidence row was written"

    assert event_delta(before.events, event_counts(subject.lead.tenant_id)) == oracle.events,
           "C3-02: the winner's events only (the loser appended nothing)"
  end

  defp assert_lineage!(subject, row) do
    assert qualification_ids(subject.lead) == Enum.sort(subject.prior ++ [row.id]),
           "C3-02: the loser left no qualification"

    assert current(subject.lead) == row.id, "C3-02: the winner's row is the current row"
    assert_superseded!(subject.superseded, row)
  end

  defp assert_superseded!(nil, row), do: assert(row.supersedes_id == nil)

  defp assert_superseded!(superseded, row),
    do:
      assert(
        successors(superseded.id) == [row.id],
        "C3-02: X has exactly one successor, the winner"
      )

  defp refute_deadlock!(result) do
    text = inspect(result, limit: :infinity, printable_limit: :infinity)
    refute(text =~ "deadlock_detected" or text =~ "40P01", "C3-02: a deadlock: #{short(result)}")
  end

  ## Committed synthetic rows (main's APIs)

  defp world! do
    assert {:ok, tenant} = Audit.bootstrap(slug: "c302-lineage", name: "Synthetic C3-02")

    %{
      tenant: tenant,
      admin: AuditCase.human(:admin, tenant),
      reviewer: AuditCase.human(:reviewer, tenant),
      agent: AuditCase.system_actor(:agent_runtime, tenant),
      seeder: AuditCase.system_actor(:seeder, tenant),
      icp: SalesFixtures.active_icp!(tenant)
    }
  end

  # A seeded lead (source fixture) at a new account, driven to qualifying.
  defp qualifying_lead!(ctx) do
    contact = SalesFixtures.contact!(ctx.tenant)
    attrs = %{contact_id: contact.id, account_id: contact.account_id, source: :fixture}
    assert {:ok, lead} = Sales.seed_lead(attrs, actor: ctx.seeder)
    assert {:ok, lead} = Sales.update(lead, :assign, %{}, actor: ctx.reviewer)
    research_and_qualify!(ctx, lead)
  end

  defp research_and_qualify!(ctx, lead) do
    %{run: run} = SalesFixtures.run!(ctx.tenant)
    research = %{decision_id: SalesFixtures.decision!(ctx.tenant, run, lead, "research").id}
    assert {:ok, lead} = Sales.update(lead, :start_research, research, actor: ctx.agent)
    qualify = %{decision_id: SalesFixtures.decision!(ctx.tenant, run, lead, "qualify").id}
    assert {:ok, lead} = Sales.update(lead, :start_qualifying, qualify, actor: ctx.agent)
    lead
  end

  # research_test.exs:484-509: a disqualifying agent qualification X, the
  # reopen, back to qualifying, and fresh evidence for the next writer.
  defp reopened!(ctx) do
    lead = qualifying_lead!(ctx)
    first = evidence!(ctx, lead)

    assert {:ok, x} =
             Research.record_qualification(record_attrs(ctx, lead, first, %{qualified: false}),
               actor: ctx.agent
             )

    assert {:ok, lead} = Sales.fetch(Lead, lead.id, actor: ctx.admin)
    assert lead.status == :disqualified
    assert {:ok, lead} = Sales.update(lead, :reopen, %{}, actor: ctx.admin)
    lead = research_and_qualify!(ctx, lead)
    %{lead: lead, x: x, evidence: evidence!(ctx, lead)}
  end

  defp evidence!(ctx, lead) do
    %{artifact: artifact, run: run} = SalesFixtures.artifact!(ctx.tenant, lead)
    claim = SalesFixtures.claim!(ctx.tenant, artifact, run)
    decision = SalesFixtures.qualification_decision!(ctx.tenant, run, lead)
    %{run: run, claim: claim, decision: decision}
  end

  defp record_attrs(ctx, lead, evidence, overrides \\ %{}) do
    SalesFixtures.qualification_attrs(
      lead,
      ctx.icp,
      evidence.run,
      evidence.decision,
      [evidence.claim],
      overrides
    )
  end

  defp successor_attrs(ctx, subject),
    do: record_attrs(ctx, subject.lead, subject.evidence, %{supersedes_id: subject.x.id})

  # :same keeps the superseded outcome (qualified: false, moves nothing);
  # :flip sets qualified: true (refused by the qualifying state).
  defp override_attrs(lead, superseded, evidence, variant) do
    %{
      lead_id: lead.id,
      icp_definition_id: superseded.icp_definition_id,
      supersedes_id: superseded.id,
      qualified: variant == :flip,
      score: if(variant == :flip, do: 95, else: 30),
      criteria: %{
        company_size: :pass,
        industry: :fail,
        geography: :pass,
        persona: :unknown,
        trigger: :pass
      },
      confidence: 0.9,
      reason: "Synthetic C3-02 manual review.",
      output_schema_version: "qualification_result/1",
      evidence_claim_ids: claim_ids(evidence)
    }
  end

  defp claim_ids(nil), do: []
  defp claim_ids(evidence), do: [evidence.claim.id]

  defp record_fun(ctx, attrs),
    do: fn -> Research.record_qualification(attrs, actor: ctx.agent) end

  defp override_fun(ctx, attrs),
    do: fn -> Research.override_qualification(attrs, actor: ctx.reviewer) end

  ## Reads (test process, own connection)

  defp snapshot(lead),
    do: %{evidence: evidence_count(lead), events: event_counts(lead.tenant_id)}

  defp qualification_ids(lead) do
    %{rows: rows} =
      Repo.query!("SELECT id FROM qualifications WHERE lead_id = $1", [dump(lead.id)])

    rows |> Enum.map(fn [id] -> Ecto.UUID.load!(id) end) |> Enum.sort()
  end

  defp successors(id) do
    %{rows: rows} =
      Repo.query!("SELECT id FROM qualifications WHERE supersedes_id = $1", [dump(id)])

    Enum.map(rows, fn [successor] -> Ecto.UUID.load!(successor) end)
  end

  defp current(lead) do
    assert %{rows: [[id]]} =
             Repo.query!(
               """
               SELECT q.id FROM qualifications q
               WHERE q.lead_id = $1
                 AND NOT EXISTS (SELECT 1 FROM qualifications s WHERE s.supersedes_id = q.id)
               """,
               [dump(lead.id)]
             )

    Ecto.UUID.load!(id)
  end

  defp status(lead) do
    assert %{rows: [[status]]} =
             Repo.query!("SELECT status FROM leads WHERE id = $1", [dump(lead.id)])

    status
  end

  defp evidence_count(lead) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM qualification_evidences e
        JOIN qualifications q ON q.id = e.qualification_id
        WHERE q.lead_id = $1
        """,
        [dump(lead.id)]
      )

    count
  end

  defp event_counts(tenant_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT event_type, count(*) FROM audit_events WHERE tenant_id = $1 GROUP BY event_type",
        [dump(tenant_id)]
      )

    Map.new(rows, fn [type, count] -> {type, count} end)
  end

  defp event_delta(before, after_counts) do
    after_counts
    |> Enum.map(fn {type, count} -> {type, count - Map.get(before, type, 0)} end)
    |> Enum.reject(fn {_type, delta} -> delta == 0 end)
    |> Map.new()
  end

  defp dump(id), do: Ecto.UUID.dump!(id)

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

  ## Helpers added below the harness (read-only, bounded, same guarantees)

  # await_blocked!/2 for a waiter that may end without ever waiting:
  # bounded, until `task`'s backend is blocked by `blocker` on a lock; if
  # the task returns or exits first, it fails at once and says what the
  # writer did instead. On main that is the T-L10 invalid writer (a root R
  # while R0 is current, an override naming another lead's row): every
  # check before its INSERT is an unlocked read (`Supersedes` and
  # `QualificationRules` before_actions, `lib/sdr_agent/audit/changes/
  # supersedes.ex`, `lib/sdr_agent/research/changes/qualification_rules.ex`)
  # and it locks the lead only in `RecordOutcome`'s after_action, so it is
  # refused without waiting on the lead or on the first writer.
  defp await_waiting!(task, blocker, label) do
    deadline = System.monotonic_time(:millisecond) + @wait_ms
    poll_waiting(task, blocker, label, deadline)
  end

  defp poll_waiting(task, blocker, label, deadline) do
    backend = backend_of(task)

    %{rows: [[type, event, blockers]]} =
      Repo.query!(
        "SELECT wait_event_type, wait_event, pg_blocking_pids(pid) " <>
          "FROM pg_stat_activity WHERE pid = $1",
        [backend]
      )

    cond do
      type == "Lock" and blocker in blockers ->
        event

      ended = Task.yield(task, 0) ->
        flunk(ended_without_waiting(task, label, blocker, ended))

      System.monotonic_time(:millisecond) > deadline ->
        flunk("C3-02: #{backend} never waited on #{blocker} (#{inspect({type, event})})")

      true ->
        Process.sleep(20)
        poll_waiting(task, blocker, label, deadline)
    end
  end

  defp ended_without_waiting(task, label, blocker, {:ok, result}) do
    read = Enum.filter(statements(task.pid), &(&1 =~ @qualifications))

    "C3-02: #{label} returned without waiting on #{blocker}: it was refused " <>
      "before any lead lock (on main: by its unlocked reads, before its INSERT), " <>
      "not serialized behind the lead: #{short(result)}; its qualifications " <>
      "statements: #{short(read)}"
  end

  defp ended_without_waiting(_task, label, blocker, {:exit, reason}),
    do: "C3-02: #{label} exited before waiting on #{blocker}: #{short(reason)}"

  # The statement `backend` is currently running (it is blocked, so it is
  # the waiting statement).
  defp waiting_statement(backend) do
    assert %{rows: [[query]]} =
             Repo.query!("SELECT query FROM pg_stat_activity WHERE pid = $1", [backend])

    query
  end

  # Granted locks of `backend` on the qualifications relation or its indexes.
  defp qualification_locks(backend) do
    for [relation, mode] <- relation_locks(backend),
        relation =~ @qualification_relation,
        do: {relation, mode}
  end

  # The harness's park-after-pass seam (parked!/2, probe!/2, resume!/1,
  # advisory_ids/1, and call/3 through parked!/2) is not used here: section
  # 11 L schedules need no production seam. This reference keeps the
  # verbatim harness warning-free; it is never called.
  @doc false
  def __unused_harness__, do: [&parked!/2, &probe!/2, &resume!/1, &advisory_ids/1]
end
