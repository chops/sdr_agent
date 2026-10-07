defmodule SdrAgent.Research.EvidenceClaim do
  @moduledoc """
  One atomic fact extracted from an artifact, with its exact quote, that
  qualifications and drafts cite (S2 row EvidenceClaim). Created in S5,
  populated by S7.

  Attributes: `research_artifact_id`, `lead_id` (the artifact's lead),
  `claim`, `quote`, embedded `source_location`
  (`SdrAgent.Research.SourceLocation`), `confidence` (0..1), `quality`
  (`:accepted`, `:rejected` — from the evidence-quality Decision),
  `extraction_decision_id`, `model_invocation_id` (optional).

  APPEND-ONLY (trigger). `:record` (AGT) takes the artifact `content` and
  runs the deterministic grounding check (`SdrAgent.Research.Changes.GroundClaim`);
  a claim whose quote is not exactly the cited span is not persisted.
  Audited: `research.claim.recorded`. Reads: ADM, REV, AUR, AGT, AUD.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Research,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Checks

  postgres do
    table "evidence_claims"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :research_artifact, on_delete: :restrict
      reference :lead, on_delete: :restrict
      reference :extraction_decision, on_delete: :restrict
      reference :model_invocation, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "evidence_claims_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :confidence, "evidence_claims_confidence_range",
        check: "confidence >= 0 AND confidence <= 1"
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("evidence_claims") do
        statement name do
          up up_sql
          down down_sql
        end
      end
    end
  end

  actions do
    defaults [:read]

    create :record do
      description "AGT: record a claim whose quote is exactly the cited span of the artifact."

      accept [
        :research_artifact_id,
        :lead_id,
        :claim,
        :quote,
        :source_location,
        :confidence,
        :quality,
        :extraction_decision_id,
        :model_invocation_id
      ]

      argument :content, :string, allow_nil?: false, constraints: [trim?: false]
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Research.Changes.GroundClaim
      change SdrAgent.Audit.Changes.TraceIds

      change {SdrAgent.Audit.Changes.AppendEvent,
              event_type: "research.claim.recorded",
              category: :domain_change,
              links: [
                decision_id: :extraction_decision_id,
                model_invocation_id: :model_invocation_id
              ]}
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

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer, :auditor]}
      authorize_if {Checks.ActorType, types: [:agent_runtime, :auditor_cli]}
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :claim, :string, allow_nil?: false, public?: true
    attribute :quote, :string, allow_nil?: false, public?: true, constraints: [trim?: false]

    attribute :source_location, SdrAgent.Research.SourceLocation,
      allow_nil?: false,
      public?: true

    attribute :confidence, :float do
      allow_nil? false
      constraints min: 0.0, max: 1.0
      public? true
    end

    attribute :quality, :atom do
      allow_nil? false
      constraints one_of: [:accepted, :rejected]
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

    belongs_to :research_artifact, SdrAgent.Research.ResearchArtifact do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :lead, SdrAgent.Sales.Lead do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :extraction_decision, SdrAgent.Agents.Decision do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :model_invocation, SdrAgent.Agents.ModelInvocation do
      attribute_writable? true
      public? true
    end
  end

  @doc false
  def __sdr_audited__, do: true
end
