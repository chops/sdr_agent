defmodule SdrAgent.Audit.Tenant do
  @moduledoc """
  The single tenant of the MVP (S2 row Tenant; ADR-0009 "Tenant").

  Lives in the lowest domain, `SdrAgent.Audit`, because the audit chain is
  partitioned by it; every `tenant_id` FK therefore points downward.

  Attributes: `slug` (globally unique), `name`, `singleton` (always true —
  unique and check-constrained, so at most one row exists), trace ids,
  `inserted_at`.

  Actions: `:bootstrap` (KRN only) creates the tenant, its genesis
  `AuditChainHead` and the genesis event `tenant.created` (sequence 1) in
  one transaction; `:read` for any actor. No update or destroy; the table is
  append-only (trigger).
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Audit,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Checks

  postgres do
    table "tenants"
    repo SdrAgent.Repo

    check_constraints do
      check_constraint :singleton, "singleton_must_be_true", check: "singleton = true"
      check_constraint :trace_id, "tenants_trace_ids", check: SdrAgent.Audit.SQL.trace_check()
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("tenants") do
        statement name do
          up up_sql
          down down_sql
        end
      end
    end
  end

  actions do
    defaults [:read]

    create :bootstrap do
      description "KRN: create the singleton tenant, its chain head and the genesis event."
      accept [:slug, :name]
      change SdrAgent.Audit.Changes.TraceIds
      change SdrAgent.Audit.Changes.InitChainHead

      change {SdrAgent.Audit.Changes.AppendEvent,
              event_type: "tenant.created", category: :system, tenant: :id}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action(:bootstrap) do
      authorize_if {Checks.ActorType, types: [:kernel]}
    end

    policy action_type(:read) do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :slug, :string do
      allow_nil? false
      public? true
    end

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :singleton, :boolean do
      allow_nil? false
      default true
      public? true
    end

    attribute :trace_id, :string, allow_nil?: false, public?: true
    attribute :span_id, :string, allow_nil?: false, public?: true

    attribute :inserted_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      default &SdrAgent.Clock.utc_now/0
      public? true
    end
  end

  identities do
    identity :unique_slug, [:slug]
    identity :unique_singleton, [:singleton]
  end

  @doc false
  def __sdr_audited__, do: true
end
