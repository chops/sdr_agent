defmodule SdrAgent.Sales.CampaignEnrollment do
  @moduledoc """
  A lead's progress through a campaign's sequence (S2 row
  CampaignEnrollment; created in S5, populated by S7/S8).

  Attributes: `campaign_id`, `lead_id` (unique together),
  `current_step_position` (≥ 0), `next_step_due_at`, `status`,
  `stop_reason`, `enrolled_at`.

  Creation (`:enroll`, AGT): the lead must be qualified and the campaign
  active (both rows locked `FOR SHARE`); the orchestrating S7 action also
  checks suppression and records the enrollment Decision.

  Lifecycle (`transitions/0`): active ↔ paused (ADM, REV); active, paused →
  replied (T) (WHK), stopped (T) with a `stop_reason` (ADM, REV, WHK). The
  S8 delivery path adds `advance_step` (which computes `next_step_due_at` in
  the campaign time zone) and its `→ completed (T)` transition, together
  with the time zone database that computation needs.

  Reads: ADM, REV, AUR, AGT, WHK, AUD. Every write appends an AuditEvent
  (`sales.enrollment.*`).
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

  @statuses [:active, :paused, :replied, :completed, :stopped]
  @stop_reasons [
    :reply,
    :unsubscribe,
    :suppressed,
    :bounced,
    :manual,
    :disqualified,
    :campaign_archived
  ]
  @transitions [
    {:pause, [:active], :paused},
    {:resume, [:paused], :active},
    {:mark_replied, [:active, :paused], :replied},
    {:stop, [:active, :paused], :stopped}
  ]
  @event [category: :domain_change, previous: [:status]]

  postgres do
    table "campaign_enrollments"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :campaign, on_delete: :restrict
      reference :lead, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "campaign_enrollments_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :status, "campaign_enrollments_status",
        check: SdrAgent.Audit.SQL.one_of("status", @statuses)

      check_constraint :stop_reason, "campaign_enrollments_stop_reason_when_stopped",
        check: "status <> 'stopped' OR stop_reason IS NOT NULL"
    end
  end

  actions do
    defaults [:read]

    create :enroll do
      description "AGT: enroll a qualified lead in an active campaign."
      accept [:campaign_id, :lead_id]

      change {Changes.RelatedInState,
              resource: SdrAgent.Sales.Lead,
              id: :lead_id,
              in: [:qualified],
              lock: "FOR SHARE",
              message: "the lead must be qualified"}

      change {Changes.RelatedInState,
              resource: SdrAgent.Sales.Campaign,
              id: :campaign_id,
              in: [:active],
              lock: "FOR SHARE",
              message: "the campaign must be active"}

      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change {AppendEvent, event_type: "sales.enrollment.created", category: :domain_change}
    end

    update :pause do
      description "ADM, REV: active → paused."
      require_atomic? false
      change get_and_lock_for_update()
      change {Transition, from: [:active], to: :paused, locked?: true}
      change {AppendEvent, [event_type: "sales.enrollment.paused"] ++ @event}
    end

    update :resume do
      description "ADM, REV: paused → active."
      require_atomic? false
      change get_and_lock_for_update()
      change {Transition, from: [:paused], to: :active, locked?: true}
      change {AppendEvent, [event_type: "sales.enrollment.resumed"] ++ @event}
    end

    update :mark_replied do
      description "WHK: active or paused → replied (T)."
      require_atomic? false
      change get_and_lock_for_update()
      change {Transition, from: [:active, :paused], to: :replied, locked?: true}
      change {AppendEvent, [event_type: "sales.enrollment.replied"] ++ @event}
    end

    update :stop do
      description "ADM, REV, WHK: active or paused → stopped (T), with a stop reason."
      require_atomic? false
      accept [:stop_reason]
      require_attributes [:stop_reason]
      change get_and_lock_for_update()
      change {Transition, from: [:active, :paused], to: :stopped, locked?: true}
      change {AppendEvent, [event_type: "sales.enrollment.stopped"] ++ @event}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action(:enroll) do
      authorize_if {Checks.ActorType, types: [:agent_runtime]}
    end

    policy action([:pause, :resume]) do
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer]}
    end

    policy action(:stop) do
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer]}
      authorize_if {Checks.ActorType, types: [:webhook_ingestor]}
    end

    policy action(:mark_replied) do
      authorize_if {Checks.ActorType, types: [:webhook_ingestor]}
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer, :auditor]}
      authorize_if {Checks.ActorType, types: [:agent_runtime, :webhook_ingestor, :auditor_cli]}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :current_step_position, :integer do
      allow_nil? false
      default 0
      writable? false
      constraints min: 0
      public? true
    end

    attribute :next_step_due_at, :utc_datetime_usec, writable?: false, public?: true

    attribute :status, :atom do
      allow_nil? false
      default :active
      writable? false
      constraints one_of: @statuses
      public? true
    end

    attribute :stop_reason, :atom, public?: true, constraints: [one_of: @stop_reasons]

    attribute :enrolled_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      default &SdrAgent.Clock.utc_now/0
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

    belongs_to :campaign, SdrAgent.Sales.Campaign do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :lead, SdrAgent.Sales.Lead do
      allow_nil? false
      attribute_writable? true
      public? true
    end
  end

  identities do
    identity :unique_campaign_lead, [:campaign_id, :lead_id]
  end

  @doc "Declared lifecycle transitions `{action, from, to}` (ADR-0010)."
  def transitions, do: @transitions

  @doc false
  def __sdr_audited__, do: true
end
