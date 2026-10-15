defmodule SdrAgent.Agents.ModelProfileSwitch do
  @moduledoc """
  One requested change of the tenant's desired model profile and its
  outcome (C2-02a; R0 readiness section 2;
  `docs/product/r0/c2-02a-interface.md`).

  Attributes: `from_profile_id` and `to_profile_id` (reviewed real
  profiles, different), `status` (`:pending | :completed | :failed |
  :blocked`), `server_generation` (the server start the switch belongs to,
  ≥ 1), `requested_by_id`, `requested_at`, `finished_at` (completed or
  failed) and `failure_reason` (failed or blocked). At most one pending or
  blocked switch per tenant (partial unique index). History is never
  relabelled.

  Lifecycle: pending → completed (the setting is applied in the same
  transaction), pending → failed, pending → blocked. In this slice a
  blocked switch has no exit (`resolve_blocked` is b2's).

  Writes run only inside their `SdrAgent.Agents.Checks.ProfileSwitchContext`
  phase, opened by `SdrAgent.Agents.ProfileSwitches`: `:request` (phase
  `:initialize`, a current human admin), `:fail` and `:block` (phase
  `:transition`, `model_runtime`), `:complete` (phase `:apply`,
  `model_runtime`, after the setting was applied). Each appends its
  `model.profile.switch_*` event (`SdrAgent.Agents.Changes.ProfileSwitchEvent`).

  Reads: admin, auditor (audited by the domain read), `agent_runtime`,
  kernel. `model_runtime` reads and locks one switch only through
  `:lock_for_transition`, in phase `:transition`, after the setting.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Agents.Changes.ProfileSwitchEvent
  alias SdrAgent.Agents.Changes.RequireAppliedSetting
  alias SdrAgent.Agents.Checks.ProfileSwitchContext
  alias SdrAgent.Agents.Preparations.TransitionLock
  alias SdrAgent.Audit.Checks

  @real_profiles SdrAgent.AI.ModelProfiles.real_ids()
  @statuses [:pending, :completed, :failed, :blocked]

  postgres do
    table "model_profile_switches"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :requested_by, on_delete: :restrict
    end

    check_constraints do
      check_constraint :to_profile_id, "model_profile_switches_distinct_profiles",
        check: "from_profile_id <> to_profile_id"

      check_constraint :status, "model_profile_switches_status",
        check: SdrAgent.Audit.SQL.one_of("status", @statuses)

      check_constraint :to_profile_id, "model_profile_switches_real_profiles",
        check:
          SdrAgent.Audit.SQL.one_of("from_profile_id", @real_profiles) <>
            " AND " <> SdrAgent.Audit.SQL.one_of("to_profile_id", @real_profiles)

      check_constraint :server_generation, "model_profile_switches_generation_positive",
        check: "server_generation >= 1"
    end

    custom_indexes do
      index [:tenant_id],
        unique: true,
        name: "model_profile_switches_one_open_index",
        where: "status IN ('pending', 'blocked')"
    end
  end

  actions do
    defaults [:read]

    read :lock_for_transition do
      get? true
      argument :switch_id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:switch_id) and tenant_id == ^actor(:tenant_id))
      prepare {TransitionLock, row: :switch}
    end

    create :request do
      accept [:from_profile_id, :to_profile_id, :server_generation]
      change SdrAgent.Audit.Changes.SetTenant
      change relate_actor(:requested_by)
      change set_attribute(:requested_at, &SdrAgent.Clock.utc_now/0)
      change {ProfileSwitchEvent, event_type: "model.profile.switch_requested"}
    end

    update :complete do
      require_atomic? false
      accept []
      change RequireAppliedSetting
      change set_attribute(:status, :completed)
      change set_attribute(:finished_at, &SdrAgent.Clock.utc_now/0)
      change {ProfileSwitchEvent, event_type: "model.profile.switch_completed"}
    end

    update :fail do
      require_atomic? false
      accept [:failure_reason]
      change set_attribute(:status, :failed)
      change set_attribute(:finished_at, &SdrAgent.Clock.utc_now/0)
      change {ProfileSwitchEvent, event_type: "model.profile.switch_failed"}
    end

    update :block do
      require_atomic? false
      accept [:failure_reason]
      change set_attribute(:status, :blocked)
      change {ProfileSwitchEvent, event_type: "model.profile.switch_blocked"}
    end
  end

  policies do
    policy action(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :auditor]}
      authorize_if {Checks.ActorType, types: [:agent_runtime]}
    end

    # Strict: refused as Forbidden outside its phase, never read as empty.
    policy action(:lock_for_transition) do
      access_type :strict
      authorize_if {ProfileSwitchContext, phase: :transition, target: :switch_id}
    end

    policy action(:request) do
      authorize_if {ProfileSwitchContext, phase: :initialize, action: :request, target: :tenant}
    end

    policy action(:complete) do
      authorize_if {ProfileSwitchContext, phase: :apply, action: :complete, target: :subject}
    end

    policy action(:fail) do
      authorize_if {ProfileSwitchContext, phase: :transition, action: :fail, target: :subject}
    end

    policy action(:block) do
      authorize_if {ProfileSwitchContext, phase: :transition, action: :block, target: :subject}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :from_profile_id, :atom do
      allow_nil? false
      public? true
      constraints one_of: @real_profiles
    end

    attribute :to_profile_id, :atom do
      allow_nil? false
      public? true
      constraints one_of: @real_profiles
    end

    attribute :status, :atom do
      allow_nil? false
      writable? false
      default :pending
      public? true
      constraints one_of: @statuses
    end

    attribute :server_generation, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1]

    attribute :requested_at, :utc_datetime_usec,
      allow_nil?: false,
      writable?: false,
      public?: true

    attribute :finished_at, :utc_datetime_usec, writable?: false, public?: true

    attribute :failure_reason, :string,
      public?: true,
      constraints: [min_length: 1, max_length: 500]

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
    belongs_to :requested_by, SdrAgent.Accounts.User, allow_nil?: false, public?: true
  end

  @doc false
  def __sdr_audited__, do: true
end
