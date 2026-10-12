defmodule SdrAgent.Agents.ModelResultRelease do
  @moduledoc """
  The immutable release decision for one model output (R0-07 entity PASS at
  1da747a, section 2; REQ-07-5; ADR-0005 R0 amendment item 4, "Release
  evidence").

  Attributes: `model_invocation_id` (unique: one release per invocation),
  `disposition` (`:released | :withheld | :calibration`), `reason`,
  `wire_witness_link_id` (optional), `projection_version` and `method`
  (copied from that link's evaluated projection and method), `evidence_sha256`
  (lowercase hex; calibration latches only), `decided_at` and the trace ids.

  Allowed disposition/reason pairs (validated by
  `SdrAgent.Agents.Changes.ReleaseDecision`, backed by a check constraint):

    * `:released` ↔ `:reconciled`, with a link that is this invocation's
      current, reconciled primary link at decision time, leaving the
      invocation `reconciled` (`SdrAgent.Agents.Witness.status/1`), whose
      evidence names the invocation's CLI version and application digests,
      and whose exact tuple is on the shipped allowlist
      (`SdrAgent.Agents.Witness.allowlisted?/3`); the output is `:valid`;
    * `:withheld` ↔ `:witness_mismatch | :witness_missing | :witness_timeout
      | :store_unreadable | :gate_interrupted`;
    * `:calibration` ↔ `:calibration`: a quarantined evidence latch, never an
      output release — only under `SdrAgent.Agents.Checks.CalibrationContext`
      (test-seam builds), for an invocation of a `:proof` run of that
      profile in any terminal status, with `evidence_sha256`.

  `:released` and `:withheld` need a completed generation-2 ClaudeCLI
  invocation outside a `:proof` run. The invocation is never updated for
  its release.

  Relationships: belongs to Tenant, ModelInvocation (RESTRICT; composite FK
  `(model_invocation_id, tenant_id)` → `model_invocations (id, tenant_id)`)
  and optionally WireWitnessLink (RESTRICT; composite FK
  `(wire_witness_link_id, model_invocation_id)` → `wire_witness_links (id,
  model_invocation_id)`, so the link is this invocation's).

  APPEND-ONLY: a trigger rejects update, delete and truncate. `:decide` is
  an upsert on the invocation that never updates: an identical replay
  (same disposition, reason, link and evidence) returns the existing row
  with no new event; a conflicting one fails with
  `SdrAgent.Agents.Errors.ReleaseConflict`. Concurrent decides serialise on
  the unique index. A link superseded later leaves the release as the
  historical decision.

  `:decide`: AGT only (the facade gate step and run recovery,
  `SdrAgent.Agents.decide_result_release/2`). Reads: admin, auditor, AGT,
  REC, AUD and the audit kernel. Audited: `model.result.released |
  withheld | calibration`.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Expr

  alias SdrAgent.Audit.Changes.AppendEvent
  alias SdrAgent.Audit.Checks

  @dispositions [:released, :withheld, :calibration]
  @withheld_reasons [
    :witness_mismatch,
    :witness_missing,
    :witness_timeout,
    :store_unreadable,
    :gate_interrupted
  ]
  @reasons [:reconciled, :calibration | @withheld_reasons]
  @methods [:time_window, :propagated_id]
  @event [
    category: :model,
    links: [model_invocation_id: :model_invocation_id],
    context_links: [agent_run_id: :model_result_release_agent_run_id]
  ]

  postgres do
    table "model_result_releases"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :model_invocation, on_delete: :restrict
      reference :wire_witness_link, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "model_result_releases_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :disposition, "model_result_releases_disposition",
        check: SdrAgent.Audit.SQL.one_of("disposition", @dispositions)

      check_constraint :reason, "model_result_releases_reason",
        check: SdrAgent.Audit.SQL.one_of("reason", @reasons)

      check_constraint :method, "model_result_releases_method",
        check: "method IS NULL OR " <> SdrAgent.Audit.SQL.one_of("method", @methods)

      check_constraint :evidence_sha256, "model_result_releases_evidence_sha256",
        check: "evidence_sha256 IS NULL OR evidence_sha256 ~ '^[0-9a-f]{64}$'"

      check_constraint :disposition, "model_result_releases_pair",
        check:
          "(disposition = 'released' AND reason = 'reconciled' AND " <>
            "wire_witness_link_id IS NOT NULL AND projection_version IS NOT NULL AND " <>
            "method IS NOT NULL AND evidence_sha256 IS NULL) OR " <>
            "(disposition = 'withheld' AND " <>
            SdrAgent.Audit.SQL.one_of("reason", @withheld_reasons) <>
            " AND evidence_sha256 IS NULL) OR " <>
            "(disposition = 'calibration' AND reason = 'calibration' AND " <>
            "evidence_sha256 IS NOT NULL)"
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("model_result_releases") do
        statement name do
          up up_sql
          down down_sql
        end
      end

      # The invocation is of the release's tenant (target: the invocations'
      # (id, tenant_id) unique key).
      statement :model_result_releases_invocation_tenant_fkey do
        up "ALTER TABLE model_result_releases ADD CONSTRAINT " <>
             "model_result_releases_invocation_tenant_fkey " <>
             "FOREIGN KEY (model_invocation_id, tenant_id) " <>
             "REFERENCES model_invocations (id, tenant_id) ON DELETE RESTRICT"

        down "ALTER TABLE model_result_releases DROP CONSTRAINT " <>
               "model_result_releases_invocation_tenant_fkey"

        after_tables ["model_invocations"]
      end

      # The link, when given, is this invocation's (target: the links'
      # (id, model_invocation_id) unique key).
      statement :model_result_releases_link_invocation_fkey do
        up "ALTER TABLE model_result_releases ADD CONSTRAINT " <>
             "model_result_releases_link_invocation_fkey " <>
             "FOREIGN KEY (wire_witness_link_id, model_invocation_id) " <>
             "REFERENCES wire_witness_links (id, model_invocation_id) ON DELETE RESTRICT"

        down "ALTER TABLE model_result_releases DROP CONSTRAINT " <>
               "model_result_releases_link_invocation_fkey"

        after_tables ["wire_witness_links"]
      end
    end
  end

  actions do
    defaults [:read]

    create :decide do
      description "AGT: the one immutable release decision for a model output."

      accept [
        :model_invocation_id,
        :disposition,
        :reason,
        :wire_witness_link_id,
        :evidence_sha256
      ]

      upsert? true
      upsert_identity :unique_invocation
      upsert_fields []
      upsert_condition Ash.Expr.expr(false)
      return_skipped_upsert? true
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change SdrAgent.Agents.Changes.ReleaseDecision

      change {AppendEvent, [event_type: "model.result.released"] ++ @event},
        where: [attribute_equals(:disposition, :released)]

      change {AppendEvent, [event_type: "model.result.withheld"] ++ @event},
        where: [attribute_equals(:disposition, :withheld)]

      change {AppendEvent, [event_type: "model.result.calibration"] ++ @event},
        where: [attribute_equals(:disposition, :calibration)]
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action(:decide) do
      authorize_if {Checks.ActorType, types: [:agent_runtime]}
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorType, types: [:agent_runtime, :reconciler, :auditor_cli]}
      authorize_if {Checks.ActorRole, roles: [:admin, :auditor]}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :disposition, :atom do
      allow_nil? false
      constraints one_of: @dispositions
      public? true
    end

    attribute :reason, :atom do
      allow_nil? false
      constraints one_of: @reasons
      public? true
    end

    attribute :projection_version, :string, writable?: false, public?: true

    attribute :method, :atom do
      writable? false
      constraints one_of: @methods
      public? true
    end

    attribute :evidence_sha256, :string do
      constraints match: ~r/\A[0-9a-f]{64}\z/
      public? true
    end

    attribute :decided_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      default &SdrAgent.Clock.utc_now/0
      public? true
    end

    attribute :trace_id, :string, allow_nil?: false, public?: true
    attribute :span_id, :string, allow_nil?: false, public?: true
  end

  relationships do
    belongs_to :tenant, SdrAgent.Audit.Tenant do
      allow_nil? false
      public? true
    end

    belongs_to :model_invocation, SdrAgent.Agents.ModelInvocation do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :wire_witness_link, SdrAgent.Agents.WireWitnessLink do
      attribute_writable? true
      public? true
    end
  end

  identities do
    identity :unique_invocation, [:model_invocation_id]
  end

  @doc "The disposition values."
  def dispositions, do: @dispositions

  @doc "The reasons allowed with `:withheld`."
  def withheld_reasons, do: @withheld_reasons

  @doc "Whether `{disposition, reason}` is an allowed pair."
  def allowed_pair?(:released, :reconciled), do: true
  def allowed_pair?(:withheld, reason), do: reason in @withheld_reasons
  def allowed_pair?(:calibration, :calibration), do: true
  def allowed_pair?(_disposition, _reason), do: false

  @doc false
  def __sdr_audited__, do: true
end
