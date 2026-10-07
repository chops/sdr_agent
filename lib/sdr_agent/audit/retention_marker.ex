defmodule SdrAgent.Audit.RetentionMarker do
  @moduledoc """
  Retention class and legal-hold state of a record or payload (S2 row
  RetentionMarker; ADR-0002 retention record).

  Attributes: `target_resource`, `target_ref`, `retention_class` (MVP:
  `:synthetic_demo` only), `legal_hold`, `reason`, `supersedes_id`,
  `effective_at`.

  Append-only with supersedes lineage: the subject is
  `(tenant_id, target_resource, target_ref)`; the current state is the
  marker with no successor (`:current`); an absent marker means
  synthetic_demo, no hold, keep indefinitely. ADM `:set` (audited as
  `retention.marker.set`); ADM, AUR, AUD read.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Audit,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Checks

  postgres do
    table "retention_markers"
    repo SdrAgent.Repo

    identity_wheres_to_sql unique_root: "supersedes_id IS NULL",
                           unique_supersedes: "supersedes_id IS NOT NULL"

    references do
      reference :tenant, on_delete: :restrict
      reference :supersedes, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "retention_markers_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("retention_markers") do
        statement name do
          up up_sql
          down down_sql
        end
      end
    end
  end

  actions do
    defaults [:read]

    read :current do
      get? true
      argument :target_resource, :string, allow_nil?: false
      argument :target_ref, :string, allow_nil?: false

      filter expr(
               target_resource == ^arg(:target_resource) and target_ref == ^arg(:target_ref) and
                 not exists(successors, true)
             )
    end

    create :set do
      accept [
        :target_resource,
        :target_ref,
        :retention_class,
        :legal_hold,
        :reason,
        :supersedes_id
      ]

      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds

      change {SdrAgent.Audit.Changes.Supersedes,
              subject: [:tenant_id, :target_resource, :target_ref]}

      change {SdrAgent.Audit.Changes.AppendEvent,
              event_type: "retention.marker.set", category: :retention}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action(:set) do
      authorize_if {Checks.ActorRole, roles: [:admin]}
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :auditor]}
      authorize_if {Checks.ActorType, types: [:auditor_cli]}
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :target_resource, :string, allow_nil?: false, public?: true
    attribute :target_ref, :string, allow_nil?: false, public?: true

    attribute :retention_class, :atom do
      allow_nil? false
      constraints one_of: [:synthetic_demo]
      public? true
    end

    attribute :legal_hold, :boolean, allow_nil?: false, default: false, public?: true
    attribute :reason, :string, allow_nil?: false, public?: true

    attribute :effective_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      default &SdrAgent.Clock.utc_now/0
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

  relationships do
    belongs_to :tenant, SdrAgent.Audit.Tenant do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :supersedes, __MODULE__ do
      attribute_writable? true
      public? true
    end

    has_many :successors, __MODULE__ do
      destination_attribute :supersedes_id
      public? true
    end
  end

  identities do
    identity :unique_root, [:tenant_id, :target_resource, :target_ref],
      where: expr(is_nil(supersedes_id))

    identity :unique_supersedes, [:supersedes_id], where: expr(not is_nil(supersedes_id))
  end

  @doc false
  def __sdr_audited__, do: true
end
