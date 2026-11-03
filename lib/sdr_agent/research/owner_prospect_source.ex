defmodule SdrAgent.Research.OwnerProspectSource do
  @moduledoc """
  An immutable owner-supplied source of one intake lead, not independently
  fetched or spot-checked. Exact raw excerpt bytes live in tenant-scoped Payload.
  URL/type/declared retrieval date remain distinct from server submission time.
  Creation is restricted to the exact coordinator transaction/action/attributes;
  Research's run-bound reader is the only agent content route.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Research,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @types [:company_site, :person_authored, :attributed_third_party, :directory, :third_party]
  postgres do
    table "owner_prospect_sources"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :lead, on_delete: :restrict
      reference :intake, on_delete: :restrict
    end

    check_constraints do
      check_constraint :content_sha256, "owner_sources_digest",
        check: "octet_length(content_sha256)=32"

      check_constraint :source_type, "owner_sources_type",
        check: SdrAgent.Audit.SQL.one_of("source_type", @types)

      check_constraint :source_key, "owner_sources_key", check: "source_key ~ '^s[1-3]$'"

      check_constraint :url, "owner_sources_https",
        check: "url ~ '^https://' AND octet_length(url) <= 2048"

      check_constraint :trace_id, "owner_sources_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("owner_prospect_sources") do
        statement name do
          up up_sql
          down down_sql
        end
      end

      {name, up_sql, down_sql} =
        SdrAgent.Audit.SQL.payload_fk("owner_prospect_sources", :content_sha256)

      statement name do
        up up_sql
        down down_sql
        after_tables ["payloads"]
      end

      statement :owner_source_intake_guard do
        up """
        CREATE FUNCTION owner_source_intake_guard() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF NOT EXISTS (SELECT 1 FROM owner_prospect_intakes i WHERE i.id=NEW.intake_id
            AND i.lead_id=NEW.lead_id AND i.tenant_id=NEW.tenant_id) THEN
            RAISE EXCEPTION 'intake_relationship_mismatch' USING ERRCODE = 'check_violation';
          END IF;
          RETURN NEW;
        END;
        $$;
        """

        down "DROP FUNCTION owner_source_intake_guard()"

        after_tables ["owner_prospect_intakes"]
      end

      statement :owner_source_intake_guard_trigger do
        up "CREATE TRIGGER owner_source_intake_guard BEFORE INSERT ON owner_prospect_sources FOR EACH ROW EXECUTE FUNCTION owner_source_intake_guard()"
        down "DROP TRIGGER owner_source_intake_guard ON owner_prospect_sources"
        after_tables ["owner_prospect_intakes"]
      end
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [
        :intake_id,
        :lead_id,
        :source_key,
        :url,
        :source_type,
        :retrieved_on,
        :content_sha256
      ]

      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds

      change {SdrAgent.Audit.Changes.OwnerIntakeEvent,
              event_type: "research.owner_source.recorded"}
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
    attribute :source_key, :string, allow_nil?: false, public?: true
    attribute :url, :string, allow_nil?: false, public?: true, constraints: [trim?: false]
    attribute :source_type, :atom, allow_nil?: false, public?: true, constraints: [one_of: @types]
    attribute :retrieved_on, :date, allow_nil?: false, public?: true
    attribute :content_sha256, :binary, allow_nil?: false, public?: true

    attribute :submitted_at, :utc_datetime_usec,
      allow_nil?: false,
      default: &SdrAgent.Clock.utc_now/0,
      writable?: false,
      public?: true

    attribute :trace_id, :string, allow_nil?: false, public?: true
    attribute :span_id, :string, allow_nil?: false, public?: true
  end

  relationships do
    belongs_to :tenant, SdrAgent.Audit.Tenant, allow_nil?: false, public?: true
    belongs_to :lead, SdrAgent.Sales.Lead, allow_nil?: false, public?: true
    belongs_to :intake, SdrAgent.Research.OwnerProspectIntake, allow_nil?: false, public?: true
  end

  identities do
    identity :unique_source, [:intake_id, :source_key]
  end

  @doc false
  def __sdr_audited__, do: true
end
