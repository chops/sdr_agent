defmodule SdrAgent.Outreach.Draft do
  @moduledoc """
  A proposed message for one sequence step to one recipient — the container
  of immutable revisions (S2 row Draft).

  Attributes: `lead_id`, `enrollment_id`, `sequence_step_id`, `campaign_id`,
  `recipient_contact_id`, `origin_agent_run_id`, `current_revision_id`
  (written with the revision in the same transaction; the FK is deferred to
  commit, so a draft cannot exist without its current revision), `status`,
  `status_reason`. At most one draft per enrollment step is open (partial
  unique index over the states other than rejected, cancelled, failed).

  Actions:

    * `:propose` (AGT) — creates the draft and its agent revision 1 with
      citations (`SdrAgent.Outreach.Changes.NewRevision`), after checking
      lead, enrollment, step, campaign and recipient agree
      (`SdrAgent.Outreach.Changes.DraftConsistency`); made by the agent's
      hand-off (`SdrAgent.SDR.Actions.HandOffProposal`);
    * `:edit` (ADM, REV; guarded) — a human revision, only while
      `pending_review`;
    * lifecycle (`transitions/0`), each only from inside another Outreach
      action (`SdrAgent.Outreach.Checks.InternalWrite`): pending_review →
      queued (approval granted) → pending_review (approval revoked);
      pending_review → rejected (T) (approval rejected); pending_review,
      queued → cancelled (T) (suppression, refused or cancelled delivery;
      S9 replies); queued → sent (T) | failed (T) (delivery accepted /
      failed permanently).

  Terminal rows are immutable and only `status`, `status_reason`,
  `current_revision_id` and `updated_at` may ever change (trigger). Reads:
  ADM, REV, AUR, AGT, DLV, WHK, AUD. Every write appends an AuditEvent
  (`outreach.draft.*`).
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Outreach,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Changes.AppendEvent
  alias SdrAgent.Audit.Changes.Transition
  alias SdrAgent.Audit.Checks
  alias SdrAgent.Outreach.Changes
  alias SdrAgent.Outreach.Checks.InternalWrite

  @statuses [:pending_review, :queued, :sent, :failed, :rejected, :cancelled]
  @terminal [:sent, :failed, :rejected, :cancelled]
  @transitions [
    {:queue, [:pending_review], :queued},
    {:unqueue, [:queued], :pending_review},
    {:reject, [:pending_review], :rejected},
    {:cancel, [:pending_review, :queued], :cancelled},
    {:mark_sent, [:queued], :sent},
    {:mark_failed, [:queued], :failed}
  ]
  @event [category: :domain_change, previous: [:status]]

  postgres do
    table "drafts"
    repo SdrAgent.Repo

    identity_wheres_to_sql one_open_per_step: "status NOT IN ('rejected', 'cancelled', 'failed')"

    references do
      reference :tenant, on_delete: :restrict
      reference :lead, on_delete: :restrict
      reference :enrollment, on_delete: :restrict
      reference :sequence_step, on_delete: :restrict
      reference :campaign, on_delete: :restrict
      reference :recipient_contact, on_delete: :restrict
      reference :origin_agent_run, on_delete: :restrict
      reference :current_revision, on_delete: :restrict, deferrable: :initially
    end

    check_constraints do
      check_constraint :trace_id, "drafts_trace_ids", check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :status, "drafts_status",
        check: SdrAgent.Audit.SQL.one_of("status", @statuses)
    end

    custom_statements do
      for {name, up_sql, down_sql} <-
            SdrAgent.Audit.SQL.terminal_immutable("drafts", @terminal, [
              :status,
              :status_reason,
              :current_revision_id,
              :updated_at
            ]) do
        statement name do
          up up_sql
          down down_sql
        end
      end
    end
  end

  actions do
    defaults [:read]

    read :review_queue do
      description "Drafts awaiting human review, oldest first."
      filter expr(status == :pending_review)
      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    create :propose do
      description "AGT: the hand-off draft with its first (agent) revision and citations."

      accept [
        :lead_id,
        :enrollment_id,
        :sequence_step_id,
        :campaign_id,
        :recipient_contact_id,
        :origin_agent_run_id
      ]

      argument :subject, :string, allow_nil?: false, constraints: [trim?: false]
      argument :body_text, :string, allow_nil?: false, constraints: [trim?: false]
      argument :angle, :string
      argument :cta, :string
      argument :risk_flags, {:array, :string}, default: []
      argument :decision_id, :uuid, allow_nil?: false
      argument :model_invocation_id, :uuid
      argument :citations, {:array, :map}, default: []

      change SdrAgent.Audit.Changes.SetTenant
      change Changes.DraftConsistency
      change SdrAgent.Audit.Changes.TraceIds

      change {AppendEvent,
              event_type: "outreach.draft.proposed",
              category: :domain_change,
              links: [agent_run_id: :origin_agent_run_id]}

      change {Changes.NewRevision, author: :agent}
    end

    update :edit do
      description "ADM, REV: a human revision of a draft pending review."
      require_atomic? false
      argument :subject, :string, allow_nil?: false, constraints: [trim?: false]
      argument :body_text, :string, allow_nil?: false, constraints: [trim?: false]
      argument :angle, :string
      argument :cta, :string
      change get_and_lock_for_update()
      change {SdrAgent.Sales.Changes.RequireState, in: [:pending_review]}
      change {Changes.NewRevision, author: :human}

      change {AppendEvent,
              event_type: "outreach.draft.edited",
              category: :domain_change,
              previous: [:current_revision_id]}
    end

    update :queue do
      description "Inside an Approval grant only: pending_review → queued."
      require_atomic? false
      change get_and_lock_for_update()
      change {Transition, from: [:pending_review], to: :queued, locked?: true}
      change {AppendEvent, [event_type: "outreach.draft.queued"] ++ @event}
    end

    update :unqueue do
      description "Inside an Approval revoke only: queued → pending_review."
      require_atomic? false
      change get_and_lock_for_update()
      change {Transition, from: [:queued], to: :pending_review, locked?: true}
      change {AppendEvent, [event_type: "outreach.draft.unqueued"] ++ @event}
    end

    update :reject do
      description "Inside an Approval rejection only: pending_review → rejected (T)."
      require_atomic? false
      accept [:status_reason]
      change get_and_lock_for_update()
      change {Transition, from: [:pending_review], to: :rejected, locked?: true}
      change {AppendEvent, [event_type: "outreach.draft.rejected"] ++ @event}
    end

    update :cancel do
      description "Inside a suppression (S9: reply) only: pending_review, queued → cancelled (T)."
      require_atomic? false
      accept [:status_reason]
      change get_and_lock_for_update()
      change {Transition, from: [:pending_review, :queued], to: :cancelled, locked?: true}
      change {AppendEvent, [event_type: "outreach.draft.cancelled"] ++ @event}
    end

    update :mark_sent do
      description "Inside a delivery's acceptance only: queued → sent (T)."
      require_atomic? false
      change get_and_lock_for_update()
      change {Transition, from: [:queued], to: :sent, locked?: true}
      change {AppendEvent, [event_type: "outreach.draft.sent"] ++ @event}
    end

    update :mark_failed do
      description "Inside a delivery's permanent failure only: queued → failed (T)."
      require_atomic? false
      change get_and_lock_for_update()
      change {Transition, from: [:queued], to: :failed, locked?: true}
      change {AppendEvent, [event_type: "outreach.draft.failed"] ++ @event}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action(:propose) do
      authorize_if {Checks.ActorType, types: [:agent_runtime]}
    end

    policy action(:edit) do
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer]}
    end

    policy action([:queue, :unqueue, :reject, :cancel, :mark_sent, :mark_failed]) do
      authorize_if InternalWrite
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer, :auditor]}

      authorize_if {Checks.ActorType,
                    types: [:agent_runtime, :delivery_worker, :webhook_ingestor, :auditor_cli]}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :status, :atom do
      allow_nil? false
      default :pending_review
      writable? false
      constraints one_of: @statuses
      public? true
    end

    attribute :status_reason, :string, public?: true
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

    belongs_to :lead, SdrAgent.Sales.Lead do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :enrollment, SdrAgent.Sales.CampaignEnrollment do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :sequence_step, SdrAgent.Sales.SequenceStep do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :campaign, SdrAgent.Sales.Campaign do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :recipient_contact, SdrAgent.Sales.Contact do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :origin_agent_run, SdrAgent.Agents.AgentRun do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :current_revision, SdrAgent.Outreach.DraftRevision do
      attribute_writable? false
      public? true
    end

    has_many :revisions, SdrAgent.Outreach.DraftRevision, public?: true
    has_many :approvals, SdrAgent.Outreach.Approval, public?: true
  end

  identities do
    identity :one_open_per_step, [:enrollment_id, :sequence_step_id],
      where: expr(status not in [:rejected, :cancelled, :failed])
  end

  @doc "Declared lifecycle transitions `{action, from, to}` (ADR-0010)."
  def transitions, do: @transitions

  @doc false
  def __sdr_audited__, do: true
end
