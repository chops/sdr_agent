defmodule SdrAgent.Agents.ToolInvocation do
  @moduledoc """
  One Jido Action execution (S2 row ToolInvocation): `action_module`,
  `action_version`, `input_sha256` / `output_sha256` (bodies in
  `SdrAgent.Audit.Payload`, composite FKs), `status`, `error`,
  `external_request_refs`, `started_at`, `finished_at`, `duration_ms`,
  `idempotency_key` (unique per tenant), `sequence_in_run` (the run's tool
  call number, counted atomically at start).

  Lifecycle (`transitions/0`): started → succeeded | failed | unknown.
  Terminal-immutable (trigger, as ModelInvocation). AGT creates and
  transitions only; reads for any actor. Audited: `tool.invocation.started`
  and `tool.invocation.finished` (every terminal transition).
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Changes.Stamp
  alias SdrAgent.Audit.Changes.AppendEvent
  alias SdrAgent.Audit.Changes.Transition
  alias SdrAgent.Audit.Checks

  @statuses [:started, :succeeded, :failed, :unknown]
  @terminal [:succeeded, :failed, :unknown]
  @mutable [
    :status,
    :output_sha256,
    :error,
    :external_request_refs,
    :finished_at,
    :duration_ms,
    :updated_at
  ]
  @transitions [
    {:succeed, [:started], :succeeded},
    {:fail, [:started], :failed},
    {:mark_unknown, [:started], :unknown}
  ]
  @event [
    category: :tool,
    links: [
      tool_invocation_id: :id,
      agent_run_id: :agent_run_id,
      idempotency_key: :idempotency_key
    ]
  ]

  postgres do
    table "tool_invocations"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :agent_run, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "tool_invocations_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :status, "tool_invocations_status",
        check: SdrAgent.Audit.SQL.one_of("status", @statuses)
    end

    custom_statements do
      for {name, up_sql, down_sql} <-
            SdrAgent.Audit.SQL.terminal_immutable("tool_invocations", @terminal, @mutable) do
        statement name do
          up up_sql
          down down_sql
        end
      end

      for column <- [:input_sha256, :output_sha256] do
        {name, up_sql, down_sql} = SdrAgent.Audit.SQL.payload_fk("tool_invocations", column)

        statement name do
          up up_sql
          down down_sql
          after_tables ["payloads"]
        end
      end
    end
  end

  actions do
    defaults [:read]

    create :start do
      accept [
        :agent_run_id,
        :sequence_in_run,
        :action_module,
        :action_version,
        :input_sha256,
        :idempotency_key
      ]

      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change {AppendEvent, [event_type: "tool.invocation.started"] ++ @event}
    end

    update :succeed do
      accept [:output_sha256, :external_request_refs]
      change {Transition, from: [:started], to: :succeeded}
      change {Stamp, fields: [:finished_at], duration_ms_since: :started_at}
      change {AppendEvent, [event_type: "tool.invocation.finished"] ++ @event}
    end

    update :fail do
      accept [:error, :output_sha256, :external_request_refs]
      validate present(:error)
      change {Transition, from: [:started], to: :failed}
      change {Stamp, fields: [:finished_at], duration_ms_since: :started_at}
      change {AppendEvent, [event_type: "tool.invocation.finished"] ++ @event}
    end

    update :mark_unknown do
      change {Transition, from: [:started], to: :unknown}
      change {AppendEvent, [event_type: "tool.invocation.finished"] ++ @event}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action([:start, :succeed, :fail, :mark_unknown]) do
      authorize_if {Checks.ActorType, types: [:agent_runtime]}
    end

    policy action_type(:read) do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :sequence_in_run, :integer do
      allow_nil? false
      constraints min: 1
      public? true
    end

    attribute :action_module, :string, allow_nil?: false, public?: true
    attribute :action_version, :string, allow_nil?: false, public?: true
    attribute :input_sha256, :binary, allow_nil?: false, public?: true
    attribute :output_sha256, :binary, public?: true

    attribute :status, :atom do
      allow_nil? false
      default :started
      writable? false
      constraints one_of: @statuses
      public? true
    end

    attribute :error, :map, public?: true

    attribute :external_request_refs, {:array, SdrAgent.Agents.ToolInvocation.ExternalRequestRef},
      allow_nil?: false,
      default: [],
      public?: true

    attribute :started_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      default &SdrAgent.Clock.utc_now/0
      public? true
    end

    attribute :finished_at, :utc_datetime_usec, writable?: false, public?: true

    attribute :duration_ms, :integer do
      writable? false
      constraints min: 0
      public? true
    end

    attribute :idempotency_key, :string, allow_nil?: false, public?: true
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

    belongs_to :agent_run, SdrAgent.Agents.AgentRun do
      allow_nil? false
      attribute_writable? true
      public? true
    end
  end

  identities do
    identity :unique_sequence_in_run, [:agent_run_id, :sequence_in_run]
    identity :unique_idempotency_key, [:tenant_id, :idempotency_key]
  end

  @doc "Declared lifecycle transitions `{action, from, to}` (ADR-0010)."
  def transitions, do: @transitions

  @doc false
  def __sdr_audited__, do: true
end
