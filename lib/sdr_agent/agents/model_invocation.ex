defmodule SdrAgent.Agents.ModelInvocation do
  @moduledoc """
  One model call with its full request and response (S2 row
  ModelInvocation; ADR-0002, ADR-0004).

  Metadata: `agent_run_id`, `sequence_in_run` (the run's reservation
  number), `purpose`, provider/model ids and catalog entry, opaque
  `account_mode_ref`, `data_control_setting`, `parameters`, prompt template
  and output schema refs with their sha256, `idempotency_key` (unique per
  tenant). Bodies live in `SdrAgent.Audit.Payload`: `request_sha256` is
  stored before the call, `response_sha256` (verbatim raw response) on
  completion, both with composite FKs to `payloads`. Also `parsed_output`,
  `validation_status`/`validation_errors`, `refusal`, `error`, `usage`,
  `latency_ms` and the status timestamps.

  Lifecycle (`transitions/0`): reserved → sent → completed | failed;
  reserved → failed; sent → unknown (crash recovery; never re-sent).
  Terminal-immutable: a trigger rejects updates of terminal rows and any
  change to columns other than status, response and usage; deletes are
  rejected.

  AGT creates and transitions only (through `SdrAgent.Agents`); reads for
  any actor (metadata only — content via `SdrAgent.Audit.read_content/2`).
  Audited: `model.invocation.reserved | sent | completed | failed | unknown`.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Agents.Changes.Stamp
  alias SdrAgent.Audit.Changes.AppendEvent
  alias SdrAgent.Audit.Changes.Transition
  alias SdrAgent.Audit.Checks

  @statuses [:reserved, :sent, :completed, :failed, :unknown]
  @terminal [:completed, :failed, :unknown]
  @mutable [
    :status,
    :response_sha256,
    :parsed_output,
    :validation_status,
    :validation_errors,
    :refusal,
    :error,
    :usage,
    :latency_ms,
    :sent_at,
    :completed_at,
    :updated_at
  ]
  @transitions [
    {:mark_sent, [:reserved], :sent},
    {:complete, [:sent], :completed},
    {:fail, [:reserved, :sent], :failed},
    {:mark_unknown, [:sent], :unknown}
  ]
  @links [
    model_invocation_id: :id,
    agent_run_id: :agent_run_id,
    idempotency_key: :idempotency_key
  ]
  @event [category: :model, links: @links, version_refs: {__MODULE__, :version_refs}]

  postgres do
    table "model_invocations"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :agent_run, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "model_invocations_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :status, "model_invocations_status",
        check: SdrAgent.Audit.SQL.one_of("status", @statuses)
    end

    custom_statements do
      for {name, up_sql, down_sql} <-
            SdrAgent.Audit.SQL.terminal_immutable("model_invocations", @terminal, @mutable) do
        statement name do
          up up_sql
          down down_sql
        end
      end

      for column <- [:request_sha256, :response_sha256] do
        {name, up_sql, down_sql} = SdrAgent.Audit.SQL.payload_fk("model_invocations", column)

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

    create :reserve do
      accept [
        :agent_run_id,
        :sequence_in_run,
        :purpose,
        :provider,
        :provider_version,
        :model_id,
        :model_catalog_entry,
        :account_mode_ref,
        :data_control_setting,
        :parameters,
        :prompt_template_id,
        :prompt_template_version,
        :prompt_template_sha256,
        :output_schema_id,
        :output_schema_version,
        :output_schema_sha256,
        :request_sha256,
        :idempotency_key
      ]

      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change {AppendEvent, [event_type: "model.invocation.reserved"] ++ @event}
    end

    update :mark_sent do
      change {Transition, from: [:reserved], to: :sent}
      change {Stamp, fields: [:sent_at]}
      change {AppendEvent, [event_type: "model.invocation.sent"] ++ @event}
    end

    update :complete do
      accept [
        :response_sha256,
        :parsed_output,
        :validation_status,
        :validation_errors,
        :refusal,
        :usage,
        :latency_ms
      ]

      change {Transition, from: [:sent], to: :completed}
      change {Stamp, fields: [:completed_at]}
      change {AppendEvent, [event_type: "model.invocation.completed"] ++ @event}
    end

    update :fail do
      accept [
        :error,
        :response_sha256,
        :parsed_output,
        :validation_status,
        :validation_errors,
        :refusal,
        :usage,
        :latency_ms
      ]

      validate present(:error)
      change {Transition, from: [:reserved, :sent], to: :failed}
      change {Stamp, fields: [:completed_at]}
      change {AppendEvent, [event_type: "model.invocation.failed"] ++ @event}
    end

    update :mark_unknown do
      change {Transition, from: [:sent], to: :unknown}
      change {AppendEvent, [event_type: "model.invocation.unknown"] ++ @event}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action([:reserve, :mark_sent, :complete, :fail, :mark_unknown]) do
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

    attribute :purpose, :atom do
      allow_nil? false

      constraints one_of: [
                    :qualification,
                    :outreach_proposal,
                    :evidence_extraction,
                    :reply_classification
                  ]

      public? true
    end

    attribute :provider, :atom do
      allow_nil? false
      constraints one_of: [:fake, :codex_app_server]
      public? true
    end

    attribute :provider_version, :string, allow_nil?: false, public?: true
    attribute :model_id, :string, allow_nil?: false, public?: true
    attribute :model_catalog_entry, :map, allow_nil?: false, public?: true
    attribute :account_mode_ref, :string, allow_nil?: false, public?: true
    attribute :data_control_setting, :string, allow_nil?: false, public?: true
    attribute :parameters, :map, allow_nil?: false, default: %{}, public?: true
    attribute :prompt_template_id, :string, allow_nil?: false, public?: true
    attribute :prompt_template_version, :string, allow_nil?: false, public?: true
    attribute :prompt_template_sha256, :binary, allow_nil?: false, public?: true
    attribute :output_schema_id, :string, allow_nil?: false, public?: true
    attribute :output_schema_version, :string, allow_nil?: false, public?: true
    attribute :output_schema_sha256, :binary, allow_nil?: false, public?: true
    attribute :request_sha256, :binary, allow_nil?: false, public?: true
    attribute :response_sha256, :binary, public?: true
    attribute :parsed_output, :map, public?: true

    attribute :validation_status, :atom do
      allow_nil? false
      default :pending
      constraints one_of: [:pending, :valid, :invalid, :not_applicable]
      public? true
    end

    attribute :validation_errors, {:array, :map}, allow_nil?: false, default: [], public?: true
    attribute :refusal, :string, public?: true
    attribute :error, :map, public?: true
    attribute :usage, SdrAgent.Agents.ModelInvocation.Usage, public?: true

    attribute :latency_ms, :integer do
      constraints min: 0
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      default :reserved
      writable? false
      constraints one_of: @statuses
      public? true
    end

    attribute :reserved_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      default &SdrAgent.Clock.utc_now/0
      public? true
    end

    attribute :sent_at, :utc_datetime_usec, writable?: false, public?: true
    attribute :completed_at, :utc_datetime_usec, writable?: false, public?: true
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

    has_many :decisions, SdrAgent.Agents.Decision, public?: true
  end

  identities do
    identity :unique_sequence_in_run, [:agent_run_id, :sequence_in_run]
    identity :unique_idempotency_key, [:tenant_id, :idempotency_key]
  end

  @doc "Declared lifecycle transitions `{action, from, to}` (ADR-0010)."
  def transitions, do: @transitions

  @doc "Version refs recorded on this invocation's audit events."
  def version_refs(invocation) do
    %{
      prompt_templates: %{invocation.prompt_template_id => invocation.prompt_template_version},
      output_schemas: %{invocation.output_schema_id => invocation.output_schema_version}
    }
  end

  @doc false
  def __sdr_audited__, do: true
end
