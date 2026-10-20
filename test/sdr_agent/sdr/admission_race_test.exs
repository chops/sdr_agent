defmodule SdrAgent.SDR.AdmissionRaceTest do
  @moduledoc """
  C3-02 RED-3, plan r8 section 11 I [P] (T-I1..T-I12, T-I14): `admit_lead/2`
  against every concurrent writer of its identity keys, its settings and
  its definition, on independent physical connections with committed
  synthetic rows (packet section 6 "Admission order", "Both orders",
  "Suppression and admission, both commit orders"; section 9 race bullets,
  "Run settings" race and "Lock order of save vs snapshot"; plan sections
  2.6, 2.7, 4.3, 4.4, 7.2-7.4, 8.3).

    * T-I1, T-I2, T-I3..T-I5, T-I6, T-I7, T-I8, T-I11: both commit orders of
      two key holders. The first writer is parked right after its identity
      pass (`parked!/2`, the shared test-build seam
      `IdentityKeys.TestFaults.park_after_pass/2`); its pass record and its
      backend's granted advisory locks (`pg_locks`) are asserted to be its
      exact key ids (`IdentityKeys.id/3`); the second writer is shown
      waiting on it on an `advisory` lock; then the first commits and both
      outcomes are asserted. Each order is its own test.
    * T-I3..T-I5 run over the email, the email domain and the company
      domain, with the person absent before and existing, including the
      section 2.7 vectors `www.www.` (an email domain keyed with one strip)
      and `www.test` (a one-label-after-strip domain that stays a valid,
      keyable suppression), plus `WWW.<c>.Test.` as company input and the
      uncovered `www.<c>` value (same key, extra serialization only). This
      also discharges RED-2's deferred "both orders" part of T-J4
      (`outreach/suppression_keys_test.exs` moduledoc).
    * T-I8 includes the failing branch of T-M5's locked re-check (deferred by
      `sales/identity_writers_test.exs`): a database-administrator rename
      committed while the seed is parked after its pass.
    * T-I9 and T-I10 include the step-16 snapshot-refusal rollback
      obligation carried from RED-2 T-F13 (`sdr/admit_lead_test.exs`).
    * T-I12 and T-I14 are the bootstrap races of plan section 7.4.
    * T-I13 (bootstrap vs a matched reply) needs a matched delivery, demo
      data and the webhook worker: it is left to the author of
      `test/sdr_agent/outreach/webhook_handoff_race_test.exs`, which is
      told to include it. It is not in this file.

  Schedules (every one deterministic; no sleep is synchronization):
    * key holders: park, then `await_blocked!/2` == `"advisory"`, then
      resume;
    * row-lock schedules (no production seam): a `holder!/2` takes a row
      with raw SQL inside its own open transaction (or runs a real save
      there and holds it uncommitted), the writer is shown blocked on it
      with `await_blocked!/2`, `relation_locks/1` and its current
      statement (`pg_stat_activity.query`, `current_query/1`, a helper
      added below the harness), then `release!/1`;
    * raw writes committed from a contender while a writer is parked or
      blocked: `AuditCase.tamper!/2` inside an explicit `Repo.transaction`
      (a database-administrator rename) and
      `SettingsFixtures.withhold_offering!/1` (a raw, test-only delete of
      the offering profile revisions, triggers disabled). Neither takes an
      identity key, so neither waits on a parked writer.

  Why the T-F13 step-16 schedule is a row-lock schedule, not a park after
  the pass: the packet's step 8a pre-check runs after the step 5 key pass,
  so a profile removed while the admission is parked after its pass is
  refused by step 8a (that schedule is kept, as the 8a control, and it
  shows no head lock). To remove the profile between step 8a and the
  snapshot, the admission is held at step 9 (an existing account locked
  `FOR UPDATE` by a holder blocks its account `FOR SHARE`), after its trace
  shows the step 8a revision reads and before any INSERT or head lock; the
  removal commits; the holder releases; the snapshot build under the head
  refuses and the whole admission (its traced contact and lead INSERTs
  included) rolls back.

  Committed-row safety and exit paths are the RED-3 [P] harness's (copied
  verbatim below the tests): sandbox `:auto` mode restored to `:manual`;
  `preflight!/0` guards every subject, checks the database name and that
  no tenant exists, and registers the tenant-scoped cleanup before anything
  commits; every contender is unlinked under a test-owned Task.Supervisor
  and tracked (killed, `:DOWN` awaited) before the cleanup runs; holders
  and parked writers are bound to the test process; every wait is bounded;
  every result is checked for 40P01.

  RED form: structural. `preflight!/0` asserts the presence of
  `SDR.admit_lead/2`, `SDR.bootstrap_definitions/1`,
  `SDRAgent.fetch_definition/1`, `IdentityKeys.id/3` and
  `IdentityKeys.TestFaults.park_after_pass/2` before anything commits, so
  every test fails there on main. Input and outcome shapes, setup and the
  definition/offering prerequisites are those of `sdr/admit_lead_test.exs`.

  Interface names chosen here for review (beyond the RED-2 brief and the
  RED-3 harness):
    * a writer refused at a unique index after the identity wait (Account
      `:create`, Contact `:create`, Account `:update` rename, Lead `:seed`)
      is asserted only as `{:error, _}` that is not a 40P01; the shape is
      not pinned;
    * the Lead `:seed` locked re-check refusal is `{:error,
      %Ash.Error.Invalid{}}` carrying an `InvalidAttribute` with no value,
      its field not pinned (the plan names none); the override's refusal is
      on `:lead_id` (as `research/override_company_key_test.exs`); the
      `:reopen` refusal's field is not pinned (as
      `sales/identity_writers_test.exs`);
    * a successful `assign_lead/2` is `{:ok, _}`;
    * the admission's identity pass is the only pass it publishes, so the
      park seam parks it after that pass, before step 6.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.AuditCase
  alias SdrAgent.InboxConcurrencyFixtures
  alias SdrAgent.Outreach
  alias SdrAgent.Outreach.Locks
  alias SdrAgent.Repo
  alias SdrAgent.Research
  alias SdrAgent.Sales
  alias SdrAgent.SalesFixtures
  alias SdrAgent.SDR.SDRAgent
  alias SdrAgent.SettingsFixtures

  @moduletag timeout: 300_000

  @guards [
    {SdrAgent.SDR, :admit_lead, 2},
    {SdrAgent.SDR, :bootstrap_definitions, 1},
    {SdrAgent.SDR.SDRAgent, :fetch_definition, 1},
    {SdrAgent.Audit.IdentityKeys, :id, 3},
    {SdrAgent.Audit.IdentityKeys.TestFaults, :park_after_pass, 2}
  ]

  @sdr SdrAgent.SDR
  @keys SdrAgent.Audit.IdentityKeys
  @lookup SdrAgent.SDR.SDRAgent
  @admission SdrAgent.Sales.LeadAdmission

  @main_tables ~w(accounts contacts leads agent_runs oban_jobs operations run_settings_snapshots
                  agent_definitions suppressions audit_events)
  @tables ["lead_admissions" | @main_tables]

  @admitted_rows %{
    "leads" => 1,
    "lead_admissions" => 1,
    "agent_runs" => 1,
    "oban_jobs" => 1,
    "operations" => 1,
    "run_settings_snapshots" => 1
  }

  @nothing %{rows: %{}, events: %{}}

  # A row-lock waiter's wait event (never "advisory").
  @row_waits ["transactionid", "tuple"]

  @publication ~r/set_config\(\s*'sdr\.identity_pass'/
  @key_lock ~r/pg_advisory_xact_lock/
  @head_lock ~r/FROM "audit_chain_heads".*\bFOR UPDATE\b/s

  # {plan id, scenario, label}: section 2.7 vectors included.
  @suppression_cases [
    {"T-I3", :email_plain, "the email"},
    {"T-I3", :email_at_www_test, "an email at www.test"},
    {"T-I4", :email_domain_plain, "the email domain"},
    {"T-I4", :email_domain_www_www, "a www.www. email domain (stripped once)"},
    {"T-I4", :email_domain_www_test, "the www.test email domain"},
    {"T-I5", :company_plain, "the company domain"},
    {"T-I5", :company_www_input, "the company domain given as WWW.<c>.Test."},
    {"T-I5", :company_www_value, "a www.<c> value (same key, not covered)"}
  ]

  describe "T-I1 two admissions at one company" do
    for {first_kind, second_kind} <- [manual: :csv, csv: :manual] do
      test "T-I1 #{first_kind} first, #{second_kind} second: one admits, the other is active_target_exists" do
        preflight!()
        ctx = world!()
        domain = "i1-#{SalesFixtures.unique()}.test"
        first = input(ctx, unquote(first_kind), domain: domain)
        second = input(ctx, unquote(second_kind), domain: domain)
        before = snapshot()

        {won, lost} =
          both!(ctx, admit_fn(ctx, first), admit_fn(ctx, second), admission_keys(ctx, first))

        won = admitted!(won, first)
        lost = outcome!(lost, second, :active_target_exists)
        assert lost.admission.matched_lead_id == won.lead.id

        assert {lost.admission.account_id, lost.admission.contact_id} ==
                 {won.lead.account_id, nil}

        assert accounts_at(ctx, domain) == 1
        assert open_leads_at(won.lead.account_id) == 1

        assert_rows!(
          before,
          Map.merge(@admitted_rows, %{"accounts" => 1, "contacts" => 1, "lead_admissions" => 2})
        )
      end
    end
  end

  describe "T-I2 same-ref double submit" do
    for order <- [:requester_first, :other_admin_first] do
      @tag order: order
      test "T-I2 an identical double submit (#{order}): one admits, the other replays it", %{
        order: order
      } do
        preflight!()
        ctx = world!()
        other = AuditCase.new_human(:admin, ctx.tenant)
        {a, b} = order_admins(order, ctx.admin, other)

        input = input(ctx, :manual)
        before = snapshot()

        {first, second} =
          both!(
            ctx,
            fn -> admit(input, a) end,
            fn -> admit(input, b) end,
            admission_keys(ctx, input)
          )

        first = admitted!(first, input)
        assert first.admission.requested_by_user_id == a.id
        replay = replayed!(second, first)
        assert replay.run.id == first.run.id
        assert replay.admission.requested_by_user_id == a.id
        assert_rows!(before, admitted_rows(true, true))
      end
    end

    test "T-I2 a conflicting double submit of one ref: one admits, the other is :source_ref_conflict" do
      preflight!()
      ctx = world!()
      input = input(ctx, :manual)
      conflicting = put_in(input, [:person, :first_name], "Other")
      before = snapshot()

      {first, second} =
        both!(ctx, admit_fn(ctx, input), admit_fn(ctx, conflicting), admission_keys(ctx, input))

      admitted!(first, input)
      assert second == {:error, :source_ref_conflict}
      assert_rows!(before, admitted_rows(true, true))
    end
  end

  describe "T-I3..T-I5 admission vs suppression, both commit orders" do
    for {id, scenario, label} <- @suppression_cases,
        order <- [:suppression_first, :admission_first],
        person <- [:absent, :existing] do
      @tag scenario: scenario, order: order, person: person
      test "#{id} #{label}: #{order}, person #{person}", %{
        scenario: scenario,
        order: order,
        person: person
      } do
        preflight!()
        suppression_race!(world!(), scenario, order, person)
      end
    end
  end

  describe "T-I6 vs create_account and create_contact" do
    test "T-I6 create_account first: the admission adopts the committed account" do
      preflight!()
      ctx = world!()
      domain = "i6a-#{SalesFixtures.unique()}.test"
      input = input(ctx, :manual, domain: domain)
      create = fn -> Sales.create_account(account_attrs(domain), actor: ctx.admin) end

      {created, admitted} =
        both!(ctx, create, admit_fn(ctx, input), [key(ctx, :domain, domain)])

      assert match?({:ok, _}, created), "C3-02: create_account: #{short(created)}"
      {:ok, account} = created
      value = admitted!(admitted, input)
      refute value.admission.account_created
      assert value.lead.account_id == account.id
      assert accounts_at(ctx, domain) == 1
    end

    test "T-I6 admission first: create_account of the same domain is refused; one account" do
      preflight!()
      ctx = world!()
      domain = "i6b-#{SalesFixtures.unique()}.test"
      input = input(ctx, :manual, domain: domain)
      create = fn -> Sales.create_account(account_attrs(domain), actor: ctx.admin) end

      {admitted, created} =
        both!(ctx, admit_fn(ctx, input), create, admission_keys(ctx, input))

      value = admitted!(admitted, input)
      assert value.admission.account_created
      refused!(created)
      assert accounts_at(ctx, domain) == 1
    end

    test "T-I6 create_contact first: the admission adopts the committed contact" do
      preflight!()
      ctx = world!()
      account = account!(ctx, "i6c-#{SalesFixtures.unique()}.test")
      email = "pat.#{SalesFixtures.unique()}@#{account.domain}"
      input = input(ctx, :manual, domain: to_string(account.domain), email: email)
      create = fn -> Sales.create_contact(contact_attrs(account, email), actor: ctx.admin) end

      {created, admitted} = both!(ctx, create, admit_fn(ctx, input), [key(ctx, :email, email)])

      assert match?({:ok, _}, created), "C3-02: create_contact: #{short(created)}"
      {:ok, contact} = created
      value = admitted!(admitted, input)
      refute value.admission.account_created or value.admission.contact_created
      assert {value.lead.account_id, value.lead.contact_id} == {account.id, contact.id}
      assert contacts_with(ctx, email) == 1
    end

    test "T-I6 admission first: create_contact of the same email is refused; one contact" do
      preflight!()
      ctx = world!()
      account = account!(ctx, "i6d-#{SalesFixtures.unique()}.test")
      email = "pat.#{SalesFixtures.unique()}@#{account.domain}"
      input = input(ctx, :manual, domain: to_string(account.domain), email: email)
      create = fn -> Sales.create_contact(contact_attrs(account, email), actor: ctx.admin) end

      {admitted, created} = both!(ctx, admit_fn(ctx, input), create, admission_keys(ctx, input))

      value = admitted!(admitted, input)
      assert value.admission.contact_created
      assert value.lead.account_id == account.id
      refused!(created)
      assert contacts_with(ctx, email) == 1
    end
  end

  # The admission's company key is the rename's old key (A->B) or its new key
  # (B->A); the rename keys both.
  describe "T-I7 vs rename A->B and B->A" do
    test "T-I7 A->B, admission at A, rename first: the admission creates a new account at A" do
      preflight!()
      ctx = world!()
      %{a: a, b: b} = pair("i7a")
      x = account!(ctx, a)
      input = input(ctx, :manual, domain: a)

      {renamed, admitted} =
        both!(ctx, rename_fn(ctx, x, b), admit_fn(ctx, input), [
          key(ctx, :domain, a),
          key(ctx, :domain, b)
        ])

      assert match?({:ok, _}, renamed), "C3-02: rename: #{short(renamed)}"
      value = admitted!(admitted, input)
      assert value.admission.account_created
      refute value.lead.account_id == x.id
      assert domain_of(x) == b
    end

    test "T-I7 A->B, admission at A, admission first: admitted at the account, then renamed" do
      preflight!()
      ctx = world!()
      %{a: a, b: b} = pair("i7b")
      x = account!(ctx, a)
      input = input(ctx, :manual, domain: a)

      {admitted, renamed} =
        both!(ctx, admit_fn(ctx, input), rename_fn(ctx, x, b), admission_keys(ctx, input))

      value = admitted!(admitted, input)
      refute value.admission.account_created
      assert value.lead.account_id == x.id
      assert match?({:ok, _}, renamed), "C3-02: rename: #{short(renamed)}"
      assert domain_of(x) == b
      assert reread(ctx, value.lead).account_id == x.id
    end

    test "T-I7 B->A, admission at A, rename first: the admission adopts the renamed account" do
      preflight!()
      ctx = world!()
      %{a: a, b: b} = pair("i7c")
      y = account!(ctx, b)
      input = input(ctx, :manual, domain: a)

      {renamed, admitted} =
        both!(ctx, rename_fn(ctx, y, a), admit_fn(ctx, input), [
          key(ctx, :domain, b),
          key(ctx, :domain, a)
        ])

      assert match?({:ok, _}, renamed), "C3-02: rename: #{short(renamed)}"
      value = admitted!(admitted, input)
      refute value.admission.account_created
      assert value.lead.account_id == y.id
      assert accounts_at(ctx, a) == 1
    end

    test "T-I7 B->A, admission at A, admission first: a new account at A; the rename is refused" do
      preflight!()
      ctx = world!()
      %{a: a, b: b} = pair("i7d")
      y = account!(ctx, b)
      input = input(ctx, :manual, domain: a)

      {admitted, renamed} =
        both!(ctx, admit_fn(ctx, input), rename_fn(ctx, y, a), admission_keys(ctx, input))

      value = admitted!(admitted, input)
      assert value.admission.account_created
      refused!(renamed)
      assert domain_of(y) == b
      assert accounts_at(ctx, a) == 1
    end
  end

  describe "T-I8 vs Lead :seed" do
    test "T-I8 seed first: another person's admission at the company is active_target_exists" do
      preflight!()
      ctx = world!()
      e = existing!(ctx, "i8a-#{SalesFixtures.unique()}.test")
      input = input(ctx, :manual, domain: e.domain)

      {seeded, recorded} =
        both!(ctx, seed_fn(ctx, e.contact), admit_fn(ctx, input), [key(ctx, :domain, e.domain)])

      assert match?({:ok, _}, seeded), "C3-02: seed: #{short(seeded)}"
      {:ok, lead} = seeded
      value = outcome!(recorded, input, :active_target_exists)
      assert value.admission.matched_lead_id == lead.id
      assert open_leads_at(e.account.id) == 1
    end

    test "T-I8 admission first: the seed's second open lead at the company is refused" do
      preflight!()
      ctx = world!()
      e = existing!(ctx, "i8b-#{SalesFixtures.unique()}.test")
      input = input(ctx, :manual, domain: e.domain)

      {admitted, seeded} =
        both!(ctx, admit_fn(ctx, input), seed_fn(ctx, e.contact), admission_keys(ctx, input))

      value = admitted!(admitted, input)
      assert value.lead.account_id == e.account.id
      refused!(seeded)
      assert open_leads_at(e.account.id) == 1
      assert leads_of(e.contact.id) == 0
    end

    # T-M5's failing re-check branch (plan section 4.4 steps 1-4; section 2.6:
    # Lead :seed keys its account's current canonical_domain, Account :update
    # keys the old AND the new canonical domain). A rename through Account
    # :update would take the old key, which the parked seed holds, so it would
    # wait on the seed and could never commit between the seed's pass and its
    # account FOR SHARE. The failing branch therefore needs a rename that
    # takes no overlapping key: a raw database-administrator UPDATE of the
    # domain (`AuditCase.tamper!/2` in its own committed transaction, as
    # RED-2 T-L5 does in-process), committed from a contender while the seed
    # is parked after its pass. The seed has locked nothing yet, so the raw
    # write does not wait on it either.
    test "T-I8 (T-M5) a rename committed between the seed's pass and its account lock: typed conflict, nothing written" do
      preflight!()
      ctx = world!()
      e = existing!(ctx, "i8c-#{SalesFixtures.unique()}.test")
      moved = "c302canary#{SalesFixtures.unique()}.test"
      events = event_count(ctx, "sales.lead.created")

      parked = parked!(ctx.sup, seed_fn(ctx, e.contact))
      assert_owns!(parked, [key(ctx, :domain, e.domain)])

      renamed = alone!(ctx, fn -> raw_rename!(e.account, moved) end)
      assert match?({:ok, %{num_rows: 1}}, renamed), "C3-02: the raw rename: #{short(renamed)}"

      resume!(parked)
      result = await_result!(parked.task)
      no_deadlock!([result])
      typed_refusal!(result, nil, [e.domain, moved])

      trace = statements(parked.pid)
      publication = first_index(trace, @publication)
      assert publication, "C3-02: the seed's pass was not observed"

      refute trace |> Enum.drop(publication + 1) |> Enum.any?(&(&1 =~ @key_lock)),
             "C3-02: the conflict requests no further key"

      refute Enum.any?(trace, &(&1 =~ ~r/INSERT INTO "leads"/)),
             "C3-02: the re-check refuses before the INSERT"

      assert leads_of(e.contact.id) == 0
      assert event_count(ctx, "sales.lead.created") == events
      assert domain_of(e.account) == moved
    end
  end

  describe "T-I9 vs the first profile save" do
    test "T-I9 save first: the first profile commits while the admission is parked; it admits on it" do
      preflight!()
      ctx = world!(offering: false)
      input = input(ctx, :manual)
      parked = parked!(ctx.sup, admit_fn(ctx, input))
      assert_owns!(parked, admission_keys(ctx, input))

      # The save takes no identity key: it commits while the admission is
      # parked (a wait would exceed the bound).
      revision = alone!(ctx, fn -> SettingsFixtures.save_offering!(ctx.admin) end)

      resume!(parked)
      result = await_result!(parked.task)
      no_deadlock!([result])
      value = admitted!(result, input)
      assert snapshot_of(ctx, value.run).offering_profile_revision_id == revision.id
    end

    test "T-I9 admission first: an uncommitted first save leaves the admission refused, not blocked; the ref stays free" do
      preflight!()
      ctx = world!(offering: false)
      input = input(ctx, :manual)
      %{holder: save, revision_id: revision_id} = hold_save!(ctx, %{})
      before = snapshot()

      # Returned while the save still holds its uncommitted revision and the
      # chain head: the step 8a pre-check reads committed revisions only.
      refused = alone!(ctx, admit_fn(ctx, input))

      assert refused == {:error, {:settings_incomplete, [:offering_profile]}},
             "C3-02: got #{short(refused)}"

      assert changes(before) == @nothing
      assert admissions_for(input.source_ref) == 0

      release!(save)
      value = admitted!(alone!(ctx, admit_fn(ctx, input)), input)
      assert snapshot_of(ctx, value.run).offering_profile_revision_id == revision_id
    end

    # Control for the schedule below: parked after its pass (step 5), the
    # admission has not yet run its step 8a pre-check, so a removal then is
    # refused by step 8a, before the head.
    test "T-I9 the profile removed after the pass: step 8a refuses before the head, nothing written" do
      preflight!()
      ctx = world!()
      input = input(ctx, :manual)
      parked = parked!(ctx.sup, admit_fn(ctx, input))
      assert_owns!(parked, admission_keys(ctx, input))
      before = snapshot()

      assert alone!(ctx, fn -> SettingsFixtures.withhold_offering!(ctx.tenant.id) end)

      resume!(parked)
      result = await_result!(parked.task)
      no_deadlock!([result])
      assert result == {:error, {:settings_incomplete, [:offering_profile]}}, short(result)
      assert changes(before) == @nothing
      refute first_index(statements(parked.pid), @head_lock), "C3-02: 8a refuses before the head"
    end

    # The T-F13 obligation (RED-2 `sdr/admit_lead_test.exs`, Codex 480e1baf
    # important 2): step 16's snapshot refusal rolls back the whole
    # admission. See the moduledoc for why the admission is held at step 9.
    test "T-I9 (T-F13) the profile removed after the pre-check: step 16 refuses; the whole admission writes nothing" do
      preflight!()
      ctx = world!()
      e = existing_account!(ctx, "i9-#{SalesFixtures.unique()}.test")
      input = input(ctx, :manual, domain: e.domain)
      holder = holder!(ctx.sup, fn -> lock_account!(e.account.id) end)
      before = snapshot()

      admission = contender!(ctx.sup, admit_fn(ctx, input))
      backend = backend_of(admission)
      assert await_blocked!(backend, holder.backend) in @row_waits
      assert current_query(backend) =~ ~r/FROM "accounts".*\bFOR SHARE\b/s
      prior = statements(admission.pid)

      assert first_index(prior, ~r/FROM "settings_revisions"/),
             "C3-02: the step 8a pre-check ran before step 9"

      refute first_index(prior, ~r/^\s*INSERT INTO/), "C3-02: nothing was written before step 9"
      refute first_index(prior, @head_lock), "C3-02: the head is not taken before step 9"

      assert alone!(ctx, fn -> SettingsFixtures.withhold_offering!(ctx.tenant.id) end)
      release!(holder)
      result = await_result!(admission)
      no_deadlock!([result])

      assert result == {:error, {:settings_incomplete, [:offering_profile]}},
             "C3-02: the snapshot refusal returns the closed reason: #{short(result)}"

      trace = prior ++ statements(admission.pid)
      assert first_index(trace, @head_lock), "C3-02: the refusal came from the snapshot build"

      assert first_index(trace, ~r/INSERT INTO "leads"/),
             "C3-02: the lead was written before the snapshot refused"

      assert changes(before) == @nothing,
             "C3-02: no account, contact, admission, lead, run, job, operation, snapshot, " <>
               "signal or success event survives the refusal"

      assert admissions_for(input.source_ref) == 0
      assert contacts_with(ctx, input.person.email) == 0
    end
  end

  # Packet section 6 "Both orders" and section 9 "Lock order of save vs
  # snapshot": the save locks the current revision FOR NO KEY UPDATE, then
  # appends under the head; the snapshot takes FOR KEY SHARE on that
  # revision (its composite foreign key) under the head. The two modes are
  # compatible; FOR UPDATE (the negative control) is not.
  describe "T-I10 save vs snapshot" do
    test "T-I10 granted at once: the snapshot's KEY SHARE does not wait on a revision FOR NO KEY UPDATE" do
      preflight!()
      ctx = world!()
      editor = holder!(ctx.sup, fn -> lock_revision_no_key!(ctx.offering.id) end)
      assert ["settings_revisions", "RowShareLock"] in relation_locks(editor.backend)
      input = input(ctx, :manual)

      # Returned while the editor still holds the revision: no wait.
      value = admitted!(alone!(ctx, admit_fn(ctx, input)), input)
      assert snapshot_of(ctx, value.run).offering_profile_revision_id == ctx.offering.id
      release!(editor)
    end

    # Admission holds the head first. A holder locks the definition row FOR
    # UPDATE, so the admission stops at its run INSERT's definition KEY SHARE,
    # after the head and after its snapshot (BuildSettingsSnapshot is the
    # run's before_action). The editor then takes the revision FOR NO KEY
    # UPDATE (granted beside the snapshot's KEY SHARE) and waits only at the
    # head: editor -> admission -> holder.
    test "T-I10 admission holds the head: the editor holds the revision and waits only at the head; both commit" do
      preflight!()
      ctx = world!()
      gate = holder!(ctx.sup, fn -> lock_definition!(ctx.definition.id) end)
      input = input(ctx, :manual)

      admission = contender!(ctx.sup, admit_fn(ctx, input))
      adm = backend_of(admission)
      assert await_blocked!(adm, gate.backend) in @row_waits
      assert current_query(adm) =~ ~r/INSERT INTO "agent_runs"/
      held = relation_locks(adm)
      assert ["audit_chain_heads", "RowShareLock"] in held, "C3-02: the admission holds the head"
      assert ["run_settings_snapshots", "RowExclusiveLock"] in held, "C3-02: its snapshot exists"
      assert ["settings_revisions", "RowShareLock"] in held, "C3-02: its KEY SHARE is held"

      editor =
        contender!(ctx.sup, fn ->
          SettingsFixtures.save_offering!(ctx.admin, %{name: "Example Widgets Planner"})
        end)

      ed = backend_of(editor)
      assert await_blocked!(ed, adm) in @row_waits, "C3-02: wait chain editor -> admission"
      assert current_query(ed) =~ @head_lock, "C3-02: the editor waits only at the head"

      assert first_index(
               statements(editor.pid),
               ~r/FROM "settings_revisions".*FOR NO KEY UPDATE/s
             ),
             "C3-02: the editor's FOR NO KEY UPDATE was granted beside the KEY SHARE"

      release!(gate)
      result = await_result!(admission)
      saved = await_result!(editor)
      no_deadlock!([result, saved])
      value = admitted!(result, input)
      assert snapshot_of(ctx, value.run).offering_profile_revision_id == ctx.offering.id
      refute saved.id == ctx.offering.id
      assert SettingsFixtures.latest_number(ctx.tenant.id, :offering_profile) == 2
    end

    test "T-I10 the save holds the head: the admission waits at the head, then snapshots the new revision" do
      preflight!()
      ctx = world!()
      %{holder: save, revision_id: newer} = hold_save!(ctx, %{name: "Example Widgets Planner"})
      input = input(ctx, :manual)

      admission = contender!(ctx.sup, admit_fn(ctx, input))
      adm = backend_of(admission)
      assert await_blocked!(adm, save.backend) in @row_waits
      assert current_query(adm) =~ @head_lock, "C3-02: the admission waits at the head"

      refute first_index(statements(admission.pid), ~r/INSERT INTO "run_settings_snapshots"/),
             "C3-02: no snapshot before the head"

      release!(save)
      result = await_result!(admission)
      no_deadlock!([result])
      value = admitted!(result, input)
      assert snapshot_of(ctx, value.run).offering_profile_revision_id == newer
    end

    # Negative control: the evidence above is not vacuous. A revision held
    # FOR UPDATE (a mode no C4 or C3 writer takes) conflicts with FOR KEY
    # SHARE, so the same admission is shown blocked at its snapshot INSERT on
    # that very revision; FOR NO KEY UPDATE (the editor's mode) is what makes
    # the first case granted at once.
    test "T-I10 (negative control) a revision FOR UPDATE blocks the snapshot's KEY SHARE" do
      preflight!()
      ctx = world!()
      blocker = holder!(ctx.sup, fn -> lock_revision_update!(ctx.offering.id) end)
      input = input(ctx, :manual)

      admission = contender!(ctx.sup, admit_fn(ctx, input))
      adm = backend_of(admission)
      assert await_blocked!(adm, blocker.backend) in @row_waits
      assert current_query(adm) =~ ~r/INSERT INTO "run_settings_snapshots"/

      release!(blocker)
      result = await_result!(admission)
      no_deadlock!([result])
      value = admitted!(result, input)
      assert snapshot_of(ctx, value.run).offering_profile_revision_id == ctx.offering.id
    end
  end

  describe "T-I11 vs :reopen and override" do
    test "T-I11 reopen first: another person's admission at the company is active_target_exists" do
      preflight!()
      ctx = world!()
      s = disqualified!(ctx)
      input = input(ctx, :manual, domain: s.domain)

      {reopened, recorded} =
        both!(ctx, reopen_fn(ctx, s.lead), admit_fn(ctx, input), [key(ctx, :domain, s.domain)])

      assert match?({:ok, %{status: :assigned}}, reopened), "C3-02: reopen: #{short(reopened)}"
      value = outcome!(recorded, input, :active_target_exists)
      assert value.admission.matched_lead_id == s.lead.id
    end

    test "T-I11 admission first: the reopen is refused while the admitted lead is open" do
      preflight!()
      ctx = world!()
      s = disqualified!(ctx)
      input = input(ctx, :manual, domain: s.domain)

      {admitted, reopened} =
        both!(ctx, admit_fn(ctx, input), reopen_fn(ctx, s.lead), admission_keys(ctx, input))

      value = admitted!(admitted, input)
      assert value.lead.account_id == s.account.id
      typed_refusal!(reopened, nil, [s.domain])
      assert reread(ctx, s.lead).status == :disqualified
    end

    test "T-I11 override first: another person's admission at the company is active_target_exists" do
      preflight!()
      ctx = world!()
      s = disqualified!(ctx)
      input = input(ctx, :manual, domain: s.domain)

      {overridden, recorded} =
        both!(ctx, override_fn(ctx, s), admit_fn(ctx, input), [key(ctx, :domain, s.domain)])

      assert match?({:ok, _}, overridden), "C3-02: override: #{short(overridden)}"
      assert reread(ctx, s.lead).status == :qualified
      value = outcome!(recorded, input, :active_target_exists)
      assert value.admission.matched_lead_id == s.lead.id
    end

    test "T-I11 admission first: the re-opening override is refused while the admitted lead is open" do
      preflight!()
      ctx = world!()
      s = disqualified!(ctx)
      input = input(ctx, :manual, domain: s.domain)

      {admitted, overridden} =
        both!(ctx, admit_fn(ctx, input), override_fn(ctx, s), admission_keys(ctx, input))

      admitted!(admitted, input)
      typed_refusal!(overridden, :lead_id, [s.domain])
      assert reread(ctx, s.lead).status == :disqualified
      assert qualifications_of(s.lead) == 1, "C3-02: the refused override wrote no row"
    end
  end

  # Plan section 7.4: the holder stands in for a bootstrap's registration
  # transaction (`SDRAgent.register/1`, the registration bootstrap_definitions/1
  # runs, held uncommitted).
  describe "T-I12 bootstrap vs admission or assignment" do
    test "T-I12 an uncommitted registration does not block the admission's lookup; after it commits, it admits" do
      preflight!()
      ctx = world!(definition: false)
      input = input(ctx, :manual)
      registration = holder!(ctx.sup, fn -> register!(ctx.tenant) end)
      before = snapshot()

      # Returned while the registration is uncommitted: not blocked.
      task = contender!(ctx.sup, admit_fn(ctx, input))
      refused = await_result!(task)
      no_deadlock!([refused])
      assert refused == {:error, :agent_definition_unavailable}, "C3-02: got #{short(refused)}"
      assert changes(before) == @nothing
      assert admissions_for(input.source_ref) == 0

      refute first_index(statements(task.pid), ~r/INSERT INTO "agent_definitions"/),
             "C3-02: the admission never registers"

      release!(registration)
      assert match?({:ok, _}, fetch_definition(ctx.tenant))
      admitted!(alone!(ctx, admit_fn(ctx, input)), input)
    end

    test "T-I12 an uncommitted registration does not block assign_lead's lookup; after it commits, it assigns" do
      preflight!()
      ctx = world!(definition: false)
      e = existing!(ctx, "i12-#{SalesFixtures.unique()}.test")
      assert {:ok, lead} = seed_fn(ctx, e.contact).()
      registration = holder!(ctx.sup, fn -> register!(ctx.tenant) end)
      before = snapshot(@main_tables)
      assign = fn -> @sdr.assign_lead(lead, campaign_id: ctx.campaign.id, actor: ctx.admin) end

      task = contender!(ctx.sup, assign)
      refused = await_result!(task)
      no_deadlock!([refused])
      assert refused == {:error, :agent_definition_unavailable}, "C3-02: got #{short(refused)}"
      assert changes(before, @main_tables) == @nothing
      assert reread(ctx, lead).status == :new

      refute first_index(statements(task.pid), ~r/INSERT INTO "agent_definitions"/),
             "C3-02: assign_lead never registers"

      release!(registration)
      assigned = alone!(ctx, assign)
      assert match?({:ok, _}, assigned), "C3-02: assign_lead: #{short(assigned)}"
      assert reread(ctx, lead).status == :assigned
    end
  end

  describe "T-I14 bootstrap vs bootstrap" do
    test "T-I14 the loser re-reads after its transaction ended and accepts the validated winner" do
      preflight!()
      ctx = world!(definition: false)
      owner = self()

      winner =
        holder!(ctx.sup, fn ->
          definition = register!(ctx.tenant)
          send(owner, {:c302_winner, definition.id})
        end)

      assert_received {:c302_winner, winner_id}

      loser = contender!(ctx.sup, fn -> bootstrap_definitions(ctx.tenant) end)
      assert await_blocked!(backend_of(loser), winner.backend) in @row_waits
      release!(winner)
      result = await_result!(loser)
      no_deadlock!([result])

      assert match?({:ok, %{id: ^winner_id}}, result),
             "C3-02: the loser returns the winner: #{short(result)}"

      {:ok, definition} = result
      assert_valid!(definition, ctx.tenant.id)
      assert registered_events(ctx.tenant.id) == 1, "C3-02: the loser appended no event"
      assert_reread_outside!(statements(loser.pid))
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

  # ---------------------------------------------------------------------
  # File-specific helpers (below the harness, within its guarantees: every
  # process they start is a harness contender, holder or parked writer).
  # ---------------------------------------------------------------------

  ## Two key holders, both orders

  # Parks `first` right after its identity pass, starts `second`, proves
  # that `second` waits on `first` for an advisory lock, then lets `first`
  # commit and joins both (bounded). Returns `{first_result, second_result}`.
  defp both!(ctx, first, second, first_keys) do
    parked = parked!(ctx.sup, first)
    assert_owns!(parked, first_keys)
    waiter = contender!(ctx.sup, second)

    assert await_blocked!(backend_of(waiter), parked.backend) == "advisory",
           "C3-02: the second writer must wait on the first's identity key"

    resume!(parked)
    results = {await_result!(parked.task), await_result!(waiter)}
    no_deadlock!(Tuple.to_list(results))
    results
  end

  # The parked writer's pass record and its backend's granted advisory
  # locks are its exact key ids; it has no transaction id yet (supporting
  # witness that the pass precedes every row lock and write, section 2.6).
  defp assert_owns!(parked, expected) do
    expected = MapSet.new(expected)

    assert MapSet.new(parked.ids) == expected,
           "C3-02: the parked pass must publish exactly the writer's keys"

    assert MapSet.subset?(expected, advisory_ids(parked.backend)),
           "C3-02: the parked backend must hold every key (pg_locks)"

    xid =
      probe!(parked, fn -> Repo.query!("SELECT pg_current_xact_id_if_assigned()::text").rows end)

    assert xid == [[nil]], "C3-02: the pass must precede every row lock and write"
  end

  # One contender, joined at once (bounded).
  defp alone!(ctx, fun) do
    result = await_result!(contender!(ctx.sup, fun))
    no_deadlock!([result])
    result
  end

  defp no_deadlock!(results) do
    for result <- results do
      refute inspect(result, limit: :infinity, printable_limit: :infinity) =~
               ~r/deadlock_detected|40P01/,
             "C3-02: a contender failed with a deadlock (40P01)"
    end

    :ok
  end

  defp order_admins(:requester_first, admin, other), do: {admin, other}
  defp order_admins(:other_admin_first, admin, other), do: {other, admin}

  ## World (committed rows, built with main's APIs after preflight!/0)

  defp world!(opts \\ []) do
    tenant = AuditCase.bootstrap!()
    admin = AuditCase.human(:admin, tenant)
    campaign = SalesFixtures.active_campaign!(tenant)
    offering = if Keyword.get(opts, :offering, true), do: SettingsFixtures.save_offering!(admin)
    definition = if Keyword.get(opts, :definition, true), do: definitions!(tenant)

    %{
      tenant: tenant,
      admin: admin,
      campaign: campaign,
      offering: offering,
      definition: definition,
      sup: supervisor!()
    }
  end

  defp account_attrs(domain), do: SalesFixtures.account_attrs(%{domain: domain})
  defp contact_attrs(account, email), do: SalesFixtures.contact_attrs(account, %{email: email})

  defp account!(ctx, domain) do
    assert {:ok, account} = Sales.create_account(account_attrs(domain), actor: ctx.admin)
    account
  end

  defp existing_account!(ctx, domain) do
    account = account!(ctx, domain)
    %{account: account, domain: to_string(account.domain)}
  end

  defp existing!(ctx, domain) do
    %{account: account} = e = existing_account!(ctx, domain)
    contact = SalesFixtures.contact!(ctx.tenant, account)
    Map.merge(e, %{contact: contact, email: to_string(contact.email)})
  end

  defp pair(label) do
    n = SalesFixtures.unique()
    %{a: "#{label}-a-#{n}.test", b: "#{label}-b-#{n}.test"}
  end

  ## Writers

  defp admit(input, actor), do: call(@sdr, :admit_lead, [input, [actor: actor]])
  defp admit_fn(ctx, input), do: fn -> admit(input, ctx.admin) end

  defp rename_fn(ctx, account, domain),
    do: fn -> Sales.update(account, :update, %{domain: domain}, actor: ctx.admin) end

  defp seed_fn(ctx, contact) do
    seeder = AuditCase.system_actor(:seeder, ctx.tenant)

    fn ->
      Sales.seed_lead(
        %{
          id: Ecto.UUID.generate(),
          contact_id: contact.id,
          account_id: contact.account_id,
          source: :fixture
        },
        actor: seeder
      )
    end
  end

  defp reopen_fn(ctx, lead), do: fn -> Sales.update(lead, :reopen, %{}, actor: ctx.admin) end

  defp override_fn(ctx, subject) do
    reviewer = AuditCase.human(:reviewer, ctx.tenant)
    attrs = requalify_attrs(subject)
    fn -> Research.override_qualification(attrs, actor: reviewer) end
  end

  # A re-opening override (the superseded qualification disqualified the
  # lead; this one qualifies it), as `research/override_company_key_test.exs`.
  defp requalify_attrs(subject) do
    %{
      lead_id: subject.lead.id,
      icp_definition_id: subject.qualification.icp_definition_id,
      supersedes_id: subject.qualification.id,
      qualified: true,
      score: 95,
      criteria: %{
        company_size: :pass,
        industry: :pass,
        geography: :pass,
        persona: :pass,
        trigger: :pass
      },
      confidence: 0.9,
      reason: "Fits the ICP after manual review.",
      output_schema_version: "qualification_result/1",
      evidence_claim_ids: [subject.claim.id]
    }
  end

  # A database-administrator rename (test-only raw SQL, triggers disabled):
  # it takes no identity key.
  defp raw_rename!(account, domain) do
    Repo.transaction(fn ->
      AuditCase.tamper!("UPDATE accounts SET domain = $1 WHERE id = $2", [
        domain,
        uuid(account.id)
      ])
    end)
  end

  # A disqualified lead at a new account (the path of
  # `sdr/admit_lead_test.exs` `qualified!/3`, on a seeded lead).
  defp disqualified!(ctx) do
    tenant = ctx.tenant
    agent = AuditCase.system_actor(:agent_runtime, tenant)
    e = existing!(ctx, "i11-#{SalesFixtures.unique()}.test")
    assert {:ok, lead} = seed_fn(ctx, e.contact).()
    %{run: run} = SalesFixtures.run!(tenant)
    reviewer = AuditCase.human(:reviewer, tenant)
    assert {:ok, lead} = Sales.update(lead, :assign, %{}, actor: reviewer)
    research = %{decision_id: SalesFixtures.decision!(tenant, run, lead, "research").id}
    assert {:ok, lead} = Sales.update(lead, :start_research, research, actor: agent)
    qualify = %{decision_id: SalesFixtures.decision!(tenant, run, lead, "qualify").id}
    assert {:ok, lead} = Sales.update(lead, :start_qualifying, qualify, actor: agent)
    %{qualification: qualification, claim: claim} = disqualify!(ctx, lead)
    lead = reread(ctx, lead)
    assert lead.status == :disqualified
    Map.merge(e, %{lead: lead, qualification: qualification, claim: claim})
  end

  defp disqualify!(ctx, lead) do
    tenant = ctx.tenant
    %{artifact: artifact, run: run} = SalesFixtures.artifact!(tenant, lead)
    claim = SalesFixtures.claim!(tenant, artifact, run)
    decision = SalesFixtures.qualification_decision!(tenant, run, lead)
    icp = SalesFixtures.active_icp!(tenant)

    attrs =
      SalesFixtures.qualification_attrs(lead, icp, run, decision, [claim], %{qualified: false})

    agent = AuditCase.system_actor(:agent_runtime, tenant)
    assert {:ok, qualification} = Research.record_qualification(attrs, actor: agent)
    %{qualification: qualification, claim: claim}
  end

  ## Suppression races (T-I3..T-I5)

  defp suppression_race!(ctx, scenario, order, person) do
    s = suppression_case(scenario, SalesFixtures.unique())
    new? = person == :absent
    if !new?, do: existing_person!(ctx, s)
    input = input(ctx, :manual, domain: s.input_domain, email: s.email)
    suppress = fn -> Outreach.suppress(%{scope: s.scope, value: s.value}, actor: ctx.admin) end
    before = snapshot()

    {suppressed, admission} = schedule_suppression!(ctx, order, suppress, input, s)
    assert match?({:ok, _}, suppressed), "C3-02: the suppression: #{short(suppressed)}"
    suppression_outcome!(ctx, {order, s.expected}, admission, input, before, new?)
  end

  defp schedule_suppression!(ctx, :suppression_first, suppress, input, s),
    do: both!(ctx, suppress, admit_fn(ctx, input), [key(ctx, s.scope, s.value)])

  defp schedule_suppression!(ctx, :admission_first, suppress, input, _s) do
    {admission, suppressed} =
      both!(ctx, admit_fn(ctx, input), suppress, admission_keys(ctx, input))

    {suppressed, admission}
  end

  # Suppression first: the admission waited at its key pass, then saw the
  # suppression: `suppressed`, nothing else created.
  defp suppression_outcome!(_ctx, {:suppression_first, scope}, result, input, before, _new?)
       when scope in [:email, :domain] do
    value = outcome!(result, input, :suppressed)
    assert value.admission.suppression_scope == scope
    refute value.admission.account_created or value.admission.contact_created
    assert_rows!(before, %{"lead_admissions" => 1, "suppressions" => 1})
  end

  # Admission first: the suppression waited at its key, then its
  # ApplySuppression saw the new contact and stopped the new lead in the same
  # transaction.
  defp suppression_outcome!(ctx, {:admission_first, scope}, result, input, before, new?)
       when scope in [:email, :domain] do
    value = admitted!(result, input)

    assert reread(ctx, value.lead).status == :stopped,
           "C3-02: the suppression must stop the newly admitted lead"

    assert_rows!(before, Map.put(admitted_rows(new?, new?), "suppressions", 1))
  end

  # Same key, no coverage (`www.<c>` covers neither `c` nor an email at a
  # mail host): serialized in both orders, admitted, the lead stays open.
  defp suppression_outcome!(ctx, {_order, :uncovered}, result, input, before, new?) do
    value = admitted!(result, input)
    assert reread(ctx, value.lead).status == :assigned, "C3-02: www.<c> does not cover c"
    assert_rows!(before, Map.put(admitted_rows(new?, new?), "suppressions", 1))
  end

  # {scope, value, account domain (stored form), email, expected scope or
  # :uncovered, admission company input}.
  defp suppression_case(:email_plain, n) do
    d = "i3-#{n}.test"
    email = "pat.#{n}@#{d}"
    sc(:email, email, d, email, :email)
  end

  defp suppression_case(:email_at_www_test, n) do
    email = "pat.#{n}@www.test"
    sc(:email, email, "i3w-#{n}.test", email, :email)
  end

  defp suppression_case(:email_domain_plain, n) do
    host = "mail-i4-#{n}.test"
    sc(:domain, host, "i4-#{n}.test", "pat.#{n}@#{host}", :domain)
  end

  # Key preimage www.mail-i4ww-<n>.test for both (stripped once).
  defp suppression_case(:email_domain_www_www, n) do
    host = "www.www.mail-i4ww-#{n}.test"
    sc(:domain, host, "i4ww-#{n}.test", "pat.#{n}@#{host}", :domain)
  end

  # Key preimage test for both; www.test stays a valid suppression.
  defp suppression_case(:email_domain_www_test, n),
    do: sc(:domain, "www.test", "i4wt-#{n}.test", "pat.#{n}@www.test", :domain)

  defp suppression_case(:company_plain, n) do
    d = "i5-#{n}.test"
    sc(:domain, d, d, "pat.#{n}@mail-i5-#{n}.test", :domain)
  end

  defp suppression_case(:company_www_input, n) do
    d = "i5w-#{n}.test"
    sc(:domain, d, d, "pat.#{n}@mail-i5w-#{n}.test", :domain, "WWW.I5W-#{n}.Test.")
  end

  defp suppression_case(:company_www_value, n) do
    d = "i5u-#{n}.test"
    sc(:domain, "www.#{d}", d, "pat.#{n}@mail-i5u-#{n}.test", :uncovered)
  end

  defp sc(scope, value, account_domain, email, expected, input_domain \\ nil) do
    %{
      scope: scope,
      value: value,
      account_domain: account_domain,
      input_domain: input_domain || account_domain,
      email: email,
      expected: expected
    }
  end

  defp existing_person!(ctx, s) do
    account = account!(ctx, s.account_domain)

    assert {:ok, _contact} =
             Sales.create_contact(contact_attrs(account, s.email), actor: ctx.admin)
  end

  ## Settings holders and row locks (T-I9, T-I10)

  # A real save (`SettingsFixtures.save_offering!/2`) completed inside a
  # holder's open transaction: it holds its uncommitted revision, the
  # current revision FOR NO KEY UPDATE (a successor) and the chain head.
  defp hold_save!(ctx, overrides) do
    owner = self()

    holder =
      holder!(ctx.sup, fn ->
        revision = SettingsFixtures.save_offering!(ctx.admin, overrides)
        send(owner, {:c302_saved, revision.id})
      end)

    assert_received {:c302_saved, revision_id}
    %{holder: holder, revision_id: revision_id}
  end

  defp lock_account!(id),
    do:
      assert(
        %{num_rows: 1} =
          Repo.query!("SELECT 1 FROM accounts WHERE id = $1 FOR UPDATE", [uuid(id)])
      )

  defp lock_revision_no_key!(id),
    do:
      assert(
        %{num_rows: 1} =
          Repo.query!("SELECT 1 FROM settings_revisions WHERE id = $1 FOR NO KEY UPDATE", [
            uuid(id)
          ])
      )

  defp lock_revision_update!(id),
    do:
      assert(
        %{num_rows: 1} =
          Repo.query!("SELECT 1 FROM settings_revisions WHERE id = $1 FOR UPDATE", [uuid(id)])
      )

  defp lock_definition!(id),
    do:
      assert(
        %{num_rows: 1} =
          Repo.query!("SELECT 1 FROM agent_definitions WHERE id = $1 FOR UPDATE", [uuid(id)])
      )

  defp snapshot_of(ctx, run),
    do: SettingsFixtures.snapshot_of!(run, AuditCase.system_actor(:agent_runtime, ctx.tenant))

  # The statement `backend` is running (or waiting in).
  defp current_query(backend) do
    %{rows: [[query]]} =
      Repo.query!("SELECT query FROM pg_stat_activity WHERE pid = $1", [backend])

    query
  end

  ## Definitions (T-I12, T-I14)

  defp register!(tenant) do
    assert {:ok, definition} = SDRAgent.register(tenant.id)
    definition
  end

  defp bootstrap_definitions(tenant), do: call(@sdr, :bootstrap_definitions, [tenant.id])
  defp fetch_definition(tenant), do: call(@lookup, :fetch_definition, [tenant.id])

  defp definitions!(tenant) do
    result = bootstrap_definitions(tenant)
    assert match?({:ok, _}, result), "C3-02: bootstrap_definitions/1: #{short(result)}"
    {:ok, definition} = result
    definition
  end

  defp assert_valid!(definition, tenant_id) do
    assert {definition.tenant_id, definition.name, definition.version, definition.status} ==
             {tenant_id, "SDRAgent", SDRAgent.version(), :active}

    assert definition.definition_sha256 == Canonical.sha256(SDRAgent.definition_body()),
           "C3-02: the winner carries the hash of current code"
  end

  # The loser's trace: its failing INSERT, then the end of its transaction
  # (rollback, no commit), then the re-read, with no transaction begun in
  # between.
  defp assert_reread_outside!(trace) do
    insert = first_index(trace, ~r/INSERT INTO "agent_definitions"/)
    assert insert, "C3-02: the loser's INSERT was not observed"
    ended = index_after(trace, insert, ~r/^\s*rollback\s*$/i)
    assert ended, "C3-02: the loser's transaction must end after its failing INSERT"

    refute trace |> Enum.slice(insert..ended) |> Enum.any?(&(&1 =~ ~r/^\s*commit\s*$/i)),
           "C3-02: the loser's transaction did not commit"

    reread = index_after(trace, ended, ~r/FROM "agent_definitions"/)
    assert reread, "C3-02: the re-read must follow the end of the loser's transaction"

    refute trace |> Enum.slice(ended..reread) |> Enum.any?(&(&1 =~ ~r/^\s*begin\s*$/i)),
           "C3-02: the re-read runs outside a transaction"
  end

  defp index_after(statements, from, pattern) do
    case statements |> Enum.drop(from + 1) |> Enum.find_index(&(&1 =~ pattern)) do
      nil -> nil
      offset -> from + 1 + offset
    end
  end

  defp registered_events(tenant_id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM audit_events WHERE tenant_id = $1 " <>
          "AND event_type = 'agents.definition.registered'",
        [uuid(tenant_id)]
      )

    count
  end

  ## Inputs (the shapes of `sdr/admit_lead_test.exs`)

  defp input(ctx, kind, opts \\ []) do
    n = SalesFixtures.unique()
    domain = Keyword.get(opts, :domain, "race-#{n}.test")

    %{
      source_kind: kind,
      source_ref: ref(kind),
      campaign_id: ctx.campaign.id,
      company: %{
        domain: domain,
        name: "Race Co #{n}",
        industry: "logistics software",
        employee_count: 120,
        geography: "US"
      },
      person: %{
        email: Keyword.get(opts, :email, "pat.#{n}@#{domain}"),
        first_name: "Pat",
        last_name: "Lee",
        title: "VP Operations",
        timezone: "America/Denver"
      }
    }
  end

  defp ref(:manual), do: "manual:#{Ecto.UUID.generate()}"
  defp ref(:csv), do: "csv:#{Ecto.UUID.generate()}:#{SalesFixtures.unique()}"

  # The admission's one pass: admission-ref, company domain, email, email
  # domain (section 2.6), as raw key inputs.
  defp admission_keys(ctx, input) do
    email = input.person.email |> String.trim() |> String.downcase()
    [_local, host] = String.split(email, "@", parts: 2)

    Enum.uniq([
      key(ctx, :"admission-ref", input.source_ref),
      key(ctx, :domain, input.company.domain),
      key(ctx, :email, email),
      key(ctx, :domain, host)
    ])
  end

  defp key(ctx, kind, raw), do: call(@keys, :id, [ctx.tenant.id, kind, raw])

  ## Outcomes

  defp outcome!(result, input, outcome) do
    assert match?({:ok, %{outcome: ^outcome, replayed?: false}}, result),
           "C3-02: expected #{outcome}, got #{short(result)}"

    {:ok, value} = result
    assert value.admission.outcome == outcome
    assert value.admission.source_ref == input.source_ref
    value
  end

  defp admitted!(result, input) do
    value = outcome!(result, input, :admitted)

    assert {value.lead.status, value.run.status, value.run.usage_origin} ==
             {:assigned, :queued, :assignment}

    assert is_binary(value.run.settings_snapshot_id)
    value
  end

  defp replayed!(result, first) do
    assert match?({:ok, %{replayed?: true}}, result), "C3-02: replay: #{short(result)}"
    {:ok, replay} = result
    assert replay.admission.id == first.admission.id
    assert replay.outcome == first.outcome
    replay
  end

  defp refused!(result) do
    assert match?({:error, _}, result), "C3-02: expected a refusal, got #{short(result)}"
  end

  defp typed_refusal!(result, field, values) do
    assert match?({:error, %Ash.Error.Invalid{}}, result),
           "C3-02: expected a typed refusal, got #{short(result)}"

    {:error, error} = result
    attributes = for %Ash.Error.Changes.InvalidAttribute{} = e <- error.errors, do: e
    assert attributes != [], "C3-02: the refusal must be an InvalidAttribute"
    assert Enum.all?(attributes, &is_nil(&1.value)), "C3-02: the refusal carries no value"

    if field do
      assert field in Enum.map(attributes, & &1.field),
             "C3-02: the refusal must name #{inspect(field)}"
    end

    for value <- values do
      refute rendered(error) =~ value, "C3-02: the refusal must not echo a domain or address"
    end
  end

  defp rendered(error),
    do:
      Exception.message(error) <>
        " " <> inspect(error, limit: :infinity, printable_limit: :infinity)

  ## Counts (the tables of `sdr/admit_lead_test.exs`)

  defp snapshot(tables \\ @tables) do
    if "lead_admissions" in tables do
      assert Code.ensure_loaded?(@admission), "C3-02: #{inspect(@admission)} is not available"
    end

    %{counts: Map.new(tables, &{&1, count(&1)}), events: event_types()}
  end

  defp changes(before, tables \\ @tables) do
    later = snapshot(tables)
    %{rows: delta(before.counts, later.counts), events: delta(before.events, later.events)}
  end

  defp delta(before, later) do
    for key <- Enum.uniq(Map.keys(before) ++ Map.keys(later)),
        diff <- [Map.get(later, key, 0) - Map.get(before, key, 0)],
        diff != 0,
        into: %{},
        do: {key, diff}
  end

  defp assert_rows!(before, expected) do
    assert Map.delete(changes(before).rows, "audit_events") == expected,
           "C3-02: exact row deltas"
  end

  defp admitted_rows(account?, contact?) do
    @admitted_rows
    |> Map.merge(%{"accounts" => if(account?, do: 1, else: 0)})
    |> Map.merge(%{"contacts" => if(contact?, do: 1, else: 0)})
    |> Map.reject(fn {_table, n} -> n == 0 end)
  end

  defp count(table) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table}")
    n
  end

  defp event_types do
    %{rows: rows} = Repo.query!("SELECT event_type, count(*) FROM audit_events GROUP BY 1")
    Map.new(rows, fn [type, n] -> {type, n} end)
  end

  defp event_count(ctx, type) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM audit_events WHERE tenant_id = $1 AND event_type = $2",
        [uuid(ctx.tenant.id), type]
      )

    n
  end

  defp admissions_for(ref) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM lead_admissions WHERE source_ref = $1", [ref])

    n
  end

  defp accounts_at(ctx, domain) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM accounts WHERE tenant_id = $1 AND domain::text = $2",
        [uuid(ctx.tenant.id), domain]
      )

    n
  end

  defp contacts_with(ctx, email) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM contacts WHERE tenant_id = $1 AND lower(email::text) = lower($2)",
        [uuid(ctx.tenant.id), email]
      )

    n
  end

  defp open_leads_at(account_id) do
    open = Enum.map(Locks.open_leads(), &Atom.to_string/1)

    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM leads WHERE account_id = $1 AND status::text = ANY($2::text[])",
        [uuid(account_id), open]
      )

    n
  end

  defp leads_of(contact_id) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM leads WHERE contact_id = $1", [uuid(contact_id)])

    n
  end

  defp qualifications_of(lead) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM qualifications WHERE lead_id = $1", [uuid(lead.id)])

    n
  end

  defp domain_of(account) do
    %{rows: [[domain]]} =
      Repo.query!("SELECT domain::text FROM accounts WHERE id = $1", [uuid(account.id)])

    domain
  end

  defp reread(ctx, lead) do
    assert {:ok, fresh} = Sales.fetch(Sales.Lead, lead.id, actor: ctx.admin)
    fresh
  end

  defp uuid(id), do: Ecto.UUID.dump!(id)
end
