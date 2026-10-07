defmodule SdrAgent.Outreach.DraftRevision do
  @moduledoc """
  One immutable content version of a Draft — what a human approves (S2 row
  DraftRevision; ADR-0002).

  Attributes: `draft_id`, `revision_number` (parent + 1; unique per draft),
  `parent_revision_id`, `author_type` (`:agent` | `:human`),
  `author_user_id`, `agent_run_id`, `decision_id` (the `draft_proposal`
  Decision), `model_invocation_id`, `subject` (1..200), `body_text`,
  `angle`, `cta`, `risk_flags`, `content_sha256` (canonical
  `{subject, body_text}`, computed server-side), `canonicalization_version`,
  `ai_baseline_revision_id` (the latest agent revision a human revision
  descends from), `diff_from_parent`, `diff_from_ai_baseline`
  (`SdrAgent.Outreach.Diff`).

  Provenance: an agent revision names its run and an `llm` `draft_proposal`
  Decision of that run (and that decision's ModelInvocation); a human
  revision names its author and stores both diffs.

  APPEND-ONLY (trigger). Created only inside a Draft `:propose` or `:edit`
  (private `SdrAgent.Outreach.Checks.InternalWrite` marker), together with
  its `RevisionCitation`s, whose rows the event payload lists. Reads: ADM,
  REV, AUR, AGT, DLV, AUD. Audited: `outreach.revision.created`.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Outreach,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Checks
  alias SdrAgent.Outreach.Changes
  alias SdrAgent.Outreach.Checks.InternalWrite

  postgres do
    table "draft_revisions"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :draft, on_delete: :restrict
      reference :parent_revision, on_delete: :restrict
      reference :ai_baseline_revision, on_delete: :restrict
      reference :author_user, on_delete: :restrict
      reference :agent_run, on_delete: :restrict
      reference :decision, on_delete: :restrict
      reference :model_invocation, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "draft_revisions_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :content_sha256, "draft_revisions_content_sha256_length",
        check: "octet_length(content_sha256) = 32"

      check_constraint :author_type, "draft_revisions_provenance",
        check:
          "(author_type = 'agent' AND agent_run_id IS NOT NULL AND decision_id IS NOT NULL " <>
            "AND author_user_id IS NULL) OR " <>
            "(author_type = 'human' AND author_user_id IS NOT NULL AND parent_revision_id IS NOT NULL)"

      check_constraint :revision_number, "draft_revisions_first_has_no_parent",
        check: "(revision_number = 1) = (parent_revision_id IS NULL)"
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("draft_revisions") do
        statement name do
          up up_sql
          down down_sql
        end
      end
    end
  end

  actions do
    defaults [:read]

    create :create do
      description "Inside a Draft propose/edit only: insert one revision and its citations."

      accept [
        :id,
        :draft_id,
        :revision_number,
        :parent_revision_id,
        :author_type,
        :author_user_id,
        :agent_run_id,
        :decision_id,
        :model_invocation_id,
        :subject,
        :body_text,
        :angle,
        :cta,
        :risk_flags,
        :ai_baseline_revision_id,
        :diff_from_parent,
        :diff_from_ai_baseline
      ]

      argument :citations, {:array, :map}, default: []
      change SdrAgent.Audit.Changes.SetTenant
      change Changes.RevisionRules
      change SdrAgent.Audit.Changes.TraceIds

      change {SdrAgent.Audit.Changes.AppendEvent,
              event_type: "outreach.revision.created",
              category: :domain_change,
              arguments: [:citations],
              links: [
                agent_run_id: :agent_run_id,
                decision_id: :decision_id,
                model_invocation_id: :model_invocation_id
              ]}

      change Changes.InsertCitations
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action(:create) do
      forbid_unless InternalWrite
      authorize_if {Checks.ActorType, types: [:agent_runtime]}
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer]}
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer, :auditor]}
      authorize_if {Checks.ActorType, types: [:agent_runtime, :delivery_worker, :auditor_cli]}
    end
  end

  attributes do
    uuid_v7_primary_key :id, writable?: true

    attribute :revision_number, :integer do
      allow_nil? false
      constraints min: 1
      public? true
    end

    attribute :author_type, :atom do
      allow_nil? false
      constraints one_of: [:agent, :human]
      public? true
    end

    attribute :subject, :string do
      allow_nil? false
      constraints min_length: 1, max_length: 200, trim?: false
      public? true
    end

    attribute :body_text, :string do
      allow_nil? false
      constraints trim?: false
      public? true
    end

    attribute :angle, :string, public?: true
    attribute :cta, :string, public?: true
    attribute :risk_flags, {:array, :string}, allow_nil?: false, default: [], public?: true
    attribute :content_sha256, :binary, allow_nil?: false, writable?: false, public?: true

    attribute :canonicalization_version, :string,
      allow_nil?: false,
      writable?: false,
      public?: true

    attribute :diff_from_parent, :string, public?: true, constraints: [trim?: false]
    attribute :diff_from_ai_baseline, :string, public?: true, constraints: [trim?: false]
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

    belongs_to :draft, SdrAgent.Outreach.Draft do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :parent_revision, __MODULE__ do
      attribute_writable? true
      public? true
    end

    belongs_to :ai_baseline_revision, __MODULE__ do
      attribute_writable? true
      public? true
    end

    belongs_to :author_user, SdrAgent.Accounts.User do
      attribute_writable? true
      public? true
    end

    belongs_to :agent_run, SdrAgent.Agents.AgentRun do
      attribute_writable? true
      public? true
    end

    belongs_to :decision, SdrAgent.Agents.Decision do
      attribute_writable? true
      public? true
    end

    belongs_to :model_invocation, SdrAgent.Agents.ModelInvocation do
      attribute_writable? true
      public? true
    end

    has_many :citations, SdrAgent.Outreach.RevisionCitation, public?: true
  end

  identities do
    identity :unique_number, [:draft_id, :revision_number]
  end

  @doc false
  def __sdr_audited__, do: true
end
