defmodule SdrAgent.Sales.Account do
  @moduledoc """
  A target company — synthetic in the MVP (S2 row Account).

  Attributes: `name`, `domain` (stored in its company-identity form,
  `SdrAgent.Sales.Domain.canonical/1`, under a reserved name —
  `SdrAgent.Sales.Synthetic`; unique per tenant by its key form
  `sdr_canonical_domain(domain)`, the calculation `canonical_domain`),
  `website_url`, `industry`, `employee_count` (≥ 0), `geography`,
  `crm_provider` (`:fake_crm`) + `crm_external_id` (unique per tenant and
  provider when present), `source` (`:fixture`, `:crm`, `:manual`, and,
  for an account a lead admission creates, `:csv`, `:hubspot`,
  `:agent_found`; C3-02), `status`.

  Lifecycle (`transitions/0`): active → archived (T); archived accounts are
  not edited and get no new leads (`Lead :create` checks).

  Company identity (C3-02; packet section 3 Account; ADR-0009 C3-02
  amendment; `SdrAgent.Sales.Changes.AccountDomainIdentity`): `:create`,
  `:seed` and `:update` refuse a domain that is not a valid company fixed
  point (D-174 Q-O6) without echoing it. `:create` and `:seed` take the new
  domain's identity key first; `:update` with a domain change takes the old
  and the new domain's keys first, re-checks the old domain on the locked
  row (a typed conflict on `:domain` otherwise) and refuses a rename to a
  suppressed company domain (D-174 Q-O1 = A, A.4). Inside the lead
  admission (the `SdrAgent.Sales.Checks.LeadAdmissionContext` marker)
  `:create` takes no key: it requires the admission's pass to hold it
  (C3-02 G4). Existing rows keep their
  stored domain; the unique expression index
  `(tenant_id, sdr_canonical_domain(domain))` dedupes them with new input.

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
  alias SdrAgent.Audit.Changes.IdentityKeyLock
  alias SdrAgent.Audit.Changes.Transition
  alias SdrAgent.Audit.Checks
  alias SdrAgent.Sales.Changes
  alias SdrAgent.Sales.Checks.LeadAdmissionContext
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

    custom_indexes do
      # C3-02 (packet section 3 Account): one company per key form and
      # tenant; a legacy `www.` row and new canonical input collide here.
      index ["tenant_id", "sdr_canonical_domain(domain::text)"],
        unique: true,
        name: "accounts_canonical_domain_index",
        error_fields: [:domain],
        message: "is already used by another account"
    end

    custom_statements do
      # C3-02 (packet section 3 Account; plan r8 section 2.7): the key and
      # index form, character for character `Normalize.strip/1`.
      statement :sdr_canonical_domain_function do
        up ~S"""
        CREATE FUNCTION sdr_canonical_domain(text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
          SELECT regexp_replace(regexp_replace(lower(btrim($1)), '\.$', ''), '^www\.', '')
        $$
        """

        down "DROP FUNCTION sdr_canonical_domain(text)"
      end

      # C3-02: target of the lead admission's account foreign key (packet
      # section 3: the recorded account is its own tenant's).
      statement :accounts_id_tenant_key do
        up "ALTER TABLE accounts ADD CONSTRAINT accounts_id_tenant_key UNIQUE (id, tenant_id)"
        down "ALTER TABLE accounts DROP CONSTRAINT accounts_id_tenant_key"
      end
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

      change {IdentityKeyLock,
              mode: :entry,
              held_when: LeadAdmissionContext,
              keys: {Changes.AccountDomainIdentity, :entry_keys}}

      change SdrAgent.Audit.Changes.TraceIds
      change {AppendEvent, event_type: "sales.account.created", category: :domain_change}
    end

    create :seed do
      description "SEED (dev/test only): create an account with a fixture id."
      accept [:id, :source | @editable]
      change Changes.NormalizeDomain
      validate {Validations.Reserved, attribute: :domain, kind: :domain}
      change SdrAgent.Audit.Changes.SetTenant
      change {IdentityKeyLock, mode: :entry, keys: {Changes.AccountDomainIdentity, :entry_keys}}
      change SdrAgent.Audit.Changes.TraceIds
      change {AppendEvent, event_type: "sales.account.created", category: :domain_change}
    end

    update :update do
      description "ADM: edit an active account (the domain guard applies again)."
      require_atomic? false
      accept @editable

      change {IdentityKeyLock, mode: :entry, keys: {Changes.AccountDomainIdentity, :update_keys}}

      change get_and_lock_for_update()
      change {Changes.RequireState, in: [:active]}
      change Changes.NormalizeDomain
      validate {Validations.Reserved, attribute: :domain, kind: :domain}
      change Changes.AccountDomainIdentity
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
      constraints one_of: [:fixture, :crm, :manual, :csv, :hubspot, :agent_found]
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

  calculations do
    # C3-02: the stored row's company key form, read from the database (the
    # unique index's expression); every lookup by company uses it.
    calculate :canonical_domain,
              :string,
              expr(fragment("sdr_canonical_domain(?::text)", domain)) do
      public? true
    end
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
