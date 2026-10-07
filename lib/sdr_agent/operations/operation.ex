defmodule SdrAgent.Operations.Operation do
  @moduledoc """
  Operator-visible unit of durable background work — the domain view of one
  Oban job for the Runs/Operations view (S2 row Operation; Oban's own table
  is the queue).

  Attributes: `kind`, `queue`, `oban_job_id`, `subject_resource` /
  `subject_id` (plain ref: Operations sits below the domains whose work it
  runs), `idempotency_key` (unique per tenant), `correlation_id`, `status`,
  `attempts`, `max_attempts`, `scheduled_at`, `started_at`, `finished_at`,
  `last_failure_id` (the Failure of the latest failed attempt).

  Lifecycle (`transitions/0`): enqueued → running → succeeded (T);
  running → failed → running (bounded retry) | discarded (T, at max
  attempts); enqueued, failed → cancelled (T). Entering failed opens a
  Failure in the same transaction — or links the existing Failure of the
  condition that caused it (e.g. the AgentRun's attention Failure), so one
  condition is one queue entry — only a live Failure of this operation's
  condition may be linked; discarded keeps that Failure; succeeding (e.g.
  after a bounded retry) resolves the operation's live Failures in the same
  transaction.

  Kinds listed in `kind_queues/0` run only on their queue (`reconcile_model`
  → `reconciliation`, S12).

  Actors: the system actor that owns the `kind` (`kind_actors/0`) creates and
  transitions it; ADM may retry and cancel; reads for ADM, REV, AUR, AUD and
  system actors. Every write appends an AuditEvent (`operations.operation.*`).
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
  alias SdrAgent.Operations.Changes
  alias SdrAgent.Operations.Checks.OperationKindActor

  @kind_actors %{
    research_lead: [:agent_runtime],
    prepare_outreach: [:agent_runtime],
    deliver: [:delivery_worker],
    reconcile_delivery: [:reconciler],
    reconcile_model: [:reconciler],
    followup_due: [:scheduler],
    process_webhook: [:webhook_ingestor],
    anchor: [:anchorer],
    export: [:anchorer]
  }
  # Kinds whose queue is fixed (S12 R2: model-witness reconciliation runs on
  # the dedicated, concurrency-one reconciliation queue).
  @kind_queues %{reconcile_model: [:reconciliation]}
  @queues [
    :research,
    :qualification,
    :agent,
    :delivery,
    :followup,
    :integration,
    :reconciliation,
    :maintenance
  ]
  @statuses [:enqueued, :running, :succeeded, :failed, :cancelled, :discarded]
  @transitions [
    {:start, [:enqueued], :running},
    {:succeed, [:running], :succeeded},
    {:fail, [:running], :failed},
    {:retry, [:failed], :running},
    {:discard, [:failed], :discarded},
    {:cancel, [:enqueued, :failed], :cancelled}
  ]
  @event [category: :domain_change, previous: [:status], links: [correlation_id: :correlation_id]]

  postgres do
    table "operations"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :last_failure, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "operations_trace_ids", check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :status, "operations_status",
        check: SdrAgent.Audit.SQL.one_of("status", @statuses)

      check_constraint :attempts, "operations_attempts_bounded",
        check: "attempts >= 0 AND attempts <= max_attempts"
    end
  end

  actions do
    defaults [:read]

    create :create do
      description "The kind's system actor: record enqueued background work."

      accept [
        :kind,
        :queue,
        :oban_job_id,
        :subject_resource,
        :subject_id,
        :idempotency_key,
        :correlation_id,
        :max_attempts,
        :scheduled_at
      ]

      validate fn changeset, _context ->
        kind = Ash.Changeset.get_attribute(changeset, :kind)
        queue = Ash.Changeset.get_attribute(changeset, :queue)

        case Map.fetch(@kind_queues, kind) do
          {:ok, queues} ->
            if queue in queues,
              do: :ok,
              else: {:error, field: :queue, message: "#{kind} runs only on #{inspect(queues)}"}

          :error ->
            :ok
        end
      end

      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds

      change {AppendEvent,
              event_type: "operations.operation.created",
              category: :domain_change,
              links: [correlation_id: :correlation_id]}
    end

    update :start do
      description "enqueued → running (first attempt)."
      require_atomic? false
      change get_and_lock_for_update()
      change {Transition, from: [:enqueued], to: :running, locked?: true}
      change Changes.CountAttempt
      change {Stamp, fields: [:started_at]}
      change {AppendEvent, [event_type: "operations.operation.started"] ++ @event}
    end

    update :succeed do
      description "running → succeeded (T)."
      require_atomic? false
      change get_and_lock_for_update()
      change {Transition, from: [:running], to: :succeeded, locked?: true}
      change {Stamp, fields: [:finished_at]}
      change Changes.ResolveOperationFailures
      change {AppendEvent, [event_type: "operations.operation.succeeded"] ++ @event}
    end

    update :fail do
      description "running → failed: opens a Failure or links `failure_id` (same transaction)."
      require_atomic? false
      argument :failure_id, :uuid
      argument :failure, :map
      change get_and_lock_for_update()
      change {Transition, from: [:running], to: :failed, locked?: true}
      change Changes.FailOperation
      change {AppendEvent, [event_type: "operations.operation.failed"] ++ @event}
    end

    update :retry do
      description "failed → running (bounded by max_attempts)."
      require_atomic? false
      change get_and_lock_for_update()
      change {Transition, from: [:failed], to: :running, locked?: true}
      change Changes.CountAttempt
      change {Stamp, fields: [:started_at]}
      change {AppendEvent, [event_type: "operations.operation.retried"] ++ @event}
    end

    update :discard do
      description "failed → discarded (T) at max attempts; keeps its Failure."
      require_atomic? false
      change get_and_lock_for_update()
      change {Transition, from: [:failed], to: :discarded, locked?: true}
      change {Stamp, fields: [:finished_at]}
      change {AppendEvent, [event_type: "operations.operation.discarded"] ++ @event}
    end

    update :cancel do
      description "ADM or the kind's system actor: enqueued | failed → cancelled (T)."
      require_atomic? false
      change get_and_lock_for_update()
      change {Transition, from: [:enqueued, :failed], to: :cancelled, locked?: true}
      change {Stamp, fields: [:finished_at]}
      change {AppendEvent, [event_type: "operations.operation.cancelled"] ++ @event}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action([:create, :start, :succeed, :fail, :discard]) do
      authorize_if OperationKindActor
    end

    policy action([:retry, :cancel]) do
      authorize_if OperationKindActor
      authorize_if {Checks.ActorRole, roles: [:admin]}
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer, :auditor]}

      authorize_if {Checks.ActorType,
                    types: [
                      :agent_runtime,
                      :delivery_worker,
                      :reconciler,
                      :webhook_ingestor,
                      :scheduler,
                      :anchorer,
                      :auditor_cli
                    ]}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :kind, :atom do
      allow_nil? false
      constraints one_of: Map.keys(@kind_actors)
      public? true
    end

    attribute :queue, :atom do
      allow_nil? false
      constraints one_of: @queues
      public? true
    end

    attribute :oban_job_id, :integer, public?: true
    attribute :subject_resource, :string, allow_nil?: false, public?: true
    attribute :subject_id, :uuid, allow_nil?: false, public?: true
    attribute :idempotency_key, :string, allow_nil?: false, public?: true
    attribute :correlation_id, :uuid, allow_nil?: false, public?: true

    attribute :status, :atom do
      allow_nil? false
      default :enqueued
      writable? false
      constraints one_of: @statuses
      public? true
    end

    attribute :attempts, :integer do
      allow_nil? false
      default 0
      writable? false
      constraints min: 0
      public? true
    end

    attribute :max_attempts, :integer do
      allow_nil? false
      default 1
      constraints min: 1, max: 10
      public? true
    end

    attribute :scheduled_at, :utc_datetime_usec, public?: true
    attribute :started_at, :utc_datetime_usec, writable?: false, public?: true
    attribute :finished_at, :utc_datetime_usec, writable?: false, public?: true
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

    belongs_to :last_failure, SdrAgent.Operations.Failure do
      attribute_writable? false
      public? true
    end

    has_many :failures, SdrAgent.Operations.Failure, public?: true
  end

  identities do
    identity :unique_idempotency_key, [:tenant_id, :idempotency_key]
  end

  @doc "System actor types allowed to create and run each operation kind."
  def kind_actors, do: @kind_actors

  @doc "Kinds restricted to specific queues."
  def kind_queues, do: @kind_queues

  @doc "Declared lifecycle transitions `{action, from, to}` (ADR-0010)."
  def transitions, do: @transitions

  @doc false
  def __sdr_audited__, do: true
end
