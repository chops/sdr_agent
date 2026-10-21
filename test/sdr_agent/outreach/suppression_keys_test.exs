defmodule SdrAgent.Outreach.SuppressionKeysTest do
  @moduledoc """
  C3-02 RED-2, plan r8 section 11 J (T-J1..T-J7): the Suppression side of
  the identity keys (sections 2.6, 2.7, 8.1) and the decided suppression
  boundary (section 5.4, D-174 Q-O1 = A with A.3, A.4 and A.5).

    * T-J1: `:manual` and `:seed` key their value (`IdentityKeyLock`, a
      prepended before_action) before `ApplySuppression` reads or locks
      anything. `:from_classification` needs an LLM `reply_classification`
      Decision on a matched reply; its entry point is covered by the RED-3
      full-path order test (T-O1), not here.
    * T-J2: `:from_webhook` (`:held`) requires the caller's pass.
    * T-J3: the strengthened company match of `Locks.contacts` (packet
      section 3): a domain suppression equal to an account's
      `canonical_domain` covers its contacts whatever their email domain.
    * T-J4: real key ids over the section 2.7 vectors. The "both orders"
      part of T-J4 is a race and is RED-3 (`admission_race_test.exs`,
      T-I3..T-I5); only the sequential key-id part is here.
    * T-J5: A.3 (`:reopen` and a re-opening override refused for a covered
      contact, under the company key) and A.4 (Account `:update` to a
      suppressed company domain refused under its keys).
    * T-J6: (control) the unchanged gates refuse for a stopped enrollment or
      lead; passes on main and must stay green.
    * T-J7: legacy S4/S5: a replay applies no effects, then the A.5 fence
      (`SdrAgent.Sales.CutoverFence.counts_sql/0`, the migration's own SQL
      text) reports aborting counts.

  The suite uses `SdrAgent.SDRCase`, as every existing Outreach suite does:
  drafts, approvals and deliveries need the seeded demo data and a drafting
  run (`AuditCase` cannot build one).

  How keys are observed (no seam):
    * a successful create runs inside an `Audit.transaction` the test opens;
      the nested action joins that application scope, and the section 2.4
      state query then shows the scope's `sdr.identity_pass` record (its
      token and exact id set), `require_held/2` of the writer's keys is
      `:ok` and a key outside the pass is `LateAcquisition`;
    * a refused action fails its (nested) transaction, after which
      DBConnection refuses further statements in an enclosing one, so a
      refusal is observed through the traced pass statements: the published
      record (`set_config('sdr.identity_pass', $1, true)`, whose ids are the
      pass's keys) and any `pg_advisory_xact_lock($1::bigint)` (RED-1
      T-A15), and through what was not executed (no `UPDATE`/`INSERT` of the
      refused row). A key already held from an earlier sandbox scope gets
      no lock statement (section 2.4 rule 8), so the record, not the lock
      statements, is the observation of which keys were taken;
    * expected ids are the plan's `H` computed in the test over the exact
      preimage bytes (`h/3`, as RED-1 T-A1), for the live tenant id.

  RED form: T-J1, T-J3, T-J4 and the T-J5 refusals are behavioural (their
  subjects exist on main: main publishes no pass, misses the company match
  and allows the re-open and the rename); the record and refusal assertions
  come before any IdentityKeys call, and `IdentityKeys` is guarded
  (`Code.ensure_loaded?/1`, `function_exported?/3`) before it is called
  through `apply/3`. T-J2 and T-J7 are structural (their guards fail).
  T-J6 and the T-J5 uncovered re-open are controls.

  Interface names chosen here for review:
    * refusals are `{:error, %Ash.Error.Invalid{}}` carrying an
      `Ash.Error.Changes.InvalidAttribute`: on `:domain` for A.4, on
      `:lead_id` for the override's A.3 refusal; the Lead `:reopen` A.3
      refusal's field is not pinned (the plan names none, and the Lead has
      no `lead_id`); no refusal renders the refused value;
    * the fence result is the shape `sales/cutover_fence_test.exs` (T-E14)
      chose: `counts_sql/0` takes no parameters and returns one row of
      totals over all tenants with the aborting columns `a`, `b1`, `b2`,
      `b3`, `b4` (and optionally the non-aborting `candidate_drafts`); the
      sandboxed singleton tenant is the only tenant with state here;
    * legacy suppressions (rows written by main, whose creation applied no
      company-domain effects) are inserted in their stored form with
      `tamper!/2`, as RED-1 inserts legacy accounts.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures

  alias SdrAgent.Actor
  alias SdrAgent.Audit
  alias SdrAgent.Outreach
  alias SdrAgent.Outreach.Suppression
  alias SdrAgent.Research
  alias SdrAgent.Sales
  alias SdrAgent.SalesFixtures
  alias SdrAgent.WebhookFixtures

  @keys SdrAgent.Audit.IdentityKeys
  @fence SdrAgent.Sales.CutoverFence
  @scope_key {SdrAgent.Audit.IdentityKeys, :scope}
  @late SdrAgent.Audit.IdentityKeys.LateAcquisition
  @missing SdrAgent.Audit.IdentityKeys.MissingPass

  # The A.5 aborting categories, as named by T-E14 (`sales/cutover_fence_test.exs`).
  @aborting ~w(a b1 b2 b3 b4)

  # Section 2.3: "v1;<token>;<backend pid>;<id>,<id>,…".
  @record_format ~r/^v1;[0-9a-f]{32};\d+;(-?\d+(,-?\d+)*)?$/

  # Section 2.4, verbatim: the one state query, no lock clause.
  @state_sql """
  SELECT current_setting('sdr.identity_pass', true),
         pg_backend_pid(),
         coalesce(array_agg((l.classid::bigint << 32) | l.objid::bigint)
                  FILTER (WHERE l.pid IS NOT NULL), '{}')
  FROM (SELECT 1) AS one
  LEFT JOIN pg_locks l
    ON  l.locktype = 'advisory'
    AND l.database = (SELECT oid FROM pg_database WHERE datname = current_database())
    AND l.pid      = pg_backend_pid()
    AND l.objsubid = 1
    AND l.mode     = 'ExclusiveLock'
    AND l.granted
  """

  describe "T-J1 the key before ApplySuppression" do
    test "T-J1 a domain :manual suppression keys its value before its first effect read", ctx do
      n = SalesFixtures.unique()
      value = "mail-j1d-#{n}.test"
      %{lead: lead} = covered_lead!(ctx, account!(ctx, "j1d-#{n}.test"), "jo-#{n}@#{value}")

      assert_keyed_first!(ctx, {:domain, value}, value, fn ->
        Outreach.suppress(%{scope: :domain, value: value}, actor: ctx.admin)
      end)

      assert reload!(ctx, lead).status == :stopped
    end

    test "T-J1 an email :manual suppression keys its value before its first effect read", ctx do
      n = SalesFixtures.unique()
      email = "jo-#{n}@mail-j1e-#{n}.test"
      %{lead: lead} = covered_lead!(ctx, account!(ctx, "j1e-#{n}.test"), email)

      assert_keyed_first!(ctx, {:email, email}, email, fn ->
        Outreach.suppress(%{scope: :email, value: email}, actor: ctx.admin)
      end)

      assert reload!(ctx, lead).status == :stopped
    end

    test "T-J1 a :seed suppression keys its value before its first effect read", ctx do
      n = SalesFixtures.unique()
      value = "mail-j1s-#{n}.test"
      %{lead: lead} = covered_lead!(ctx, account!(ctx, "j1s-#{n}.test"), "jo-#{n}@#{value}")
      attrs = %{id: Ecto.UUID.generate(), scope: :domain, value: value}

      assert_keyed_first!(ctx, {:domain, value}, value, fn ->
        Outreach.seed_suppression(attrs, actor: seeder(ctx))
      end)

      assert reload!(ctx, lead).status == :stopped
    end
  end

  describe "T-J2 :from_webhook finds its key held" do
    test "T-J2 :from_webhook without a pass is MissingPass, with a wrong pass LateAcquisition",
         ctx do
      guard_keys!()
      t = ctx.tenant.id
      n = SalesFixtures.unique()
      email = "jo-#{n}@j2-#{n}.test"
      %{contact: contact, lead: lead} = covered_lead!(ctx, account!(ctx, "j2-#{n}.test"), email)
      event = unsubscribe_event!(contact)

      attrs = %{
        scope: :email,
        value: email,
        reason: :unsubscribe_link,
        webhook_event_id: event.id
      }

      created = created_count(ctx)

      without = attempt(fn -> from_webhook(ctx, attrs) end)

      assert carries?(without, @missing),
             "C3-02: :from_webhook outside a pass must raise MissingPass, got #{inspect(without)}"

      wrong =
        attempt(fn ->
          Audit.transaction(fn ->
            assert pass(t, [{:email, "other-#{n}@j2-other-#{n}.test"}]) == :ok
            from_webhook(ctx, attrs)
          end)
        end)

      assert carries?(wrong, @late),
             "C3-02: :from_webhook must not acquire its own key late, got #{inspect(wrong)}"

      assert {:ok, []} = Outreach.matching_suppressions(email, actor: ctx.admin)
      assert created_count(ctx) == created
      assert reload!(ctx, lead).status == :new

      # The refusal is the pass and nothing else: with the caller's pass the
      # same create succeeds and applies its effects.
      assert {:ok, {:ok, suppression}} =
               Audit.transaction(fn ->
                 assert pass(t, [{:email, email}]) == :ok
                 from_webhook(ctx, attrs)
               end)

      assert suppression.reason == :unsubscribe_link
      assert reload!(ctx, lead).status == :stopped
    end
  end

  describe "T-J3 the strengthened company match" do
    test "T-J3 a suppression of the account's canonical domain stops a contact at another email domain",
         ctx do
      n = SalesFixtures.unique()
      company = "acme-j3-#{n}.test"
      %{lead: lead} = covered_lead!(ctx, account!(ctx, company), "c-#{n}@mail-j3-#{n}.example")

      %{lead: bystander} =
        covered_lead!(ctx, account!(ctx, "other-j3-#{n}.test"), "d-#{n}@else-j3-#{n}.example")

      # Coverage is equality with canonical_domain: a www. suppression covers
      # email domain www.<company> and no account (D0). Passes on main.
      assert {:ok, _} =
               Outreach.suppress(%{scope: :domain, value: "www." <> company}, actor: ctx.admin)

      assert reload!(ctx, lead).status == :new

      assert {:ok, _} = Outreach.suppress(%{scope: :domain, value: company}, actor: ctx.admin)
      stopped = reload!(ctx, lead)

      assert stopped.status == :stopped,
             "C3-02: a company-domain suppression must stop the account's contacts' open leads"

      assert stopped.status_reason == "suppressed: manual"
      assert reload!(ctx, bystander).status == :new
    end

    test "T-J3 a legacy www. account is matched by its canonical domain, not its stored form",
         ctx do
      n = SalesFixtures.unique()
      c = "orbit-j3-#{n}.example.org"
      account = legacy_account!(ctx, "www." <> c)
      %{lead: lead} = covered_lead!(ctx, account, "c-#{n}@mail-j3l-#{n}.example")

      assert {:ok, _} = Outreach.suppress(%{scope: :domain, value: c}, actor: ctx.admin)

      assert reload!(ctx, lead).status == :stopped,
             "C3-02: the company match must compare the value with canonical_domain"
    end
  end

  describe "T-J4 real ids over the section 2.7 vectors" do
    test "T-J4 www.www., www., www.test and a@www.test stay valid and key exactly one strip",
         ctx do
      t = ctx.tenant.id
      n = SalesFixtures.unique()

      # {scope = key kind, stored value (as given), exact H preimage}
      vectors = [
        # stripped exactly once: the preimage is www.acme…, never acme…
        {:domain, "www.www.acme-j4-#{n}.test", "www.acme-j4-#{n}.test"},
        # extra serialization only: K(www.x) = K(x)
        {:domain, "www.acme-j4w-#{n}.test", "acme-j4w-#{n}.test"},
        # one label after the strip, still a valid, keyable suppression
        {:domain, "www.test", "test"},
        # email keys are trimmed and lowercased only
        {:email, "a-#{n}@www.test", "a-#{n}@www.test"}
      ]

      for {scope, value, preimage} <- vectors do
        assert {:ok, {{:ok, suppression}, observed}} =
                 Audit.transaction(fn ->
                   created = Outreach.suppress(%{scope: scope, value: value}, actor: ctx.admin)
                   {created, observe(t, [{scope, value}])}
                 end)

        assert to_string(suppression.value) == value
        assert_pass!(observed, [h(scope, t, preimage)])
        assert key_id(t, scope, value) == h(scope, t, preimage)
      end

      # The email domain of a@www.www.acme… is the raw input www.www.acme…:
      # the same id as the www.www. suppression (one strip each).
      assert key_id(t, :domain, "www.www.acme-j4-#{n}.test") ==
               h(:domain, t, "www.acme-j4-#{n}.test")

      refute h(:domain, t, "www.acme-j4-#{n}.test") == h(:domain, t, "acme-j4-#{n}.test")
    end

    # Control: coverage of the vectors is unchanged (email and email domain);
    # passes on main and must stay green.
    test "T-J4 (control) www.test covers a@www.test and www.www.x covers a@www.www.x by email domain",
         ctx do
      n = SalesFixtures.unique()
      # One open lead per account (one_open_per_account, T-E6): each vector
      # has its own account, neither of whose domain the suppressions name.
      %{lead: plain} = covered_lead!(ctx, account!(ctx, "j4c-#{n}.test"), "a-#{n}@www.test")

      %{lead: doubled} =
        covered_lead!(ctx, account!(ctx, "j4c-b-#{n}.test"), "b-#{n}@www.www.acme-j4c-#{n}.test")

      assert {:ok, _} = Outreach.suppress(%{scope: :domain, value: "www.test"}, actor: ctx.admin)
      assert reload!(ctx, plain).status == :stopped
      assert reload!(ctx, doubled).status == :new

      assert {:ok, _} =
               Outreach.suppress(%{scope: :domain, value: "www.www.acme-j4c-#{n}.test"},
                 actor: ctx.admin
               )

      assert reload!(ctx, doubled).status == :stopped
    end
  end

  describe "T-J5 A.3 and A.4 (D-174 Q-O1 = A)" do
    # Control: passes on main and must stay green (no coverage, no other open
    # lead at the account).
    test "T-J5 (control) an uncovered disqualified lead reopens", ctx do
      lead = disqualified_lead!(ctx)
      assert {:ok, %{status: :assigned}} = Sales.update(lead, :reopen, %{}, actor: ctx.admin)
    end

    test "T-J5 A.3 :reopen of a covered contact's lead is refused under the company key", ctx do
      t = ctx.tenant.id
      lead = disqualified_lead!(ctx)
      company = company_of!(ctx, lead)
      email = to_string(contact!(ctx, lead).email)
      assert {:ok, _} = Outreach.suppress(%{scope: :email, value: email}, actor: ctx.admin)
      assert reload!(ctx, lead).status == :disqualified
      before = length(events(ctx.tenant))

      {result, queries} =
        trace_queries(fn -> Sales.update(lead, :reopen, %{}, actor: ctx.admin) end)

      assert_refused!(result, nil, [email])
      assert reload!(ctx, lead).status == :disqualified
      assert length(events(ctx.tenant)) == before

      assert h(:domain, t, company) in lock_ids(queries),
             "C3-02: the A.3 refusal must be made under the company key"

      refute Enum.any?(queries, &statement?(&1, :update, "leads")),
             "C3-02: the refusal precedes the transition"
    end

    test "T-J5 A.3 an override that would re-open a covered contact's lead is refused", ctx do
      t = ctx.tenant.id
      lead = disqualified_lead!(ctx)
      company = company_of!(ctx, lead)
      assert {:ok, current} = Research.current_qualification(lead.id, actor: ctx.admin)
      refute current.qualified
      claim = accepted_claim!(ctx, lead)
      assert {:ok, _} = Outreach.suppress(%{scope: :domain, value: company}, actor: ctx.admin)
      before = length(events(ctx.tenant))

      {result, queries} =
        trace_queries(fn ->
          Research.override_qualification(reopening_override(lead, current, claim),
            actor: ctx.admin
          )
        end)

      assert_refused!(result, :lead_id, [company])
      assert reload!(ctx, lead).status == :disqualified
      assert {:ok, still} = Research.current_qualification(lead.id, actor: ctx.admin)
      assert still.id == current.id
      assert length(events(ctx.tenant)) == before

      assert h(:domain, t, company) in lock_ids(queries),
             "C3-02: the A.3 refusal must be made under the company key"

      refute Enum.any?(queries, &statement?(&1, :insert, "qualifications")),
             "C3-02: the refusal precedes the INSERT (section 4.2 step 6)"
    end

    test "T-J5 A.4 Account :update to a suppressed company domain is refused under its keys",
         ctx do
      t = ctx.tenant.id
      n = SalesFixtures.unique()
      old = "orig-j5-#{n}.test"
      new = "renamed-j5-#{n}.test"
      account = account!(ctx, old)
      %{lead: lead} = covered_lead!(ctx, account, "c-#{n}@mail-j5-#{n}.example")
      assert {:ok, _} = Outreach.suppress(%{scope: :domain, value: new}, actor: ctx.admin)
      before = length(events(ctx.tenant))

      {result, queries} =
        trace_queries(fn -> Sales.update(account, :update, %{domain: new}, actor: ctx.admin) end)

      assert_refused!(result, :domain, [new, old])
      assert to_string(reload!(ctx, account).domain) == old
      assert reload!(ctx, lead).status == :new
      assert length(events(ctx.tenant)) == before

      assert MapSet.new(lock_ids(queries)) ==
               MapSet.new([h(:domain, t, old), h(:domain, t, new)]),
             "C3-02: the refusal must be made under the old and the new key"

      refute Enum.any?(queries, &statement?(&1, :update, "accounts"))
    end
  end

  describe "T-J6 (control) the gates refuse stopped work" do
    # Control: passes on main and must stay green (gates unchanged, Q-O1 = A).
    test "T-J6 (control) the send gate refuses a delivery whose enrollment is stopped", ctx do
      %{delivery: op, approval: approval, lead: lead} = approved!(ctx)

      assert {:ok, %{status: :stopped}} =
               Sales.update(enrollment!(ctx, lead), :stop, %{stop_reason: :manual},
                 actor: ctx.admin
               )

      assert %{success: 1} = deliver!()
      refused = outreach!(ctx, op)
      assert {refused.state, refused.last_error["reason"]} == {:cancelled, "enrollment_inactive"}
      assert Enum.map(decisions_about!(ctx, op.id, :send_gate), & &1.outcome) == ["refuse"]
      assert outreach!(ctx, approval).status == :invalidated
      assert receipts!(ctx, op) == []
    end

    # Control: passes on main and must stay green. The approval gate checks
    # the draft, not the lead; the draft gate is the one that checks the lead.
    test "T-J6 (control) the draft gate refuses a stopped lead", ctx do
      %{draft: draft, revision: revision, lead: lead} = drafted!(ctx)

      assert {:ok, %{status: :stopped}} =
               Sales.update(lead, :stop, %{status_reason: "c302 operator stop"}, actor: ctx.admin)

      result = Outreach.propose_draft(followup_attrs(ctx, draft, revision), actor: ctx.agent)
      assert {:error, %Ash.Error.Invalid{} = error} = result
      assert :lead_id in Enum.map(error.errors, &Map.get(&1, :field))
    end

    # Control: passes on main and must stay green.
    test "T-J6 (control) once a suppression stops the lead, the approval gate refuses its draft",
         ctx do
      %{draft: draft, lead: lead} = drafted!(ctx)
      email = to_string(contact!(ctx, lead).email)
      assert {:ok, _} = Outreach.suppress(%{scope: :email, value: email}, actor: ctx.admin)
      assert reload!(ctx, lead).status == :stopped
      assert enrollment!(ctx, lead).status == :stopped
      draft = draft!(ctx, draft)
      assert draft.status == :cancelled

      result =
        Outreach.approve(draft, approval_input(revision!(ctx, draft.current_revision_id)),
          actor: operator!(ctx, :reviewer)
        )

      assert {:error, %Ash.Error.Invalid{} = error} = result
      assert :draft_id in Enum.map(error.errors, &Map.get(&1, :field))
    end
  end

  describe "T-J7 legacy S4 and S5 (A.5)" do
    test "T-J7 S4: a replay leaves the covered contact's open lead open; the fence aborts", ctx do
      n = SalesFixtures.unique()
      company = "acme-j7-#{n}.test"
      %{lead: lead} = covered_lead!(ctx, account!(ctx, company), "c-#{n}@mail-j7-#{n}.example")
      legacy = legacy_suppression!(ctx, company)
      created = created_count(ctx)

      assert {:ok, replay} =
               Outreach.suppress(%{scope: :domain, value: company}, actor: ctx.admin)

      assert replay.id == legacy
      assert created_count(ctx) == created
      assert reload!(ctx, lead).status == :new

      assert aborting_counts(fence_row!()) ==
               %{"a" => 1, "b1" => 0, "b2" => 0, "b3" => 0, "b4" => 0},
             "C3-02: S4 (an open lead of a covered contact) must abort the fence"
    end

    test "T-J7 S5: with every lead closed, a replay leaves eligible work; the fence aborts",
         ctx do
      n = SalesFixtures.unique()
      %{draft: draft, lead: lead} = drafted!(ctx)
      contact = contact!(ctx, lead)

      # The contact becomes covered by its company domain only (S5).
      assert {:ok, _} =
               Sales.update(contact, :change_email, %{email: "jo-#{n}@mail-j7s5-#{n}.example"},
                 actor: ctx.admin
               )

      assert {:ok, %{status: :stopped}} =
               Sales.update(lead, :stop, %{status_reason: "c302 legacy stop"}, actor: ctx.admin)

      company = company_of!(ctx, lead)
      legacy = legacy_suppression!(ctx, company)
      created = created_count(ctx)

      assert {:ok, replay} =
               Outreach.suppress(%{scope: :domain, value: company}, actor: ctx.admin)

      assert replay.id == legacy
      assert created_count(ctx) == created
      assert enrollment!(ctx, lead).status == :active
      assert draft!(ctx, draft).status == :pending_review

      assert aborting_counts(fence_row!()) ==
               %{"a" => 0, "b1" => 1, "b2" => 0, "b3" => 1, "b4" => 0},
             "C3-02: S5 (eligible work on closed leads) must abort the fence"
    end
  end

  # C3-02 G6 (plan r8 section 16.13 R-S1/R-S2; Codex Q6.11): the suppression
  # key is taken on a replay (it precedes the upsert) and not on an invalid
  # changeset (Ash runs no before_action on one), both through the action.
  describe "T-J8 (G6) replay and invalid value" do
    # Behavioural RED: main publishes no pass for the replay.
    test "T-J8 a replayed :manual suppression takes its key and returns the stored row", ctx do
      t = ctx.tenant.id
      n = SalesFixtures.unique()
      email = "jo-#{n}@mail-j8-#{n}.test"
      assert {:ok, original} = Outreach.suppress(%{scope: :email, value: email}, actor: ctx.admin)
      created = created_count(ctx)

      result =
        Audit.transaction(fn ->
          replay = Outreach.suppress(%{scope: :email, value: email}, actor: ctx.admin)
          {replay, observe(t, [{:email, email}])}
        end)

      assert match?({:ok, {{:ok, _}, _}}, result), "C3-02: the replay must succeed"
      {:ok, {{:ok, replay}, observed}} = result
      assert replay.id == original.id
      assert Ash.Resource.get_metadata(replay, :sdr_replayed) == true
      assert created_count(ctx) == created
      assert_pass!(observed, [h(:email, t, email)])
    end

    # Control: passes on main (no key at all) and must stay green after G6.
    test "T-J8 (control) an invalid value is refused with no key, no pass and no insert", ctx do
      {result, queries} =
        trace_queries(fn ->
          Outreach.suppress(%{scope: :domain, value: "not a host"}, actor: ctx.admin)
        end)

      assert match?({:error, %Ash.Error.Invalid{}}, result)
      refute Enum.any?(queries, &publication?/1), "C3-02: an invalid value published a pass"
      refute Enum.any?(queries, &advisory_lock?/1), "C3-02: an invalid value locked a key"

      refute Enum.any?(queries, &statement?(&1, :insert, "suppressions")),
             "C3-02: an invalid value was inserted"
    end
  end

  ## Key observation

  defp assert_keyed_first!(ctx, {kind, _raw} = key, preimage, create) do
    t = ctx.tenant.id

    {result, queries} =
      trace_queries(fn ->
        Audit.transaction(fn -> {create.(), observe(t, [key])} end)
      end)

    assert {:ok, {{:ok, _suppression}, observed}} = result
    assert_pass!(observed, [h(kind, t, preimage)])

    # The pass's publication is the observed key step: a key already held
    # from an earlier sandbox scope (e.g. the contact create's email key)
    # gets no lock statement (section 2.4 rule 8), but the first pass of a
    # scope always publishes its record.
    lock_at = Enum.find_index(queries, &publication?/1)
    assert lock_at, "C3-02: no identity pass was published"

    for {query, at} <- Enum.with_index(queries), advisory_lock?(query) do
      assert at < lock_at, "C3-02: every key lock precedes the publication"
    end

    for {label, pattern} <- [
          contacts: ~r/"contacts"/,
          leads: ~r/"leads".*FOR UPDATE/s,
          insert: ~r/INSERT INTO "suppressions"/
        ] do
      at = Enum.find_index(queries, fn {sql, _params} -> sql =~ pattern end)
      assert at, "precondition: the create runs its #{label} statement"
      assert lock_at < at, "C3-02: the key must precede ApplySuppression's #{label} statement"
    end
  end

  # Read inside the enclosing scope, after the writer returned. The
  # IdentityKeys calls run only when the module is present; their results
  # are asserted after the record, behind `guard_keys!/0`.
  defp observe(tenant_id, keys) do
    present? = keys_present?()

    %{
      record: record(),
      scope: Process.get(@scope_key),
      held: if(present?, do: outcome(fn -> require_held(tenant_id, keys) end)),
      late: if(present?, do: outcome(fn -> require_held(tenant_id, [unrelated_key()]) end))
    }
  end

  defp assert_pass!(observed, expected) do
    assert observed.record,
           "C3-02: the writer published no identity pass in the enclosing application scope"

    assert observed.record.ids == MapSet.new(expected),
           "C3-02: the pass must hold exactly the writer's keys"

    assert match?(%{token: _}, observed.scope) and observed.scope.token == observed.record.token,
           "C3-02: the pass must belong to the enclosing scope"

    guard_keys!()
    assert observed.held == :ok, "C3-02: require_held/2 of the writer's keys must be :ok"

    assert observed.late == {:raised, @late},
           "C3-02: a key outside the pass must raise LateAcquisition"
  end

  defp unrelated_key, do: {:domain, "c302-unrelated-#{SalesFixtures.unique()}.test"}

  # Every id keyed by the traced statements: the ids of each published pass
  # record (section 2.3; a key already held from an earlier sandbox scope is
  # in the record without a lock statement), plus each lock statement's
  # single integer parameter.
  defp lock_ids(queries) do
    published = for query <- queries, publication?(query), id <- record_ids(query), do: id

    locked =
      for {sql, params} = query <- queries, advisory_lock?(query), param <- params do
        assert sql =~ ~r/pg_advisory_xact_lock\(\$1::bigint\)/
        param
      end

    Enum.uniq(published ++ locked)
  end

  defp record_ids({_sql, [record]}) do
    assert record =~ @record_format, "C3-02: the published record is not v1"
    [_version, _token, _pid, ids] = String.split(record, ";")
    MapSet.to_list(parse_ids(ids))
  end

  defp advisory_lock?({sql, _params}), do: sql =~ "pg_advisory_xact_lock"
  defp publication?({sql, _params}), do: sql =~ ~r/set_config\(\s*'sdr\.identity_pass'/

  defp statement?({sql, _params}, :update, table), do: sql =~ ~r/^\s*UPDATE "#{table}"/
  defp statement?({sql, _params}, :insert, table), do: sql =~ ~r/^\s*INSERT INTO "#{table}"/

  ## Presence guards and calls

  defp present!(module, function, arity) do
    assert Code.ensure_loaded?(module), "C3-02: #{inspect(module)} is not available"

    assert function_exported?(module, function, arity),
           "C3-02: #{inspect(module)}.#{function}/#{arity} is not implemented"

    module
  end

  defp keys_present? do
    Code.ensure_loaded?(@keys) and function_exported?(@keys, :require_held, 2) and
      function_exported?(@keys, :pass, 2) and function_exported?(@keys, :id, 3)
  end

  defp guard_keys! do
    present!(@keys, :pass, 2)
    present!(@keys, :require_held, 2)
    present!(@keys, :id, 3)

    for exception <- [@late, @missing] do
      assert Code.ensure_loaded?(exception) and function_exported?(exception, :exception, 1),
             "C3-02: exception #{inspect(exception)} is not defined"
    end
  end

  defp call(module, function, args) do
    present!(module, function, length(args))
    apply(module, function, args)
  end

  defp pass(tenant_id, keys), do: call(@keys, :pass, [tenant_id, keys])
  defp require_held(tenant_id, keys), do: call(@keys, :require_held, [tenant_id, keys])
  defp key_id(tenant_id, kind, raw), do: call(@keys, :id, [tenant_id, kind, raw])

  # The plan's H (section 2.7), over the exact preimage bytes.
  defp h(kind, tenant_id, bytes) do
    <<id::signed-64, _rest::binary>> =
      :crypto.hash(
        :sha256,
        "sdr-identity-key/1\0" <> Atom.to_string(kind) <> "\0" <> tenant_id <> "\0" <> bytes
      )

    id
  end

  ## Database state

  defp record do
    %{rows: [[setting, _pid, _ids]]} = Repo.query!(@state_sql)

    case setting do
      value when value in [nil, ""] ->
        nil

      value ->
        assert value =~ @record_format, "C3-02: sdr.identity_pass is not a v1 record"
        [_version, token, pid, ids] = String.split(value, ";")
        %{token: token, pid: String.to_integer(pid), ids: parse_ids(ids)}
    end
  end

  defp parse_ids(""), do: MapSet.new()
  defp parse_ids(ids), do: ids |> String.split(",") |> MapSet.new(&String.to_integer/1)

  defp trace_queries(fun) do
    parent = self()
    handler = "c3-02-suppression-keys-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:sdr_agent, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == parent do
            send(
              parent,
              {:c302_query, IO.iodata_to_binary(metadata.query), metadata[:params] || []}
            )
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_queries([])}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain_queries(acc) do
    receive do
      {:c302_query, sql, params} -> drain_queries([{sql, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  ## Fence

  # The one row of totals (T-E14's shape); the sandboxed singleton tenant is
  # the only tenant with state, and its demo data counts zero (section 5.4).
  defp fence_row! do
    present!(@fence, :counts_sql, 0)
    sql = call(@fence, :counts_sql, [])
    assert is_binary(sql), "C3-02: CutoverFence.counts_sql/0 must return the SQL text"
    %{columns: columns, rows: rows} = Repo.query!(sql, [])
    assert match?([_], rows), "C3-02: the fence returns exactly one row of totals"
    [row] = rows
    columns |> Enum.zip(row) |> Map.new()
  end

  defp aborting_counts(row), do: Map.new(@aborting, &{&1, row[&1]})

  ## Builders (main's APIs and the seed boundary)

  defp seeder(ctx), do: Actor.system(:seeder, ctx.tenant.id, "c302-j")

  defp account!(ctx, domain) do
    assert {:ok, account} =
             Sales.create_account(SalesFixtures.account_attrs(%{domain: domain}),
               actor: ctx.admin
             )

    account
  end

  # A contact at `account` with `email` and its open (`:new`) lead, through
  # the dev/test `:seed` boundary (Lead `:create` is admission-only after G5).
  defp covered_lead!(ctx, account, email) do
    assert {:ok, contact} =
             Sales.create_contact(SalesFixtures.contact_attrs(account, %{email: email}),
               actor: ctx.admin
             )

    assert {:ok, lead} =
             Sales.seed_lead(
               %{
                 id: Ecto.UUID.generate(),
                 contact_id: contact.id,
                 account_id: account.id,
                 source: :fixture
               },
               actor: seeder(ctx)
             )

    %{contact: contact, lead: lead}
  end

  # A row in its stored legacy form, as it exists before C3-02 (plan section
  # 2.7): inserted directly, because C3-02's :create stores company(raw).
  defp legacy_account!(ctx, stored_domain) do
    id = Ecto.UUID.generate()

    tamper!(
      """
      INSERT INTO accounts
        (id, tenant_id, name, domain, source, status, trace_id, span_id, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, 'manual', 'active', $5, $6, now(), now())
      """,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(ctx.tenant.id),
        "Legacy Orbit #{SalesFixtures.unique()}",
        stored_domain,
        hex(:crypto.strong_rand_bytes(16)),
        hex(:crypto.strong_rand_bytes(8))
      ]
    )

    assert {:ok, account} = Sales.fetch(Sales.Account, id, actor: ctx.admin)
    account
  end

  # A domain suppression written by main before the cutover: main's creation
  # matched contacts by email domain only, so it applied no effects to a
  # contact covered by its company domain (S4/S5). Inserted in its stored
  # form, independent of C3-02's create paths.
  defp legacy_suppression!(ctx, value) do
    id = Ecto.UUID.generate()

    tamper!(
      """
      INSERT INTO suppressions
        (id, tenant_id, scope, value, reason, created_by_user_id, effective_at,
         trace_id, span_id, inserted_at)
      VALUES ($1, $2, 'domain', $3, 'manual', $4, now(), $5, $6, now())
      """,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(ctx.tenant.id),
        value,
        Ecto.UUID.dump!(ctx.admin.id),
        hex(:crypto.strong_rand_bytes(16)),
        hex(:crypto.strong_rand_bytes(8))
      ]
    )

    id
  end

  defp company_of!(ctx, lead) do
    assert {:ok, account} = Sales.fetch(Sales.Account, lead.account_id, actor: ctx.admin)
    to_string(account.domain)
  end

  # Demo company "05" is the designated disqualify outcome: a real agent
  # qualification (`qualified: false`) and a disqualified lead.
  defp disqualified_lead!(ctx) do
    %{lead: lead} = assign!(ctx, "05")
    assert %{success: 1} = drain!()
    lead = reload!(ctx, lead)
    assert lead.status == :disqualified
    lead
  end

  defp accepted_claim!(ctx, lead) do
    assert {:ok, [claim | _]} =
             Research.list_records(SdrAgent.Research.EvidenceClaim,
               filter: [lead_id: lead.id, quality: :accepted],
               actor: ctx.admin
             )

    claim
  end

  defp reopening_override(lead, current, claim) do
    %{
      lead_id: lead.id,
      icp_definition_id: current.icp_definition_id,
      supersedes_id: current.id,
      qualified: true,
      score: 80,
      criteria: %{
        company_size: :pass,
        industry: :pass,
        geography: :pass,
        persona: :pass,
        trigger: :pass
      },
      confidence: 0.9,
      reason: "Fits after manual review.",
      output_schema_version: "qualification_result/1",
      evidence_claim_ids: [claim.id]
    }
  end

  # The agent's step-2 draft for the same enrollment (as
  # `WebhookFixtures.followup_draft!/2`, returning the result).
  defp followup_attrs(ctx, draft, revision) do
    assert {:ok, steps} = Sales.list_records(Sales.SequenceStep, actor: ctx.admin)
    step = Enum.find(steps, &(&1.position == 2))

    %{
      lead_id: draft.lead_id,
      enrollment_id: draft.enrollment_id,
      sequence_step_id: step.id,
      campaign_id: draft.campaign_id,
      recipient_contact_id: draft.recipient_contact_id,
      origin_agent_run_id: draft.origin_agent_run_id,
      subject: "Following up",
      body_text: "Hi again, just following up on my note.",
      decision_id: revision.decision_id,
      model_invocation_id: revision.model_invocation_id,
      citations: []
    }
  end

  defp unsubscribe_event!(contact) do
    body = WebhookFixtures.unsubscribe_body(contact)

    assert {:ok, %{status: :accepted, event: event}} =
             WebhookFixtures.ingest!("unsubscribe", body)

    event
  end

  defp from_webhook(ctx, attrs) do
    Suppression
    |> Ash.Changeset.for_create(:from_webhook, attrs,
      actor: Actor.system(:webhook_ingestor, ctx.tenant.id)
    )
    |> Ash.create()
  end

  defp created_count(ctx),
    do: length(events_of_type(ctx.tenant, "outreach.suppression.created"))

  ## Outcomes

  defp assert_refused!(result, field, values) do
    assert match?({:error, %Ash.Error.Invalid{}}, result),
           "C3-02: expected a typed refusal, got #{inspect(result, limit: 4)}"

    {:error, error} = result
    attributes = for %Ash.Error.Changes.InvalidAttribute{} = e <- error.errors, do: e
    assert attributes != [], "C3-02: the refusal must be an InvalidAttribute"

    if field do
      assert field in Enum.map(attributes, & &1.field),
             "C3-02: the refusal must name #{inspect(field)}"
    end

    for value <- values do
      refute rendered(error) =~ value, "C3-02: the refusal must not echo the value"
    end
  end

  defp outcome(fun) do
    case fun.() do
      :ok -> :ok
      other -> {:returned, other}
    end
  rescue
    error -> {:raised, error.__struct__}
  end

  defp attempt(fun) do
    fun.()
  rescue
    error in ExUnit.AssertionError -> reraise error, __STACKTRACE__
    error -> {:raised, error}
  end

  # Whether an IdentityKeys exception surfaced, raised directly, wrapped by
  # Ash (an unknown error rendering it) or returned through a transaction.
  defp carries?({:raised, error}, module), do: carries?(error, module)
  defp carries?({:error, error}, module), do: carries?(error, module)
  defp carries?({:ok, value}, module), do: carries?(value, module)

  defp carries?(%{__exception__: true} = error, module),
    do: error.__struct__ == module or rendered(error) =~ inspect(module)

  defp carries?(_other, _module), do: false

  defp rendered(error),
    do:
      Exception.message(error) <>
        " " <> inspect(error, limit: :infinity, printable_limit: :infinity)
end
