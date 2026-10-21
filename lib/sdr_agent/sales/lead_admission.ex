defmodule SdrAgent.Sales.LeadAdmission do
  @moduledoc """
  One immutable record per new lead admission request and its outcome: the
  provenance and dedupe history of `SdrAgent.SDR.admit_lead/2` (packet
  section 3 row Sales.LeadAdmission, section 5.2; plan r8 section 3).
  APPEND-ONLY: a database trigger rejects every UPDATE, DELETE and TRUNCATE.

  Attributes: `source_kind` (`:manual | :csv | :hubspot | :agent_found |
  :referral`), `source_ref` (≤ 120, ids only, per-kind grammar:
  `manual:<uuid>`, `csv:<uuid>:<row ≥ 1>`, `hubspot:<digits>:<digits>`,
  `agent_found:<run uuid>:<candidate uuid>`, `referral:<original lead
  uuid>:<reply or outcome uuid>`, lowercase uuids), `input_version` (= 1),
  `input_sha256` (64 lowercase hex, packet section 5.2), `outcome`
  (`:admitted | :duplicate_open_lead | :active_target_exists |
  :previously_worked | :contact_at_other_account | :contact_archived |
  :account_archived | :company_in_relationship | :suppressed`),
  `suppression_scope` (`:email | :domain`, only when suppressed; no FK to
  Outreach), `readmit`, `account_created`, `contact_created`, the trace ids
  and `inserted_at`.

  Relationships (composite FKs, all restrict, every one inside the row's
  tenant): `requested_by` (user, required), `campaign` (required),
  `account`, `contact` (also at the recorded account when both are set),
  `matched_lead` (at the recorded account), `agent_run` (agent_found),
  `referral_from_lead` (referral); `lead` (has_one, the lead bound to an
  admitted row through `Lead.admission_id`). Identity: unique
  `(tenant_id, source_kind, source_ref)`; `(id, tenant_id, account_id,
  contact_id)` is unique as the target of the Lead binding FK.

  Database checks: the per-kind `source_ref` grammar and its embedded run or
  original lead id (`agent_run_id` / `referral_from_lead_id`, compared as
  text); `matched_lead_id` iff the outcome is `duplicate_open_lead` or
  `active_target_exists`, and then a known account; `suppression_scope` iff
  `suppressed`; `agent_run_id` iff `agent_found`; `referral_from_lead_id`
  iff `referral`; `readmit` only for `manual` and `referral`;
  `company_in_relationship` only for `csv`, `hubspot` and `agent_found`,
  with a known account; `account_created`/`contact_created` only when
  admitted; account and contact set when admitted; no account when
  `contact_at_other_account`. A deferred constraint trigger (`DEFERRABLE
  INITIALLY DEFERRED`) refuses, at commit, an `admitted` row that is not
  bound by exactly one lead.

  Actions: `:record` (create) only, with every input the orchestrator
  supplies (`requested_by_user_id` included); reads. Writes: an active human
  admin, only inside the admission orchestrator
  (`SdrAgent.Sales.Checks.LeadAdmissionContext`); every other actor is
  refused and an auditor's refusal is audited by the Guard. Reads: ADM, REV,
  AUR, AGT (`agent_runtime`), the `auditor_cli` and the kernel, each in its
  own tenant. Every write appends `sales.admission.recorded`.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Sales,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Changes.AppendEvent
  alias SdrAgent.Audit.Checks
  alias SdrAgent.Audit.SQL
  alias SdrAgent.Sales.Checks.LeadAdmissionContext

  @kinds [:manual, :csv, :hubspot, :agent_found, :referral]
  @outcomes [
    :admitted,
    :duplicate_open_lead,
    :active_target_exists,
    :previously_worked,
    :contact_at_other_account,
    :contact_archived,
    :account_archived,
    :company_in_relationship,
    :suppressed
  ]
  @scopes [:email, :domain]
  @uuid "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
  @source_ref_check "length(source_ref) <= 120 AND (" <>
                      "(source_kind = 'manual' AND source_ref ~ '^manual:#{@uuid}$') OR " <>
                      "(source_kind = 'csv' AND source_ref ~ '^csv:#{@uuid}:[1-9][0-9]*$') OR " <>
                      "(source_kind = 'hubspot' AND source_ref ~ '^hubspot:[0-9]+:[0-9]+$') OR " <>
                      "(source_kind = 'agent_found' AND " <>
                      "source_ref ~ '^agent_found:#{@uuid}:#{@uuid}$') OR " <>
                      "(source_kind = 'referral' AND source_ref ~ '^referral:#{@uuid}:#{@uuid}$'))"
  @accepted [
    :source_kind,
    :source_ref,
    :input_version,
    :input_sha256,
    :outcome,
    :suppression_scope,
    :readmit,
    :account_created,
    :contact_created,
    :requested_by_user_id,
    :campaign_id,
    :account_id,
    :contact_id,
    :matched_lead_id,
    :agent_run_id,
    :referral_from_lead_id
  ]

  postgres do
    table "lead_admissions"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      # Every other foreign key is composite (inside the row's tenant): a
      # custom statement below.
      reference :requested_by, ignore?: true
      reference :campaign, ignore?: true
      reference :account, ignore?: true
      reference :contact, ignore?: true
      reference :matched_lead, ignore?: true
      reference :agent_run, ignore?: true
      reference :referral_from_lead, ignore?: true
    end

    check_constraints do
      check_constraint :trace_id, "lead_admissions_trace_ids", check: SQL.trace_check()

      check_constraint :source_kind, "lead_admissions_source_kind",
        check: SQL.one_of("source_kind", @kinds)

      check_constraint :outcome, "lead_admissions_outcome",
        check: SQL.one_of("outcome", @outcomes)

      check_constraint :suppression_scope, "lead_admissions_suppression_scope",
        check: "suppression_scope IS NULL OR " <> SQL.one_of("suppression_scope", @scopes)

      check_constraint :source_ref, "lead_admissions_source_ref", check: @source_ref_check

      check_constraint :input_version, "lead_admissions_input_version", check: "input_version = 1"

      check_constraint :input_sha256, "lead_admissions_input_sha256",
        check: "input_sha256 ~ '^[0-9a-f]{64}$'"

      check_constraint :matched_lead_id, "lead_admissions_matched_lead_outcome",
        check:
          "(matched_lead_id IS NOT NULL) = " <>
            "(outcome IN ('duplicate_open_lead', 'active_target_exists'))"

      check_constraint :matched_lead_id, "lead_admissions_matched_lead_account",
        check: "matched_lead_id IS NULL OR account_id IS NOT NULL"

      check_constraint :suppression_scope, "lead_admissions_suppression_scope_outcome",
        check: "(suppression_scope IS NOT NULL) = (outcome = 'suppressed')"

      check_constraint :agent_run_id, "lead_admissions_agent_run_kind",
        check: "(agent_run_id IS NOT NULL) = (source_kind = 'agent_found')"

      check_constraint :referral_from_lead_id, "lead_admissions_referral_kind",
        check: "(referral_from_lead_id IS NOT NULL) = (source_kind = 'referral')"

      check_constraint :agent_run_id, "lead_admissions_agent_run_ref",
        check:
          "source_kind <> 'agent_found' OR split_part(source_ref, ':', 2) = agent_run_id::text"

      check_constraint :referral_from_lead_id, "lead_admissions_referral_ref",
        check:
          "source_kind <> 'referral' OR " <>
            "split_part(source_ref, ':', 2) = referral_from_lead_id::text"

      check_constraint :readmit, "lead_admissions_readmit_kind",
        check: "NOT readmit OR source_kind IN ('manual', 'referral')"

      check_constraint :outcome, "lead_admissions_company_in_relationship",
        check:
          "outcome <> 'company_in_relationship' OR " <>
            "(source_kind IN ('csv', 'hubspot', 'agent_found') AND account_id IS NOT NULL)"

      check_constraint :outcome, "lead_admissions_created_when_admitted",
        check: "outcome = 'admitted' OR (NOT account_created AND NOT contact_created)"

      check_constraint :outcome, "lead_admissions_admitted_identity",
        check: "outcome <> 'admitted' OR (account_id IS NOT NULL AND contact_id IS NOT NULL)"

      check_constraint :outcome, "lead_admissions_other_account",
        check: "outcome <> 'contact_at_other_account' OR account_id IS NULL"
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SQL.append_only("lead_admissions") do
        statement name do
          up up_sql
          down down_sql
        end
      end

      # Target of the Lead binding FK (`leads_admission_fkey`).
      statement :lead_admissions_id_tenant_account_contact_key do
        up "ALTER TABLE lead_admissions ADD CONSTRAINT " <>
             "lead_admissions_id_tenant_account_contact_key " <>
             "UNIQUE (id, tenant_id, account_id, contact_id)"

        down "ALTER TABLE lead_admissions DROP CONSTRAINT " <>
               "lead_admissions_id_tenant_account_contact_key"
      end

      statement :lead_admissions_requested_by_fkey do
        up "ALTER TABLE lead_admissions ADD CONSTRAINT lead_admissions_requested_by_fkey " <>
             "FOREIGN KEY (requested_by_user_id, tenant_id) " <>
             "REFERENCES users (id, tenant_id) ON DELETE RESTRICT"

        down "ALTER TABLE lead_admissions DROP CONSTRAINT lead_admissions_requested_by_fkey"
      end

      statement :lead_admissions_campaign_fkey do
        up "ALTER TABLE lead_admissions ADD CONSTRAINT lead_admissions_campaign_fkey " <>
             "FOREIGN KEY (campaign_id, tenant_id) " <>
             "REFERENCES campaigns (id, tenant_id) ON DELETE RESTRICT"

        down "ALTER TABLE lead_admissions DROP CONSTRAINT lead_admissions_campaign_fkey"
      end

      statement :lead_admissions_account_fkey do
        up "ALTER TABLE lead_admissions ADD CONSTRAINT lead_admissions_account_fkey " <>
             "FOREIGN KEY (account_id, tenant_id) " <>
             "REFERENCES accounts (id, tenant_id) ON DELETE RESTRICT"

        down "ALTER TABLE lead_admissions DROP CONSTRAINT lead_admissions_account_fkey"
      end

      statement :lead_admissions_contact_fkey do
        up "ALTER TABLE lead_admissions ADD CONSTRAINT lead_admissions_contact_fkey " <>
             "FOREIGN KEY (contact_id, tenant_id) " <>
             "REFERENCES contacts (id, tenant_id) ON DELETE RESTRICT"

        down "ALTER TABLE lead_admissions DROP CONSTRAINT lead_admissions_contact_fkey"
      end

      # Checked when both are set (MATCH SIMPLE): the person is at the company.
      statement :lead_admissions_contact_account_fkey do
        up "ALTER TABLE lead_admissions ADD CONSTRAINT lead_admissions_contact_account_fkey " <>
             "FOREIGN KEY (contact_id, account_id, tenant_id) " <>
             "REFERENCES contacts (id, account_id, tenant_id) ON DELETE RESTRICT"

        down "ALTER TABLE lead_admissions DROP CONSTRAINT lead_admissions_contact_account_fkey"
      end

      # Never skipped: a matched lead always has a known account (check above).
      statement :lead_admissions_matched_lead_fkey do
        up "ALTER TABLE lead_admissions ADD CONSTRAINT lead_admissions_matched_lead_fkey " <>
             "FOREIGN KEY (matched_lead_id, tenant_id, account_id) " <>
             "REFERENCES leads (id, tenant_id, account_id) ON DELETE RESTRICT"

        down "ALTER TABLE lead_admissions DROP CONSTRAINT lead_admissions_matched_lead_fkey"
      end

      statement :lead_admissions_agent_run_fkey do
        up "ALTER TABLE lead_admissions ADD CONSTRAINT lead_admissions_agent_run_fkey " <>
             "FOREIGN KEY (agent_run_id, tenant_id) " <>
             "REFERENCES agent_runs (id, tenant_id) ON DELETE RESTRICT"

        down "ALTER TABLE lead_admissions DROP CONSTRAINT lead_admissions_agent_run_fkey"
      end

      statement :lead_admissions_referral_from_lead_fkey do
        up "ALTER TABLE lead_admissions ADD CONSTRAINT lead_admissions_referral_from_lead_fkey " <>
             "FOREIGN KEY (referral_from_lead_id, tenant_id) " <>
             "REFERENCES leads (id, tenant_id) ON DELETE RESTRICT"

        down "ALTER TABLE lead_admissions DROP CONSTRAINT lead_admissions_referral_from_lead_fkey"
      end

      # Packet section 3: an admitted row is bound by exactly one lead at
      # commit (the lead is inserted after its admission, in the same
      # transaction; `leads_unique_admission_index` keeps it to one).
      statement :lead_admissions_admitted_bound_function do
        up """
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
        """

        down "DROP FUNCTION lead_admissions_admitted_bound()"
      end

      statement :lead_admissions_admitted_bound do
        up "CREATE CONSTRAINT TRIGGER lead_admissions_admitted_bound AFTER INSERT " <>
             "ON lead_admissions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW " <>
             "EXECUTE FUNCTION lead_admissions_admitted_bound()"

        down "DROP TRIGGER lead_admissions_admitted_bound ON lead_admissions"
      end
    end
  end

  actions do
    defaults [:read]

    create :record do
      description "ADM, inside the admission orchestrator only: record one admission request."
      accept @accepted
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change {AppendEvent, event_type: "sales.admission.recorded", category: :domain_change}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action(:record) do
      forbid_unless LeadAdmissionContext
      authorize_if SdrAgent.Sales.Checks.ActiveAdmin
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer, :auditor]}
      authorize_if {Checks.ActorType, types: [:agent_runtime, :auditor_cli]}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :source_kind, :atom do
      allow_nil? false
      constraints one_of: @kinds
      public? true
    end

    attribute :source_ref, :string do
      allow_nil? false
      constraints max_length: 120
      public? true
    end

    attribute :input_version, :integer, allow_nil?: false, public?: true
    attribute :input_sha256, :string, allow_nil?: false, public?: true

    attribute :outcome, :atom do
      allow_nil? false
      constraints one_of: @outcomes
      public? true
    end

    attribute :suppression_scope, :atom, public?: true, constraints: [one_of: @scopes]
    attribute :readmit, :boolean, allow_nil?: false, default: false, public?: true
    attribute :account_created, :boolean, allow_nil?: false, default: false, public?: true
    attribute :contact_created, :boolean, allow_nil?: false, default: false, public?: true
    attribute :trace_id, :string, allow_nil?: false, public?: true
    attribute :span_id, :string, allow_nil?: false, public?: true

    attribute :inserted_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      default &SdrAgent.Clock.utc_now/0
      public? true
    end
  end

  relationships do
    belongs_to :tenant, SdrAgent.Audit.Tenant do
      allow_nil? false
      public? true
    end

    belongs_to :requested_by, SdrAgent.Accounts.User do
      source_attribute :requested_by_user_id
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :campaign, SdrAgent.Sales.Campaign do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :account, SdrAgent.Sales.Account do
      attribute_writable? true
      public? true
    end

    belongs_to :contact, SdrAgent.Sales.Contact do
      attribute_writable? true
      public? true
    end

    belongs_to :matched_lead, SdrAgent.Sales.Lead do
      source_attribute :matched_lead_id
      attribute_writable? true
      public? true
    end

    belongs_to :agent_run, SdrAgent.Agents.AgentRun do
      attribute_writable? true
      public? true
    end

    belongs_to :referral_from_lead, SdrAgent.Sales.Lead do
      source_attribute :referral_from_lead_id
      attribute_writable? true
      public? true
    end

    has_one :lead, SdrAgent.Sales.Lead do
      destination_attribute :admission_id
      public? true
    end
  end

  identities do
    identity :unique_source, [:tenant_id, :source_kind, :source_ref]
  end

  @doc false
  def __sdr_audited__, do: true
end
