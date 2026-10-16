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
  transaction), pending → failed, pending → blocked, and (C2-02b2β,
  `docs/product/r0/c2-02b2b-interface.md`) blocked → failed by
  `resolve_blocked` only, the attended resolution: an active human admin's
  typed attestation, executed by the registered coordinator.

  The resolution's attributes (C2-02b2β; all null, or all set): `resolution`
  (`:owner_attested`), `resolved_by_id` (the resolving admin), `resolved_at`
  (equal to `finished_at`: one clock value read once in the action),
  `attestation_id` (client-generated, unique per tenant),
  `attested_start_id` (the latest start the admin attested; a composite FK
  on `(attested_start_id, tenant_id)`), `attested_generation` (≥ the
  switch's `server_generation`: the covered range is `[server_generation,
  attested_generation]`) and `attested_lease_kind` (`:none | :survivor |
  :dead_holder`, as observed by the coordinator). A check constraint keeps
  them all null or all set, and set only on a failed switch. The block's
  `failure_reason` and the request's provenance are kept.

  Writes run only inside their `SdrAgent.Agents.Checks.ProfileSwitchContext`
  phase, opened by `SdrAgent.Agents.ProfileSwitches`: `:request` (phase
  `:initialize`, a current human admin), `:fail` and `:block` (phase
  `:transition`, `model_runtime`), `:complete` (phase `:apply`,
  `model_runtime`, after the setting was applied), and `:resolve_blocked`
  (phase `:resolve`, an active human admin, only in the registered
  coordinator process: `SdrAgent.Agents.Checks.ResolveContext`). The runtime
  writes are
  guarded on the re-locked stored rows (`SdrAgent.Agents.Changes.ProfileSwitchGuard`):
  only a pending switch of the phase's generation moves, so a finished one
  is never relabelled. Each appends its
  `model.profile.switch_*` event (`SdrAgent.Agents.Changes.ProfileSwitchEvent`).

  Reads: admin, auditor (audited by the domain read), `agent_runtime`,
  kernel. `model_runtime` reads and locks one switch only through
  `:lock_for_transition`, in phase `:transition` (or, in the coordinator,
  the read-only `:settle`), after the setting; the resolving admin locks it
  the same way in phase `:resolve` or `:settle`.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Agents.Changes.ProfileSwitchEvent
  alias SdrAgent.Agents.Changes.ProfileSwitchGuard
  alias SdrAgent.Agents.Checks.ProfileSwitchContext
  alias SdrAgent.Agents.Checks.ResolveContext
  alias SdrAgent.Agents.Preparations.TransitionLock
  alias SdrAgent.Audit.Checks

  @real_profiles SdrAgent.AI.ModelProfiles.real_ids()
  @statuses [:pending, :completed, :failed, :blocked]
  @lease_kinds [:none, :survivor, :dead_holder]
  @resolution_columns ~w(resolution resolved_by_id resolved_at attestation_id
                         attested_start_id attested_generation attested_lease_kind)

  postgres do
    table "model_profile_switches"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :requested_by, on_delete: :restrict
      reference :resolved_by, on_delete: :restrict
      reference :attested_start, on_delete: :restrict
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

      # C2-02b2β: the seven resolution columns are all null, or all set on
      # a failed switch, from one clock value, over a covered range that
      # starts at the switch's own generation.
      check_constraint :resolution, "model_profile_switches_resolution",
        check:
          "(" <>
            Enum.map_join(@resolution_columns, " AND ", &"#{&1} IS NULL") <>
            ") OR (" <>
            Enum.map_join(@resolution_columns, " AND ", &"#{&1} IS NOT NULL") <>
            " AND resolution = 'owner_attested' AND " <>
            SdrAgent.Audit.SQL.one_of("attested_lease_kind", @lease_kinds) <>
            " AND status = 'failed' AND resolved_at = finished_at" <>
            " AND attested_generation >= server_generation)"
    end

    custom_indexes do
      index [:tenant_id],
        unique: true,
        name: "model_profile_switches_one_open_index",
        where: "status IN ('pending', 'blocked')"

      # C2-02b2β: replay is by attestation id, unique per tenant.
      index [:tenant_id, :attestation_id],
        unique: true,
        name: "model_profile_switches_attestation_index",
        where: "attestation_id IS NOT NULL",
        error_fields: [:attestation_id],
        message: "is already used by another resolution"
    end

    custom_statements do
      # C2-02b2β: the attested start is a start of the switch's own tenant
      # (target: the starts' composite unique key).
      statement :model_profile_switches_attested_start_tenant_fkey do
        up "ALTER TABLE model_profile_switches ADD CONSTRAINT " <>
             "model_profile_switches_attested_start_tenant_fkey " <>
             "FOREIGN KEY (attested_start_id, tenant_id) " <>
             "REFERENCES model_server_starts (id, tenant_id) ON DELETE RESTRICT"

        down "ALTER TABLE model_profile_switches DROP CONSTRAINT " <>
               "model_profile_switches_attested_start_tenant_fkey"

        after_tables ["model_server_starts"]
      end
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
      change {ProfileSwitchGuard, write: :complete}
      change set_attribute(:status, :completed)
      change set_attribute(:finished_at, &SdrAgent.Clock.utc_now/0)
      change {ProfileSwitchEvent, event_type: "model.profile.switch_completed"}
    end

    update :fail do
      require_atomic? false
      accept [:failure_reason]
      change {ProfileSwitchGuard, write: :fail}
      change set_attribute(:status, :failed)
      change set_attribute(:finished_at, &SdrAgent.Clock.utc_now/0)
      change {ProfileSwitchEvent, event_type: "model.profile.switch_failed"}
    end

    update :block do
      require_atomic? false
      accept [:failure_reason]
      change {ProfileSwitchGuard, write: :block}
      change set_attribute(:status, :blocked)
      change {ProfileSwitchEvent, event_type: "model.profile.switch_blocked"}
    end

    # C2-02b2β: blocked → failed, the attended resolution. The guard checks
    # the arguments against the phase's validated attestation and the
    # re-locked stored rows, then sets the status and the seven resolution
    # fields (one clock value for `finished_at` and `resolved_at`); the
    # block's `failure_reason` is kept.
    update :resolve_blocked do
      require_atomic? false
      accept []
      argument :attestation_id, :uuid, allow_nil?: false
      argument :attested_start_id, :uuid, allow_nil?: false
      argument :attested_generation, :integer, allow_nil?: false, constraints: [min: 1]

      argument :attested_lease_kind, :atom,
        allow_nil?: false,
        constraints: [one_of: @lease_kinds]

      change {ProfileSwitchGuard, write: :resolve}
      change {ProfileSwitchEvent, event_type: "model.profile.switch_resolved"}
    end
  end

  policies do
    policy action(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :auditor]}
      authorize_if {Checks.ActorType, types: [:agent_runtime]}
    end

    # Strict: refused as Forbidden outside its phase, never read as empty.
    # `:resolve` and the read-only `:settle` take the same lock (C2-02b2β).
    policy action(:lock_for_transition) do
      access_type :strict

      authorize_if {ProfileSwitchContext,
                    phase: [:transition, :resolve, :settle], target: :switch_id}
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

    # C2-02b2β: only in the registered coordinator, as a currently active
    # human admin, inside the coordinator's own `:resolve` phase.
    policy action(:resolve_blocked) do
      forbid_unless ResolveContext

      authorize_if {ProfileSwitchContext,
                    phase: :resolve, action: :resolve_blocked, target: :subject}
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

    # C2-02b2β: the attended resolution (see the moduledoc).
    attribute :resolution, :atom do
      writable? false
      public? true
      constraints one_of: [:owner_attested]
    end

    attribute :resolved_at, :utc_datetime_usec, writable?: false, public?: true
    attribute :attestation_id, :uuid, writable?: false, public?: true

    attribute :attested_generation, :integer,
      writable?: false,
      public?: true,
      constraints: [min: 1]

    attribute :attested_lease_kind, :atom do
      writable? false
      public? true
      constraints one_of: @lease_kinds
    end

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
    # C2-02b2β: set exactly with `resolution`.
    belongs_to :resolved_by, SdrAgent.Accounts.User, public?: true, attribute_writable?: false

    belongs_to :attested_start, SdrAgent.Agents.ModelServerStart,
      public?: true,
      attribute_writable?: false
  end

  @doc false
  def __sdr_audited__, do: true
end
