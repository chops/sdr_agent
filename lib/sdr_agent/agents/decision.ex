defmodule SdrAgent.Agents.Decision do
  @moduledoc """
  Every branch point, LLM or deterministic, with its exact inputs, rule or
  model provenance and outcome (S2 row Decision; ADR-0002).

  Attributes: `agent_run_id` (optional), `kind`, `mode`, `subject_resource`
  / `subject_id`, `input_refs` (`{resource, id, record_sha256}`),
  `inputs_sha256` (canonical snapshot of the exact inputs, stored as a
  Payload), `rule_id`/`rule_version`, `model_invocation_id` +
  `output_pointer` (JSON Pointer into that invocation's `parsed_output`;
  several decisions may cite one invocation), `outcome`, `outcome_detail`,
  `rationale`, `confidence`, `decided_at`, `idempotency_key` (unique per
  tenant).

  Invariants: see `SdrAgent.Agents.Changes.DecisionRules`. Idempotency
  (`SdrAgent.Agents.Changes.Replay`): the create is a never-updating upsert
  on `(tenant_id, idempotency_key)`; recording the same decision again —
  sequentially or concurrently — returns the existing row with no new
  event, while reusing the key for a decision with a different
  `replay_sha256` fails with `SdrAgent.Agents.Errors.IdempotencyConflict`.

  Actors: each system actor records only its own kinds (`kind_actors/0`);
  humans never record decisions; reads for any actor. Append-only (no
  update/destroy action; trigger). Audited: `agents.decision.recorded`.

  `kind_actors/0` encodes the S2 rows that name the actor behind each kind
  (AGT for agent reasoning, enrollment, phase and budget decisions; DLV for
  the send gate and its checks; REC reconciliation; WHK the unsubscribe
  rule; SCH follow-up scheduling; suppression and campaign-state checks by
  AGT before it works or enrolls a lead (S7) and by DLV at send). Slices
  that first emit a kind may tighten it.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Expr

  alias SdrAgent.Audit.Canonical

  @protected_kinds [
    :suppression_check,
    :send_gate,
    :quiet_hours,
    :quota_check,
    :approval_validation,
    :campaign_state_check,
    :budget_reservation,
    :unsubscribe_rule,
    :delivery_reconciliation
  ]

  @kind_actors %{
    qualification: [:agent_runtime],
    evidence_quality: [:agent_runtime],
    angle: [:agent_runtime],
    draft_proposal: [:agent_runtime],
    claims_validation: [:agent_runtime],
    personalization_validation: [:agent_runtime],
    reply_classification: [:agent_runtime],
    enrollment: [:agent_runtime],
    phase_transition: [:agent_runtime],
    budget_reservation: [:agent_runtime],
    suppression_check: [:agent_runtime, :delivery_worker],
    send_gate: [:delivery_worker],
    quiet_hours: [:delivery_worker],
    quota_check: [:delivery_worker],
    approval_validation: [:delivery_worker],
    campaign_state_check: [:delivery_worker, :agent_runtime],
    delivery_reconciliation: [:reconciler],
    unsubscribe_rule: [:webhook_ingestor],
    followup_next_step: [:scheduler]
  }

  postgres do
    table "decisions"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :agent_run, on_delete: :restrict
      reference :model_invocation, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "decisions_trace_ids", check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :mode, "decisions_mode_provenance",
        check:
          "(mode = 'llm' AND model_invocation_id IS NOT NULL AND output_pointer IS NOT NULL " <>
            "AND rule_id IS NULL AND rule_version IS NULL) OR " <>
            "(mode = 'deterministic' AND rule_id IS NOT NULL AND rule_version IS NOT NULL " <>
            "AND model_invocation_id IS NULL AND output_pointer IS NULL)"
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("decisions") do
        statement name do
          up up_sql
          down down_sql
        end
      end

      {name, up_sql, down_sql} = SdrAgent.Audit.SQL.payload_fk("decisions", :inputs_sha256)

      statement name do
        up up_sql
        down down_sql
        after_tables ["payloads"]
      end
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [
        :agent_run_id,
        :kind,
        :mode,
        :subject_resource,
        :subject_id,
        :input_refs,
        :rule_id,
        :rule_version,
        :model_invocation_id,
        :output_pointer,
        :outcome,
        :outcome_detail,
        :rationale,
        :confidence,
        :idempotency_key
      ]

      argument :inputs, :map, allow_nil?: false
      upsert? true
      upsert_identity :unique_idempotency_key
      upsert_fields []
      upsert_condition Ash.Expr.expr(false)
      return_skipped_upsert? true
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Agents.Changes.DecisionRules
      change SdrAgent.Audit.Changes.TraceIds
      change SdrAgent.Agents.Changes.Replay

      change {SdrAgent.Audit.Changes.AppendEvent,
              event_type: "agents.decision.recorded",
              category: :decision,
              version_refs: {__MODULE__, :version_refs},
              links: [
                decision_id: :id,
                agent_run_id: :agent_run_id,
                model_invocation_id: :model_invocation_id,
                idempotency_key: :idempotency_key
              ]}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action(:record) do
      authorize_if SdrAgent.Agents.Checks.DecisionKindActor
    end

    policy action_type(:read) do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :kind, :atom do
      allow_nil? false
      constraints one_of: Map.keys(@kind_actors)
      public? true
    end

    attribute :mode, :atom do
      allow_nil? false
      constraints one_of: [:llm, :deterministic]
      public? true
    end

    attribute :subject_resource, :string, allow_nil?: false, public?: true
    attribute :subject_id, :uuid, allow_nil?: false, public?: true

    attribute :input_refs, {:array, SdrAgent.Agents.Decision.InputRef},
      allow_nil?: false,
      default: [],
      public?: true

    attribute :inputs_sha256, :binary, allow_nil?: false, writable?: false, public?: true
    attribute :rule_id, :string, public?: true
    attribute :rule_version, :string, public?: true

    attribute :output_pointer, :string,
      public?: true,
      constraints: [trim?: false, allow_empty?: true]

    attribute :outcome, :string, allow_nil?: false, public?: true
    attribute :outcome_detail, :map, allow_nil?: false, default: %{}, public?: true
    attribute :rationale, :string, public?: true

    attribute :confidence, :float do
      constraints min: 0.0, max: 1.0
      public? true
    end

    attribute :decided_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      default &SdrAgent.Clock.utc_now/0
      public? true
    end

    attribute :idempotency_key, :string, allow_nil?: false, public?: true

    attribute :replay_sha256, :binary do
      description "Canonical hash of every decision-defining field (SdrAgent.Agents.Changes.Replay)."
      allow_nil? false
      writable? false
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
  end

  relationships do
    belongs_to :tenant, SdrAgent.Audit.Tenant do
      allow_nil? false
      public? true
    end

    belongs_to :agent_run, SdrAgent.Agents.AgentRun do
      attribute_writable? true
      public? true
    end

    belongs_to :model_invocation, SdrAgent.Agents.ModelInvocation do
      attribute_writable? true
      public? true
    end
  end

  identities do
    identity :unique_idempotency_key, [:tenant_id, :idempotency_key]
  end

  @doc "Kinds the model may never decide (spec §8)."
  def protected_kinds, do: @protected_kinds

  @doc "System actor types allowed to record each kind."
  def kind_actors, do: @kind_actors

  @doc """
  Idempotency key derived per S2 from the run (or the actor, when there is
  no run), kind, subject, model invocation and output pointer — so
  re-processing the same output is a no-op.
  """
  def idempotency_key(attrs, actor) do
    origin =
      case attrs[:agent_run_id] do
        nil -> actor_origin(actor)
        run_id -> "run:#{run_id}"
      end

    [
      origin,
      attrs[:kind],
      attrs[:subject_resource],
      attrs[:subject_id],
      attrs[:model_invocation_id],
      attrs[:output_pointer]
    ]
    |> Canonical.sha256()
    |> Base.encode16(case: :lower)
  end

  defp actor_origin(%SdrAgent.Actor{type: type, id: id}), do: "actor:#{type}:#{id}"
  defp actor_origin(%{id: id}), do: "actor:user:#{id}"
  defp actor_origin(_actor), do: "actor:anonymous"

  @doc "Version refs recorded on the decision's audit event."
  def version_refs(%{rule_id: nil}), do: %{}

  def version_refs(%{rule_id: rule_id, rule_version: version}),
    do: %{policy_rules: %{rule_id => version}}

  @doc false
  def __sdr_audited__, do: true
end
