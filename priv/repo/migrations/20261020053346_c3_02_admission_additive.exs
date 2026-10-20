defmodule SdrAgent.Repo.Migrations.C302AdmissionAdditive do
  @moduledoc """
  C3-02 additive migration (plan r8 sections 2.7, 5.4 A.5 and 10.2 G2;
  packet section 3 rows LeadAdmission, Lead, Account and Contact; ADR-0009
  C3 and C3-02 amendments): the `sdr_canonical_domain(text)` key form and
  the unique `(tenant_id, sdr_canonical_domain(domain))` account index; the
  composite foreign key targets on users, campaigns, accounts, contacts,
  agent_runs and leads; the nullable Lead provenance columns
  `admission_id` and `referred_from_lead_id` (each unique when set) and
  their composite foreign keys; the `referred` terminal Lead status in both
  open-lead indexes and the new `one_open_per_account` index; and the
  append-only `lead_admissions` table with its checks, composite foreign
  keys and its deferred bound-at-commit constraint trigger. The cutover
  triggers (`leads_admission_binding`, Lead immutability) are the separate
  cutover migration (G5).

  Generated with `mix ash.codegen c3_02_admission_additive`; reordered by
  hand so that (a) the function exists first, (b) the shared pre-checks
  (`SdrAgent.Sales.AdmissionPrechecks.run!/1`: canonical collisions, double
  open leads, legacy identity) and the A.5 cutover fence
  (`SdrAgent.Sales.CutoverFence.run!/1`) run on the existing rows before any
  index, column, table or row change, and abort with counts only, and (c)
  each composite unique key exists before the foreign key that references
  it (and is dropped after it). The migration runs in one transaction, so an
  abort also rolls back the function. No existing row is rewritten,
  repaired or backfilled; drops are in `down/0` only.

  The pre-checks and the fence are application modules called from here:
  their SQL is reviewed in those modules, and a later change to it must keep
  this migration replayable (on a fresh database every count is zero).
  """

  use Ecto.Migration

  alias SdrAgent.Sales.AdmissionPrechecks
  alias SdrAgent.Sales.CutoverFence

  def up do
    # a. the key and index form (Normalize.strip/1), needed by the pre-checks.
    # ~S keeps the regex backslashes (a plain heredoc would drop them).
    execute(~S"""
    CREATE FUNCTION sdr_canonical_domain(text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
      SELECT regexp_replace(regexp_replace(lower(btrim($1)), '\.$', ''), '^www\.', '')
    $$
    """)

    # b. the pre-checks and the A.5 fence, before any index, column, table or
    # row change; an abort raises and rolls the whole migration back.
    flush()
    AdmissionPrechecks.run!(repo())
    CutoverFence.run!(repo())

    # c. composite foreign key targets on existing tables.
    execute("""
    ALTER TABLE users ADD CONSTRAINT users_id_tenant_key UNIQUE (id, tenant_id)
    """)

    execute("""
    ALTER TABLE campaigns ADD CONSTRAINT campaigns_id_tenant_key UNIQUE (id, tenant_id)
    """)

    execute("""
    ALTER TABLE accounts ADD CONSTRAINT accounts_id_tenant_key UNIQUE (id, tenant_id)
    """)

    execute("""
    ALTER TABLE contacts ADD CONSTRAINT contacts_id_tenant_key UNIQUE (id, tenant_id)
    """)

    execute("""
    ALTER TABLE contacts ADD CONSTRAINT contacts_id_account_tenant_key UNIQUE (id, account_id, tenant_id)
    """)

    execute("""
    ALTER TABLE agent_runs ADD CONSTRAINT agent_runs_id_tenant_key UNIQUE (id, tenant_id)
    """)

    execute("""
    ALTER TABLE leads ADD CONSTRAINT leads_id_tenant_key UNIQUE (id, tenant_id)
    """)

    execute("""
    ALTER TABLE leads ADD CONSTRAINT leads_id_tenant_account_key UNIQUE (id, tenant_id, account_id)
    """)

    # d. one company per key form and tenant.
    create index(:accounts, ["tenant_id", "sdr_canonical_domain(domain::text)"],
             name: "accounts_canonical_domain_index",
             unique: true
           )

    # e. leads: provenance columns, the referred terminal status, both
    # open-lead indexes.
    drop_if_exists unique_index(:leads, [:tenant_id, :contact_id],
                     name: "leads_unique_open_lead_index"
                   )

    alter table(:leads) do
      add :admission_id, :uuid
      add :referred_from_lead_id, :uuid
    end

    create unique_index(:leads, [:tenant_id, :contact_id],
             name: "leads_unique_open_lead_index",
             where:
               "(status NOT IN ('disqualified', 'converted', 'nurture', 'stopped', 'referred'))"
           )

    create unique_index(:leads, [:tenant_id, :account_id],
             name: "leads_one_open_per_account_index",
             where:
               "(status NOT IN ('disqualified', 'converted', 'nurture', 'stopped', 'referred'))"
           )

    create unique_index(:leads, [:admission_id],
             name: "leads_unique_admission_index",
             where: "(admission_id IS NOT NULL)"
           )

    create unique_index(:leads, [:referred_from_lead_id],
             name: "leads_unique_referred_from_index",
             where: "(referred_from_lead_id IS NOT NULL)"
           )

    drop_if_exists constraint(:leads, :leads_status)

    create constraint(:leads, :leads_status,
             check: """
               status IN ('new', 'assigned', 'researching', 'qualifying', 'qualified', 'disqualified', 'in_outreach', 'replied', 'converted', 'nurture', 'stopped', 'blocked', 'referred')
             """
           )

    # f. lead_admissions: table, checks, append-only, binding target, composite
    # foreign keys and the deferred bound-at-commit trigger.
    create table(:lead_admissions, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuidv7()"), primary_key: true
      add :source_kind, :text, null: false
      add :source_ref, :text, null: false
      add :input_version, :bigint, null: false
      add :input_sha256, :text, null: false
      add :outcome, :text, null: false
      add :suppression_scope, :text
      add :readmit, :boolean, null: false, default: false
      add :account_created, :boolean, null: false, default: false
      add :contact_created, :boolean, null: false, default: false
      add :trace_id, :text, null: false
      add :span_id, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false

      add :tenant_id,
          references(:tenants,
            column: :id,
            name: "lead_admissions_tenant_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :restrict
          ),
          null: false
    end

    create unique_index(:lead_admissions, [:tenant_id, :source_kind, :source_ref],
             name: "lead_admissions_unique_source_index"
           )

    alter table(:lead_admissions) do
      add :requested_by_user_id, :uuid, null: false
      add :campaign_id, :uuid, null: false
      add :account_id, :uuid
      add :contact_id, :uuid
      add :matched_lead_id, :uuid
      add :agent_run_id, :uuid
      add :referral_from_lead_id, :uuid
    end

    create constraint(:lead_admissions, :lead_admissions_trace_ids,
             check: """
               trace_id ~ '^[0-9a-f]{32}$' AND trace_id <> repeat('0', 32) AND span_id ~ '^[0-9a-f]{16}$' AND span_id <> repeat('0', 16)
             """
           )

    create constraint(:lead_admissions, :lead_admissions_source_kind,
             check: """
               source_kind IN ('manual', 'csv', 'hubspot', 'agent_found', 'referral')
             """
           )

    create constraint(:lead_admissions, :lead_admissions_outcome,
             check: """
               outcome IN ('admitted', 'duplicate_open_lead', 'active_target_exists', 'previously_worked', 'contact_at_other_account', 'contact_archived', 'account_archived', 'company_in_relationship', 'suppressed')
             """
           )

    create constraint(:lead_admissions, :lead_admissions_suppression_scope,
             check: """
               suppression_scope IS NULL OR suppression_scope IN ('email', 'domain')
             """
           )

    create constraint(:lead_admissions, :lead_admissions_source_ref,
             check: """
               length(source_ref) <= 120 AND ((source_kind = 'manual' AND source_ref ~ '^manual:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') OR (source_kind = 'csv' AND source_ref ~ '^csv:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[1-9][0-9]*$') OR (source_kind = 'hubspot' AND source_ref ~ '^hubspot:[0-9]+:[0-9]+$') OR (source_kind = 'agent_found' AND source_ref ~ '^agent_found:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') OR (source_kind = 'referral' AND source_ref ~ '^referral:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'))
             """
           )

    create constraint(:lead_admissions, :lead_admissions_input_version,
             check: """
               input_version = 1
             """
           )

    create constraint(:lead_admissions, :lead_admissions_input_sha256,
             check: """
               input_sha256 ~ '^[0-9a-f]{64}$'
             """
           )

    create constraint(:lead_admissions, :lead_admissions_matched_lead_outcome,
             check: """
               (matched_lead_id IS NOT NULL) = (outcome IN ('duplicate_open_lead', 'active_target_exists'))
             """
           )

    create constraint(:lead_admissions, :lead_admissions_matched_lead_account,
             check: """
               matched_lead_id IS NULL OR account_id IS NOT NULL
             """
           )

    create constraint(:lead_admissions, :lead_admissions_suppression_scope_outcome,
             check: """
               (suppression_scope IS NOT NULL) = (outcome = 'suppressed')
             """
           )

    create constraint(:lead_admissions, :lead_admissions_agent_run_kind,
             check: """
               (agent_run_id IS NOT NULL) = (source_kind = 'agent_found')
             """
           )

    create constraint(:lead_admissions, :lead_admissions_referral_kind,
             check: """
               (referral_from_lead_id IS NOT NULL) = (source_kind = 'referral')
             """
           )

    create constraint(:lead_admissions, :lead_admissions_agent_run_ref,
             check: """
               source_kind <> 'agent_found' OR split_part(source_ref, ':', 2) = agent_run_id::text
             """
           )

    create constraint(:lead_admissions, :lead_admissions_referral_ref,
             check: """
               source_kind <> 'referral' OR split_part(source_ref, ':', 2) = referral_from_lead_id::text
             """
           )

    create constraint(:lead_admissions, :lead_admissions_readmit_kind,
             check: """
               NOT readmit OR source_kind IN ('manual', 'referral')
             """
           )

    create constraint(:lead_admissions, :lead_admissions_company_in_relationship,
             check: """
               outcome <> 'company_in_relationship' OR (source_kind IN ('csv', 'hubspot', 'agent_found') AND account_id IS NOT NULL)
             """
           )

    create constraint(:lead_admissions, :lead_admissions_created_when_admitted,
             check: """
               outcome = 'admitted' OR (NOT account_created AND NOT contact_created)
             """
           )

    create constraint(:lead_admissions, :lead_admissions_admitted_identity,
             check: """
               outcome <> 'admitted' OR (account_id IS NOT NULL AND contact_id IS NOT NULL)
             """
           )

    create constraint(:lead_admissions, :lead_admissions_other_account,
             check: """
               outcome <> 'contact_at_other_account' OR account_id IS NULL
             """
           )

    execute("""
    CREATE FUNCTION lead_admissions_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION '% is append-only: % rejected', TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'restrict_violation';
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER lead_admissions_guard_row BEFORE UPDATE OR DELETE ON lead_admissions FOR EACH ROW EXECUTE FUNCTION lead_admissions_append_only()
    """)

    execute("""
    CREATE TRIGGER lead_admissions_guard_truncate BEFORE TRUNCATE ON lead_admissions FOR EACH STATEMENT EXECUTE FUNCTION lead_admissions_append_only()
    """)

    execute("""
    ALTER TABLE lead_admissions ADD CONSTRAINT lead_admissions_id_tenant_account_contact_key UNIQUE (id, tenant_id, account_id, contact_id)
    """)

    execute("""
    ALTER TABLE lead_admissions ADD CONSTRAINT lead_admissions_requested_by_fkey FOREIGN KEY (requested_by_user_id, tenant_id) REFERENCES users (id, tenant_id) ON DELETE RESTRICT
    """)

    execute("""
    ALTER TABLE lead_admissions ADD CONSTRAINT lead_admissions_campaign_fkey FOREIGN KEY (campaign_id, tenant_id) REFERENCES campaigns (id, tenant_id) ON DELETE RESTRICT
    """)

    execute("""
    ALTER TABLE lead_admissions ADD CONSTRAINT lead_admissions_account_fkey FOREIGN KEY (account_id, tenant_id) REFERENCES accounts (id, tenant_id) ON DELETE RESTRICT
    """)

    execute("""
    ALTER TABLE lead_admissions ADD CONSTRAINT lead_admissions_contact_fkey FOREIGN KEY (contact_id, tenant_id) REFERENCES contacts (id, tenant_id) ON DELETE RESTRICT
    """)

    execute("""
    ALTER TABLE lead_admissions ADD CONSTRAINT lead_admissions_contact_account_fkey FOREIGN KEY (contact_id, account_id, tenant_id) REFERENCES contacts (id, account_id, tenant_id) ON DELETE RESTRICT
    """)

    execute("""
    ALTER TABLE lead_admissions ADD CONSTRAINT lead_admissions_matched_lead_fkey FOREIGN KEY (matched_lead_id, tenant_id, account_id) REFERENCES leads (id, tenant_id, account_id) ON DELETE RESTRICT
    """)

    execute("""
    ALTER TABLE lead_admissions ADD CONSTRAINT lead_admissions_agent_run_fkey FOREIGN KEY (agent_run_id, tenant_id) REFERENCES agent_runs (id, tenant_id) ON DELETE RESTRICT
    """)

    execute("""
    ALTER TABLE lead_admissions ADD CONSTRAINT lead_admissions_referral_from_lead_fkey FOREIGN KEY (referral_from_lead_id, tenant_id) REFERENCES leads (id, tenant_id) ON DELETE RESTRICT
    """)

    execute("""
    CREATE FUNCTION lead_admissions_admitted_bound() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.outcome = 'admitted'
         AND (SELECT count(*) FROM leads WHERE admission_id = NEW.id) <> 1 THEN
        RAISE EXCEPTION 'lead_admissions: an admitted admission must be bound by exactly one lead at commit'
          USING ERRCODE = 'restrict_violation';
      END IF;
      RETURN NULL;
    END;
    $$
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER lead_admissions_admitted_bound AFTER INSERT ON lead_admissions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION lead_admissions_admitted_bound()
    """)

    # g. the Lead binding and referral foreign keys.
    execute("""
    ALTER TABLE leads ADD CONSTRAINT leads_admission_fkey FOREIGN KEY (admission_id, tenant_id, account_id, contact_id) REFERENCES lead_admissions (id, tenant_id, account_id, contact_id) ON DELETE RESTRICT
    """)

    execute("""
    ALTER TABLE leads ADD CONSTRAINT leads_referred_from_fkey FOREIGN KEY (referred_from_lead_id, tenant_id, account_id) REFERENCES leads (id, tenant_id, account_id) ON DELETE RESTRICT
    """)
  end

  def down do
    execute("""
    ALTER TABLE leads DROP CONSTRAINT leads_referred_from_fkey
    """)

    execute("""
    ALTER TABLE leads DROP CONSTRAINT leads_admission_fkey
    """)

    execute("""
    DROP TRIGGER lead_admissions_admitted_bound ON lead_admissions
    """)

    execute("""
    DROP FUNCTION lead_admissions_admitted_bound()
    """)

    execute("""
    ALTER TABLE lead_admissions DROP CONSTRAINT lead_admissions_referral_from_lead_fkey
    """)

    execute("""
    ALTER TABLE lead_admissions DROP CONSTRAINT lead_admissions_agent_run_fkey
    """)

    execute("""
    ALTER TABLE lead_admissions DROP CONSTRAINT lead_admissions_matched_lead_fkey
    """)

    execute("""
    ALTER TABLE lead_admissions DROP CONSTRAINT lead_admissions_contact_account_fkey
    """)

    execute("""
    ALTER TABLE lead_admissions DROP CONSTRAINT lead_admissions_contact_fkey
    """)

    execute("""
    ALTER TABLE lead_admissions DROP CONSTRAINT lead_admissions_account_fkey
    """)

    execute("""
    ALTER TABLE lead_admissions DROP CONSTRAINT lead_admissions_campaign_fkey
    """)

    execute("""
    ALTER TABLE lead_admissions DROP CONSTRAINT lead_admissions_requested_by_fkey
    """)

    execute("""
    ALTER TABLE lead_admissions DROP CONSTRAINT lead_admissions_id_tenant_account_contact_key
    """)

    execute("""
    DROP TRIGGER lead_admissions_guard_truncate ON lead_admissions
    """)

    execute("""
    DROP TRIGGER lead_admissions_guard_row ON lead_admissions
    """)

    execute("""
    DROP FUNCTION lead_admissions_append_only()
    """)

    drop_if_exists constraint(:lead_admissions, :lead_admissions_other_account)

    drop_if_exists constraint(:lead_admissions, :lead_admissions_admitted_identity)

    drop_if_exists constraint(:lead_admissions, :lead_admissions_created_when_admitted)

    drop_if_exists constraint(:lead_admissions, :lead_admissions_company_in_relationship)

    drop_if_exists constraint(:lead_admissions, :lead_admissions_readmit_kind)

    drop_if_exists constraint(:lead_admissions, :lead_admissions_referral_ref)

    drop_if_exists constraint(:lead_admissions, :lead_admissions_agent_run_ref)

    drop_if_exists constraint(:lead_admissions, :lead_admissions_referral_kind)

    drop_if_exists constraint(:lead_admissions, :lead_admissions_agent_run_kind)

    drop_if_exists constraint(:lead_admissions, :lead_admissions_suppression_scope_outcome)

    drop_if_exists constraint(:lead_admissions, :lead_admissions_matched_lead_account)

    drop_if_exists constraint(:lead_admissions, :lead_admissions_matched_lead_outcome)

    drop_if_exists constraint(:lead_admissions, :lead_admissions_input_sha256)

    drop_if_exists constraint(:lead_admissions, :lead_admissions_input_version)

    drop_if_exists constraint(:lead_admissions, :lead_admissions_source_ref)

    drop_if_exists constraint(:lead_admissions, :lead_admissions_suppression_scope)

    drop_if_exists constraint(:lead_admissions, :lead_admissions_outcome)

    drop_if_exists constraint(:lead_admissions, :lead_admissions_source_kind)

    drop_if_exists constraint(:lead_admissions, :lead_admissions_trace_ids)

    drop constraint(:lead_admissions, "lead_admissions_tenant_id_fkey")

    alter table(:lead_admissions) do
      remove :referral_from_lead_id
      remove :agent_run_id
      remove :matched_lead_id
      remove :contact_id
      remove :account_id
      remove :campaign_id
      remove :requested_by_user_id
    end

    drop_if_exists unique_index(:lead_admissions, [:tenant_id, :source_kind, :source_ref],
                     name: "lead_admissions_unique_source_index"
                   )

    drop table(:lead_admissions)

    drop_if_exists constraint(:leads, :leads_status)

    create constraint(:leads, :leads_status,
             check: """
               status IN ('new', 'assigned', 'researching', 'qualifying', 'qualified', 'disqualified', 'in_outreach', 'replied', 'converted', 'nurture', 'stopped', 'blocked')
             """
           )

    drop_if_exists unique_index(:leads, [:referred_from_lead_id],
                     name: "leads_unique_referred_from_index"
                   )

    drop_if_exists unique_index(:leads, [:admission_id], name: "leads_unique_admission_index")

    drop_if_exists unique_index(:leads, [:tenant_id, :account_id],
                     name: "leads_one_open_per_account_index"
                   )

    drop_if_exists unique_index(:leads, [:tenant_id, :contact_id],
                     name: "leads_unique_open_lead_index"
                   )

    alter table(:leads) do
      remove :referred_from_lead_id
      remove :admission_id
    end

    create unique_index(:leads, [:tenant_id, :contact_id],
             name: "leads_unique_open_lead_index",
             where: "(status NOT IN ('disqualified', 'converted', 'nurture', 'stopped'))"
           )

    drop_if_exists index(:accounts, ["tenant_id", "sdr_canonical_domain(domain::text)"],
                     name: "accounts_canonical_domain_index"
                   )

    execute("""
    ALTER TABLE leads DROP CONSTRAINT leads_id_tenant_account_key
    """)

    execute("""
    ALTER TABLE leads DROP CONSTRAINT leads_id_tenant_key
    """)

    execute("""
    ALTER TABLE agent_runs DROP CONSTRAINT agent_runs_id_tenant_key
    """)

    execute("""
    ALTER TABLE contacts DROP CONSTRAINT contacts_id_account_tenant_key
    """)

    execute("""
    ALTER TABLE contacts DROP CONSTRAINT contacts_id_tenant_key
    """)

    execute("""
    ALTER TABLE accounts DROP CONSTRAINT accounts_id_tenant_key
    """)

    execute("""
    ALTER TABLE campaigns DROP CONSTRAINT campaigns_id_tenant_key
    """)

    execute("""
    ALTER TABLE users DROP CONSTRAINT users_id_tenant_key
    """)

    execute("""
    DROP FUNCTION sdr_canonical_domain(text)
    """)
  end
end
