defmodule SdrAgent.Sales.Contact do
  @moduledoc """
  A person at an Account — the only possible recipient identity (S2 row
  Contact).

  Attributes: `account_id`, `first_name`, `last_name`, `email` (unique per
  tenant, reserved domain only), `title`, `persona`, `timezone` (IANA name),
  `crm_external_id`, `status`.

  The email changes only through `:change_email`, whose event records the
  old and the new address. Sales never calls Outreach: the S8 send gate
  compares an approval's recipient email with the current contact email.

  Lifecycle (`transitions/0`): active → archived (T); archived contacts are
  not edited.

  Actors: ADM create, update, change_email, archive; SEED (dev/test only)
  `:seed`; ADM, REV, AUR, AGT, AUD read. Every write appends an AuditEvent
  (`sales.contact.*`).
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
  @editable [:first_name, :last_name, :title, :persona, :timezone, :crm_external_id]

  postgres do
    table "contacts"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :account, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "contacts_trace_ids", check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :status, "contacts_status",
        check: SdrAgent.Audit.SQL.one_of("status", @statuses)
    end
  end

  actions do
    defaults [:read]

    create :create do
      description "ADM: create a contact with a reserved email at an account."
      accept [:account_id, :email | @editable]
      validate {Validations.Reserved, attribute: :email, kind: :email}
      validate {Validations.Timezone, attribute: :timezone}
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change {AppendEvent, event_type: "sales.contact.created", category: :domain_change}
    end

    create :seed do
      description "SEED (dev/test only): create a contact with a fixture id."
      accept [:id, :account_id, :email | @editable]
      validate {Validations.Reserved, attribute: :email, kind: :email}
      validate {Validations.Timezone, attribute: :timezone}
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change {AppendEvent, event_type: "sales.contact.created", category: :domain_change}
    end

    update :update do
      description "ADM: edit an active contact (not its email)."
      require_atomic? false
      accept @editable
      change get_and_lock_for_update()
      change {Changes.RequireState, in: [:active]}
      validate {Validations.Timezone, attribute: :timezone}
      change {AppendEvent, event_type: "sales.contact.updated", category: :domain_change}
    end

    update :change_email do
      description "ADM: change an active contact's email; the event records old and new."
      require_atomic? false
      accept [:email]
      require_attributes [:email]
      change get_and_lock_for_update()
      change {Changes.RequireState, in: [:active]}
      validate {Validations.Reserved, attribute: :email, kind: :email}

      change {AppendEvent,
              event_type: "sales.contact.email_changed",
              category: :domain_change,
              previous: [:email]}
    end

    update :archive do
      description "ADM: active → archived (terminal)."
      require_atomic? false
      change get_and_lock_for_update()
      change {Transition, from: [:active], to: :archived, locked?: true}

      change {AppendEvent,
              event_type: "sales.contact.archived", category: :domain_change, previous: [:status]}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action([:create, :update, :change_email, :archive]) do
      authorize_if {Checks.ActorRole, roles: [:admin]}
    end

    policy action(:seed) do
      authorize_if Checks.SeedingAllowed
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer, :auditor]}

      authorize_if {Checks.ActorType,
                    types: [
                      :agent_runtime,
                      :auditor_cli,
                      :seeder,
                      :delivery_worker,
                      :reconciler,
                      :scheduler
                    ]}
    end
  end

  attributes do
    uuid_v7_primary_key :id, writable?: true
    attribute :first_name, :string, allow_nil?: false, public?: true
    attribute :last_name, :string, allow_nil?: false, public?: true
    attribute :email, :ci_string, allow_nil?: false, public?: true
    attribute :title, :string, public?: true
    attribute :persona, :string, public?: true
    attribute :timezone, :string, public?: true
    attribute :crm_external_id, :string, public?: true

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

    belongs_to :account, SdrAgent.Sales.Account do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    has_many :leads, SdrAgent.Sales.Lead, public?: true
  end

  identities do
    identity :unique_email, [:tenant_id, :email]
  end

  @doc "Declared lifecycle transitions `{action, from, to}` (ADR-0010)."
  def transitions, do: @transitions

  @doc false
  def __sdr_audited__, do: true
end
