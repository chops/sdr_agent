defmodule SdrAgent.Agents.ModelCallGrant do
  @moduledoc """
  An owner-granted budget of real-model attempts (C9; R0 readiness packet,
  G5-R0; ADR-0004 R0 amendment item 5).

  Attributes: `name`, `purpose`, `status` (`:active | :revoked`),
  `profile_ids` (non-empty; reviewed real profiles only), `total_attempts`,
  optional `per_utc_day_attempts`, the `starts_at`/`expires_at` window,
  `revision` (bumped by every change), `created_by_id`, `updated_by_id`,
  `revoked_at`. Its spendable slices are `ModelCallAllocation`s; their
  attempts never sum above `total_attempts`.

  Consumption is derived from the ModelInvocations charged to the grant and
  is never stored or refunded (C9-02). Lowering a limit below what is
  consumed is allowed; it only stops new reservations.

  Actions: `:create` (with its `allocations`), `:update_terms` (terms and
  allocation changes as one bundle), `:release_allocation` and `:revoke`
  (terminal). The last three refuse a stale `expected_revision` and bump
  `revision`. Allocation rows are written only by these actions
  (`SdrAgent.Agents.Changes.GrantBundle`), which lock the grant row first,
  then its allocations, and validate the complete final state. Every write
  requires an active human admin, re-read at the time of the action
  (`SdrAgent.Agents.Checks.CurrentAdmin`); every system actor is refused.
  Reads: admin, auditor, `agent_runtime`, kernel.
  Audited: `model.grant.created | terms_changed | allocation_released |
  revoked`, each with the previous revision.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Agents.Changes.GrantBundle
  alias SdrAgent.Agents.Changes.GrantRevision
  alias SdrAgent.Agents.Checks.CurrentAdmin
  alias SdrAgent.Audit.Changes.AppendEvent
  alias SdrAgent.Audit.Checks
  alias SdrAgent.Sales.Changes.RequireState

  @real_profiles [:claude_cli_opus, :claude_cli_sonnet]
  @statuses [:active, :revoked]
  @terms [
    :name,
    :purpose,
    :profile_ids,
    :total_attempts,
    :per_utc_day_attempts,
    :starts_at,
    :expires_at
  ]
  @event [category: :model, links: [subject_id: :id]]

  postgres do
    table "model_call_grants"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :created_by, on_delete: :restrict
      reference :updated_by, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "model_call_grants_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :status, "model_call_grants_status",
        check: SdrAgent.Audit.SQL.one_of("status", @statuses)

      check_constraint :expires_at, "model_call_grants_window", check: "expires_at > starts_at"

      check_constraint :total_attempts, "model_call_grants_total_positive",
        check: "total_attempts > 0 AND (per_utc_day_attempts IS NULL OR per_utc_day_attempts > 0)"

      check_constraint :profile_ids, "model_call_grants_profiles",
        check: "cardinality(profile_ids) > 0"
    end

    custom_statements do
      # Target of the ModelInvocation (grant_id, tenant_id) composite FK (C9).
      statement :model_call_grants_id_tenant_key do
        up "ALTER TABLE model_call_grants ADD CONSTRAINT model_call_grants_id_tenant_key UNIQUE (id, tenant_id)"
        down "ALTER TABLE model_call_grants DROP CONSTRAINT model_call_grants_id_tenant_key"
      end
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept @terms
      argument :allocations, {:array, :map}, default: []
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change relate_actor(:created_by)
      change relate_actor(:updated_by)
      change {GrantBundle, mode: :create}
      change {AppendEvent, [event_type: "model.grant.created"] ++ @event}
    end

    update :update_terms do
      require_atomic? false
      accept @terms
      argument :expected_revision, :integer, allow_nil?: false
      argument :allocations, {:array, :map}, default: []
      change get_and_lock_for_update()
      change {RequireState, in: [:active]}
      change GrantRevision
      change {GrantBundle, mode: :update}
      change relate_actor(:updated_by)

      change {AppendEvent,
              [event_type: "model.grant.terms_changed", previous: [:revision | @terms]] ++ @event}
    end

    update :release_allocation do
      require_atomic? false
      accept []
      argument :expected_revision, :integer, allow_nil?: false
      argument :key, :atom, allow_nil?: false
      argument :profile_id, :atom
      change get_and_lock_for_update()
      change {RequireState, in: [:active]}
      change GrantRevision
      change {GrantBundle, mode: :release}
      change relate_actor(:updated_by)

      change {AppendEvent,
              [event_type: "model.grant.allocation_released", previous: [:revision]] ++ @event}
    end

    update :revoke do
      require_atomic? false
      accept []
      argument :expected_revision, :integer, allow_nil?: false
      change get_and_lock_for_update()
      change {RequireState, in: [:active]}
      change GrantRevision
      change set_attribute(:status, :revoked)
      change set_attribute(:revoked_at, &SdrAgent.Clock.utc_now/0)
      change relate_actor(:updated_by)

      change {AppendEvent,
              [event_type: "model.grant.revoked", previous: [:status, :revision]] ++ @event}
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

  validations do
    validate compare(:expires_at, greater_than: :starts_at),
      message: "must be after starts_at"
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 80]

    attribute :purpose, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 500]

    attribute :status, :atom do
      allow_nil? false
      writable? false
      default :active
      public? true
      constraints one_of: @statuses
    end

    attribute :profile_ids, {:array, :atom} do
      allow_nil? false
      public? true
      constraints min_length: 1, items: [one_of: @real_profiles]
    end

    attribute :total_attempts, :integer, allow_nil?: false, public?: true, constraints: [min: 1]
    attribute :per_utc_day_attempts, :integer, public?: true, constraints: [min: 1]
    attribute :starts_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: true

    attribute :revision, :integer do
      allow_nil? false
      writable? false
      default 1
      public? true
      constraints min: 1
    end

    attribute :revoked_at, :utc_datetime_usec, writable?: false, public?: true
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
    belongs_to :created_by, SdrAgent.Accounts.User, allow_nil?: false, public?: true
    belongs_to :updated_by, SdrAgent.Accounts.User, allow_nil?: false, public?: true

    has_many :allocations, SdrAgent.Agents.ModelCallAllocation,
      destination_attribute: :grant_id,
      public?: true
  end

  @doc "The reviewed real profiles a grant may name (until the R0-03 registry exists)."
  def real_profiles, do: @real_profiles
end
