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

  Real-model ledger (C9; R0 readiness packet): `ledger_generation` (1 for
  every row written before R0, 2 for every row `:reserve` writes),
  `profile_id` (the model profile; `:fake` for the Fake), and for a
  ClaudeCLI call the `grant_id`/`allocation_id` it was charged to at
  reservation (`SdrAgent.Agents.Admission`). All four are written only by
  `:reserve` and are immutable afterwards (outside the trigger's mutable
  set). `:reserve` accepts no grant, allocation or generation: a ClaudeCLI
  reservation is refused unless `SdrAgent.Agents` attached the admitted
  charge (`SdrAgent.Agents.Checks.AdmissionContext`), and any other provider
  is refused if one is attached (`SdrAgent.Agents.Changes.AdmissionCharge`). A check constraint makes every generation-2 ClaudeCLI row carry
  profile, grant and allocation; composite FKs keep the allocation within
  its grant, and the grant within the invocation's tenant.

  Lifecycle (`transitions/0`): reserved → sent → completed | failed;
  reserved → failed; sent → unknown (crash recovery; never re-sent).
  Terminal-immutable: a trigger rejects updates of terminal rows and any
  change to columns other than status, response and usage; deletes are
  rejected.

  AGT creates and transitions only (through `SdrAgent.Agents`); reads for
  any actor (metadata only — content via `SdrAgent.Audit.read_content/2`).
  Audited: `model.invocation.reserved | sent | completed | failed | unknown`.

  Read gate (R0-07 REQ-07-5; entity PASS at 1da747a; round 5 PASS at
  dc8cae7): for a generation-2 ClaudeCLI row, the output-bearing fields
  (`output_fields/0`: `parsed_output`, `validation_errors`, `refusal`) are
  readable only by the released-output
  read (`SdrAgent.Agents.released_output/2`, marked by
  `SdrAgent.Agents.Checks.ReleasedOutputRead` and requiring a `:released`
  `SdrAgent.Agents.ModelResultRelease`), by the witness evidence seam (REC
  and AUD), by the audit kernel's integrity read (chain verification and
  event hashing, `SdrAgent.Audit.Checks.IntegrityRead`) and, as AGT, for
  the one proof invocation bound by the test-seam
  `SdrAgent.Agents.Checks.CalibrationContext`
  (`SdrAgent.Agents.Checks.CalibrationRead`). Its audit events carry
  commitments instead (`__sdr_output_commitment__/1`). Every other read — generic
  Ash reads, domain list and detail APIs, kernel-context reads, admins and
  AGT — returns `%Ash.ForbiddenField{}`, released or not. Generation-1 and
  Fake rows are unchanged. An `(id, tenant_id)` unique key is the target of
  the release's composite FK.
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

  @statuses [:reserved, :sent, :completed, :failed, :unknown]
  # R0-07: the model-authored (output-bearing) fields of a gated row.
  @output_fields [:parsed_output, :validation_errors, :refusal]
  # The model profile ids (R0-03 registry, `SdrAgent.AI.ModelProfiles`).
  @profiles SdrAgent.AI.ModelProfiles.ids()
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
      reference :grant, on_delete: :restrict
      reference :allocation, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "model_invocations_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :status, "model_invocations_status",
        check: SdrAgent.Audit.SQL.one_of("status", @statuses)

      # C9 cutover predicate: applies to every insert and update; rows
      # written before R0 are generation 1 and keep every transition.
      check_constraint :grant_id, "model_invocations_real_call_charged",
        check:
          "ledger_generation = 1 OR provider <> 'claude_cli' OR " <>
            "(profile_id IS NOT NULL AND grant_id IS NOT NULL AND allocation_id IS NOT NULL)"
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

      # C9: the allocation belongs to the recorded grant, and the grant to
      # the invocation's tenant (targets: the grants' and allocations'
      # composite unique keys).
      statement :model_invocations_grant_tenant_fkey do
        up "ALTER TABLE model_invocations ADD CONSTRAINT model_invocations_grant_tenant_fkey " <>
             "FOREIGN KEY (grant_id, tenant_id) REFERENCES model_call_grants (id, tenant_id) " <>
             "ON DELETE RESTRICT"

        down "ALTER TABLE model_invocations DROP CONSTRAINT model_invocations_grant_tenant_fkey"
        after_tables ["model_call_grants"]
      end

      # Target of the ModelResultRelease (model_invocation_id, tenant_id)
      # composite FK (R0-07).
      statement :model_invocations_id_tenant_key do
        up "ALTER TABLE model_invocations ADD CONSTRAINT model_invocations_id_tenant_key " <>
             "UNIQUE (id, tenant_id)"

        down "ALTER TABLE model_invocations DROP CONSTRAINT model_invocations_id_tenant_key"
      end

      statement :model_invocations_allocation_grant_fkey do
        up "ALTER TABLE model_invocations ADD CONSTRAINT model_invocations_allocation_grant_fkey " <>
             "FOREIGN KEY (allocation_id, grant_id) " <>
             "REFERENCES model_call_allocations (id, grant_id) ON DELETE RESTRICT"

        down "ALTER TABLE model_invocations DROP CONSTRAINT " <>
               "model_invocations_allocation_grant_fkey"

        after_tables ["model_call_allocations"]
      end
    end
  end

  field_policies do
    # R0-07: the output of a generation-2 ClaudeCLI call is a business read
    # only once released, and then only through the released-output read.
    # Round 5: the diagnostics `validation_errors` and `refusal` are copies
    # of model-authored output and share the boundary.
    field_policy @output_fields do
      authorize_if expr(ledger_generation != 2 or provider != :claude_cli)
      authorize_if {Checks.ActorType, types: [:reconciler, :auditor_cli]}
      authorize_if SdrAgent.Audit.Checks.IntegrityRead
      authorize_if SdrAgent.Agents.Checks.CalibrationRead
      forbid_unless SdrAgent.Agents.Checks.ReleasedOutputRead
      authorize_if expr(exists(result_release, disposition == :released))
    end

    field_policy :* do
      authorize_if always()
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
        :idempotency_key,
        :profile_id
      ]

      # R0-07 slice B (row B4): the authority of an authorized calibration
      # call, set only from the admitted charge (AdmissionCharge) and
      # recorded on the reservation event for launch admission.
      argument :calibration_tuple, :map

      # R0-07 E4c-2: the calibration console's launch-record claim
      # (`%{"instance_id" => uuid}`), set only from the admitted charge.
      argument :calibration_claim, :map

      validate SdrAgent.Agents.Validations.InvocationProfile
      change SdrAgent.Agents.Changes.AdmissionCharge
      change set_attribute(:ledger_generation, 2)
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds

      change {AppendEvent,
              [
                event_type: "model.invocation.reserved",
                arguments: [:calibration_tuple, :calibration_claim]
              ] ++ @event}
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
      constraints one_of: [:fake, :claude_cli, :codex_app_server]
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

    # C9: 1 for rows written before R0; :reserve writes 2.
    attribute :ledger_generation, :integer do
      allow_nil? false
      writable? false
      default 1
      constraints min: 1, max: 2
      public? true
    end

    attribute :profile_id, :atom do
      constraints one_of: @profiles
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

    # C9: set only from the admission context (AdmissionCharge), never input.
    belongs_to :grant, SdrAgent.Agents.ModelCallGrant do
      attribute_writable? false
      public? true
    end

    belongs_to :allocation, SdrAgent.Agents.ModelCallAllocation do
      attribute_writable? false
      public? true
    end

    has_many :decisions, SdrAgent.Agents.Decision, public?: true
    has_many :wire_witness_links, SdrAgent.Agents.WireWitnessLink, public?: true
    has_one :result_release, SdrAgent.Agents.ModelResultRelease, public?: true
  end

  identities do
    identity :unique_sequence_in_run, [:agent_run_id, :sequence_in_run]
    identity :unique_idempotency_key, [:tenant_id, :idempotency_key]
  end

  @doc """
  R0-07 round 5: the output-bearing fields of a gated (generation-2
  ClaudeCLI) row — withheld by the field policy, and replaced by
  `sdr-output-commitment/1` commitments in its audit events
  (`SdrAgent.Audit.Changes.AppendEvent`).
  """
  def output_fields, do: @output_fields

  @doc "Whether `invocation` is gated: generation 2 and `claude_cli`."
  def gated?(%{ledger_generation: 2, provider: :claude_cli}), do: true
  def gated?(_invocation), do: false

  @doc false
  # AppendEvent's output-commitment hook: `{fields, metadata}` for a gated
  # row, nil otherwise.
  def __sdr_output_commitment__(invocation) do
    if gated?(invocation) do
      {@output_fields,
       %{
         validation_status: invocation.validation_status,
         output_schema_id: invocation.output_schema_id,
         output_schema_version: invocation.output_schema_version
       }}
    end
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
