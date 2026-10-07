defmodule SdrAgent.Research.ResearchArtifact do
  @moduledoc """
  One retrieved source document that evidence is grounded in (S2 row
  ResearchArtifact; spec §10). Created in S5, populated by S7.

  Attributes: `lead_id` (Sales), `agent_run_id`, `tool_invocation_id`
  (Agents), `source_type`, `provider` (fixture/fake only), `source_url`
  (`fixture://…` or a reserved host), `retrieved_at`, `published_at`,
  `title`, `content_sha256` (→ Payload; the full content is stored verbatim,
  never truncated), `excerpt` (≤ 2000 characters, a substring of the
  content), `trust_level`, `freshness` (computed by the retrieving action),
  `metadata`.

  APPEND-ONLY (trigger). `:record` (AGT) is idempotent on
  `(lead_id, source_url, content_sha256)`: recording the same source again
  returns the stored row and appends no second event. Audited:
  `research.artifact.recorded`. Reads: ADM, REV, AUR, AGT, AUD.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Research,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Expr

  alias SdrAgent.Audit.Checks

  postgres do
    table "research_artifacts"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :lead, on_delete: :restrict
      reference :agent_run, on_delete: :restrict
      reference :tool_invocation, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "research_artifacts_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :excerpt, "research_artifacts_excerpt_length",
        check: "char_length(excerpt) <= 2000"

      check_constraint :content_sha256, "research_artifacts_content_sha256_length",
        check: "octet_length(content_sha256) = 32"
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("research_artifacts") do
        statement name do
          up up_sql
          down down_sql
        end
      end

      {name, up_sql, down_sql} =
        SdrAgent.Audit.SQL.payload_fk("research_artifacts", :content_sha256)

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
      description "AGT: record a retrieved source (idempotent on lead, URL and content hash)."

      accept [
        :lead_id,
        :agent_run_id,
        :tool_invocation_id,
        :source_type,
        :provider,
        :source_url,
        :retrieved_at,
        :published_at,
        :title,
        :excerpt,
        :trust_level,
        :freshness,
        :metadata
      ]

      argument :content, :string, allow_nil?: false, constraints: [trim?: false]
      argument :content_type, :string, default: "text/plain"
      upsert? true
      upsert_identity :unique_source
      upsert_fields []
      upsert_condition Ash.Expr.expr(false)
      return_skipped_upsert? true
      validate {SdrAgent.Sales.Validations.Reserved, attribute: :source_url, kind: :url}
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Research.Changes.StoreContent
      change SdrAgent.Audit.Changes.TraceIds
      change SdrAgent.Research.Changes.MarkExisting

      change {SdrAgent.Audit.Changes.AppendEvent,
              event_type: "research.artifact.recorded",
              category: :domain_change,
              links: [agent_run_id: :agent_run_id, tool_invocation_id: :tool_invocation_id]}
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

    attribute :source_type, :atom do
      allow_nil? false

      constraints one_of: [
                    :crm_record,
                    :company_website,
                    :web_page,
                    :search_result,
                    :news,
                    :people_data
                  ]

      public? true
    end

    attribute :provider, :atom do
      allow_nil? false
      constraints one_of: [:fake_crm, :fixture_search, :fixture_web]
      public? true
    end

    attribute :source_url, :string, allow_nil?: false, public?: true

    attribute :retrieved_at, :utc_datetime_usec do
      allow_nil? false
      default &SdrAgent.Clock.utc_now/0
      public? true
    end

    attribute :published_at, :utc_datetime_usec, public?: true
    attribute :title, :string, public?: true
    attribute :content_sha256, :binary, allow_nil?: false, writable?: false, public?: true

    attribute :excerpt, :string do
      allow_nil? false
      constraints max_length: 2000, trim?: false
      public? true
    end

    attribute :trust_level, :atom do
      allow_nil? false
      constraints one_of: [:high, :medium, :low, :unverified]
      public? true
    end

    attribute :freshness, :atom do
      allow_nil? false
      constraints one_of: [:current, :recent, :stale, :unknown]
      public? true
    end

    attribute :metadata, :map, allow_nil?: false, default: %{}, public?: true
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

    belongs_to :agent_run, SdrAgent.Agents.AgentRun do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :tool_invocation, SdrAgent.Agents.ToolInvocation do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    has_many :claims, SdrAgent.Research.EvidenceClaim, public?: true
  end

  identities do
    identity :unique_source, [:lead_id, :source_url, :content_sha256]
  end

  @doc false
  def __sdr_audited__, do: true
end
