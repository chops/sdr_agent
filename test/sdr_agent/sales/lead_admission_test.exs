defmodule SdrAgent.Sales.LeadAdmissionTest do
  @moduledoc """
  C3-02 RED-2, plan r8 section 11 E (T-E1..T-E13; T-E14 is
  `sales/cutover_fence_test.exs`): the database side of lead admission
  (packet section 3 rows LeadAdmission, Lead and Account; section 9
  "Cutover", "Deferred trigger" and "Matched-lead binding"; plan section
  2.7 legacy-identity pre-check; implementation obligation O7).

  Numbering follows the order of the section 11 E list:

    * T-E1 cutover triggers (BEFORE INSERT `leads_admission_binding`, BEFORE
      UPDATE immutability);
    * T-E2 binding (admitted outcome, same kind, same referral, composite FK
      to the admission's company and person, one lead per admission);
    * T-E3 seed/fixture boundary (prod-config `SeedingAllowed`);
    * T-E4 legacy rows untouched;
    * T-E5 provenance columns (schema and DB checks of `lead_admissions`);
    * T-E6 account index (`one_open_per_account`, the account slot);
    * T-E7 deferred trigger with rollback;
    * T-E8 isolated matched-lead negatives, both matched outcomes;
    * T-E9 stored `readmit` restriction;
    * T-E10..T-E12 migration pre-checks: collisions, double open leads,
      legacy identity (T-E12 is the plan's legacy-identity test);
    * T-E13 marker policy.

  RED form: every new table, column, trigger, index, SQL function, module
  and Ash surface is guarded first with a `C3-02:` assertion (SQL catalog
  reads: `to_regclass`, `information_schema.columns`, `pg_trigger`,
  `pg_index`; `Code.ensure_loaded?/1`, `function_exported?/3`,
  `Ash.Resource.Info`), so missing schema is a structural assertion failure,
  never a Postgrex crash. Direct-SQL negatives run in a savepoint
  (`AuditCase.raw_error/2`, or the multi-statement `savepoint/1` below) and
  pin the refusal by its Postgres error code. Behavioural REDs (main's
  surface exists, C3-02 changes its behaviour) are labelled in comments.
  Controls pass on main and must stay green.

  The migration pre-checks have no callable surface named by the plan:
  T-E12 runs the literal section 2.7 SQL predicate, and T-E10/T-E11 run the
  pre-check predicates over pre-cutover-shaped temporary tables, then pin
  the post-cutover constraint that makes the state unrepresentable. That
  the migration runs these predicates and aborts with counts only is GREEN
  evidence (migration review), not asserted here.

  Interface names chosen here for review:
    * trigger refusal codes: `raise_exception` or `restrict_violation` (the
      convention of `SettingsFixtures.trigger_message/1` and
      `Audit.SQL.terminal_immutable/4`); DB checks `check_violation`; FKs
      `foreign_key_violation`; indexes `unique_violation`. No constraint or
      trigger name is pinned except `leads_admission_binding`;
    * the deferred constraint trigger lives on `lead_admissions`;
      `SET CONSTRAINTS ALL IMMEDIATE` stands in for commit in the sandbox
      (the pattern of `outreach/draft_test.exs`);
    * `SdrAgent.Sales.Checks.LeadAdmissionContext.context/0` returns the
      marker context map (as `QualificationContext.context/0`);
    * a refused application `:create` with source `:fixture`/`:crm` under
      the marker is `Ash.Error.Invalid` on `:source`;
    * `LeadAdmission :record` is reached with only the inputs its action
      accepts (`Ash.Resource.Info.action/2` `accept`).
  """
  use SdrAgent.AuditCase, async: false

  alias Ecto.Adapters.SQL
  alias SdrAgent.Audit.GuardedCall
  alias SdrAgent.Audit.RecordHash
  alias SdrAgent.OutreachFixtures
  alias SdrAgent.Outreach.Locks
  alias SdrAgent.Sales
  alias SdrAgent.Sales.Account
  alias SdrAgent.Sales.Lead
  alias SdrAgent.SalesFixtures

  @lead_admission SdrAgent.Sales.LeadAdmission
  @marker SdrAgent.Sales.Checks.LeadAdmissionContext
  @normalize SdrAgent.Audit.IdentityKeys.Normalize

  @trigger_refusal [:raise_exception, :restrict_violation]
  @kinds [:manual, :csv, :hubspot, :agent_found, :referral]
  @terminal [:disqualified, :converted, :nurture, :stopped, :referred]

  @uuid_columns ~w(id tenant_id requested_by_user_id campaign_id account_id contact_id
                   matched_lead_id agent_run_id referral_from_lead_id admission_id
                   referred_from_lead_id)

  # Packet section 3, LeadAdmission attributes and relationships:
  # {column, type, is_nullable}
  @admission_columns [
    {:id, :uuid, "NO"},
    {:tenant_id, :uuid, "NO"},
    {:source_kind, :text, "NO"},
    {:source_ref, :text, "NO"},
    {:input_version, :integer, "NO"},
    {:input_sha256, :text, "NO"},
    {:outcome, :text, "NO"},
    {:suppression_scope, :text, "YES"},
    {:readmit, :boolean, "NO"},
    {:account_created, :boolean, "NO"},
    {:contact_created, :boolean, "NO"},
    {:requested_by_user_id, :uuid, "NO"},
    {:campaign_id, :uuid, "NO"},
    {:account_id, :uuid, "YES"},
    {:contact_id, :uuid, "YES"},
    {:matched_lead_id, :uuid, "YES"},
    {:agent_run_id, :uuid, "YES"},
    {:referral_from_lead_id, :uuid, "YES"},
    {:trace_id, :text, "NO"},
    {:span_id, :text, "NO"},
    {:inserted_at, :timestamp, "NO"}
  ]

  # Plan section 2.7, verbatim: the legacy-identity pre-check predicate over
  # c = sdr_canonical_domain(stored domain).
  @legacy_predicate ~S"""
  length(c) BETWEEN 1 AND 253
  AND c ~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$'
  AND c !~ '^www\.'
  AND sdr_canonical_domain(c) = c
  """

  @label63 String.duplicate("a", 63)
  @max_host "#{@label63}.#{@label63}.#{@label63}.#{String.duplicate("d", 61)}"
  @long_host @max_host <> "d"

  # The T-D1 corpus, copied verbatim from test/sdr_agent/sales/domain_test.exs.
  # {raw, strip(raw) = SQL sdr_canonical_domain(raw), company(raw)}
  @corpus [
    {"acme.test", "acme.test", {:ok, "acme.test"}},
    {"ACME.Test", "acme.test", {:ok, "acme.test"}},
    {"  acme.test  ", "acme.test", {:ok, "acme.test"}},
    {"acme.test.", "acme.test", {:ok, "acme.test"}},
    {"acme.test. ", "acme.test", {:ok, "acme.test"}},
    {"www.acme.test", "acme.test", {:ok, "acme.test"}},
    {"WWW.Acme.Test.", "acme.test", {:ok, "acme.test"}},
    {"www.x.test", "x.test", {:ok, "x.test"}},
    {"sales.acme.test", "sales.acme.test", {:ok, "sales.acme.test"}},
    {"xn--bcher-kva.test", "xn--bcher-kva.test", {:ok, "xn--bcher-kva.test"}},
    {@max_host, @max_host, {:ok, @max_host}},
    # repeated www.: stripped exactly once, refused as company identity
    {"www.www.acme.test", "www.acme.test", {:error, :invalid_domain}},
    {" WWW.WWW.Acme.Test. ", "www.acme.test", {:error, :invalid_domain}},
    {"www.www.www.acme.test", "www.www.acme.test", {:error, :invalid_domain}},
    {"www.www.x.test", "www.x.test", {:error, :invalid_domain}},
    # www. alone, and fewer than two labels after the strip
    {"www.", "www", {:error, :invalid_domain}},
    {"www", "www", {:error, :invalid_domain}},
    {"www.test", "test", {:error, :invalid_domain}},
    {"WWW.test", "test", {:error, :invalid_domain}},
    {"acme", "acme", {:error, :invalid_domain}},
    # trailing dots, consecutive dots, empty labels
    {"acme.test..", "acme.test.", {:error, :invalid_domain}},
    {"acme..test", "acme..test", {:error, :invalid_domain}},
    {"www..acme.test", ".acme.test", {:error, :invalid_domain}},
    {".acme.test", ".acme.test", {:error, :invalid_domain}},
    {".", "", {:error, :invalid_domain}},
    {"", "", {:error, :invalid_domain}},
    {"   ", "", {:error, :invalid_domain}},
    # whitespace other than spaces is not trimmed by SQL btrim
    {"\tacme.test", "\tacme.test", {:error, :invalid_domain}},
    {"acme .test", "acme .test", {:error, :invalid_domain}},
    # labels and length
    {"-acme.test", "-acme.test", {:error, :invalid_domain}},
    {"acme-.test", "acme-.test", {:error, :invalid_domain}},
    {"#{@label63}a.test", "#{@label63}a.test", {:error, :invalid_domain}},
    {@long_host, @long_host, {:error, :invalid_domain}},
    # URL, port, path, address, non-ASCII
    {"https://acme.test", "https://acme.test", {:error, :invalid_domain}},
    {"acme.test:443", "acme.test:443", {:error, :invalid_domain}},
    {"acme.test/path", "acme.test/path", {:error, :invalid_domain}},
    {"a@acme.test", "a@acme.test", {:error, :invalid_domain}},
    {"bücher.test", "bücher.test", {:error, :invalid_domain}},
    {"www.bücher.test", "bücher.test", {:error, :invalid_domain}}
  ]

  setup do
    tenant = bootstrap!()
    admin = human(:admin, tenant)
    account = SalesFixtures.account!(tenant)
    other_account = SalesFixtures.account!(tenant)
    origin_account = SalesFixtures.account!(tenant)

    %{
      tenant: tenant,
      admin: admin,
      reviewer: human(:reviewer, tenant),
      auditor: human(:auditor, tenant),
      seeder: system_actor(:seeder, tenant),
      campaign: SalesFixtures.active_campaign!(tenant),
      account: account,
      contact: SalesFixtures.contact!(tenant, account),
      colleague: SalesFixtures.contact!(tenant, account),
      other_account: other_account,
      other_contact: SalesFixtures.contact!(tenant, other_account),
      origin_contact: SalesFixtures.contact!(tenant, origin_account)
    }
  end

  describe "T-E1 cutover triggers" do
    test "T-E1 a manual lead without an admission and any crm lead fail at leads_admission_binding",
         ctx do
      guard_lead_columns!()
      guard_binding_trigger!()

      for source <- [:manual, :crm] do
        insert = insert_sql("leads", lead_row(ctx, ctx.contact, %{"source" => source}))
        assert_refused!(raw(insert), @trigger_refusal, "#{source} lead without an admission")

        # Attribution: with only leads_admission_binding disabled the row inserts.
        disabled =
          savepoint(["ALTER TABLE leads DISABLE TRIGGER leads_admission_binding", insert])

        assert_accepted!(disabled, "#{source} lead with leads_admission_binding disabled")
      end

      # a crm lead cannot be inserted even with an admitted admission of the same company/person
      admission = admission_row(ctx, :manual)
      row = lead_row(ctx, ctx.contact, %{"source" => :crm, "admission_id" => admission["id"]})
      outcome = savepoint([insert_sql("lead_admissions", admission), insert_sql("leads", row)])
      assert_refused!(outcome, @trigger_refusal, "crm lead with an admission")
      assert lead_count(ctx.account) == 0
    end

    test "T-E1 source, admission_id, referred_from_lead_id, account_id and contact_id are immutable",
         ctx do
      guard_lead_columns!()
      guard_update_trigger!()
      lead = seed_lead!(ctx, ctx.contact)
      original = seed_lead!(ctx, ctx.origin_contact)
      # Persisted in the test transaction (no lead binds it; the deferred
      # check never runs because the sandbox never commits).
      admission = admission_row(ctx, :manual)
      {sql, params} = insert_sql("lead_admissions", admission)
      Repo.query!(sql, params)

      changes = [
        {"source", "'manual'"},
        {"admission_id", "'#{admission["id"]}'::uuid"},
        {"referred_from_lead_id", "'#{original.id}'::uuid"},
        {"account_id", "'#{ctx.other_account.id}'::uuid"},
        {"contact_id", "'#{ctx.colleague.id}'::uuid"}
      ]

      for {column, value} <- changes do
        update = {"UPDATE leads SET #{column} = #{value} WHERE id = $1", [dump(lead.id)]}
        assert_refused!(raw(update), @trigger_refusal, "UPDATE leads.#{column}")
      end

      # Attribution: the refusal comes from a user trigger, not a constraint.
      for {column, value} <- Enum.take(changes, 2) do
        update = {"UPDATE leads SET #{column} = #{value} WHERE id = $1", [dump(lead.id)]}
        disabled = savepoint(["ALTER TABLE leads DISABLE TRIGGER USER", update])
        assert_accepted!(disabled, "UPDATE leads.#{column} with user triggers disabled")
      end

      # Lifecycle columns stay writable.
      status = {"UPDATE leads SET status_reason = 'c302 note' WHERE id = $1", [dump(lead.id)]}
      assert_accepted!(raw(status), "UPDATE leads.status_reason")
      assert lead_identity(lead.id) == [["fixture", nil]]
    end
  end

  describe "T-E2 binding" do
    test "T-E2 a lead binds only an admitted admission of its kind, referral, company and person",
         ctx do
      guard_admissions!()
      guard_binding_trigger!()
      ctx = Map.put(ctx, :original, seed_lead!(ctx, ctx.origin_contact))

      admitted = admission_row(ctx, :manual)

      assert_accepted!(
        savepoint([insert_sql("lead_admissions", admitted), bound_lead(ctx, admitted, :manual)]),
        "a manual lead bound to its admitted manual admission"
      )

      refused = [
        {"a non-admitted outcome",
         admission_row(ctx, :manual, %{"outcome" => :previously_worked}), :manual, %{},
         @trigger_refusal},
        {"another kind", admission_row(ctx, :csv), :manual, %{}, @trigger_refusal},
        {"another referral", admission_row(ctx, :referral), :referral, %{}, @trigger_refusal},
        {"another person", admitted, :manual, %{contact: ctx.colleague}, :foreign_key_violation},
        {"another company", admitted, :manual, %{contact: ctx.other_contact},
         :foreign_key_violation}
      ]

      for {label, admission, source, opts, codes} <- refused do
        lead = bound_lead(ctx, admission, source, opts)
        outcome = savepoint([insert_sql("lead_admissions", admission), lead])
        assert_refused!(outcome, codes, label)
      end

      assert lead_count(ctx.account) == 0
      assert lead_count(ctx.other_account) == 0
    end

    test "T-E2 an admission is bound by at most one lead", ctx do
      guard_admissions!()
      admission = admission_row(ctx, :manual)
      first = bound_lead(ctx, admission, :manual, %{status: :stopped})
      second = bound_lead(ctx, admission, :manual)

      outcome = savepoint([insert_sql("lead_admissions", admission), first, second])
      assert_refused!(outcome, :unique_violation, "a second lead on one admission")
    end
  end

  describe "T-E3 seed/fixture boundary" do
    # Control: passes on main; must stay green (the trusted database-admin boundary).
    test "T-E3 (control) a raw fixture row without an admission inserts at the database", ctx do
      row = lead_row(ctx, ctx.contact, %{"source" => :fixture})
      assert_accepted!(raw(insert_sql("leads", row)), "fixture lead without an admission")
    end

    # Control: passes on main; must stay green (prod config refuses every seed write).
    test "T-E3 (control) in prod config the seeder's Lead :seed is forbidden and writes nothing",
         ctx do
      OutreachFixtures.put_env!(:seeding_allowed?, false)
      id = Ecto.UUID.generate()

      result =
        Sales.seed_lead(
          %{id: id, contact_id: ctx.contact.id, account_id: ctx.account.id, source: :fixture},
          actor: ctx.seeder
        )

      assert match?({:error, %Ash.Error.Forbidden{}}, result)
      assert lead_exists?(id) == false
    end

    test "T-E3 Lead :seed stays the fixture path; it cannot write a manual lead", ctx do
      assert Ash.Resource.Info.attribute(Lead, :admission_id),
             "C3-02: the Lead attribute :admission_id is not defined"

      fixture = seed_lead!(ctx, ctx.contact)
      assert {fixture.source, Map.get(fixture, :admission_id)} == {:fixture, nil}

      # Behavioural: main's :seed accepts source :manual without an admission.
      id = Ecto.UUID.generate()

      result =
        attempt(fn ->
          Sales.seed_lead(
            %{id: id, contact_id: ctx.colleague.id, account_id: ctx.account.id, source: :manual},
            actor: ctx.seeder
          )
        end)

      refute match?({:ok, _}, result), "C3-02: a manual lead without an admission is impossible"
      assert lead_exists?(id) == false
    end

    # Behavioural: main's Lead :create accepts source :fixture for an admin.
    test "T-E3 application writes cannot choose source fixture or crm", ctx do
      for source <- [:fixture, :crm] do
        before = lead_count(ctx.account)
        result = Sales.create_lead(lead_attrs(ctx.contact, source), actor: ctx.admin)
        refute match?({:ok, _}, result), "C3-02: Lead :create must refuse source #{source}"
        assert lead_count(ctx.account) == before
      end

      present!(@marker, :context, 0)

      for source <- [:fixture, :crm] do
        result = marked_create(ctx.admin, lead_attrs(ctx.contact, source))
        assert_invalid_field!(result, :source, "marked Lead :create with source #{source}")
      end

      assert lead_count(ctx.account) == 0
    end
  end

  describe "T-E4 legacy rows untouched" do
    test "T-E4 legacy manual, crm and fixture rows keep source and null admission through transitions",
         ctx do
      guard_lead_columns!()

      assert Ash.Resource.Info.attribute(Lead, :admission_id),
             "C3-02: the Lead attribute :admission_id is not defined"

      legacy = [
        legacy_lead!(ctx, :manual),
        legacy_lead!(ctx, :crm),
        seed_lead!(ctx, SalesFixtures.contact!(ctx.tenant))
      ]

      for lead <- legacy do
        before = lead_identity(lead.id)
        assert {:ok, loaded} = Sales.fetch(Lead, lead.id, actor: ctx.admin)
        assert Map.get(loaded, :admission_id) == nil
        assert {:ok, assigned} = Sales.update(loaded, :assign, %{}, actor: ctx.admin)

        assert {:ok, stopped} =
                 Sales.update(assigned, :stop, %{status_reason: "c302 legacy"}, actor: ctx.admin)

        assert stopped.source == loaded.source
        assert lead_identity(lead.id) == before
      end

      assert Enum.map(legacy, &lead_identity(&1.id)) == [
               [["manual", nil]],
               [["crm", nil]],
               [["fixture", nil]]
             ]
    end
  end

  describe "T-E5 provenance columns" do
    test "T-E5 lead_admissions and the Lead provenance columns exist with their types", _ctx do
      assert table?("lead_admissions"), "C3-02: table lead_admissions does not exist"
      admissions = column_types("lead_admissions")

      for {attribute, type, nullable} <- @admission_columns do
        column = Atom.to_string(attribute)

        assert Map.has_key?(admissions, column),
               "C3-02: column lead_admissions.#{column} is missing"

        {data_type, is_nullable} = admissions[column]
        assert type?(type, data_type), "C3-02: lead_admissions.#{column} type #{data_type}"
        assert is_nullable == nullable, "C3-02: lead_admissions.#{column} nullability"
      end

      leads = column_types("leads")

      for column <- ["admission_id", "referred_from_lead_id"] do
        assert leads[column] == {"uuid", "YES"}, "C3-02: leads.#{column} must be a nullable uuid"
      end

      assert Code.ensure_loaded?(@lead_admission), "C3-02: #{inspect(@lead_admission)} is missing"

      for {attribute, _type, _nullable} <- @admission_columns do
        assert Ash.Resource.Info.attribute(@lead_admission, attribute),
               "C3-02: LeadAdmission attribute #{attribute} is not defined"
      end
    end

    test "T-E5 per-kind source_ref grammar, version, hash and embedded ids are DB checks", ctx do
      guard_admissions!()
      ctx = with_sources(ctx)
      uuid = Ecto.UUID.generate()

      negatives = [
        {:manual, %{"source_ref" => "manual:not-a-uuid"}},
        {:manual, %{"source_ref" => "manual:" <> String.upcase(uuid)}},
        {:manual, %{"source_ref" => "csv:#{uuid}:1"}},
        {:manual, %{"input_version" => 2}},
        {:manual, %{"input_sha256" => String.upcase(sha256())}},
        {:manual, %{"input_sha256" => String.slice(sha256(), 0, 63)}},
        {:manual, %{"agent_run_id" => ctx.run.id}},
        {:manual, %{"referral_from_lead_id" => ctx.original.id}},
        {:csv, %{"source_ref" => "csv:#{uuid}:0"}},
        {:csv, %{"source_ref" => "csv:#{uuid}:" <> String.duplicate("9", 90)}},
        {:hubspot, %{"source_ref" => "hubspot:abc:456"}},
        {:agent_found, %{"agent_run_id" => nil}},
        {:agent_found, %{"source_ref" => "agent_found:#{uuid}:#{Ecto.UUID.generate()}"}},
        {:referral, %{"referral_from_lead_id" => nil}},
        {:referral, %{"source_ref" => "referral:#{uuid}:#{Ecto.UUID.generate()}"}}
      ]

      for kind <- @kinds do
        base = insert_sql("lead_admissions", admission_row(ctx, kind))
        assert_accepted!(raw(base), "a valid #{kind} admission")
      end

      for {kind, change} <- negatives do
        row = admission_row(ctx, kind, change)
        label = "#{kind} with #{inspect(Map.keys(change))}"
        assert_refused!(raw(insert_sql("lead_admissions", row)), :check_violation, label)
      end

      row = admission_row(ctx, :manual)

      twice =
        savepoint([
          insert_sql("lead_admissions", row),
          insert_sql("lead_admissions", %{row | "id" => uuid})
        ])

      assert_refused!(twice, :unique_violation, "a repeated (tenant, kind, source_ref)")
    end
  end

  describe "T-E6 account index" do
    test "T-E6 a second open lead at an account fails at one_open_per_account; rollback keeps the first",
         ctx do
      guard_slot!()
      {sql, params} = insert_sql("leads", lead_row(ctx, ctx.contact, %{"source" => :fixture}))
      assert %{num_rows: 1} = Repo.query!(sql, params)

      second = insert_sql("leads", lead_row(ctx, ctx.colleague, %{"source" => :fixture}))
      assert_refused!(raw(second), :unique_violation, "a second open lead at the account")
      assert lead_count(ctx.account) == 1

      # The typed refusal through main's :seed (behavioural: main allows it).
      result = attempt(fn -> seed_attrs(ctx, ctx.colleague) end)
      assert match?({:error, %Ash.Error.Invalid{}}, result), "C3-02: :seed must hit the identity"
      assert lead_count(ctx.account) == 1
    end

    test "T-E6 a terminal lead frees the slot; referred is terminal for both open-lead indexes",
         ctx do
      guard_slot!()

      for status <- @terminal do
        closed = lead_row(ctx, ctx.contact, %{"source" => :fixture, "status" => status})
        same_account = lead_row(ctx, ctx.colleague, %{"source" => :fixture})
        same_contact = lead_row(ctx, ctx.contact, %{"source" => :fixture})

        for {label, row} <- [{"account", same_account}, {"contact", same_contact}] do
          outcome = savepoint([insert_sql("leads", closed), insert_sql("leads", row)])
          assert_accepted!(outcome, "an open lead at the same #{label} after a #{status} lead")
        end
      end
    end
  end

  describe "T-E7 deferred trigger" do
    test "T-E7 an admitted row without a lead fails at commit and rolls back; with its lead it commits",
         ctx do
      guard_admissions!()
      guard_deferred_trigger!()
      admitted = admission_row(ctx, :manual)
      insert = insert_sql("lead_admissions", admitted)

      deferred = savepoint([insert])
      assert_accepted!(deferred, "the admitted insert itself (the check is deferred)")

      outcome = savepoint([insert, "SET CONSTRAINTS ALL IMMEDIATE"])
      assert_refused!(outcome, @trigger_refusal, "an admitted row without a lead at commit")
      assert admission_exists?(admitted["id"]) == false

      bound = bound_lead(ctx, admitted, :manual)
      committed = savepoint([insert, bound, "SET CONSTRAINTS ALL IMMEDIATE"])
      assert_accepted!(committed, "an admitted row with its one lead at commit")

      for outcome <- [:previously_worked, :suppressed] do
        extra =
          if outcome == :suppressed,
            do: %{"suppression_scope" => :email, "account_id" => nil, "contact_id" => nil},
            else: %{}

        row = admission_row(ctx, :manual, Map.put(extra, "outcome", outcome))
        statements = [insert_sql("lead_admissions", row), "SET CONSTRAINTS ALL IMMEDIATE"]
        assert_accepted!(savepoint(statements), "a #{outcome} row needs no lead")
      end
    end
  end

  describe "T-E8 matched-lead binding" do
    for outcome <- [:duplicate_open_lead, :active_target_exists] do
      test "T-E8 #{outcome}: isolated negatives against a valid same-tenant, same-company binding",
           ctx do
        guard_admissions!()
        matched = seed_lead!(ctx, ctx.contact)
        elsewhere = seed_lead!(ctx, ctx.other_contact)
        foreign = foreign_lead!(ctx)
        base = matched_row(ctx, unquote(outcome), matched)

        assert_accepted!(raw(insert_sql("lead_admissions", base)), "the valid binding")

        negatives = [
          {"account_id null", %{"account_id" => nil}, :check_violation},
          {"matched_lead_id null", %{"matched_lead_id" => nil}, :check_violation},
          {"a matched lead of another tenant", %{"matched_lead_id" => foreign},
           :foreign_key_violation},
          {"a matched lead at another company", %{"matched_lead_id" => elsewhere.id},
           :foreign_key_violation}
        ]

        for {label, change, code} <- negatives do
          row = Map.merge(base, change)
          assert_refused!(raw(insert_sql("lead_admissions", row)), code, label)
        end
      end
    end

    test "T-E8 a matched lead on any other outcome fails the check", ctx do
      guard_admissions!()
      matched = seed_lead!(ctx, ctx.contact)

      for outcome <- [:admitted, :previously_worked] do
        row =
          admission_row(ctx, :manual, %{"outcome" => outcome, "matched_lead_id" => matched.id})

        assert_refused!(raw(insert_sql("lead_admissions", row)), :check_violation, "#{outcome}")
      end
    end
  end

  describe "T-E9 stored readmit" do
    test "T-E9 readmit = true is stored only for manual and referral", ctx do
      guard_admissions!()
      ctx = with_sources(ctx)

      for kind <- @kinds do
        insert = insert_sql("lead_admissions", admission_row(ctx, kind, %{"readmit" => true}))
        base = insert_sql("lead_admissions", admission_row(ctx, kind))
        assert_accepted!(raw(base), "#{kind} with readmit false")

        if kind in [:manual, :referral] do
          assert_accepted!(raw(insert), "#{kind} with readmit true")
        else
          assert_refused!(raw(insert), :check_violation, "#{kind} with readmit true")
        end
      end
    end
  end

  describe "T-E10..T-E12 migration pre-checks" do
    test "T-E10 collisions: canonical collisions are counted; the index makes them unrepresentable",
         ctx do
      guard_canonical_index!()
      n = SalesFixtures.unique()
      Repo.query!("CREATE TEMP TABLE c302_pre_accounts (LIKE accounts)")
      other_tenant = Ecto.UUID.generate()

      for {tenant_id, domain} <- [
            {ctx.tenant.id, "www.acme-#{n}.test"},
            {ctx.tenant.id, "ACME-#{n}.test."},
            {ctx.tenant.id, "acme-#{n}.test"},
            {ctx.tenant.id, "eu.acme-#{n}.test"},
            {other_tenant, "acme-#{n}.test"}
          ] do
        {sql, params} = insert_sql("c302_pre_accounts", account_row(tenant_id, domain))
        Repo.query!(sql, params)
      end

      assert %{columns: ["groups", "accounts"], rows: [[1, 3]]} =
               Repo.query!("""
               SELECT count(*)::bigint AS groups, coalesce(sum(n), 0)::bigint AS accounts
               FROM (SELECT count(*) AS n FROM c302_pre_accounts
                     GROUP BY tenant_id, sdr_canonical_domain(domain::text)
                     HAVING count(*) > 1) AS g
               """)

      domain = to_string(ctx.account.domain)

      for colliding <- ["www." <> domain, "WWW." <> String.upcase(domain) <> "."] do
        insert = insert_sql("accounts", account_row(ctx.tenant.id, colliding))
        assert_refused!(raw(insert), :unique_violation, "legacy-form #{colliding}")
      end

      distinct = insert_sql("accounts", account_row(ctx.tenant.id, "eu." <> domain))
      assert_accepted!(raw(distinct), "a subdomain stays distinct")
    end

    test "T-E11 double open leads: accounts with two open leads are counted over the open set",
         ctx do
      guard_slot!()
      Repo.query!("CREATE TEMP TABLE c302_pre_leads (LIKE leads)")
      [a, b, c] = for _ <- 1..3, do: Ecto.UUID.generate()

      for {account_id, status} <- [
            {a, :new},
            {a, :in_outreach},
            {b, :assigned},
            {b, :stopped},
            {b, :disqualified},
            {b, :referred},
            {c, :qualified},
            {c, :blocked},
            {c, :replied}
          ] do
        row = %{
          lead_row(ctx, ctx.contact, %{"status" => status, "source" => :fixture})
          | "account_id" => account_id
        }

        {sql, params} = insert_sql("c302_pre_leads", row)
        Repo.query!(sql, params)
      end

      open = Enum.map(Locks.open_leads(), &Atom.to_string/1)

      assert %{rows: [[2, 5]]} =
               Repo.query!(
                 """
                 SELECT count(*)::bigint, coalesce(sum(n), 0)::bigint
                 FROM (SELECT count(*) AS n FROM c302_pre_leads WHERE status = ANY($1::text[])
                       GROUP BY tenant_id, account_id HAVING count(*) > 1) AS g
                 """,
                 [open]
               )
    end

    test "T-E12 legacy identity: the section 2.7 predicate keeps the two failure kinds apart",
         _ctx do
      guard_canonical_function!()
      present!(@normalize, :company, 1)

      cases = [
        # normalization succeeds to a different value -> abort
        {"www.www.x.test", "www.x.test", {:ok, "x.test"}, false},
        # an invalid indexed form -> abort
        {"www.test", "test", {:error, :invalid_domain}, false},
        # valid fixed points -> pass
        {"www.x.test", "x.test", {:ok, "x.test"}, true},
        {"x.test", "x.test", {:ok, "x.test"}, true}
      ]

      for {stored, c, company, accepted?} <- cases do
        assert legacy_check(stored) == {c, accepted?}, "C3-02: predicate over stored #{stored}"
        assert call(@normalize, :company, [c]) == company, "C3-02: company(#{c})"
        assert company == {:ok, c} == accepted?
      end

      assert match?(
               {:ok, other} when other != "www.x.test",
               call(@normalize, :company, ["www.x.test"])
             )

      assert match?({:error, _}, call(@normalize, :company, ["test"]))
    end

    test "T-E12 legacy identity: SQL predicate and company(c) == {:ok, c} agree over the T-D1 corpus",
         _ctx do
      guard_canonical_function!()
      present!(@normalize, :company, 1)

      for {raw, _strip, _company} <- @corpus do
        {c, accepted?} = legacy_check(raw)

        assert accepted? == (call(@normalize, :company, [c]) == {:ok, c}),
               "C3-02: the predicate and company/1 disagree on stored #{inspect(raw)}"
      end
    end

    test "T-E12 legacy identity: failing rows are counted only; rows and hashes unchanged", ctx do
      guard_canonical_function!()
      n = SalesFixtures.unique()

      stored = [
        "www.www.x-#{n}.test",
        "www.test",
        "www.x-#{n}-pass.test",
        "x-#{n}-plain.test"
      ]

      accounts = Enum.map(stored, &legacy_account!(ctx, &1))
      before = Enum.map(accounts, &{to_string(&1.domain), RecordHash.hex(&1)})

      assert %{columns: ["failing", "total"], rows: [[2, 4]]} =
               Repo.query!(
                 "SELECT count(*) FILTER (WHERE NOT (" <>
                   @legacy_predicate <>
                   "))::bigint AS failing, count(*)::bigint AS total " <>
                   "FROM (SELECT sdr_canonical_domain(domain::text) AS c FROM accounts " <>
                   "WHERE id = ANY($1::uuid[])) AS s",
                 [Enum.map(accounts, &dump(&1.id))]
               )

      after_check =
        Enum.map(accounts, fn account ->
          assert {:ok, fresh} = GuardedCall.get(Account, account.id, actor: ctx.admin)
          {to_string(fresh.domain), RecordHash.hex(fresh)}
        end)

      assert after_check == before
      assert Enum.map(before, &elem(&1, 0)) == stored
    end
  end

  describe "T-E13 marker policy" do
    # Behavioural: main's Lead :create is allowed for an active admin.
    test "T-E13 Lead :create without the LeadAdmissionContext marker is forbidden", ctx do
      for source <- @kinds do
        result = Sales.create_lead(lead_attrs(ctx.contact, source), actor: ctx.admin)

        assert match?({:error, %Ash.Error.Forbidden{}}, result),
               "C3-02: Lead :create (#{source}) without the marker must be forbidden"
      end

      assert lead_count(ctx.account) == 0
    end

    test "T-E13 LeadAdmission :record without the marker is forbidden for every actor", ctx do
      assert Code.ensure_loaded?(@lead_admission), "C3-02: #{inspect(@lead_admission)} is missing"

      assert Ash.Resource.Info.action(@lead_admission, :record),
             "C3-02: LeadAdmission :record is not defined"

      refute Enum.any?(
               Ash.Resource.Info.actions(@lead_admission),
               &(&1.type in [:update, :destroy])
             ),
             "C3-02: LeadAdmission is append-only"

      denials = length(events_of_type(ctx.tenant, "authz.denied"))

      actors = [
        ctx.admin,
        ctx.reviewer,
        ctx.auditor,
        system_actor(:agent_runtime, ctx.tenant),
        system_actor(:seeder, ctx.tenant),
        system_actor(:webhook_ingestor, ctx.tenant)
      ]

      for actor <- actors do
        result = GuardedCall.create(@lead_admission, :record, record_input(ctx), actor: actor)

        assert match?({:error, %Ash.Error.Forbidden{}}, result),
               "C3-02: :record must be forbidden"
      end

      assert admission_count(ctx.tenant) == 0
      assert length(events_of_type(ctx.tenant, "authz.denied")) > denials
    end

    test "T-E13 with the marker, only an active admin passes the policy", ctx do
      present!(@marker, :context, 0)

      for actor <- [ctx.reviewer, system_actor(:agent_runtime, ctx.tenant)] do
        result = marked_create(actor, lead_attrs(ctx.contact, :manual))

        assert match?({:error, %Ash.Error.Forbidden{}}, result),
               "C3-02: marked :create by non-admin"

        record =
          @lead_admission
          |> Ash.Changeset.for_create(:record, record_input(ctx),
            actor: actor,
            context: call(@marker, :context, [])
          )
          |> Ash.create()

        assert match?({:error, %Ash.Error.Forbidden{}}, record),
               "C3-02: marked :record by non-admin"
      end

      assert lead_count(ctx.account) == 0
      assert admission_count(ctx.tenant) == 0
    end
  end

  ## Guards and calls

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

  defp table?(name) do
    %{rows: [[present?]]} = Repo.query!("SELECT to_regclass($1) IS NOT NULL", [name])
    present?
  end

  defp column_types(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name, data_type, is_nullable FROM information_schema.columns " <>
          "WHERE table_schema = current_schema() AND table_name = $1",
        [table]
      )

    Map.new(rows, fn [name, type, nullable] -> {name, {type, nullable}} end)
  end

  defp type?(:uuid, type), do: type == "uuid"
  defp type?(:text, type), do: type in ["text", "character varying"]
  defp type?(:integer, type), do: type in ["bigint", "integer"]
  defp type?(:boolean, type), do: type == "boolean"
  defp type?(:timestamp, type), do: String.starts_with?(type, "timestamp")

  defp guard_lead_columns! do
    leads = column_types("leads")

    for column <- ["admission_id", "referred_from_lead_id"] do
      assert Map.has_key?(leads, column), "C3-02: column leads.#{column} does not exist"
    end
  end

  defp guard_admissions! do
    assert table?("lead_admissions"), "C3-02: table lead_admissions does not exist"
    admissions = column_types("lead_admissions")

    for {attribute, _type, _nullable} <- @admission_columns do
      assert Map.has_key?(admissions, Atom.to_string(attribute)),
             "C3-02: column lead_admissions.#{attribute} is missing"
    end

    guard_lead_columns!()
  end

  defp guard_binding_trigger! do
    assert trigger_count("tgname = 'leads_admission_binding' AND (tgtype & 4) = 4") == 1,
           "C3-02: BEFORE INSERT trigger leads_admission_binding on leads is not defined"
  end

  defp guard_update_trigger! do
    assert trigger_count("(tgtype & 16) = 16") > 0,
           "C3-02: no BEFORE UPDATE row trigger on leads (immutable columns)"
  end

  defp trigger_count(condition) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_trigger WHERE tgrelid = to_regclass('leads') " <>
          "AND NOT tgisinternal AND tgenabled <> 'D' AND (tgtype & 1) = 1 AND (tgtype & 2) = 2 " <>
          "AND " <> condition
      )

    count
  end

  defp guard_deferred_trigger! do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_trigger WHERE tgrelid = to_regclass('lead_admissions') " <>
          "AND tgconstraint <> 0 AND NOT tgisinternal AND tgdeferrable AND tginitdeferred"
      )

    assert count > 0,
           "C3-02: no DEFERRABLE INITIALLY DEFERRED constraint trigger on lead_admissions"
  end

  defp guard_slot! do
    identity = Ash.Resource.Info.identity(Lead, :one_open_per_account)
    assert identity, "C3-02: the Lead identity :one_open_per_account is not defined"
    assert identity.keys == [:tenant_id, :account_id]
  end

  defp guard_canonical_function! do
    %{rows: [[present?]]} =
      Repo.query!("SELECT to_regprocedure('sdr_canonical_domain(text)') IS NOT NULL")

    assert present?, "C3-02: SQL function sdr_canonical_domain(text) is not defined"
  end

  defp guard_canonical_index! do
    guard_canonical_function!()

    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_index i WHERE i.indrelid = 'accounts'::regclass " <>
          "AND i.indisunique AND pg_get_indexdef(i.indexrelid) LIKE '%sdr_canonical_domain(%'"
      )

    assert count > 0,
           "C3-02: unique index (tenant_id, sdr_canonical_domain(domain)) on accounts is missing"
  end

  ## Savepoints and Postgres outcomes

  # One statement through AuditCase.raw_error/2: {:ok, result} | {:error, %Postgrex.Error{}}.
  defp raw({sql, params}) do
    case raw_error(sql, params) do
      {:error, {:unexpected_success, result}} -> {:ok, result}
      {:error, error} -> {:error, error}
    end
  end

  # Statements in order in one savepoint, always rolled back; the first
  # failure ends the sequence.
  defp savepoint(statements) do
    case Repo.transaction(fn -> Repo.rollback(run_all(statements)) end) do
      {:error, outcome} -> outcome
    end
  end

  defp run_all(statements), do: Enum.reduce_while(statements, {:ok, []}, &run_one/2)

  defp run_one(sql, acc) when is_binary(sql), do: run_one({sql, []}, acc)

  defp run_one({sql, params}, {:ok, results}) do
    case SQL.query(Repo, sql, params) do
      {:ok, result} -> {:cont, {:ok, [result | results]}}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp assert_refused!(outcome, codes, label) do
    assert code(outcome) in List.wrap(codes),
           "C3-02: #{label}: expected #{inspect(codes)}, got #{describe(outcome)}"
  end

  defp assert_accepted!(outcome, label) do
    assert match?({:ok, _}, outcome),
           "C3-02: #{label}: expected success, got #{describe(outcome)}"
  end

  defp code({:error, %Postgrex.Error{postgres: %{code: code}}}), do: code
  defp code(_outcome), do: nil

  defp describe({:ok, _}), do: "success"

  defp describe({:error, %Postgrex.Error{postgres: %{code: code, message: message}}}),
    do: "#{code}: #{message}"

  defp describe(other), do: inspect(other, limit: 5)

  ## Rows

  defp insert_sql(table, row) do
    {names, exprs, params} =
      row
      |> Enum.sort()
      |> Enum.reduce({[], [], []}, &column/2)

    sql =
      "INSERT INTO #{table} (#{names |> Enum.reverse() |> Enum.join(", ")}) " <>
        "VALUES (#{exprs |> Enum.reverse() |> Enum.join(", ")})"

    {sql, Enum.reverse(params)}
  end

  defp column({name, :now}, {names, exprs, params}),
    do: {[name | names], ["now()" | exprs], params}

  defp column({name, value}, {names, exprs, params}) do
    placeholder = "$#{length(params) + 1}"
    {[name | names], [placeholder | exprs], [param(name, value) | params]}
  end

  defp param(name, value) when name in @uuid_columns and is_binary(value), do: dump(value)
  defp param(_name, value) when is_boolean(value) or is_nil(value), do: value
  defp param(_name, value) when is_atom(value), do: Atom.to_string(value)
  defp param(_name, value), do: value

  defp dump(id), do: Ecto.UUID.dump!(id)
  defp sha256, do: hex(:crypto.strong_rand_bytes(32))

  defp trace,
    do: %{
      "trace_id" => hex(:crypto.strong_rand_bytes(16)),
      "span_id" => hex(:crypto.strong_rand_bytes(8))
    }

  defp admission_row(ctx, kind, overrides \\ %{}) do
    %{
      "id" => Ecto.UUID.generate(),
      "tenant_id" => ctx.tenant.id,
      "source_kind" => kind,
      "source_ref" => ref(ctx, kind),
      "input_version" => 1,
      "input_sha256" => sha256(),
      "outcome" => :admitted,
      "suppression_scope" => nil,
      "readmit" => false,
      "account_created" => false,
      "contact_created" => false,
      "requested_by_user_id" => ctx.admin.id,
      "campaign_id" => ctx.campaign.id,
      "account_id" => ctx.account.id,
      "contact_id" => ctx.contact.id,
      "matched_lead_id" => nil,
      "agent_run_id" => if(kind == :agent_found, do: ctx.run.id),
      "referral_from_lead_id" => if(kind == :referral, do: ctx.original.id),
      "inserted_at" => :now
    }
    |> Map.merge(trace())
    |> Map.merge(overrides)
  end

  defp ref(_ctx, :manual), do: "manual:#{Ecto.UUID.generate()}"
  defp ref(_ctx, :csv), do: "csv:#{Ecto.UUID.generate()}:#{SalesFixtures.unique()}"
  defp ref(_ctx, :hubspot), do: "hubspot:#{SalesFixtures.unique()}:#{SalesFixtures.unique()}"
  defp ref(ctx, :agent_found), do: "agent_found:#{ctx.run.id}:#{Ecto.UUID.generate()}"
  defp ref(ctx, :referral), do: "referral:#{ctx.original.id}:#{Ecto.UUID.generate()}"

  defp matched_row(ctx, :duplicate_open_lead, matched),
    do:
      admission_row(ctx, :manual, %{
        "outcome" => :duplicate_open_lead,
        "matched_lead_id" => matched.id
      })

  defp matched_row(ctx, :active_target_exists, matched),
    do:
      admission_row(ctx, :manual, %{
        "outcome" => :active_target_exists,
        "contact_id" => nil,
        "matched_lead_id" => matched.id
      })

  # The original lead and run the agent_found and referral kinds name.
  defp with_sources(ctx) do
    %{run: run} = SalesFixtures.run!(ctx.tenant)
    Map.merge(ctx, %{run: run, original: seed_lead!(ctx, ctx.origin_contact)})
  end

  defp lead_row(ctx, contact, overrides) do
    %{
      "id" => Ecto.UUID.generate(),
      "tenant_id" => ctx.tenant.id,
      "account_id" => contact.account_id,
      "contact_id" => contact.id,
      "source" => :manual,
      "status" => :new,
      "status_reason" => "c302 synthetic",
      "inserted_at" => :now,
      "updated_at" => :now
    }
    |> Map.merge(trace())
    |> Map.merge(overrides)
  end

  # The INSERT of a lead bound to `admission` (its company and person unless
  # `contact:` names another), with `source`.
  defp bound_lead(ctx, admission, source, opts \\ %{}) do
    contact = Map.get(opts, :contact, ctx.contact)

    row =
      lead_row(ctx, contact, %{
        "source" => source,
        "status" => Map.get(opts, :status, :new),
        "admission_id" => admission["id"]
      })

    insert_sql("leads", row)
  end

  defp account_row(tenant_id, domain) do
    %{
      "id" => Ecto.UUID.generate(),
      "tenant_id" => tenant_id,
      "name" => "Legacy #{SalesFixtures.unique()}",
      "domain" => domain,
      "source" => :manual,
      "status" => :active,
      "inserted_at" => :now,
      "updated_at" => :now
    }
    |> Map.merge(trace())
  end

  defp lead_attrs(contact, source),
    do: %{contact_id: contact.id, account_id: contact.account_id, source: source}

  defp seed_lead!(ctx, contact) do
    assert {:ok, lead} = seed_attrs(ctx, contact)
    lead
  end

  defp seed_attrs(ctx, contact) do
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

  # A pre-cutover row in its stored form (the cutover trigger forbids new
  # manual and crm rows, so it is written as a database administrator).
  defp legacy_lead!(ctx, source) do
    contact = SalesFixtures.contact!(ctx.tenant)
    row = lead_row(ctx, contact, %{"source" => source})
    {sql, params} = insert_sql("leads", row)
    tamper!(sql, params)
    %{id: row["id"]}
  end

  # A lead of another tenant at this company, written with foreign keys
  # disabled (AuditCase: the singleton tenant is the only tenant row).
  defp foreign_lead!(ctx) do
    row =
      lead_row(ctx, ctx.colleague, %{"source" => :fixture, "tenant_id" => Ecto.UUID.generate()})

    {sql, params} = insert_sql("leads", row)
    tamper!(sql, params)
    row["id"]
  end

  # An account in its stored legacy form (C3-02's :create stores company(raw)).
  defp legacy_account!(ctx, stored_domain) do
    row = account_row(ctx.tenant.id, stored_domain)
    {sql, params} = insert_sql("accounts", row)
    tamper!(sql, params)
    assert {:ok, account} = GuardedCall.get(Account, row["id"], actor: ctx.admin)
    account
  end

  ## Reads

  defp lead_identity(id) do
    %{rows: rows} =
      Repo.query!("SELECT source, admission_id::text FROM leads WHERE id = $1", [dump(id)])

    rows
  end

  defp lead_count(account) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM leads WHERE account_id = $1", [dump(account.id)])

    count
  end

  defp lead_exists?(id) do
    %{rows: [[found?]]} =
      Repo.query!("SELECT EXISTS (SELECT 1 FROM leads WHERE id = $1)", [dump(id)])

    found?
  end

  defp admission_exists?(id) do
    %{rows: [[found?]]} =
      Repo.query!("SELECT EXISTS (SELECT 1 FROM lead_admissions WHERE id = $1)", [dump(id)])

    found?
  end

  defp admission_count(tenant) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM lead_admissions WHERE tenant_id = $1", [dump(tenant.id)])

    count
  end

  # {c, predicate(c)} for a stored value, with the section 2.7 SQL.
  defp legacy_check(stored) do
    %{rows: [[c, accepted?]]} =
      Repo.query!(
        "SELECT c, (" <>
          @legacy_predicate <> ") FROM (SELECT sdr_canonical_domain($1::text) AS c) AS s",
        [stored]
      )

    {c, accepted?}
  end

  ## Ash calls

  defp marked_create(actor, attrs) do
    Lead
    |> Ash.Changeset.for_create(:create, attrs,
      actor: actor,
      context: call(@marker, :context, [])
    )
    |> Ash.create()
  end

  defp record_input(ctx) do
    accepted = Ash.Resource.Info.action(@lead_admission, :record).accept

    %{
      source_kind: :manual,
      source_ref: ref(ctx, :manual),
      input_version: 1,
      input_sha256: sha256(),
      outcome: :admitted,
      readmit: false,
      account_created: false,
      contact_created: false,
      requested_by_user_id: ctx.admin.id,
      campaign_id: ctx.campaign.id,
      account_id: ctx.account.id,
      contact_id: ctx.contact.id
    }
    |> Map.take(accepted)
  end

  defp assert_invalid_field!(result, field, label) do
    assert match?({:error, %Ash.Error.Invalid{}}, result), "C3-02: #{label} must be invalid"
    {:error, error} = result
    assert field in Enum.map(error.errors, &Map.get(&1, :field)), "C3-02: #{label} on #{field}"
  end

  defp attempt(fun) do
    fun.()
  rescue
    error -> {:raised, error.__struct__}
  end
end
