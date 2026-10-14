defmodule SdrAgent.Agents.AgentRun do
  @moduledoc """
  One Jido agent execution for one assignment, with its budget (S2 row
  AgentRun; spec §4).

  Attributes: `agent_definition_id`, plain `lead_id`/`campaign_id` (Agents
  sits below Sales), trigger signal type/id, `correlation_id`, `phase`,
  `status`, embedded `budget` (`SdrAgent.Agents.AgentRun.Budget`),
  `operation_id` (the Operations `Operation` running it) and
  `attention_failure_id` (its operator-attention `Failure`), `retry_of_id`,
  `usage_origin` (C9: where the run started — `SdrAgent.Agents.UsageBucket`;
  set by the server code of the entry point at `:create`, immutable, copied
  by `:retry`; null only for runs created before R0),
  `status_reason` (required in failed / budget_exhausted / cancelled),
  `failure_reason` (detail, passed through the secret redactor before it is
  written), `started_at`, `finished_at`.

  Lifecycle (`transitions/0`): queued → running → succeeded | failed |
  budget_exhausted | cancelled; queued → cancelled. `start` and `succeed`
  guard the from-state inside the SQL `UPDATE`; `fail`, `exhaust_budget` and
  `cancel` run on the row re-read `FOR UPDATE` because they also open the
  operator-attention Failure (S2): entering failed or budget_exhausted, or
  cancelled by a system actor, opens a Failure and sets
  `attention_failure_id` in the same transaction (an operator cancel opens
  none); an operator `retry` resolves the retried run's Failure. A run
  stopped by a refused real-model reservation (C9: `:fail` with
  `:grant_unavailable`, `:exhaust_budget` with `:grant_exhausted`; R0-07
  slice B: `:fail` with `:model_not_admitted`, a real call refused by the
  admission gate before reservation or at launch — each with the refusal
  receipt's `refusal_failure_id` and `refusal_request_id`)
  opens none and links that exact deduplicated Failure instead, even if an
  admin has resolved it meanwhile; the stop event records both arguments
  (`SdrAgent.Agents.Changes.LinkRefusalAttention`). A run stopped by the
  result gate (R0-07 slice C: `:fail` with `:witness_mismatch` or
  `:witness_unreconciled`, with `witness_failure_id` and `release_id`)
  likewise links the gate's exact cause
  (`SdrAgent.Agents.Changes.LinkGateCause`); under the finalizer's verified
  Prelocked context its run and cause are re-read with no lock clause
  (`SdrAgent.Agents.Changes.RunRow`). A `:proof` run is finished by the
  guarded calibration finish only (R0-07 slice E, row R11-2:
  `:finish_calibration`, running → succeeded with `:calibration_latched`,
  given its `:calibration` latch, `SdrAgent.Agents.Changes.CalibrationLatch`).

  Counters: `:reserve_model_call` (atomic, refuses at `max_model_calls`),
  `:settle_model_call`, `:record_tool_call` (atomic, refuses at
  `max_tool_calls`) — counters only increase. An operator `:retry` creates a
  new run linked by `retry_of_id` (and, for an assignment, bound to its new
  Operation).

  Actors: AGT, SCH create; AGT transitions, phase and counters; ADM, REV
  cancel (AGT may also cancel); retry is active ADM inside
  `SdrAgent.SDR.retry_run/2` only (S13b); reads for any actor. Every write
  appends an AuditEvent (`agents.run.*`).
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Agents.Changes.BudgetCounter
  alias SdrAgent.Audit.Changes.Stamp
  alias SdrAgent.Audit.Changes.AppendEvent
  alias SdrAgent.Audit.Changes.Transition
  alias SdrAgent.Audit.Checks
  alias SdrAgent.Operations.Changes.OpenAttention

  @statuses [:queued, :running, :succeeded, :failed, :budget_exhausted, :cancelled]
  @phases [
    :discover,
    :research,
    :qualify,
    :plan,
    :personalize,
    :draft,
    :validate,
    :review,
    :queue,
    :deliver,
    :observe,
    :reply,
    :stop
  ]
  @status_reasons [
    :run_budget_calls,
    :run_budget_tokens,
    :daily_budget,
    :grant_exhausted,
    :grant_unavailable,
    :invalid_model_output,
    :provider_error,
    :crash,
    :cancelled_by_operator,
    :witness_mismatch,
    :witness_unreconciled,
    :model_not_admitted,
    :calibration_latched
  ]
  # C9: stop reasons of a refused real-model reservation (its Failure is
  # linked); R0-07 slice B adds :model_not_admitted (admission refusals
  # before reservation and at launch).
  @refused [:grant_exhausted, :grant_unavailable, :model_not_admitted]
  # R0-07 slice C: stop reasons of the result gate (its exact cause is linked).
  @gate [:witness_mismatch, :witness_unreconciled]
  @transitions [
    {:start, [:queued], :running},
    {:succeed, [:running], :succeeded},
    {:finish_calibration, [:running], :succeeded},
    {:fail, [:running], :failed},
    {:exhaust_budget, [:running], :budget_exhausted},
    {:cancel, [:queued, :running], :cancelled}
  ]
  @links [agent_run_id: :id, correlation_id: :correlation_id]

  postgres do
    table "agent_runs"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :agent_definition, on_delete: :restrict
      reference :retry_of, on_delete: :restrict
      reference :operation, on_delete: :restrict
      reference :attention_failure, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "agent_runs_trace_ids", check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :status, "agent_runs_status",
        check: SdrAgent.Audit.SQL.one_of("status", @statuses)

      check_constraint :status_reason, "agent_runs_status_reason_required",
        check:
          "status NOT IN ('failed', 'budget_exhausted', 'cancelled') OR status_reason IS NOT NULL"
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :agent_definition_id,
        :lead_id,
        :campaign_id,
        :trigger_signal_type,
        :trigger_signal_id,
        :correlation_id,
        :phase,
        :operation_id
      ]

      argument :max_model_calls, :integer, default: 20, constraints: [min: 0]
      argument :max_tool_calls, :integer, allow_nil?: false, constraints: [min: 0]
      argument :max_tokens, :integer, default: 100_000, constraints: [min: 0]

      # C9: chosen by the server code of the entry point that creates the run
      # (`SdrAgent.SDR.assign_lead/2` → :assignment, reply intake → :reply),
      # never by job args or model output; immutable afterwards.
      argument :usage_origin, :atom,
        allow_nil?: false,
        constraints: [one_of: SdrAgent.Agents.UsageBucket.origins()]

      change set_attribute(:usage_origin, arg(:usage_origin))

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :budget, %{
          max_model_calls: Ash.Changeset.get_argument(changeset, :max_model_calls),
          max_tool_calls: Ash.Changeset.get_argument(changeset, :max_tool_calls),
          max_tokens: Ash.Changeset.get_argument(changeset, :max_tokens)
        })
      end

      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds

      change {AppendEvent,
              event_type: "agents.run.created", category: :domain_change, links: @links}
    end

    create :retry do
      description """
      Operator retry of a failed, budget-exhausted or cancelled run — only
      inside `SdrAgent.SDR.retry_run/2` (S13b). `operation_id`: the new
      run's Operation, required for an assignment (`sdr.lead.assigned`)
      retry, absent for a reply-classification retry.
      """

      argument :run_id, :uuid, allow_nil?: false
      argument :operation_id, :uuid
      change SdrAgent.Agents.Changes.RetryOf
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds

      change {SdrAgent.Operations.Changes.ResolveAttention,
              subject_resource: "SdrAgent.Agents.AgentRun",
              subject_field: :retry_of_id,
              note: "retried as run"}

      change {AppendEvent,
              event_type: "agents.run.retried",
              category: :domain_change,
              links: @links,
              arguments: [:run_id]}
    end

    update :start do
      change {Transition, from: [:queued], to: :running}
      change {Stamp, fields: [:started_at]}

      change {AppendEvent,
              event_type: "agents.run.started", category: :domain_change, links: @links}
    end

    update :set_phase do
      accept [:phase]
      validate attribute_in(:status, [:running])

      change {AppendEvent,
              event_type: "agents.run.phase_changed", category: :domain_change, links: @links}
    end

    update :succeed do
      change {Transition, from: [:running], to: :succeeded}
      change {Stamp, fields: [:finished_at]}

      change {AppendEvent,
              event_type: "agents.run.succeeded", category: :domain_change, links: @links}
    end

    # R0-07 slice E (row R11-2): the only writer of :calibration_latched,
    # reachable only through `SdrAgent.Agents.finish_calibration/3` under its
    # verified Prelocked context with the run's calibration latch.
    update :finish_calibration do
      require_atomic? false
      argument :release_id, :uuid, allow_nil?: false

      change set_attribute(:status_reason, :calibration_latched)
      change SdrAgent.Agents.Changes.CalibrationLatch
      change {Transition, from: [:running], to: :succeeded, locked?: true}
      change {Stamp, fields: [:finished_at]}

      change {AppendEvent,
              event_type: "agents.run.calibration_latched",
              category: :domain_change,
              links: @links,
              arguments: [:release_id]}
    end

    update :fail do
      require_atomic? false
      accept [:failure_reason]
      change {SdrAgent.Operations.Changes.Redact, fields: [:failure_reason]}

      argument :status_reason, :atom,
        allow_nil?: false,
        constraints: [
          one_of: [
            :invalid_model_output,
            :provider_error,
            :crash,
            :grant_unavailable,
            :witness_mismatch,
            :witness_unreconciled,
            :model_not_admitted
          ]
        ]

      # C9: the refusal receipt — its exact Failure and request id (required
      # with, and only with, :grant_unavailable or :model_not_admitted);
      # linked instead of a new one.
      argument :refusal_failure_id, :uuid
      argument :refusal_request_id, :string

      validate present([:refusal_failure_id, :refusal_request_id]),
        where: [argument_in(:status_reason, @refused)]

      validate absent([:refusal_failure_id, :refusal_request_id]),
        where: [negate(argument_in(:status_reason, @refused))]

      # R0-07 slice C: the result gate's receipt — the withheld release and
      # its exact cause (required with, and only with, the gate reasons).
      argument :witness_failure_id, :uuid
      argument :release_id, :uuid

      validate present([:witness_failure_id, :release_id]),
        where: [argument_in(:status_reason, @gate)]

      validate absent([:witness_failure_id, :release_id]),
        where: [negate(argument_in(:status_reason, @gate))]

      change set_attribute(:status_reason, arg(:status_reason))
      # The run row re-read FOR UPDATE — or, for a gate stop under the
      # finalizer's verified Prelocked context, with no lock clause (G6).
      change SdrAgent.Agents.Changes.RunRow
      change {Transition, from: [:running], to: :failed, locked?: true}

      change {OpenAttention,
              class: :run_stopped,
              severity: :critical,
              message: {__MODULE__, :attention_message},
              field: :attention_failure_id,
              operation_field: :operation_id},
             where: [absent(:refusal_failure_id), absent(:witness_failure_id)]

      change SdrAgent.Agents.Changes.LinkRefusalAttention, where: [present(:refusal_failure_id)]
      change SdrAgent.Agents.Changes.LinkGateCause, where: [present(:witness_failure_id)]

      change {Stamp, fields: [:finished_at]}

      change {AppendEvent,
              event_type: "agents.run.failed",
              category: :domain_change,
              links: @links,
              arguments: [
                :refusal_failure_id,
                :refusal_request_id,
                :witness_failure_id,
                :release_id
              ]}
    end

    update :exhaust_budget do
      require_atomic? false

      argument :status_reason, :atom,
        allow_nil?: false,
        constraints: [
          one_of: [:run_budget_calls, :run_budget_tokens, :daily_budget, :grant_exhausted]
        ]

      # C9: the refusal receipt — its exact Failure and request id (required
      # with, and only with, :grant_exhausted); linked instead of a new one.
      argument :refusal_failure_id, :uuid
      argument :refusal_request_id, :string

      validate present([:refusal_failure_id, :refusal_request_id]),
        where: [argument_in(:status_reason, @refused)]

      validate absent([:refusal_failure_id, :refusal_request_id]),
        where: [negate(argument_in(:status_reason, @refused))]

      change set_attribute(:status_reason, arg(:status_reason))
      change get_and_lock_for_update()
      change {Transition, from: [:running], to: :budget_exhausted, locked?: true}

      change {OpenAttention,
              class: :budget_exhausted,
              severity: :critical,
              message: {__MODULE__, :attention_message},
              field: :attention_failure_id,
              operation_field: :operation_id},
             where: [absent(:refusal_failure_id)]

      change SdrAgent.Agents.Changes.LinkRefusalAttention, where: [present(:refusal_failure_id)]

      change {Stamp, fields: [:finished_at]}

      change {AppendEvent,
              event_type: "agents.run.budget_exhausted",
              category: :domain_change,
              links: @links,
              arguments: [:refusal_failure_id, :refusal_request_id]}
    end

    update :cancel do
      require_atomic? false

      argument :status_reason, :atom,
        default: :cancelled_by_operator,
        constraints: [one_of: [:cancelled_by_operator, :crash, :provider_error]]

      change set_attribute(:status_reason, arg(:status_reason))
      change get_and_lock_for_update()
      change {Transition, from: [:queued, :running], to: :cancelled, locked?: true}

      change {OpenAttention,
              class: :run_stopped,
              severity: :critical,
              message: {__MODULE__, :attention_message},
              field: :attention_failure_id,
              operation_field: :operation_id,
              system_only?: true}

      change {Stamp, fields: [:finished_at]}

      change {AppendEvent,
              event_type: "agents.run.cancelled", category: :domain_change, links: @links}
    end

    update :reserve_model_call do
      require_atomic? false
      description "Reserve one model call before it is made (atomic; refuses at the limit)."

      change {BudgetCounter,
              increment: [model_calls_reserved: 1],
              limit: {:model_calls_reserved, :max_model_calls}}

      change {AppendEvent,
              event_type: "agents.run.model_call_reserved",
              category: :domain_change,
              links: @links}
    end

    update :settle_model_call do
      require_atomic? false
      description "Count a sent model call as used and add its tokens."
      argument :calls, :integer, default: 1, constraints: [min: 0, max: 1]
      argument :tokens, :integer, default: 0, constraints: [min: 0]

      change {BudgetCounter,
              increment: [model_calls_used: {:arg, :calls}, tokens_used: {:arg, :tokens}]}

      change {AppendEvent,
              event_type: "agents.run.model_call_settled",
              category: :domain_change,
              links: @links,
              arguments: [:calls, :tokens]}
    end

    update :record_tool_call do
      require_atomic? false
      description "Count one tool call at its start (atomic; refuses at the limit)."

      change {BudgetCounter,
              increment: [tool_calls_used: 1], limit: {:tool_calls_used, :max_tool_calls}}

      change {AppendEvent,
              event_type: "agents.run.tool_call_recorded", category: :domain_change, links: @links}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action(:create) do
      authorize_if {Checks.ActorType, types: [:agent_runtime, :scheduler]}
    end

    # S13b: active ADM only, and only inside the retry orchestration.
    policy action(:retry) do
      forbid_unless SdrAgent.Agents.Checks.RetryContext
      authorize_if {Checks.ActorRole, roles: [:admin]}
    end

    policy action(:cancel) do
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer]}
      authorize_if {Checks.ActorType, types: [:agent_runtime]}
    end

    policy action([
             :start,
             :set_phase,
             :succeed,
             :finish_calibration,
             :fail,
             :exhaust_budget,
             :reserve_model_call,
             :settle_model_call,
             :record_tool_call
           ]) do
      authorize_if {Checks.ActorType, types: [:agent_runtime]}
    end

    policy action_type(:read) do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :lead_id, :uuid, public?: true
    attribute :campaign_id, :uuid, public?: true
    attribute :trigger_signal_type, :string, allow_nil?: false, public?: true
    attribute :trigger_signal_id, :string, allow_nil?: false, public?: true
    attribute :correlation_id, :uuid, allow_nil?: false, public?: true

    attribute :phase, :atom do
      allow_nil? false
      constraints one_of: @phases
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      default :queued
      writable? false
      constraints one_of: @statuses
      public? true
    end

    attribute :budget, SdrAgent.Agents.AgentRun.Budget, allow_nil?: false, public?: true

    # C9: where the run started (`SdrAgent.Agents.UsageBucket`); null only
    # for runs created before R0. Set at :create, copied by :retry.
    attribute :usage_origin, :atom do
      writable? false
      constraints one_of: SdrAgent.Agents.UsageBucket.origins()
      public? true
    end

    attribute :status_reason, :atom do
      writable? false
      constraints one_of: @status_reasons
      public? true
    end

    attribute :failure_reason, :string, public?: true
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

    belongs_to :agent_definition, SdrAgent.Agents.AgentDefinition do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :retry_of, __MODULE__ do
      public? true
    end

    belongs_to :operation, SdrAgent.Operations.Operation do
      attribute_writable? true
      public? true
    end

    belongs_to :attention_failure, SdrAgent.Operations.Failure do
      attribute_writable? false
      public? true
    end

    has_many :model_invocations, SdrAgent.Agents.ModelInvocation, public?: true
    has_many :tool_invocations, SdrAgent.Agents.ToolInvocation, public?: true
    has_many :decisions, SdrAgent.Agents.Decision, public?: true
  end

  @doc "Declared lifecycle transitions `{action, from, to}` (ADR-0010)."
  def transitions, do: @transitions

  @doc "The operator-attention message of a stopping transition (redacted by Failure)."
  def attention_message(changeset) do
    to = Ash.Changeset.get_attribute(changeset, :status)
    reason = Ash.Changeset.get_argument(changeset, :status_reason)

    case Ash.Changeset.get_attribute(changeset, :failure_reason) do
      nil -> "agent run #{to}: #{reason}"
      detail -> "agent run #{to}: #{reason}: #{detail}"
    end
  end

  @doc "R0-07 slice C: the result gate's stop reasons."
  def gate_reasons, do: @gate

  @doc false
  def __sdr_audited__, do: true
end
