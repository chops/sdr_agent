defmodule SdrAgent.Research.OwnerProspectIntake do
  @moduledoc """
  Immutable owner-intake/1 admission provenance: actual owner user, current
  binding/relocation, canonical submission digest and same-tenant sales ids.
  Unverified is fixed, never independent spot-check evidence. Exact replay is
  coordinated under the binding/head locks; each lead has at most one origin.
  Only the coordinator's process/transaction-bound action creates a record.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Research,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "owner_prospect_intakes"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :binding, on_delete: :restrict
      reference :relocation, on_delete: :restrict
      reference :owner_user, on_delete: :restrict
      reference :account, on_delete: :restrict
      reference :contact, on_delete: :restrict
      reference :lead, on_delete: :restrict
    end

    check_constraints do
      check_constraint :submission_sha256, "owner_intakes_digest",
        check: "octet_length(submission_sha256) = 32"

      check_constraint :classification, "owner_intakes_unverified",
        check: "classification = 'unverified' AND format_version = 'owner-intake/1'"

      check_constraint :trace_id, "owner_intakes_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("owner_prospect_intakes") do
        statement name do
          up up_sql
          down down_sql
        end
      end

      statement :owner_prospect_origin_guard do
        up """
        CREATE FUNCTION owner_prospect_origin_guard() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          PERFORM id FROM leads WHERE id = NEW.lead_id FOR UPDATE;
          IF TG_TABLE_NAME = 'owner_prospect_intakes' THEN
            IF EXISTS (SELECT 1 FROM dossier_entries WHERE lead_id = NEW.lead_id) THEN
              RAISE EXCEPTION 'lead_origin_ambiguous' USING ERRCODE = 'check_violation';
            END IF;
            IF NOT EXISTS (
              SELECT 1 FROM leads l JOIN contacts c ON c.id=l.contact_id
              JOIN accounts a ON a.id=l.account_id
              JOIN prototype_database_bindings b ON b.id=NEW.binding_id
              JOIN prototype_relocations r ON r.id=NEW.relocation_id AND r.binding_id=b.id
              JOIN users u ON u.id=NEW.owner_user_id
              WHERE l.id=NEW.lead_id AND l.tenant_id=NEW.tenant_id
                AND c.id=NEW.contact_id AND c.tenant_id=NEW.tenant_id
                AND c.account_id=a.id AND a.id=NEW.account_id AND a.tenant_id=NEW.tenant_id
                AND b.tenant_id=NEW.tenant_id AND u.tenant_id=NEW.tenant_id
            ) THEN
              RAISE EXCEPTION 'intake_relationship_mismatch' USING ERRCODE = 'check_violation';
            END IF;
          ELSIF EXISTS (SELECT 1 FROM owner_prospect_intakes WHERE lead_id=NEW.lead_id) THEN
            RAISE EXCEPTION 'lead_origin_ambiguous' USING ERRCODE = 'check_violation';
          END IF;
          RETURN NEW;
        END;
        $$;
        """

        down "DROP FUNCTION owner_prospect_origin_guard()"

        after_tables [
          "dossier_entries",
          "leads",
          "contacts",
          "accounts",
          "prototype_relocations",
          "users"
        ]
      end

      statement :owner_intake_origin_trigger do
        up "CREATE TRIGGER owner_intake_single_origin BEFORE INSERT ON owner_prospect_intakes FOR EACH ROW EXECUTE FUNCTION owner_prospect_origin_guard()"
        down "DROP TRIGGER owner_intake_single_origin ON owner_prospect_intakes"
        after_tables ["dossier_entries"]
      end

      statement :dossier_intake_origin_trigger do
        up "CREATE TRIGGER dossier_intake_single_origin BEFORE INSERT ON dossier_entries FOR EACH ROW EXECUTE FUNCTION owner_prospect_origin_guard()"
        down "DROP TRIGGER dossier_intake_single_origin ON dossier_entries"
        after_tables ["dossier_entries"]
      end
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [:account_id, :contact_id, :lead_id, :binding_id, :relocation_id, :submission_sha256]
      change set_attribute(:owner_user_id, actor(:id))
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds

      change {SdrAgent.Audit.Changes.OwnerIntakeEvent,
              event_type: "research.owner_intake.recorded"}
    end
  end

  policies do
    policy action(:record) do
      authorize_if SdrAgent.Audit.Checks.OwnerIntakeWriteScope
    end

    policy action_type(:read) do
      authorize_if SdrAgent.Audit.Checks.KernelContext
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :submission_sha256, :binary, allow_nil?: false, public?: true

    attribute :format_version, :string,
      allow_nil?: false,
      default: "owner-intake/1",
      writable?: false,
      public?: true

    attribute :classification, :atom,
      allow_nil?: false,
      default: :unverified,
      writable?: false,
      public?: true,
      constraints: [one_of: [:unverified]]

    attribute :imported_at, :utc_datetime_usec,
      allow_nil?: false,
      default: &SdrAgent.Clock.utc_now/0,
      writable?: false,
      public?: true

    attribute :trace_id, :string, allow_nil?: false, public?: true
    attribute :span_id, :string, allow_nil?: false, public?: true
  end

  relationships do
    belongs_to :tenant, SdrAgent.Audit.Tenant, allow_nil?: false, public?: true

    belongs_to :binding, SdrAgent.Operations.PrototypeDatabaseBinding,
      allow_nil?: false,
      public?: true

    belongs_to :relocation, SdrAgent.Prototype.Relocation, allow_nil?: false, public?: true
    belongs_to :owner_user, SdrAgent.Accounts.User, allow_nil?: false, public?: true
    belongs_to :account, SdrAgent.Sales.Account, allow_nil?: false, public?: true
    belongs_to :contact, SdrAgent.Sales.Contact, allow_nil?: false, public?: true
    belongs_to :lead, SdrAgent.Sales.Lead, allow_nil?: false, public?: true
  end

  identities do
    identity :unique_input, [:tenant_id, :submission_sha256]
    identity :unique_lead, [:tenant_id, :lead_id]
  end

  @doc false
  def __sdr_audited__, do: true
end
