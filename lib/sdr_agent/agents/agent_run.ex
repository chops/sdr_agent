defmodule SdrAgent.Agents.AgentRun do
  @moduledoc """
  One Jido agent execution for one assignment, with its budget (S2 row
  AgentRun; spec §4).

  Attributes: `agent_definition_id`, plain `lead_id`/`campaign_id` (Agents
  sits below Sales), trigger signal type/id, `correlation_id`, `phase`,
  `status`, embedded `budget` (`SdrAgent.Agents.AgentRun.Budget`),
  `operation_id` and `attention_failure_id` (plain uuids until S7 adds
  their FKs and the operator-attention Failure), `retry_of_id`,
  `status_reason` (required in failed / budget_exhausted / cancelled),
  `failure_reason` (redacted detail), `started_at`, `finished_at`.

  Lifecycle (`transitions/0`): queued → running → succeeded | failed |
  budget_exhausted | cancelled; queued → cancelled. Every transition is an
  update action whose from-state guard runs inside the SQL `UPDATE`.

  Counters: `:reserve_model_call` (atomic, refuses at `max_model_calls`),
  `:settle_model_call`, `:record_tool_call` (atomic, refuses at
  `max_tool_calls`) — counters only increase. An operator `:retry` creates a
  new run linked by `retry_of_id`.

  Actors: AGT, SCH create; AGT transitions, phase and counters; ADM, REV
  cancel and retry (AGT may also cancel); reads for any actor. Every write
  appends an AuditEvent (`agents.run.*`).
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Agents.Changes.BudgetCounter
  alias SdrAgent.Agents.Changes.Stamp
  alias SdrAgent.Audit.Changes.AppendEvent
  alias SdrAgent.Audit.Changes.Transition
  alias SdrAgent.Audit.Checks

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
    :invalid_model_output,
    :provider_error,
    :crash,
    :cancelled_by_operator
  ]
  @transitions [
    {:start, [:queued], :running},
    {:succeed, [:running], :succeeded},
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
      description "Operator retry of a failed, budget-exhausted or cancelled run."
      argument :run_id, :uuid, allow_nil?: false
      change SdrAgent.Agents.Changes.RetryOf
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds

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

    update :fail do
      accept [:failure_reason]

      argument :status_reason, :atom,
        allow_nil?: false,
        constraints: [one_of: [:invalid_model_output, :provider_error, :crash]]

      change set_attribute(:status_reason, arg(:status_reason))
      change {Transition, from: [:running], to: :failed}
      change {Stamp, fields: [:finished_at]}

      change {AppendEvent,
              event_type: "agents.run.failed", category: :domain_change, links: @links}
    end

    update :exhaust_budget do
      argument :status_reason, :atom,
        allow_nil?: false,
        constraints: [one_of: [:run_budget_calls, :run_budget_tokens, :daily_budget]]

      change set_attribute(:status_reason, arg(:status_reason))
      change {Transition, from: [:running], to: :budget_exhausted}
      change {Stamp, fields: [:finished_at]}

      change {AppendEvent,
              event_type: "agents.run.budget_exhausted", category: :domain_change, links: @links}
    end

    update :cancel do
      argument :status_reason, :atom,
        default: :cancelled_by_operator,
        constraints: [one_of: [:cancelled_by_operator, :crash, :provider_error]]

      change set_attribute(:status_reason, arg(:status_reason))
      change {Transition, from: [:queued, :running], to: :cancelled}
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

    policy action(:retry) do
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer]}
    end

    policy action(:cancel) do
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer]}
      authorize_if {Checks.ActorType, types: [:agent_runtime]}
    end

    policy action([
             :start,
             :set_phase,
             :succeed,
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
    attribute :operation_id, :uuid, public?: true

    attribute :status_reason, :atom do
      writable? false
      constraints one_of: @status_reasons
      public? true
    end

    attribute :failure_reason, :string, public?: true
    attribute :attention_failure_id, :uuid, writable?: false, public?: true
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

    has_many :model_invocations, SdrAgent.Agents.ModelInvocation, public?: true
    has_many :tool_invocations, SdrAgent.Agents.ToolInvocation, public?: true
    has_many :decisions, SdrAgent.Agents.Decision, public?: true
  end

  @doc "Declared lifecycle transitions `{action, from, to}` (ADR-0010)."
  def transitions, do: @transitions

  @doc false
  def __sdr_audited__, do: true
end
