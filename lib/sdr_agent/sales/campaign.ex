defmodule SdrAgent.Sales.Campaign do
  @moduledoc """
  An outreach program: ICP + sequence + sender identity + compliance
  defaults (S2 row Campaign; checklist 1.6).

  Attributes: `name`, `status`, `icp_definition_id`, `sequence_id` (nullable
  until activation), `sender_name` (default "Demo SDR"), `sender_email`
  (default "sdr@example.test", reserved domain only), `timezone` (default
  "America/Denver"), `quiet_hours_start`/`quiet_hours_end` (default
  18:00–08:00), `autonomy_tier` (always 0 — Tier 0, not an input),
  `footer_template_version`. The daily send cap is tenant-wide (S8
  SendQuotaDay), not a campaign attribute.

  Lifecycle (`transitions/0`): draft → active (needs an active ICP and an
  active sequence) ↔ paused; active, paused → completed (T); draft, active,
  paused → archived (T). Edits (`:update`) only while draft. Paused,
  completed and archived campaigns block every send at the S8 send gate.

  Actors: ADM create, update, activate, complete, archive; ADM, REV pause and
  resume (pausing is safety-increasing); SEED (dev/test only) `:seed` and
  `:activate`; ADM, REV, AUR, AGT, AUD read. Every write appends an
  AuditEvent (`sales.campaign.*`).
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

  @statuses [:draft, :active, :paused, :completed, :archived]
  @transitions [
    {:activate, [:draft], :active},
    {:pause, [:active], :paused},
    {:resume, [:paused], :active},
    {:complete, [:active, :paused], :completed},
    {:archive, [:draft, :active, :paused], :archived}
  ]
  @editable [
    :name,
    :icp_definition_id,
    :sequence_id,
    :sender_name,
    :sender_email,
    :timezone,
    :quiet_hours_start,
    :quiet_hours_end,
    :footer_template_version
  ]

  postgres do
    table "campaigns"
    repo SdrAgent.Repo
    migration_defaults sender_email: ~S["sdr@example.test"]

    references do
      reference :tenant, on_delete: :restrict
      reference :icp_definition, on_delete: :restrict
      reference :sequence, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "campaigns_trace_ids", check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :status, "campaigns_status",
        check: SdrAgent.Audit.SQL.one_of("status", @statuses)

      check_constraint :autonomy_tier, "campaigns_tier_zero",
        check: "autonomy_tier = 0",
        message: "only autonomy tier 0 exists in the MVP"

      check_constraint :sequence_id, "campaigns_sequence_when_live",
        check: "status IN ('draft', 'archived') OR sequence_id IS NOT NULL"
    end
  end

  actions do
    defaults [:read]

    create :create do
      description "ADM: create a draft campaign with the compliance defaults."
      accept @editable
      validate {Validations.Reserved, attribute: :sender_email, kind: :email}
      validate {Validations.Timezone, attribute: :timezone}
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change {AppendEvent, event_type: "sales.campaign.created", category: :domain_change}
    end

    create :seed do
      description "SEED (dev/test only): create a draft campaign with a fixture id."
      accept [:id | @editable]
      validate {Validations.Reserved, attribute: :sender_email, kind: :email}
      validate {Validations.Timezone, attribute: :timezone}
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change {AppendEvent, event_type: "sales.campaign.created", category: :domain_change}
    end

    update :update do
      description "ADM: edit a draft campaign."
      require_atomic? false
      accept @editable
      change get_and_lock_for_update()
      change {Changes.RequireState, in: [:draft]}
      validate {Validations.Reserved, attribute: :sender_email, kind: :email}
      validate {Validations.Timezone, attribute: :timezone}
      change {AppendEvent, event_type: "sales.campaign.updated", category: :domain_change}
    end

    update :activate do
      description "ADM, SEED: draft → active; the ICP and the sequence must be active."
      require_atomic? false
      change get_and_lock_for_update()
      change {Transition, from: [:draft], to: :active, locked?: true}

      change {Changes.RelatedInState,
              resource: SdrAgent.Sales.IcpDefinition,
              id: :icp_definition_id,
              in: [:active],
              lock: "FOR SHARE",
              message: "the ICP must be active"}

      change {Changes.RelatedInState,
              resource: SdrAgent.Sales.Sequence,
              id: :sequence_id,
              in: [:active],
              lock: "FOR SHARE",
              message: "the sequence must be active"}

      change {AppendEvent,
              event_type: "sales.campaign.activated",
              category: :domain_change,
              previous: [:status]}
    end

    update :pause do
      description "ADM, REV: active → paused (blocks sends)."
      require_atomic? false
      change get_and_lock_for_update()
      change {Transition, from: [:active], to: :paused, locked?: true}

      change {AppendEvent,
              event_type: "sales.campaign.paused", category: :domain_change, previous: [:status]}
    end

    update :resume do
      description "ADM, REV: paused → active."
      require_atomic? false
      change get_and_lock_for_update()
      change {Transition, from: [:paused], to: :active, locked?: true}

      change {AppendEvent,
              event_type: "sales.campaign.resumed", category: :domain_change, previous: [:status]}
    end

    update :complete do
      description "ADM: active or paused → completed (terminal)."
      require_atomic? false
      change get_and_lock_for_update()
      change {Transition, from: [:active, :paused], to: :completed, locked?: true}

      change {AppendEvent,
              event_type: "sales.campaign.completed",
              category: :domain_change,
              previous: [:status]}
    end

    update :archive do
      description "ADM: draft, active or paused → archived (terminal)."
      require_atomic? false
      change get_and_lock_for_update()
      change {Transition, from: [:draft, :active, :paused], to: :archived, locked?: true}

      change {AppendEvent,
              event_type: "sales.campaign.archived", category: :domain_change, previous: [:status]}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action([:create, :update, :complete, :archive]) do
      authorize_if {Checks.ActorRole, roles: [:admin]}
    end

    policy action(:activate) do
      authorize_if {Checks.ActorRole, roles: [:admin]}
      authorize_if Checks.SeedingAllowed
    end

    policy action([:pause, :resume]) do
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer]}
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
    attribute :name, :string, allow_nil?: false, public?: true

    attribute :status, :atom do
      allow_nil? false
      default :draft
      writable? false
      constraints one_of: @statuses
      public? true
    end

    attribute :sender_name, :string, allow_nil?: false, default: "Demo SDR", public?: true

    attribute :sender_email, :ci_string,
      allow_nil?: false,
      default: "sdr@example.test",
      public?: true

    attribute :timezone, :string, allow_nil?: false, default: "America/Denver", public?: true
    attribute :quiet_hours_start, :time, allow_nil?: false, default: ~T[18:00:00], public?: true
    attribute :quiet_hours_end, :time, allow_nil?: false, default: ~T[08:00:00], public?: true

    attribute :autonomy_tier, :integer do
      allow_nil? false
      default 0
      writable? false
      constraints min: 0, max: 0
      public? true
    end

    attribute :footer_template_version, :string, allow_nil?: false, public?: true
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

    belongs_to :icp_definition, SdrAgent.Sales.IcpDefinition do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :sequence, SdrAgent.Sales.Sequence do
      attribute_writable? true
      public? true
    end

    has_many :enrollments, SdrAgent.Sales.CampaignEnrollment, public?: true
  end

  @doc "Declared lifecycle transitions `{action, from, to}` (ADR-0010)."
  def transitions, do: @transitions

  @doc false
  def __sdr_audited__, do: true
end
