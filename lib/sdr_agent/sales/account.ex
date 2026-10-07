defmodule SdrAgent.Sales.Account do
  @moduledoc """
  A target company — synthetic in the MVP (S2 row Account).

  Attributes: `name`, `domain` (lowercase host without scheme, unique per
  tenant, under a reserved name — `SdrAgent.Sales.Synthetic`),
  `website_url`, `industry`, `employee_count` (≥ 0), `geography`,
  `crm_provider` (`:fake_crm`) + `crm_external_id` (unique per tenant and
  provider when present), `source` (`:fixture`, `:crm`, `:manual`),
  `status`.

  Lifecycle (`transitions/0`): active → archived (T); archived accounts are
  not edited and get no new leads (`Lead :create` checks).

  Actors: ADM create, update, archive; SEED (dev/test only) `:seed`; ADM,
  REV, AUR, AGT, AUD read. Every write appends an AuditEvent
  (`sales.account.*`).
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
  alias SdrAgent.Sales.Validations

  @statuses [:active, :archived]
  @transitions [{:archive, [:active], :archived}]
  @editable [
    :name,
    :domain,
    :website_url,
    :industry,
    :employee_count,
    :geography,
    :crm_provider,
    :crm_external_id
  ]

  postgres do
    table "accounts"
    repo SdrAgent.Repo

    identity_wheres_to_sql unique_crm_id: "crm_external_id IS NOT NULL"

    references do
      reference :tenant, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "accounts_trace_ids", check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :status, "accounts_status",
        check: SdrAgent.Audit.SQL.one_of("status", @statuses)
    end
  end

  actions do
    defaults [:read]

    create :create do
      description "ADM: create an account under a reserved domain."
      accept @editable ++ [:source]
      change Changes.NormalizeDomain
      validate {Validations.Reserved, attribute: :domain, kind: :domain}
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change {AppendEvent, event_type: "sales.account.created", category: :domain_change}
    end

    create :seed do
      description "SEED (dev/test only): create an account with a fixture id."
      accept [:id, :source | @editable]
      change Changes.NormalizeDomain
      validate {Validations.Reserved, attribute: :domain, kind: :domain}
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change {AppendEvent, event_type: "sales.account.created", category: :domain_change}
    end

    update :update do
      description "ADM: edit an active account (the domain guard applies again)."
      require_atomic? false
      accept @editable
      change get_and_lock_for_update()
      change {Changes.RequireState, in: [:active]}
      change Changes.NormalizeDomain
      validate {Validations.Reserved, attribute: :domain, kind: :domain}
      change {AppendEvent, event_type: "sales.account.updated", category: :domain_change}
    end

    update :archive do
      description "ADM: active → archived (terminal)."
      require_atomic? false
      change get_and_lock_for_update()
      change {Transition, from: [:active], to: :archived, locked?: true}

      change {AppendEvent,
              event_type: "sales.account.archived", category: :domain_change, previous: [:status]}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action([:create, :update, :archive]) do
      authorize_if {Checks.ActorRole, roles: [:admin]}
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
    attribute :domain, :ci_string, allow_nil?: false, public?: true
    attribute :website_url, :string, public?: true
    attribute :industry, :string, public?: true
    attribute :employee_count, :integer, public?: true, constraints: [min: 0]
    attribute :geography, :string, public?: true
    attribute :crm_provider, :atom, public?: true, constraints: [one_of: [:fake_crm]]
    attribute :crm_external_id, :string, public?: true

    attribute :source, :atom do
      allow_nil? false
      constraints one_of: [:fixture, :crm, :manual]
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      default :active
      writable? false
      constraints one_of: @statuses
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

    has_many :contacts, SdrAgent.Sales.Contact, public?: true
    has_many :leads, SdrAgent.Sales.Lead, public?: true
  end

  identities do
    identity :unique_domain, [:tenant_id, :domain]

    identity :unique_crm_id, [:tenant_id, :crm_provider, :crm_external_id],
      where: expr(not is_nil(crm_external_id))
  end

  @doc "Declared lifecycle transitions `{action, from, to}` (ADR-0010)."
  def transitions, do: @transitions

  @doc false
  def __sdr_audited__, do: true
end
