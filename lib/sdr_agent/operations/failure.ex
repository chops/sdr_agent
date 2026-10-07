defmodule SdrAgent.Operations.Failure do
  @moduledoc """
  A recorded error with class, severity, retryability and resolution —
  nothing fails silently (S2 row Failure). Open and acknowledged Failures are
  the operator-attention queue (`SdrAgent.Operations.list_attention/1`); the
  runtime sends no external notification (owner decision 2026-10-06).

  Attributes: `operation_id` (optional), `subject_resource` / `subject_id`
  (the record whose state change opened it — a plain ref, Operations sits
  below the domains that open Failures), `class`, `severity`, `message`
  (passed through `SdrAgent.Operations.Redactor` before insert),
  `detail_sha256` (optional redacted detail in the Payload store),
  `retryable`, `status`, `acknowledged_at`, `resolved_at`,
  `resolved_by_type` (`:user` or the system actor type), `resolved_by_id`
  (User, only when resolved by a user), `resolution_note`, `occurred_at`.

  Lifecycle (`transitions/0`): open → acknowledged → resolved (T);
  open → resolved (T). Resolution requires a note.

  Actions: `:open` (system actors), `:acknowledge` (ADM, REV), `:resolve`
  (ADM, REV, the reconciler, and the system actor that opened it — recorded
  provenance, `SdrAgent.Operations.Checks.FailureResolver` — when the
  causing condition clears),
  `:attention` read. Reads: ADM, REV, AUR, AUD and system actors. Every
  write appends an AuditEvent (`operations.failure.*`).
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Operations,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Changes.Stamp
  alias SdrAgent.Audit.Changes.AppendEvent
  alias SdrAgent.Audit.Changes.Transition
  alias SdrAgent.Audit.Checks

  @classes [
    :provider_error,
    :validation_error,
    :budget_exhausted,
    :run_stopped,
    :reconciliation_required,
    :delivery_failed,
    :timeout,
    :policy_denied,
    :signature_invalid,
    :crash
  ]
  @statuses [:open, :acknowledged, :resolved]
  @system [
    :agent_runtime,
    :delivery_worker,
    :reconciler,
    :webhook_ingestor,
    :scheduler,
    :anchorer,
    :kernel
  ]
  @transitions [
    {:acknowledge, [:open], :acknowledged},
    {:resolve, [:open, :acknowledged], :resolved}
  ]
  @event [category: :domain_change, previous: [:status]]

  postgres do
    table "failures"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :operation, on_delete: :restrict
      reference :resolved_by, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "failures_trace_ids", check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :status, "failures_status",
        check: SdrAgent.Audit.SQL.one_of("status", @statuses)

      check_constraint :resolution_note, "failures_resolution_note_when_resolved",
        check: "status <> 'resolved' OR resolution_note IS NOT NULL"
    end

    custom_statements do
      {name, up_sql, down_sql} = SdrAgent.Audit.SQL.payload_fk("failures", :detail_sha256)

      statement name do
        up up_sql
        down down_sql
        after_tables ["payloads"]
      end
    end
  end

  actions do
    defaults [:read]

    read :attention do
      description "Open and acknowledged failures, newest first (operator attention)."
      filter expr(status in [:open, :acknowledged])
      prepare build(sort: [occurred_at: :desc, id: :desc])
    end

    create :open do
      description "System actors: record a failure (message redacted, detail stored as a Payload)."

      accept [
        :operation_id,
        :subject_resource,
        :subject_id,
        :class,
        :severity,
        :message,
        :retryable
      ]

      argument :detail, :string, constraints: [trim?: false]
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Operations.Changes.RedactFailure
      change SdrAgent.Audit.Changes.TraceIds

      change {AppendEvent, event_type: "operations.failure.opened", category: :domain_change}
    end

    update :acknowledge do
      description "ADM, REV: open → acknowledged."
      require_atomic? false
      change get_and_lock_for_update()
      change {Transition, from: [:open], to: :acknowledged, locked?: true}
      change {Stamp, fields: [:acknowledged_at]}
      change {AppendEvent, [event_type: "operations.failure.acknowledged"] ++ @event}
    end

    update :resolve do
      description "ADM, REV, system actors: open | acknowledged → resolved (T), with a note."
      require_atomic? false
      accept [:resolution_note]
      require_attributes [:resolution_note]
      change get_and_lock_for_update()
      change {Transition, from: [:open, :acknowledged], to: :resolved, locked?: true}
      change {Stamp, fields: [:resolved_at]}
      change SdrAgent.Operations.Changes.ResolvedBy
      change {AppendEvent, [event_type: "operations.failure.resolved"] ++ @event}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action(:open) do
      authorize_if {Checks.ActorType, types: @system}
    end

    policy action(:acknowledge) do
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer]}
    end

    policy action(:resolve) do
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer]}
      authorize_if SdrAgent.Operations.Checks.FailureResolver
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer, :auditor]}
      authorize_if {Checks.ActorType, types: [:auditor_cli | @system]}
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :subject_resource, :string, allow_nil?: false, public?: true
    attribute :subject_id, :uuid, allow_nil?: false, public?: true

    attribute :class, :atom do
      allow_nil? false
      constraints one_of: @classes
      public? true
    end

    attribute :severity, :atom do
      allow_nil? false
      constraints one_of: [:warning, :critical]
      public? true
    end

    attribute :message, :string, allow_nil?: false, public?: true, constraints: [trim?: false]
    attribute :detail_sha256, :binary, writable?: false, public?: true
    attribute :retryable, :boolean, allow_nil?: false, default: true, public?: true

    attribute :status, :atom do
      allow_nil? false
      default :open
      writable? false
      constraints one_of: @statuses
      public? true
    end

    attribute :acknowledged_at, :utc_datetime_usec, writable?: false, public?: true
    attribute :resolved_at, :utc_datetime_usec, writable?: false, public?: true

    attribute :resolved_by_type, :atom do
      writable? false
      constraints one_of: [:user | @system]
      public? true
    end

    attribute :resolution_note, :string, public?: true

    attribute :occurred_at, :utc_datetime_usec do
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

    belongs_to :operation, SdrAgent.Operations.Operation do
      attribute_writable? true
      public? true
    end

    belongs_to :resolved_by, SdrAgent.Accounts.User do
      source_attribute :resolved_by_id
      attribute_writable? false
      public? true
    end
  end

  @doc "Failure classes (S2)."
  def classes, do: @classes

  @doc "Declared lifecycle transitions `{action, from, to}` (ADR-0010)."
  def transitions, do: @transitions

  @doc false
  def __sdr_audited__, do: true
end
