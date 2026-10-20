defmodule SdrAgent.SDR.AdmitLeadTest do
  @moduledoc """
  C3-02 RED-2, plan r8 section 11 F (T-F1..T-F15): `SdrAgent.SDR.admit_lead/2`
  for `manual`, `csv`, `hubspot` and `agent_found` (packet section 4.1
  decision table, 4.3 readmit, 4.4 step 14a, 4.5 run settings, section 9
  C3-02 bullets; plan sections 6.3 owner and origin, 6.5 guard, 7.2 lookup
  callers including `assign_lead`).

  RED form: `admit_lead/2`, `bootstrap_definitions/1`,
  `SdrAgent.Sales.LeadAdmission` and `SdrAgent.SDR.Admission` do not exist
  on main. Each test asserts their presence (`C3-02:` messages) before any
  call and calls them through `apply/3`. Setup uses only main's APIs
  (`bootstrap!/0`, `human/2`, `SalesFixtures`, `SettingsFixtures`,
  `AgentsFixtures`, Lead `:seed`, `Outreach.suppress/2`); everything that
  needs a definition calls the guarded `bootstrap_definitions/1` first in
  the test body. Leads built at an existing company use the dev/test
  `:seed` boundary (source `fixture`), so the setup stays valid after the
  cutover. Three tests are behavioural: T-F9's direct Lead `:create` (main
  allows it) and T-F15's `assign_lead` (main registers the definition).

  Exact counts: `snapshot/1` counts every row of the tables an admission can
  touch (`lead_admissions` only after asserting the resource exists) and
  audit events per type; deltas are asserted exactly.

  Not buildable with main's APIs, so not covered here: a last closed lead
  `referred` (C3-03) and the referral handover (C3-03); the step 16
  snapshot refusal (T-F13 names the code path); the step 9 guard on
  resolved values (T-F11 says why); the direct-SQL negatives of step 14a
  and the DB checks (section 11 E).

  Interface names chosen here for review (beyond the RED-2 brief):
    * `SdrAgent.SDR.Admission.real_data_permitted?(domain, email)` returns a
      boolean (the reserved-name policy until C5-04);
    * a refused actor gets `{:error, :forbidden}`; only an auditor's attempt
      is pinned to append exactly one `authz.denied` (the Guard rule),
      other refusals may append only `authz.denied`;
    * a refused input names the leaf field: `{:invalid, [:email]}`,
      `{:invalid, [:domain]}`, `{:invalid, [:readmit]}`;
    * a replay returns the stored admission and run with `lead` re-read
      (its current status) and `replayed?: true`;
    * a non-admitted outcome appends exactly one `sales.admission.recorded`
      event and one `lead_admissions` row, nothing else;
    * `assign_lead/2` on a missing definition returns
      `{:error, :agent_definition_unavailable}`;
    * `admission.contact_id` is nil for `active_target_exists` and
      `company_in_relationship` (no contact created), `account_id` nil for
      `contact_at_other_account` (packet section 3 check).
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Accounts
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit.GuardedCall
  alias SdrAgent.Outreach
  alias SdrAgent.Research
  alias SdrAgent.Sales
  alias SdrAgent.SalesFixtures
  alias SdrAgent.SDR.SDRAgent
  alias SdrAgent.SettingsFixtures

  @sdr SdrAgent.SDR
  @admission SdrAgent.Sales.LeadAdmission
  @admission_orchestrator SdrAgent.SDR.Admission

  @kinds [:manual, :csv, :hubspot, :agent_found]
  @company_kinds [:csv, :hubspot, :agent_found]

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

  @recorded %{
    rows: %{"lead_admissions" => 1, "audit_events" => 1},
    events: %{"sales.admission.recorded" => 1}
  }

  @nothing %{rows: %{}, events: %{}}

  setup do
    tenant = bootstrap!()
    admin = human(:admin, tenant)
    campaign = SalesFixtures.active_campaign!(tenant)
    %{tenant: tenant, admin: admin, campaign: campaign}
  end

  describe "T-F1 each kind admits" do
    setup :offering

    for kind <- [:manual, :csv, :hubspot, :agent_found] do
      test "T-F1 #{kind} admits a new person at a new company", ctx do
        kind = unquote(kind)
        ctx = ready!(ctx, kind)
        input = input(ctx, kind)
        before = snapshot()

        value = admit!(input, ctx.admin, :admitted)

        assert_admitted_rows!(before, account: true, contact: true)
        assert_admitted!(ctx, kind, input, value)
        assert queued_runs(value.lead.id) == 1
        assert value.admission.account_created and value.admission.contact_created

        assert {:ok, account} =
                 Sales.fetch(Sales.Account, value.lead.account_id, actor: ctx.admin)

        assert to_string(account.domain) == input.company.domain
        assert account.source == kind

        assert {:ok, contact} =
                 Sales.fetch(Sales.Contact, value.lead.contact_id, actor: ctx.admin)

        assert to_string(contact.email) == input.person.email
        assert contact.account_id == account.id
      end
    end
  end

  describe "T-F2 decision table" do
    setup :offering

    test "T-F2 an email at another account is contact_at_other_account; no account is created",
         ctx do
      ctx = ready!(ctx, :agent_found)

      for kind <- @kinds do
        e = existing(ctx)
        input = input(ctx, kind, email: e.email)
        before = snapshot()
        value = admit!(input, ctx.admin, :contact_at_other_account)
        assert changes(before) == @recorded
        assert value.admission.account_id == nil
        assert value.admission.matched_lead_id == nil
      end
    end

    test "T-F2 an archived contact is contact_archived; an archived account is account_archived",
         ctx do
      ctx = ready!(ctx, :agent_found)

      for kind <- @kinds do
        e = existing(ctx)
        assert {:ok, _} = Sales.update(e.contact, :archive, %{}, actor: ctx.admin)
        before = snapshot()

        value =
          admit!(input(ctx, kind, domain: e.domain, email: e.email), ctx.admin, :contact_archived)

        assert changes(before) == @recorded

        assert {value.admission.account_id, value.admission.contact_id} ==
                 {e.account.id, e.contact.id}

        account = SalesFixtures.account!(ctx.tenant)
        assert {:ok, _} = Sales.update(account, :archive, %{}, actor: ctx.admin)
        before = snapshot()
        domain = to_string(account.domain)
        value = admit!(input(ctx, kind, domain: domain), ctx.admin, :account_archived)
        assert changes(before) == @recorded
        assert {value.admission.account_id, value.admission.contact_id} == {account.id, nil}
      end
    end

    test "T-F2 the contact's open lead is duplicate_open_lead with the matched lead", ctx do
      ctx = ready!(ctx, :agent_found)

      for kind <- @kinds do
        e = existing(ctx)
        open = seed_lead!(ctx.tenant, e.contact)
        before = snapshot()

        value =
          admit!(
            input(ctx, kind, domain: e.domain, email: e.email),
            ctx.admin,
            :duplicate_open_lead
          )

        assert changes(before) == @recorded
        assert value.admission.matched_lead_id == open.id

        assert {value.admission.account_id, value.admission.contact_id} ==
                 {e.account.id, e.contact.id}
      end
    end

    test "T-F2 a second admission of the same person by another ref is duplicate_open_lead",
         ctx do
      ctx = ready!(ctx, :agent_found)
      first_input = input(ctx, :manual)
      first = admit!(first_input, ctx.admin, :admitted)
      %{company: %{domain: domain}, person: %{email: email}} = first_input

      for kind <- @kinds do
        before = snapshot()

        value =
          admit!(input(ctx, kind, domain: domain, email: email), ctx.admin, :duplicate_open_lead)

        assert changes(before) == @recorded
        assert value.admission.matched_lead_id == first.lead.id
      end
    end

    test "T-F2 another person at a company with an open lead is active_target_exists", ctx do
      ctx = ready!(ctx, :agent_found)

      for kind <- @kinds do
        e = existing(ctx)
        open = seed_lead!(ctx.tenant, e.contact)
        input = input(ctx, kind, domain: e.domain)
        before = snapshot()
        value = admit!(input, ctx.admin, :active_target_exists)
        assert changes(before) == @recorded
        assert value.admission.matched_lead_id == open.id
        assert {value.admission.account_id, value.admission.contact_id} == {e.account.id, nil}
      end
    end

    test "T-F2 a contact with only closed leads is previously_worked without readmit", ctx do
      ctx = ready!(ctx, :agent_found)

      for kind <- @kinds do
        e = existing(ctx)
        _stopped = closed_lead!(ctx, e.contact, :stopped)
        before = snapshot()

        value =
          admit!(
            input(ctx, kind, domain: e.domain, email: e.email),
            ctx.admin,
            :previously_worked
          )

        assert changes(before) == @recorded
        assert value.admission.readmit == false
        assert value.admission.matched_lead_id == nil
      end
    end
  end

  describe "T-F3 suppressed" do
    setup :offering

    test "T-F3 a suppressed email is recorded suppressed (scope :email); nothing else written",
         ctx do
      ctx = ready!(ctx, :agent_found)

      for kind <- @kinds do
        input = input(ctx, kind)
        suppress!(ctx, :email, input.person.email)
        assert_suppressed!(ctx, input, :email)
      end
    end

    test "T-F3 a suppressed email domain is recorded suppressed (scope :domain)", ctx do
      ctx = ready!(ctx, :agent_found)

      for kind <- @kinds do
        n = SalesFixtures.unique()
        mail_host = "mailhost-#{n}.test"
        input = input(ctx, kind, email: "pat.#{n}@#{mail_host}")
        suppress!(ctx, :domain, mail_host)
        assert_suppressed!(ctx, input, :domain)
      end
    end

    test "T-F3 a suppressed company domain is recorded suppressed, new or existing account",
         ctx do
      ctx = ready!(ctx, :agent_found)

      for kind <- @kinds do
        n = SalesFixtures.unique()
        input = input(ctx, kind, email: "pat.#{n}@mailhost-#{n}.test")
        suppress!(ctx, :domain, input.company.domain)
        assert_suppressed!(ctx, input, :domain)

        account = SalesFixtures.account!(ctx.tenant)
        domain = to_string(account.domain)
        input = input(ctx, kind, domain: domain, email: "kim.#{n}@mailhost-#{n}.test")
        suppress!(ctx, :domain, domain)
        assert_suppressed!(ctx, input, :domain)
      end
    end

    test "T-F3 suppression (step 10) wins over an email at another account (step 11)", ctx do
      ctx = ready!(ctx, :manual)
      e = existing(ctx)
      suppress!(ctx, :email, e.email)
      assert_suppressed!(ctx, input(ctx, :manual, email: e.email), :email)
    end
  end

  describe "T-F4 step 14a" do
    setup :offering

    test "T-F4 a last closed converted or nurture lead gives company_in_relationship", ctx do
      ctx = ready!(ctx, :agent_found)

      for kind <- @company_kinds, status <- [:converted, :nurture] do
        e = existing(ctx)
        _closed = closed_lead!(ctx, e.contact, status)
        before = snapshot()
        value = admit!(input(ctx, kind, domain: e.domain), ctx.admin, :company_in_relationship)
        assert changes(before) == @recorded, "C3-02: #{kind} after #{status}"
        assert {value.admission.account_id, value.admission.contact_id} == {e.account.id, nil}
        assert value.admission.source_kind == kind
      end
    end

    # A last closed `referred` lead (C3-03) cannot be built on main.
    test "T-F4 a last closed disqualified or stopped lead does not apply step 14a", ctx do
      ctx = ready!(ctx, :agent_found)

      for kind <- @company_kinds, status <- [:disqualified, :stopped] do
        e = existing(ctx)
        _closed = closed_lead!(ctx, e.contact, status)
        before = snapshot()
        value = admit!(input(ctx, kind, domain: e.domain), ctx.admin, :admitted)
        assert_admitted_rows!(before, account: false, contact: true)
        assert value.lead.account_id == e.account.id
      end
    end

    # A referral is unaffected by step 14a: `admit_lead` refuses it (T-F10);
    # its handover is C3-03.
    test "T-F4 manual skips step 14a", ctx do
      ctx = ready!(ctx, :manual)

      for status <- [:converted, :nurture] do
        e = existing(ctx)
        _closed = closed_lead!(ctx, e.contact, status)
        before = snapshot()
        value = admit!(input(ctx, :manual, domain: e.domain), ctx.admin, :admitted)
        assert_admitted_rows!(before, account: false, contact: true)
        assert value.lead.account_id == e.account.id
      end
    end

    test "T-F4 the most recently closed lead decides: closed_at DESC NULLS LAST, id DESC", ctx do
      ctx = ready!(ctx, :csv)

      # later closed_at wins
      %{domain: d1} = two_closed!(ctx, {:converted, "2026-01-01"}, {:disqualified, "2026-02-01"})
      admit!(input(ctx, :csv, domain: d1), ctx.admin, :admitted)

      %{domain: d2} = two_closed!(ctx, {:converted, "2026-02-01"}, {:disqualified, "2026-01-01"})
      admit!(input(ctx, :csv, domain: d2), ctx.admin, :company_in_relationship)

      # a legacy closed row without closed_at sorts after every stamped one
      %{domain: d3} = two_closed!(ctx, {:converted, "2026-01-01"}, {:disqualified, nil})
      admit!(input(ctx, :csv, domain: d3), ctx.admin, :company_in_relationship)

      # equal closed_at: the higher id decides
      %{domain: d4, leads: leads} =
        two_closed!(ctx, {:converted, "2026-03-01"}, {:disqualified, "2026-03-01"})

      expected =
        if Enum.max_by(leads, & &1.id).status == :converted,
          do: :company_in_relationship,
          else: :admitted

      admit!(input(ctx, :csv, domain: d4), ctx.admin, expected)
    end
  end

  describe "T-F5 readmit" do
    setup :offering

    test "T-F5 manual: readmit false is previously_worked; readmit true admits, old lead kept",
         ctx do
      ctx = ready!(ctx, :manual)
      e = existing(ctx)
      old = closed_lead!(ctx, e.contact, :stopped)

      for put <- [[], [readmit: false]] do
        before = snapshot()
        input = input(ctx, :manual, domain: e.domain, email: e.email, put: put)
        value = admit!(input, ctx.admin, :previously_worked)
        assert changes(before) == @recorded
        assert value.admission.readmit == false
      end

      before = snapshot()
      input = input(ctx, :manual, domain: e.domain, email: e.email, put: [readmit: true])
      value = admit!(input, ctx.admin, :admitted)
      assert_admitted_rows!(before, account: false, contact: false)
      assert value.admission.readmit == true
      refute value.admission.account_created or value.admission.contact_created
      assert value.lead.contact_id == e.contact.id
      refute value.lead.id == old.id
      assert reread(ctx, old).status == :stopped
    end

    test "T-F5 readmit present on csv, hubspot or agent_found is refused; nothing written", ctx do
      ctx = ready!(ctx, :agent_found)
      e = existing(ctx)
      _old = closed_lead!(ctx, e.contact, :stopped)

      for kind <- @company_kinds, flag <- [true, false] do
        input = input(ctx, kind, domain: e.domain, email: e.email, put: [readmit: flag])
        before = snapshot()
        assert admit(input, ctx.admin) == {:error, {:invalid, [:readmit]}}, "C3-02: #{kind}"
        assert changes(before) == @nothing
        assert admissions_for(input.source_ref) == 0
      end
    end

    test "T-F5 readmit never overrides suppression, archived identities or an open lead", ctx do
      ctx = ready!(ctx, :manual)

      suppressed = existing(ctx)
      _ = closed_lead!(ctx, suppressed.contact, :stopped)
      suppress!(ctx, :email, suppressed.email)

      archived = existing(ctx)
      _ = closed_lead!(ctx, archived.contact, :stopped)
      assert {:ok, _} = Sales.update(archived.contact, :archive, %{}, actor: ctx.admin)

      open = existing(ctx)
      _ = seed_lead!(ctx.tenant, open.contact)

      # The worked contact's lead closes before the open lead is seeded (one
      # open lead per company after C3-02).
      target = existing(ctx)
      other = SalesFixtures.contact!(ctx.tenant, target.account)
      _ = closed_lead!(ctx, other, :stopped)
      _ = seed_lead!(ctx.tenant, target.contact)

      cases = [
        {suppressed, suppressed.email, :suppressed},
        {archived, archived.email, :contact_archived},
        {open, open.email, :duplicate_open_lead},
        {target, to_string(other.email), :active_target_exists}
      ]

      for {e, email, outcome} <- cases do
        input = input(ctx, :manual, domain: e.domain, email: email, put: [readmit: true])
        before = snapshot()
        value = admit!(input, ctx.admin, outcome)
        assert changes(before) == @recorded
        assert value.admission.readmit == true
      end
    end
  end

  describe "T-F6..T-F8 replay" do
    setup :offering

    test "T-F6 an identical replay after the campaign is paused writes nothing", ctx do
      ctx = ready!(ctx, :agent_found)
      firsts = for kind <- @kinds, do: {kind, input(ctx, kind)}
      firsts = for {kind, input} <- firsts, do: {input, admit!(input, ctx.admin, :admitted), kind}
      assert {:ok, _} = Sales.update(ctx.campaign, :pause, %{}, actor: ctx.admin)
      before = snapshot()

      for {input, first, kind} <- firsts do
        replay = replay!(input, ctx.admin, first)
        assert replay.outcome == :admitted, "C3-02: #{kind}"
        assert replay.run.id == first.run.id
      end

      assert changes(before) == @nothing
      new_request = admit(input(ctx, :manual), ctx.admin)
      assert new_request == {:error, :campaign_not_active}
    end

    test "T-F6 an identical replay after the lead moved on returns its current status", ctx do
      ctx = ready!(ctx, :manual)
      input = input(ctx, :manual)
      first = admit!(input, ctx.admin, :admitted)
      reason = %{status_reason: "c3-02 fixture"}
      assert {:ok, _} = Sales.update(first.lead, :stop, reason, actor: ctx.admin)
      before = snapshot()

      replay = replay!(input, ctx.admin, first)
      assert replay.lead.id == first.lead.id
      assert replay.lead.status == :stopped
      assert changes(before) == @nothing
    end

    test "T-F6 an identical replay after a suppression appeared returns the stored result", ctx do
      ctx = ready!(ctx, :manual)
      input = input(ctx, :manual)
      first = admit!(input, ctx.admin, :admitted)
      suppress!(ctx, :email, input.person.email)
      current = reread(ctx, first.lead)
      before = snapshot()

      replay = replay!(input, ctx.admin, first)
      assert replay.outcome == :admitted
      assert replay.lead.status == current.status
      assert changes(before) == @nothing
    end

    test "T-F6 a recorded outcome replays as stored after its facts change; another admin too",
         ctx do
      ctx = ready!(ctx, :manual)
      e = existing(ctx)
      open = seed_lead!(ctx.tenant, e.contact)
      input = input(ctx, :manual, domain: e.domain, email: e.email)
      first = admit!(input, ctx.admin, :duplicate_open_lead)
      assert {:ok, _} = Sales.update(open, :stop, %{status_reason: "c3-02"}, actor: ctx.admin)
      other_admin = new_human(:admin, ctx.tenant)
      before = snapshot()

      for actor <- [ctx.admin, other_admin] do
        replay = replay!(input, actor, first)
        assert replay.outcome == :duplicate_open_lead
        assert replay.admission.requested_by_user_id == ctx.admin.id
      end

      assert changes(before) == @nothing
    end

    test "T-F7 the same ref with different input is :source_ref_conflict; nothing written", ctx do
      ctx = ready!(ctx, :manual)
      input = input(ctx, :manual)
      first = admit!(input, ctx.admin, :admitted)
      other_campaign = SalesFixtures.active_campaign!(ctx.tenant)

      changed = [
        put_in(input, [:person, :first_name], "Other"),
        put_in(input, [:company, :name], "Other Co"),
        put_in(input, [:person, :title], nil),
        Map.put(input, :campaign_id, other_campaign.id),
        Map.put(input, :readmit, true)
      ]

      before = snapshot()

      for conflicting <- changed do
        assert admit(conflicting, ctx.admin) == {:error, :source_ref_conflict}
      end

      assert changes(before) == @nothing

      equivalent =
        input
        |> put_in([:person, :email], "  " <> String.upcase(input.person.email) <> " ")
        |> put_in([:company, :domain], "WWW." <> input.company.domain <> ".")
        |> put_in([:person, :first_name], " Pat ")

      replay!(equivalent, ctx.admin, first)
      assert changes(before) == @nothing
    end

    test "T-F8 a replay is refused only by steps 1-5", ctx do
      ctx = ready!(ctx, :manual)
      input = input(ctx, :manual)
      first = admit!(input, ctx.admin, :admitted)
      disabled = disabled_admin!(ctx)
      nonreserved = "#{canary()}.zz"

      refusals = [
        {input, human(:reviewer, ctx.tenant), {:error, :forbidden}},
        {input, disabled, {:error, :forbidden}},
        {put_in(input, [:person, :email], "not-an-email"), ctx.admin,
         {:error, {:invalid, [:email]}}},
        {put_in(input, [:company, :domain], "www.www.x.test"), ctx.admin,
         {:error, {:invalid, [:domain]}}},
        {put_in(input, [:person, :email], "pat@" <> nonreserved), ctx.admin,
         {:error, :real_data_disabled}}
      ]

      before = snapshot()

      for {attempt, actor, expected} <- refusals do
        assert admit(attempt, actor) == expected
      end

      assert_only_denials!(before)

      # Steps 7, 8 and 8a do not refuse a replay.
      assert {:ok, _} = Sales.update(ctx.campaign, :pause, %{}, actor: ctx.admin)
      retire_definitions!(ctx.tenant)
      SettingsFixtures.withhold_offering!(ctx.tenant.id)
      before = snapshot()
      replay = replay!(input, ctx.admin, first)
      assert replay.run.id == first.run.id
      assert changes(before) == @nothing
    end
  end

  describe "T-F9 policy" do
    setup :offering

    test "T-F9 an active admin admits and owns the lead (allow)", ctx do
      ctx = ready!(ctx, :manual)
      other = new_human(:admin, ctx.tenant)
      value = admit!(input(ctx, :manual), other, :admitted)
      assert value.lead.owner_user_id == other.id
      assert value.admission.requested_by_user_id == other.id
    end

    test "T-F9 reviewers, disabled or foreign admins, nil and every system actor are refused",
         ctx do
      ctx = ready!(ctx, :manual)
      disabled = disabled_admin!(ctx)
      foreign = %{ctx.admin | tenant_id: Ecto.UUID.generate()}
      systems = for type <- SdrAgent.Actor.types(), do: SdrAgent.Actor.system(type, ctx.tenant.id)
      actors = [human(:reviewer, ctx.tenant), disabled, foreign, nil | systems]
      attempts = for actor <- actors, do: {actor, input(ctx, :manual)}
      before = snapshot()

      for {actor, input} <- attempts do
        assert admit(input, actor) == {:error, :forbidden}, "C3-02: #{inspect(actor)}"
        assert admissions_for(input.source_ref) == 0
      end

      assert_only_denials!(before)
    end

    test "T-F9 an auditor is refused and the refusal is audited exactly once", ctx do
      ctx = ready!(ctx, :manual)
      auditor = human(:auditor, ctx.tenant)
      input = input(ctx, :manual)
      before = snapshot()

      assert admit(input, auditor) == {:error, :forbidden}

      assert changes(before) == %{
               rows: %{"audit_events" => 1},
               events: %{"authz.denied" => 1}
             }
    end

    test "T-F9 a stale admin struct demoted or disabled in the database is refused (step 5)",
         ctx do
      ctx = ready!(ctx, :manual)
      demoted = new_human(:admin, ctx.tenant)
      disabled = new_human(:admin, ctx.tenant)
      assert {:ok, _} = Accounts.change_role(demoted, :reviewer, actor: ctx.admin)
      assert {:ok, _} = Accounts.change_status(disabled, :disabled, actor: ctx.admin)
      attempts = for stale <- [demoted, disabled], do: {stale, input(ctx, :manual)}
      before = snapshot()

      for {stale, input} <- attempts do
        assert stale.role == :admin and stale.status == :active
        assert admit(input, stale) == {:error, :forbidden}
        assert admissions_for(input.source_ref) == 0
      end

      assert_only_denials!(before)
    end

    # Behavioural RED: main's Lead :create authorizes an active admin
    # without any admission marker.
    test "T-F9 a direct Lead :create without the admission marker is denied", ctx do
      e = existing(ctx)

      refute Ash.can?({Sales.Lead, :create}, ctx.admin),
             "C3-02: Lead :create must be forbidden without LeadAdmissionContext"

      result =
        Sales.create_lead(
          %{contact_id: e.contact.id, account_id: e.account.id, source: :manual},
          actor: ctx.admin
        )

      assert match?({:error, %Ash.Error.Forbidden{}}, result),
             "C3-02: a direct Lead :create must be refused: #{short(result)}"

      assert leads_of(e.contact.id) == 0
    end

    test "T-F9 LeadAdmission :record without the admission marker is denied", ctx do
      assert Code.ensure_loaded?(@admission), "C3-02: #{inspect(@admission)} is not available"

      assert Ash.Resource.Info.action(@admission, :record),
             "C3-02: #{inspect(@admission)} has no :record action"

      refute Ash.can?({@admission, :record}, ctx.admin),
             "C3-02: LeadAdmission :record must be forbidden without LeadAdmissionContext"

      ref = "manual:#{Ecto.UUID.generate()}"

      attrs = %{
        source_kind: :manual,
        source_ref: ref,
        input_version: 1,
        input_sha256: String.duplicate("0", 64),
        outcome: :suppressed,
        suppression_scope: :email,
        campaign_id: ctx.campaign.id,
        requested_by_user_id: ctx.admin.id
      }

      before = snapshot()
      result = GuardedCall.create(@admission, :record, attrs, actor: ctx.admin)
      refute match?({:ok, _}, result), "C3-02: a direct :record must be refused"
      assert admissions_for(ref) == 0
      assert_only_denials!(before)
    end
  end

  describe "T-F10 referral" do
    setup :offering

    test "T-F10 admit_lead refuses :referral with :use_referral_handover; nothing written", ctx do
      present!(@sdr, :admit_lead, 2)

      attempts =
        for put <- [[], [readmit: true]] do
          ctx
          |> input(:manual, put: put)
          |> Map.merge(%{source_kind: :referral, source_ref: ref(ctx, :referral)})
        end

      before = snapshot()

      for input <- attempts do
        assert admit(input, ctx.admin) == {:error, :use_referral_handover}
        assert admissions_for(input.source_ref) == 0
      end

      assert changes(before) == @nothing
    end
  end

  describe "T-F11 guard" do
    setup :offering

    test "T-F11 real_data_permitted?/2 is the reserved-name policy until C5-04" do
      present!(@admission_orchestrator, :real_data_permitted?, 2)
      nonreserved = "#{canary()}.zz"

      vectors = [
        {"acme.test", "jo@acme.test", true},
        {"orbit.example.org", "pat@example.com", true},
        {"sales.acme.example", "kim@mail.acme.invalid", true},
        {nonreserved, "jo@acme.test", false},
        {"acme.test", "jo@" <> nonreserved, false},
        {nonreserved, "jo@" <> nonreserved, false}
      ]

      for {domain, email, permitted} <- vectors do
        assert call(@admission_orchestrator, :real_data_permitted?, [domain, email]) == permitted,
               "C3-02: real_data_permitted?(#{domain}, #{email})"
      end
    end

    # Step 9 re-applies the same function to the resolved stored values. On
    # main it cannot refuse separately: an adopted account is found by the
    # canonical form of the input domain and a contact by the normalized
    # input email, so a value that passed step 4 resolves to a stored value
    # with the same reserved-name verdict.
    test "T-F11 a non-reserved domain or email is refused :real_data_disabled (step 4)", ctx do
      ctx = ready!(ctx, :agent_found)
      nonreserved = "#{canary()}.zz"

      attempts =
        for kind <- @kinds,
            opts <- [[domain: nonreserved], [email: "pat@" <> nonreserved]] do
          input(ctx, kind, opts)
        end

      before = snapshot()

      for input <- attempts do
        assert admit(input, ctx.admin) == {:error, :real_data_disabled}
        assert admissions_for(input.source_ref) == 0
      end

      assert changes(before) == @nothing
    end
  end

  describe "T-F12 settings pre-check" do
    for kind <- [:manual, :csv, :hubspot, :agent_found] do
      test "T-F12 #{kind}: no offering profile refuses every new request; the ref stays free",
           ctx do
        kind = unquote(kind)
        present!(@sdr, :admit_lead, 2)
        definitions!(ctx.tenant)
        ctx = discovery_without_offering(ctx, kind)
        shapes = shapes(ctx, kind)
        before = snapshot()

        for {_outcome, input} <- shapes do
          assert admit(input, ctx.admin) == {:error, {:settings_incomplete, [:offering_profile]}}
        end

        assert changes(before) == @nothing

        assert Enum.map(shapes, fn {_, input} -> admissions_for(input.source_ref) end) == [
                 0,
                 0,
                 0
               ]

        SettingsFixtures.save_offering!(ctx.admin)

        for {outcome, input} <- shapes do
          value = admit!(input, ctx.admin, outcome)
          assert value.replayed? == false
        end
      end
    end
  end

  # The authoritative refusal at step 16 is `BuildSettingsSnapshot.build/2`
  # (lib/sdr_agent/agents/changes/build_settings_snapshot.ex:60-89) under
  # the chain head: `missing/2` non-empty adds the `settings_incomplete`
  # error on `:usage_origin`, and `snapshot_values/2` with an `:unavailable`
  # slot (`CodeDefaults.fetch/2` returning `:error` for the current default)
  # adds `settings_default_unavailable` on `:settings_snapshot_id`. No main
  # mechanism reaches either inside an admission: the C4 suite reaches
  # `settings_default_unavailable` only through `run_settings/2` over a
  # tampered stored snapshot, and `settings_incomplete` at step 16 needs the
  # profile to vanish between the step 8a pre-check and the snapshot (the
  # T-I9/T-I10 races, RED-3). What is reachable here: `admitted` always
  # carries its queued run bound to a snapshot, and a replay builds none.
  describe "T-F13 snapshot" do
    setup :offering

    test "T-F13 an admitted run is bound to its snapshot built for :assignment", ctx do
      ctx = ready!(ctx, :manual)
      value = admit!(input(ctx, :manual), ctx.admin, :admitted)
      agent = system_actor(:agent_runtime, ctx.tenant)
      snapshot = SettingsFixtures.snapshot_of!(value.run, agent)

      assert {snapshot.offering_profile_source, snapshot.offering_profile_revision_id} ==
               {:revision, ctx.offering.id}

      for kind <- [:writing_guide, :research_brief, :operational_limits] do
        assert Map.get(snapshot, :"#{kind}_source") == :code_default
      end

      assert value.run.usage_origin == :assignment

      assert {value.run.budget.max_model_calls, value.run.budget.max_tool_calls,
              value.run.budget.max_tokens} ==
               {snapshot.limits.run_max_model_calls, snapshot.limits.run_max_tool_calls,
                snapshot.limits.run_max_tokens}
    end

    test "T-F13 a replay after a new settings revision returns the stored run, builds nothing",
         ctx do
      ctx = ready!(ctx, :manual)
      input = input(ctx, :manual)
      first = admit!(input, ctx.admin, :admitted)
      _newer = SettingsFixtures.save_offering!(ctx.admin, %{name: "Example Widgets Planner"})
      before = snapshot()

      replay = replay!(input, ctx.admin, first)
      assert replay.run.id == first.run.id
      assert replay.run.settings_snapshot_id == first.run.settings_snapshot_id
      assert changes(before) == @nothing
    end
  end

  describe "T-F14 no skip" do
    setup :offering

    test "T-F14 an admitted lead cannot qualify, start outreach or enroll without research",
         ctx do
      ctx = ready!(ctx, :agent_found)
      agent = system_actor(:agent_runtime, ctx.tenant)
      %{run: run} = SalesFixtures.run!(ctx.tenant)

      for kind <- @kinds do
        lead = admit!(input(ctx, kind), ctx.admin, :admitted).lead
        decision = SalesFixtures.decision!(ctx.tenant, run, lead, "skip").id

        attempts = [
          Sales.update(lead, :start_outreach, %{decision_id: decision}, actor: agent),
          Sales.update(lead, :qualify, %{decision_id: decision}, actor: agent),
          Sales.enroll_lead(%{campaign_id: ctx.campaign.id, lead_id: lead.id}, actor: agent),
          qualify_directly(ctx, lead)
        ]

        for result <- attempts, do: assert(match?({:error, _}, result), "C3-02: #{kind}")
        assert reread(ctx, lead).status == :assigned
        assert work_rows(lead.id) == %{qualifications: 0, enrollments: 0, drafts: 0}
      end
    end
  end

  describe "T-F15 missing definition" do
    setup :offering

    test "T-F15 with no definition, refusals before step 8 write and register nothing", ctx do
      present!(@sdr, :admit_lead, 2)
      assert_no_definition!(ctx.tenant)
      paused = SalesFixtures.active_campaign!(ctx.tenant)
      assert {:ok, paused} = Sales.update(paused, :pause, %{}, actor: ctx.admin)

      referral =
        Map.merge(input(ctx, :manual), %{source_kind: :referral, source_ref: ref(ctx, :referral)})

      refusals = [
        {input(ctx, :manual), human(:reviewer, ctx.tenant), {:error, :forbidden}},
        {referral, ctx.admin, {:error, :use_referral_handover}},
        {input(ctx, :manual, email: "not-an-email"), ctx.admin, {:error, {:invalid, [:email]}}},
        {input(ctx, :manual, domain: "#{canary()}.zz"), ctx.admin, {:error, :real_data_disabled}},
        {input(ctx, :manual, put: [campaign_id: paused.id]), ctx.admin,
         {:error, :campaign_not_active}}
      ]

      before = snapshot()

      for {input, actor, expected} <- refusals do
        assert admit(input, actor) == expected
      end

      assert_only_denials!(before)
      assert_no_definition!(ctx.tenant)
    end

    test "T-F15 with no definition, every new request is :agent_definition_unavailable", ctx do
      present!(@sdr, :admit_lead, 2)
      ctx = discovery(ctx)
      assert_no_definition!(ctx.tenant)
      attempts = Enum.flat_map(@kinds, &shapes(ctx, &1))
      before = snapshot()

      for {_outcome, input} <- attempts do
        assert admit(input, ctx.admin) == {:error, :agent_definition_unavailable},
               "C3-02: #{input.source_kind}"
      end

      assert changes(before) == @nothing
      assert Enum.all?(attempts, fn {_, input} -> admissions_for(input.source_ref) == 0 end)
      assert_no_definition!(ctx.tenant)
    end

    test "T-F15 after the definition goes missing, replay and conflict are unchanged", ctx do
      ctx = ready!(ctx, :manual)
      input = input(ctx, :manual)
      first = admit!(input, ctx.admin, :admitted)
      retire_definitions!(ctx.tenant)
      before = snapshot()

      replay = replay!(input, ctx.admin, first)
      assert replay.run.id == first.run.id
      conflicting = put_in(input, [:person, :first_name], "Other")
      assert admit(conflicting, ctx.admin) == {:error, :source_ref_conflict}
      assert admit(input(ctx, :manual), ctx.admin) == {:error, :agent_definition_unavailable}
      assert changes(before) == @nothing
    end

    # Behavioural RED: main's assign_lead registers the definition under the
    # head (sdr.ex:91-92); C3-02 makes it a read-only lookup before any write.
    test "T-F15 assign_lead with no definition is :agent_definition_unavailable", ctx do
      assert_no_definition!(ctx.tenant)
      e = existing(ctx)
      lead = seed_lead!(ctx.tenant, e.contact)
      before = snapshot(@main_tables)

      result = @sdr.assign_lead(lead, campaign_id: ctx.campaign.id, actor: ctx.admin)

      assert result == {:error, :agent_definition_unavailable},
             "C3-02: assign_lead must not register: #{short(result)}"

      assert changes(before, @main_tables) == @nothing
      assert reread(ctx, lead).status == :new
      assert_no_definition!(ctx.tenant)
    end
  end

  ## Setup helpers

  defp offering(ctx), do: %{offering: SettingsFixtures.save_offering!(ctx.admin)}

  # Guards the subject, gives the tenant its definition, and a discovery run
  # when the kind needs one.
  defp ready!(ctx, kind) do
    present!(@sdr, :admit_lead, 2)
    definitions!(ctx.tenant)
    if kind == :agent_found, do: discovery(ctx), else: ctx
  end

  defp discovery(ctx) do
    %{run: run} = AgentsFixtures.running_run(ctx.tenant, usage_origin: :discovery)
    Map.put(ctx, :discovery_run, run)
  end

  # The discovery run needs an offering profile; it is withheld afterwards
  # with main's C4 fixture, standing in for "no offering saved".
  defp discovery_without_offering(ctx, :agent_found) do
    ctx = discovery(ctx)
    SettingsFixtures.withhold_offering!(ctx.tenant.id)
    ctx
  end

  defp discovery_without_offering(ctx, _kind), do: ctx

  # Three request shapes for the pre-check: would admit, would record
  # suppressed, would record duplicate_open_lead.
  defp shapes(ctx, kind) do
    suppressed = input(ctx, kind)
    suppress!(ctx, :email, suppressed.person.email)
    e = existing(ctx)
    _open = seed_lead!(ctx.tenant, e.contact)

    [
      {:admitted, input(ctx, kind)},
      {:suppressed, suppressed},
      {:duplicate_open_lead, input(ctx, kind, domain: e.domain, email: e.email)}
    ]
  end

  defp existing(ctx) do
    account = SalesFixtures.account!(ctx.tenant)
    contact = SalesFixtures.contact!(ctx.tenant, account)

    %{
      account: account,
      contact: contact,
      domain: to_string(account.domain),
      email: to_string(contact.email)
    }
  end

  defp seed_lead!(tenant, contact) do
    assert {:ok, lead} =
             Sales.seed_lead(
               %{contact_id: contact.id, account_id: contact.account_id, source: :fixture},
               actor: system_actor(:seeder, tenant)
             )

    lead
  end

  defp closed_lead!(ctx, contact, :stopped) do
    lead = seed_lead!(ctx.tenant, contact)
    reason = %{status_reason: "c3-02 fixture"}
    assert {:ok, lead} = Sales.update(lead, :stop, reason, actor: ctx.admin)
    lead
  end

  defp closed_lead!(ctx, contact, :disqualified), do: qualified!(ctx, contact, false)

  defp closed_lead!(ctx, contact, status) when status in [:converted, :nurture] do
    lead = qualified!(ctx, contact, true)
    agent = system_actor(:agent_runtime, ctx.tenant)
    %{run: run} = SalesFixtures.run!(ctx.tenant)
    decision = SalesFixtures.decision!(ctx.tenant, run, lead, "outreach").id

    assert {:ok, lead} =
             Sales.update(lead, :start_outreach, %{decision_id: decision}, actor: agent)

    webhook = system_actor(:webhook_ingestor, ctx.tenant)
    assert {:ok, lead} = Sales.update(lead, :mark_replied, %{}, actor: webhook)
    action = if status == :converted, do: :convert, else: :nurture
    assert {:ok, lead} = Sales.update(lead, action, %{}, actor: ctx.admin)
    lead
  end

  # The path of `SalesFixtures.qualified_lead!/2`, on a seeded lead at
  # `contact`: assign, research, qualifying, then an agent qualification.
  defp qualified!(ctx, contact, qualified?) do
    tenant = ctx.tenant
    agent = system_actor(:agent_runtime, tenant)
    lead = seed_lead!(tenant, contact)
    %{run: run} = SalesFixtures.run!(tenant)
    assert {:ok, lead} = Sales.update(lead, :assign, %{}, actor: human(:reviewer, tenant))
    research = %{decision_id: SalesFixtures.decision!(tenant, run, lead, "research").id}
    assert {:ok, lead} = Sales.update(lead, :start_research, research, actor: agent)
    qualify = %{decision_id: SalesFixtures.decision!(tenant, run, lead, "qualify").id}
    assert {:ok, lead} = Sales.update(lead, :start_qualifying, qualify, actor: agent)
    assert {:ok, _qualification} = record_qualification(ctx, lead, qualified?)
    reread(ctx, lead)
  end

  defp record_qualification(ctx, lead, qualified?) do
    tenant = ctx.tenant
    %{artifact: artifact, run: run} = SalesFixtures.artifact!(tenant, lead)
    claim = SalesFixtures.claim!(tenant, artifact, run)
    decision = SalesFixtures.qualification_decision!(tenant, run, lead)
    icp = SalesFixtures.active_icp!(tenant)

    attrs =
      SalesFixtures.qualification_attrs(lead, icp, run, decision, [claim], %{
        qualified: qualified?
      })

    Research.record_qualification(attrs, actor: system_actor(:agent_runtime, tenant))
  end

  defp qualify_directly(ctx, lead), do: record_qualification(ctx, lead, true)

  # Two leads at one new account, closed in turn, with closed_at then set
  # by a database-administrator write (nil = a legacy row without it).
  defp two_closed!(ctx, {first_status, first_at}, {second_status, second_at}) do
    e = existing(ctx)
    first = closed_lead!(ctx, e.contact, first_status)
    second = closed_lead!(ctx, SalesFixtures.contact!(ctx.tenant, e.account), second_status)
    set_closed_at!(first, first_at)
    set_closed_at!(second, second_at)
    %{domain: e.domain, leads: [first, second]}
  end

  defp set_closed_at!(lead, nil),
    do: tamper!("UPDATE leads SET closed_at = NULL WHERE id = $1", [uuid(lead.id)])

  defp set_closed_at!(lead, date),
    do:
      tamper!("UPDATE leads SET closed_at = ($2 || ' 00:00:00')::timestamp WHERE id = $1", [
        uuid(lead.id),
        date
      ])

  defp suppress!(ctx, scope, value) do
    assert {:ok, _} = Outreach.suppress(%{scope: scope, value: value}, actor: ctx.admin)
  end

  defp disabled_admin!(ctx) do
    admin = new_human(:admin, ctx.tenant)
    assert {:ok, disabled} = Accounts.change_status(admin, :disabled, actor: ctx.admin)
    disabled
  end

  # A database-administrator write that makes the committed definition fail
  # the lookup (status no longer `active`).
  defp retire_definitions!(tenant) do
    tamper!("UPDATE agent_definitions SET status = 'retired' WHERE tenant_id = $1", [
      uuid(tenant.id)
    ])
  end

  defp assert_no_definition!(tenant) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM agent_definitions WHERE tenant_id = $1 AND name = 'SDRAgent' " <>
          "AND version = $2 AND status = 'active'",
        [uuid(tenant.id), SDRAgent.version()]
      )

    assert n == 0, "an active SDRAgent definition exists (committed pollution?)"
  end

  ## Inputs

  defp input(ctx, kind, opts \\ []) do
    n = SalesFixtures.unique()
    domain = Keyword.get(opts, :domain, "admit-#{n}.test")

    %{
      source_kind: kind,
      source_ref: ref(ctx, kind),
      campaign_id: ctx.campaign.id,
      company: %{
        domain: domain,
        name: "Admit Co #{n}",
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
    |> with_run(ctx, kind)
    |> Map.merge(Map.new(Keyword.get(opts, :put, [])))
  end

  defp with_run(input, ctx, :agent_found), do: Map.put(input, :agent_run_id, ctx.discovery_run.id)
  defp with_run(input, _ctx, _kind), do: input

  defp ref(_ctx, :manual), do: "manual:#{Ecto.UUID.generate()}"
  defp ref(_ctx, :csv), do: "csv:#{Ecto.UUID.generate()}:#{SalesFixtures.unique()}"
  defp ref(_ctx, :hubspot), do: "hubspot:#{SalesFixtures.unique()}:#{SalesFixtures.unique()}"

  defp ref(ctx, :agent_found),
    do: "agent_found:#{ctx.discovery_run.id}:#{Ecto.UUID.generate()}"

  defp ref(_ctx, :referral), do: "referral:#{Ecto.UUID.generate()}:#{Ecto.UUID.generate()}"

  defp canary, do: "c302canary#{SalesFixtures.unique()}"

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

  defp definitions!(tenant) do
    result = call(@sdr, :bootstrap_definitions, [tenant.id])
    assert match?({:ok, _}, result), "C3-02: bootstrap_definitions/1: #{short(result)}"
    {:ok, definition} = result
    definition
  end

  defp admit(input, actor), do: call(@sdr, :admit_lead, [input, [actor: actor]])

  defp admit!(input, actor, outcome) do
    result = admit(input, actor)

    assert match?({:ok, %{outcome: ^outcome, replayed?: false}}, result),
           "C3-02: expected #{outcome}, got #{short(result)}"

    {:ok, value} = result
    assert value.admission.outcome == outcome
    assert value.admission.source_ref == input.source_ref
    value
  end

  defp replay!(input, actor, first) do
    result = admit(input, actor)
    assert match?({:ok, %{replayed?: true}}, result), "C3-02: replay: #{short(result)}"
    {:ok, replay} = result
    assert replay.admission.id == first.admission.id
    assert replay.outcome == first.outcome
    replay
  end

  ## Assertions

  defp assert_admitted!(ctx, kind, input, value) do
    assert Ash.Resource.Info.attribute(Sales.Lead, :admission_id),
           "C3-02: Lead has no :admission_id attribute"

    assert %{admission: admission, lead: lead, run: run, replayed?: false} = value

    assert {admission.source_kind, admission.source_ref, admission.input_version} ==
             {kind, input.source_ref, 1}

    assert admission.input_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert {admission.tenant_id, admission.campaign_id} == {ctx.tenant.id, ctx.campaign.id}
    assert admission.requested_by_user_id == ctx.admin.id
    assert {admission.account_id, admission.contact_id} == {lead.account_id, lead.contact_id}

    assert {admission.readmit, admission.suppression_scope, admission.matched_lead_id} ==
             {false, nil, nil}

    assert admission.agent_run_id == expected_run_id(ctx, kind)

    assert {lead.status, lead.source, lead.owner_user_id} == {:assigned, kind, ctx.admin.id}
    assert Map.get(lead, :admission_id) == admission.id

    assert {run.status, run.usage_origin, run.lead_id, run.campaign_id} ==
             {:queued, :assignment, lead.id, ctx.campaign.id}

    assert is_binary(run.settings_snapshot_id)
  end

  defp expected_run_id(ctx, :agent_found), do: ctx.discovery_run.id
  defp expected_run_id(_ctx, _kind), do: nil

  defp assert_admitted_rows!(before, created) do
    %{rows: rows, events: events} = changes(before)
    account = if created[:account], do: 1, else: 0
    contact = if created[:contact], do: 1, else: 0

    expected =
      @admitted_rows
      |> Map.merge(%{"accounts" => account, "contacts" => contact})
      |> Map.reject(fn {_table, n} -> n == 0 end)

    assert Map.delete(rows, "audit_events") == expected

    assert Map.take(events, [
             "sales.admission.recorded",
             "sales.account.created",
             "sales.contact.created",
             "sales.lead.created",
             "sales.lead.assigned",
             "sdr.lead.assigned"
           ]) ==
             Map.reject(
               %{
                 "sales.admission.recorded" => 1,
                 "sales.account.created" => account,
                 "sales.contact.created" => contact,
                 "sales.lead.created" => 1,
                 "sales.lead.assigned" => 1,
                 "sdr.lead.assigned" => 1
               },
               fn {_type, n} -> n == 0 end
             )
  end

  defp assert_suppressed!(ctx, input, scope) do
    before = snapshot()
    value = admit!(input, ctx.admin, :suppressed)
    assert changes(before) == @recorded
    assert value.admission.suppression_scope == scope
    refute value.admission.account_created or value.admission.contact_created
  end

  # Refused actors: no row is written; the only events allowed are Guard
  # denials (`authz.denied`), one row each.
  defp assert_only_denials!(before) do
    %{rows: rows, events: events} = changes(before)
    denials = Map.get(events, "authz.denied", 0)
    assert Map.delete(events, "authz.denied") == %{}
    assert rows == if(denials == 0, do: %{}, else: %{"audit_events" => denials})
  end

  ## Counts

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

  defp count(table) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table}")
    n
  end

  defp event_types do
    %{rows: rows} = Repo.query!("SELECT event_type, count(*) FROM audit_events GROUP BY 1")
    Map.new(rows, fn [type, n] -> {type, n} end)
  end

  defp admissions_for(ref) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM lead_admissions WHERE source_ref = $1", [ref])

    n
  end

  defp queued_runs(lead_id) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM agent_runs WHERE lead_id = $1 AND status = 'queued'", [
        uuid(lead_id)
      ])

    n
  end

  defp leads_of(contact_id) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM leads WHERE contact_id = $1", [uuid(contact_id)])

    n
  end

  defp work_rows(lead_id) do
    id = uuid(lead_id)

    Map.new(
      [qualifications: "qualifications", enrollments: "campaign_enrollments", drafts: "drafts"],
      fn {key, table} ->
        %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table} WHERE lead_id = $1", [id])
        {key, n}
      end
    )
  end

  ## Reads

  defp reread(ctx, lead) do
    assert {:ok, fresh} = Sales.fetch(Sales.Lead, lead.id, actor: ctx.admin)
    fresh
  end

  defp uuid(id), do: Ecto.UUID.dump!(id)

  defp short(term), do: inspect(term, limit: 8, printable_limit: 200)
end
