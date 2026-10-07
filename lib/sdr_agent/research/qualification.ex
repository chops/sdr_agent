defmodule SdrAgent.Research.Qualification do
  @moduledoc """
  A validated QualificationResult (spec §9) for one lead against one ICP
  version (S2 row Qualification). Created in S5, populated by S7.

  Attributes: `lead_id`, `icp_definition_id` (Sales), `agent_run_id`,
  `decision_id` (Agents), `source` (`:agent`, `:human_override`),
  `qualified`, `score` (0..100), embedded `criteria`
  (`SdrAgent.Research.QualificationCriteria`), `confidence` (0..1),
  `reason`, `output_schema_version`, `supersedes_id`, `created_by_user_id`.
  Cited claims: `SdrAgent.Research.QualificationEvidence`, created in the
  same transaction from argument `evidence_claim_ids`.

  APPEND-ONLY with supersedes lineage (subject = lead): one root per lead,
  each row superseded at most once, the current row is the one with no
  successor (`:current`), and every new qualification of a lead must
  supersede the current one. `qualified: true` needs at least one cited
  accepted claim of the same lead (`SdrAgent.Research.Changes.QualificationRules`).

    * `:record` (AGT) — agent source: an LLM qualification Decision of the
      same run with a completed, valid model invocation; the lead must be
      qualifying and moves to qualified/disqualified in the same transaction;
    * `:override` (ADM, REV) — human override: supersedes the current row,
      records the acting user and a reason, cites the superseded row's
      decision, and leaves the lead's status alone.

  Audited: `research.qualification.recorded` (with the cited claim ids).
  Reads: ADM, REV, AUR, AGT, AUD.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Research,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Changes.AppendEvent
  alias SdrAgent.Audit.Checks
  alias SdrAgent.Research.Changes

  @result [
    :lead_id,
    :icp_definition_id,
    :qualified,
    :score,
    :criteria,
    :confidence,
    :reason,
    :output_schema_version,
    :supersedes_id
  ]
  @event [
    event_type: "research.qualification.recorded",
    category: :domain_change,
    arguments: [:evidence_claim_ids],
    links: [decision_id: :decision_id, agent_run_id: :agent_run_id]
  ]

  postgres do
    table "qualifications"
    repo SdrAgent.Repo

    identity_wheres_to_sql unique_root: "supersedes_id IS NULL",
                           unique_supersedes: "supersedes_id IS NOT NULL"

    references do
      reference :tenant, on_delete: :restrict
      reference :lead, on_delete: :restrict
      reference :icp_definition, on_delete: :restrict
      reference :agent_run, on_delete: :restrict
      reference :decision, on_delete: :restrict
      reference :supersedes, on_delete: :restrict
      reference :created_by_user, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "qualifications_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :score, "qualifications_score_range", check: "score >= 0 AND score <= 100"

      check_constraint :confidence, "qualifications_confidence_range",
        check: "confidence >= 0 AND confidence <= 1"

      check_constraint :source, "qualifications_source_provenance",
        check:
          "(source = 'agent' AND agent_run_id IS NOT NULL) OR " <>
            "(source = 'human_override' AND created_by_user_id IS NOT NULL " <>
            "AND supersedes_id IS NOT NULL)"
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("qualifications") do
        statement name do
          up up_sql
          down down_sql
        end
      end
    end
  end

  actions do
    defaults [:read]

    read :current do
      description "The current (unsuperseded) qualification of a lead, if any."
      get? true
      argument :lead_id, :uuid, allow_nil?: false
      filter expr(lead_id == ^arg(:lead_id) and not exists(successors, true))
    end

    create :record do
      description "AGT: record an agent qualification and move the lead in the same transaction."
      accept [:agent_run_id, :decision_id | @result]
      argument :evidence_claim_ids, {:array, :uuid}, allow_nil?: false, default: []
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change {SdrAgent.Audit.Changes.Supersedes, subject: [:tenant_id, :lead_id]}
      change {Changes.QualificationRules, source: :agent}
      change {Changes.RecordOutcome, transition_lead?: true}
      change {AppendEvent, @event}
    end

    create :override do
      description "ADM, REV: override the current qualification of a lead (with a reason)."
      accept @result
      require_attributes [:supersedes_id, :reason]
      argument :evidence_claim_ids, {:array, :uuid}, allow_nil?: false, default: []
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change {SdrAgent.Audit.Changes.Supersedes, subject: [:tenant_id, :lead_id]}
      change {Changes.QualificationRules, source: :human_override}
      change {Changes.RecordOutcome, transition_lead?: false}
      change {AppendEvent, @event}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action(:record) do
      authorize_if {Checks.ActorType, types: [:agent_runtime]}
    end

    policy action(:override) do
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer]}
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer, :auditor]}
      authorize_if {Checks.ActorType, types: [:agent_runtime, :auditor_cli]}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :source, :atom do
      allow_nil? false
      writable? false
      constraints one_of: [:agent, :human_override]
      public? true
    end

    attribute :qualified, :boolean, allow_nil?: false, public?: true

    attribute :score, :integer do
      allow_nil? false
      constraints min: 0, max: 100
      public? true
    end

    attribute :criteria, SdrAgent.Research.QualificationCriteria,
      allow_nil?: false,
      public?: true

    attribute :confidence, :float do
      allow_nil? false
      constraints min: 0.0, max: 1.0
      public? true
    end

    attribute :reason, :string, allow_nil?: false, public?: true
    attribute :output_schema_version, :string, allow_nil?: false, public?: true
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

    belongs_to :lead, SdrAgent.Sales.Lead do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :icp_definition, SdrAgent.Sales.IcpDefinition do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :agent_run, SdrAgent.Agents.AgentRun do
      attribute_writable? true
      public? true
    end

    belongs_to :decision, SdrAgent.Agents.Decision do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :supersedes, __MODULE__ do
      attribute_writable? true
      public? true
    end

    belongs_to :created_by_user, SdrAgent.Accounts.User do
      attribute_writable? false
      public? true
    end

    has_many :successors, __MODULE__ do
      destination_attribute :supersedes_id
      public? true
    end

    has_many :evidence, SdrAgent.Research.QualificationEvidence, public?: true
  end

  identities do
    identity :unique_root, [:lead_id], where: expr(is_nil(supersedes_id))
    identity :unique_supersedes, [:supersedes_id], where: expr(not is_nil(supersedes_id))
  end

  @doc false
  def __sdr_audited__, do: true
end
