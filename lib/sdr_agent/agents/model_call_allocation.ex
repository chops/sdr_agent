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

  Invariants (`SdrAgent.Agents.Changes.GrantInvariants`, checked with the
  grant row locked): the grant is active, `profile_id` is one of the grant's
  `profile_ids`, and all allocations of a grant sum to at most its
  `total_attempts`. Unique per `[grant_id, key, profile_id]`, with a missing
  `profile_id` counted as equal.

  Actions: `:create`, `:update_terms`, `:release`; only an active human
  admin (`SdrAgent.Agents.Checks.CurrentAdmin`), through
  `SdrAgent.Agents`, which also bumps the grant's revision. Reads as the
  grant. Audited: `model.grant.allocation_created | allocation_changed |
  allocation_released`.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Agents.Changes.GrantInvariants
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
  end

  actions do
    defaults [:read]

    create :create do
      accept [:grant_id, :key, :profile_id | @terms]
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change {GrantInvariants, on: :allocation}
      change {AppendEvent, [event_type: "model.grant.allocation_created"] ++ @event}
    end

    update :update_terms do
      require_atomic? false
      accept @terms
      change get_and_lock_for_update()
      change {GrantInvariants, on: :allocation}

      change {AppendEvent,
              [event_type: "model.grant.allocation_changed", previous: @terms] ++ @event}
    end

    update :release do
      require_atomic? false
      accept []
      change get_and_lock_for_update()
      change {GrantInvariants, on: :allocation}
      change set_attribute(:released_at, &SdrAgent.Clock.utc_now/0)

      change {AppendEvent,
              [event_type: "model.grant.allocation_released", previous: [:released_at]] ++ @event}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
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
      constraints one_of: SdrAgent.Agents.ModelCallGrant.real_profiles()
    end

    attribute :attempts, :integer, allow_nil?: false, public?: true, constraints: [min: 1]
    attribute :available_from, :utc_datetime_usec, public?: true
    attribute :available_until, :utc_datetime_usec, public?: true
    attribute :released_at, :utc_datetime_usec, writable?: false, public?: true
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
end
