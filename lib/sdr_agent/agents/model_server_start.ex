defmodule SdrAgent.Agents.ModelServerStart do
  @moduledoc """
  One model server start attempt, the authority on server generations
  (C2-02b2α, `docs/product/r0/c2-02b2-interface.md` sections 1 and 1a). An
  allocation is intent only.

  Attributes: `generation` (≥ 1, unique per tenant), `boot_id` (the
  allocating coordinator's boot), `profile_id` (a reviewed real profile),
  `reason` (`:boot | :replacement | :activation | :rollback`), `switch_id`
  (required for activation and rollback, null otherwise), `status`
  (`:allocated | :started | :ready | :failed`), the observed identity `pid`,
  `node` and `reaper_pid` (diagnostic strings, required from `:started`
  on) and `ready_evidence` (`:spawn_preflight | :adopted`, required iff
  `:ready`; `:adopted` only on a `:replacement`). Identity and provenance
  never change; the status is forward-only: `allocated → started → ready`,
  `allocated | started → failed`. Never destroyed.

  Writes (`:allocate`, `:mark_started`, `:mark_ready`, `:mark_failed`) run
  only in the registered coordinator process as `model_runtime`
  (`SdrAgent.Agents.Checks.CoordinatorProcess`), through
  `SdrAgent.Agents.ServerStarts`, which takes the locks of section 1b and
  checks the boot fence and the per-action prerequisites. Each appends its
  `model.server.start_*` event (`SdrAgent.Agents.Changes.ServerStartEvent`);
  pids stay out of events. Reads: admin, auditor (audited by the domain
  read), `agent_runtime`, kernel, and the coordinator.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Agents.Changes.ServerStartEvent
  alias SdrAgent.Agents.Checks.CoordinatorProcess
  alias SdrAgent.Audit.Checks

  @real_profiles SdrAgent.AI.ModelProfiles.real_ids()
  @reasons [:boot, :replacement, :activation, :rollback]
  @statuses [:allocated, :started, :ready, :failed]
  @evidence [:spawn_preflight, :adopted]

  postgres do
    table "model_server_starts"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :switch, on_delete: :restrict
    end

    check_constraints do
      check_constraint :generation, "model_server_starts_generation_positive",
        check: "generation >= 1"

      check_constraint :profile_id, "model_server_starts_real_profile",
        check: SdrAgent.Audit.SQL.one_of("profile_id", @real_profiles)

      check_constraint :reason, "model_server_starts_reason",
        check: SdrAgent.Audit.SQL.one_of("reason", @reasons)

      check_constraint :status, "model_server_starts_status",
        check: SdrAgent.Audit.SQL.one_of("status", @statuses)

      check_constraint :switch_id, "model_server_starts_switch_iff_switch_reason",
        check: "(reason IN ('activation', 'rollback')) = (switch_id IS NOT NULL)"

      check_constraint :pid, "model_server_starts_identity_once_started",
        check:
          "status = 'allocated' OR status = 'failed' OR " <>
            "(pid IS NOT NULL AND node IS NOT NULL AND reaper_pid IS NOT NULL)"

      check_constraint :ready_evidence, "model_server_starts_evidence_iff_ready",
        check:
          "(status = 'ready') = (ready_evidence IS NOT NULL) AND " <>
            "(ready_evidence IS NULL OR " <>
            SdrAgent.Audit.SQL.one_of("ready_evidence", @evidence) <>
            ") AND (ready_evidence IS DISTINCT FROM 'adopted' OR reason = 'replacement')"
    end
  end

  actions do
    defaults [:read]

    # The caller adds the lock (`FOR UPDATE`) and runs it in its transaction.
    read :latest do
      get? true
      argument :generation, :integer, allow_nil?: false
      filter expr(tenant_id == ^actor(:tenant_id) and generation == ^arg(:generation))
    end

    create :allocate do
      accept [:boot_id, :profile_id, :reason, :switch_id]
      argument :generation, :integer, allow_nil?: false, constraints: [min: 1]
      change SdrAgent.Audit.Changes.SetTenant
      change set_attribute(:generation, arg(:generation))
      change {ServerStartEvent, event_type: "model.server.start_allocated"}
    end

    update :mark_started do
      require_atomic? false
      accept []
      argument :pid, :string, allow_nil?: false
      argument :node, :string, allow_nil?: false
      argument :reaper_pid, :string, allow_nil?: false
      change set_attribute(:status, :started)
      change set_attribute(:pid, arg(:pid))
      change set_attribute(:node, arg(:node))
      change set_attribute(:reaper_pid, arg(:reaper_pid))
      change {ServerStartEvent, event_type: "model.server.start_started"}
    end

    update :mark_ready do
      require_atomic? false
      accept []
      argument :ready_evidence, :atom, allow_nil?: false, constraints: [one_of: @evidence]
      change set_attribute(:status, :ready)
      change set_attribute(:ready_evidence, arg(:ready_evidence))
      change {ServerStartEvent, event_type: "model.server.start_ready"}
    end

    update :mark_failed do
      require_atomic? false
      accept []
      change set_attribute(:status, :failed)
      change {ServerStartEvent, event_type: "model.server.start_failed"}
    end
  end

  policies do
    policy action(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :auditor]}
      authorize_if {Checks.ActorType, types: [:agent_runtime]}
      authorize_if CoordinatorProcess
    end

    policy action([:latest, :allocate, :mark_started, :mark_ready, :mark_failed]) do
      authorize_if CoordinatorProcess
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :generation, :integer,
      allow_nil?: false,
      writable?: false,
      public?: true,
      constraints: [min: 1]

    attribute :boot_id, :uuid, allow_nil?: false, public?: true

    attribute :profile_id, :atom do
      allow_nil? false
      public? true
      constraints one_of: @real_profiles
    end

    attribute :reason, :atom do
      allow_nil? false
      public? true
      constraints one_of: @reasons
    end

    attribute :status, :atom do
      allow_nil? false
      writable? false
      default :allocated
      public? true
      constraints one_of: @statuses
    end

    attribute :pid, :string, writable?: false, public?: true
    attribute :node, :string, writable?: false, public?: true
    attribute :reaper_pid, :string, writable?: false, public?: true

    attribute :ready_evidence, :atom do
      writable? false
      public? true
      constraints one_of: @evidence
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
    belongs_to :switch, SdrAgent.Agents.ModelProfileSwitch, public?: true
  end

  identities do
    identity :generation, [:tenant_id, :generation]
  end

  @doc false
  def __sdr_audited__, do: true
end
