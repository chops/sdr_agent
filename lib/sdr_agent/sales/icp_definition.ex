defmodule SdrAgent.Sales.IcpDefinition do
  @moduledoc """
  A versioned ideal-customer profile that qualification is evaluated
  against (S2 row IcpDefinition).

  Attributes: `name`, `version` (≥ 1; unique per tenant and name),
  `status`, `description`, embedded `criteria` (`SdrAgent.Sales.IcpCriteria`)
  and `criteria_sha256` (canonical hash, computed server-side).

  Lifecycle (`transitions/0`): draft → active → retired (T). Criteria are
  editable only while draft (`:update`); after activation a change is a new
  draft row (`:new_version`, next version of the same name). Only active
  ICPs may back a campaign at activation (checked by `Campaign :activate`).

  Actors: ADM create, update, new_version, activate, retire; SEED (dev/test
  only) `:seed` and `:activate`; ADM, REV, AUR, AGT, AUD read. Every write
  appends an AuditEvent (`sales.icp_definition.*`).
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Sales,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Changes.AppendEvent
  alias SdrAgent.Audit.Changes.Transition
  alias SdrAgent.Audit.Checks
  alias SdrAgent.Sales.Changes

  @statuses [:draft, :active, :retired]
  @transitions [{:activate, [:draft], :active}, {:retire, [:active], :retired}]

  postgres do
    table "icp_definitions"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "icp_definitions_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :status, "icp_definitions_status",
        check: SdrAgent.Audit.SQL.one_of("status", @statuses)

      check_constraint :version, "icp_definitions_version_positive", check: "version >= 1"

      check_constraint :criteria_sha256, "icp_definitions_criteria_sha256_length",
        check: "octet_length(criteria_sha256) = 32"
    end
  end

  actions do
    defaults [:read]

    create :create do
      description "ADM: create a draft ICP (version 1)."
      accept [:name, :description, :criteria]
      change SdrAgent.Audit.Changes.SetTenant
      change Changes.CriteriaHash
      change SdrAgent.Audit.Changes.TraceIds
      change {AppendEvent, event_type: "sales.icp_definition.created", category: :domain_change}
    end

    create :seed do
      description "SEED (dev/test only): create an ICP with a fixture id."
      accept [:id, :name, :version, :description, :criteria]
      change SdrAgent.Audit.Changes.SetTenant
      change Changes.CriteriaHash
      change SdrAgent.Audit.Changes.TraceIds
      change {AppendEvent, event_type: "sales.icp_definition.created", category: :domain_change}
    end

    create :new_version do
      description "ADM: start the next draft version of an ICP (criteria change after activation)."
      accept [:description, :criteria]
      argument :icp_definition_id, :uuid, allow_nil?: false
      change Changes.NextIcpVersion
      change SdrAgent.Audit.Changes.SetTenant
      change Changes.CriteriaHash
      change SdrAgent.Audit.Changes.TraceIds

      change {AppendEvent,
              event_type: "sales.icp_definition.version_created",
              category: :domain_change,
              arguments: [:icp_definition_id]}
    end

    update :update do
      description "ADM: edit a draft ICP."
      require_atomic? false
      accept [:description, :criteria]
      change get_and_lock_for_update()
      change {Changes.RequireState, in: [:draft]}
      change Changes.CriteriaHash
      change {AppendEvent, event_type: "sales.icp_definition.updated", category: :domain_change}
    end

    update :activate do
      description "ADM, SEED: draft → active; criteria are frozen from now on."
      require_atomic? false
      change get_and_lock_for_update()
      change {Transition, from: [:draft], to: :active, locked?: true}

      change {AppendEvent,
              event_type: "sales.icp_definition.activated",
              category: :domain_change,
              previous: [:status]}
    end

    update :retire do
      description "ADM: active → retired (terminal)."
      require_atomic? false
      change get_and_lock_for_update()
      change {Transition, from: [:active], to: :retired, locked?: true}

      change {AppendEvent,
              event_type: "sales.icp_definition.retired",
              category: :domain_change,
              previous: [:status]}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action([:create, :new_version, :update, :retire]) do
      authorize_if {Checks.ActorRole, roles: [:admin]}
    end

    policy action(:activate) do
      authorize_if {Checks.ActorRole, roles: [:admin]}
      authorize_if Checks.SeedingAllowed
    end

    policy action(:seed) do
      authorize_if Checks.SeedingAllowed
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer, :auditor]}
      authorize_if {Checks.ActorType, types: [:agent_runtime, :auditor_cli, :seeder]}
    end
  end

  attributes do
    uuid_v7_primary_key :id, writable?: true
    attribute :name, :string, allow_nil?: false, public?: true

    attribute :version, :integer do
      allow_nil? false
      default 1
      constraints min: 1
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      default :draft
      writable? false
      constraints one_of: @statuses
      public? true
    end

    attribute :description, :string, public?: true
    attribute :criteria, SdrAgent.Sales.IcpCriteria, allow_nil?: false, public?: true
    attribute :criteria_sha256, :binary, allow_nil?: false, writable?: false, public?: true
    attribute :trace_id, :string, allow_nil?: false, public?: true
    attribute :span_id, :string, allow_nil?: false, public?: true

    attribute :inserted_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      default &SdrAgent.Clock.utc_now/0
      public? true
    end

    attribute :updated_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      default &SdrAgent.Clock.utc_now/0
      update_default &SdrAgent.Clock.utc_now/0
      public? true
    end
  end

  relationships do
    belongs_to :tenant, SdrAgent.Audit.Tenant do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_name_version, [:tenant_id, :name, :version]
  end

  @doc "Declared lifecycle transitions `{action, from, to}` (ADR-0010)."
  def transitions, do: @transitions

  @doc false
  def __sdr_audited__, do: true
end
