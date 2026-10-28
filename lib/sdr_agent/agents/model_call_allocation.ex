defmodule SdrAgent.Agents.ModelCallAllocation do
  @moduledoc """
  One spendable slice of a `ModelCallGrant` (C9; R0 readiness packet).

  Attributes: `key` (the allocation's name: a usage bucket such as `:b1`,
  or a context such as `:rehearsal`, `:daily_use`, `:workshop`),
  `applies_to` (the usage buckets it may fund), optional `profile_id`
  (restricts it to one profile), `attempts`, the optional
  `available_from`/`available_until` window and `released_at` (the owner's
  early release). The workshop reserve is an ordinary allocation with an
  `available_from`, so there is one balance and nothing is counted twice.

  Invariants (`SdrAgent.Agents.Changes.GrantBundle`, checked on the
  complete final state with the grant row locked): the grant is active,
  `profile_id` is one of the grant's `profile_ids`, and all allocations of a
  grant sum to at most its `total_attempts`. `grant_revision` records the
  grant revision that last wrote the allocation. Unique per `[grant_id, key, profile_id]`, with a missing
  `profile_id` counted as equal.

  Actions: `:create`, `:update_terms`, `:release`; only from the grant's own
  action (`SdrAgent.Agents.Checks.GrantContext`) and as an active human
  admin (`SdrAgent.Agents.Checks.CurrentAdmin`), or, for `:create` only,
  as the D-237 prototype operator under the registered, single-use
  `SdrAgent.Prototype.ProvisionScope` that `ModelCallGrant
  :provision_prototype` forwards (`SdrAgent.Prototype.Checks.ProvisionScope`,
  consumed by `SdrAgent.Prototype.Changes.ConsumeProvisionScope`); a direct
  call is refused before any lock. Reads as the grant. Audited:
  `model.grant.allocation_created | allocation_changed`,
  `model.allocation.released`, each carrying `grant_revision`.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Agents.Checks.GrantContext
  alias SdrAgent.Agents.Checks.CurrentAdmin
  alias SdrAgent.Audit.Changes.AppendEvent
  alias SdrAgent.Audit.Checks

  @buckets [:b1, :b2, :b3, :b4, :b5, :proof]
  @keys @buckets ++ [:rehearsal, :daily_use, :workshop]
  @terms [:applies_to, :attempts, :available_from, :available_until]
  @event [category: :model, links: [subject_id: :grant_id]]

  postgres do
    table "model_call_allocations"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :grant, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "model_call_allocations_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :attempts, "model_call_allocations_attempts_positive",
        check: "attempts > 0"

      check_constraint :applies_to, "model_call_allocations_applies_to",
        check: "cardinality(applies_to) > 0"

      check_constraint :available_until, "model_call_allocations_window",
        check:
          "available_from IS NULL OR available_until IS NULL OR available_until > available_from"
    end

    custom_statements do
      # Target of the ModelInvocation (allocation_id, grant_id) composite FK (C9).
      statement :model_call_allocations_id_grant_key do
        up "ALTER TABLE model_call_allocations ADD CONSTRAINT model_call_allocations_id_grant_key UNIQUE (id, grant_id)"

        down "ALTER TABLE model_call_allocations DROP CONSTRAINT model_call_allocations_id_grant_key"
      end
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept [:grant_id, :grant_revision, :key, :profile_id | @terms]
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change SdrAgent.Prototype.Changes.ConsumeProvisionScope
      change {AppendEvent, [event_type: "model.grant.allocation_created"] ++ @event}
    end

    update :update_terms do
      require_atomic? false
      accept [:grant_revision | @terms]

      change {AppendEvent,
              [event_type: "model.grant.allocation_changed", previous: [:grant_revision | @terms]] ++
                @event}
    end

    update :release do
      require_atomic? false
      accept [:grant_revision]
      change set_attribute(:released_at, &SdrAgent.Clock.utc_now/0)

      change {AppendEvent,
              [event_type: "model.allocation.released", previous: [:grant_revision, :released_at]] ++
                @event}
    end
  end

  policies do
    # Both must pass: written only by the grant's own action, as a current admin.
    policy action_type([:create, :update, :destroy, :action]) do
      authorize_if GrantContext
    end

    # The D-237 operator creates its one planned allocation only under the
    # registered scope `ModelCallGrant :provision_prototype` forwards (a pure
    # check; consumed once in the action by ConsumeProvisionScope; the
    # GrantContext marker above still applies); every other write remains a
    # current admin's.
    policy action_type(:create) do
      authorize_if SdrAgent.Prototype.Checks.ProvisionScope
      authorize_if CurrentAdmin
    end

    policy action_type([:update, :destroy, :action]) do
      authorize_if CurrentAdmin
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :auditor]}
      authorize_if {Checks.ActorType, types: [:agent_runtime, :auditor_cli]}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :key, :atom do
      allow_nil? false
      public? true
      constraints one_of: @keys
    end

    attribute :applies_to, {:array, :atom} do
      allow_nil? false
      public? true
      constraints min_length: 1, items: [one_of: @buckets]
    end

    attribute :profile_id, :atom do
      public? true
      constraints one_of: SdrAgent.AI.ModelProfiles.real_ids()
    end

    attribute :attempts, :integer, allow_nil?: false, public?: true, constraints: [min: 1]
    attribute :available_from, :utc_datetime_usec, public?: true
    attribute :available_until, :utc_datetime_usec, public?: true
    attribute :released_at, :utc_datetime_usec, writable?: false, public?: true

    attribute :grant_revision, :integer do
      description "The grant revision that last wrote this allocation."
      allow_nil? false
      public? true
      constraints min: 1
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
    belongs_to :tenant, SdrAgent.Audit.Tenant, allow_nil?: false, public?: true

    belongs_to :grant, SdrAgent.Agents.ModelCallGrant do
      allow_nil? false
      public? true
      attribute_writable? true
    end
  end

  identities do
    identity :unique_key_profile, [:grant_id, :key, :profile_id], nils_distinct?: false
  end

  @doc "Usage buckets an allocation may fund (D-104 mapping, C9-02)."
  def buckets, do: @buckets

  @doc "The allocation keys: the usage buckets and the contexts (rehearsal, daily use, workshop)."
  def keys, do: @keys
end
