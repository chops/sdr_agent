defmodule SdrAgent.Outreach.ReplyAssessment do
  @moduledoc """
  The classification of a reply (S2 row ReplyAssessment; spec §16).

  Attributes: `reply_id`, `classification` (`interested`, `objection`,
  `referral`, `not_now`, `unsubscribe`, `out_of_office`, `irrelevant`,
  `unknown`), `sentiment` (`positive`, `neutral`, `negative`), `intent`,
  `suggested_next_action` (`hand_off`, `nurture`, `stop`, `escalate`,
  `none`), `confidence` (0..1), `source` (`agent`, `human_override`),
  `agent_run_id`, `decision_id`, `model_invocation_id`, `reviewer_user_id`,
  `reason`, `supersedes_id`.

  APPEND-ONLY with supersedes lineage (subject = reply): the current
  assessment is the row with no successor (`:current`).

    * `:record` (AGT) — the agent's assessment: the cited Decision is an LLM
      `reply_classification` Decision of the same run about this reply whose
      invocation is the cited one and whose outcome is the classification
      (`SdrAgent.Outreach.Changes.AssessmentRules`). A classification of
      `unsubscribe` ensures the recipient's `unsubscribe_reply` Suppression
      in the same transaction, *before* the row and its event are written
      (lock order) — the model may only add a suppression, never lift one
      (an existing one is returned unchanged).

  No response is drafted for any classification (owner decision
  2026-10-06: classify + hand off). Human override (ADM, REV) is deferred:
  S2 gives REV no suppression source for an overridden `unsubscribe`.
  Reads: ADM, REV, AUR, AGT, AUD. Audited: `outreach.reply.assessed`.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Outreach,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Changes.AppendEvent
  alias SdrAgent.Audit.Checks

  @classifications [
    :interested,
    :objection,
    :referral,
    :not_now,
    :unsubscribe,
    :out_of_office,
    :irrelevant,
    :unknown
  ]
  @sentiments [:positive, :neutral, :negative]
  @next_actions [:hand_off, :nurture, :stop, :escalate, :none]

  postgres do
    table "reply_assessments"
    repo SdrAgent.Repo

    identity_wheres_to_sql unique_root: "supersedes_id IS NULL",
                           unique_supersedes: "supersedes_id IS NOT NULL"

    references do
      reference :tenant, on_delete: :restrict
      reference :reply, on_delete: :restrict
      reference :agent_run, on_delete: :restrict
      reference :decision, on_delete: :restrict
      reference :model_invocation, on_delete: :restrict
      reference :reviewer_user, on_delete: :restrict
      reference :supersedes, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "reply_assessments_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :classification, "reply_assessments_classification",
        check: SdrAgent.Audit.SQL.one_of("classification", @classifications)

      check_constraint :sentiment, "reply_assessments_sentiment",
        check: SdrAgent.Audit.SQL.one_of("sentiment", @sentiments)

      check_constraint :suggested_next_action, "reply_assessments_next_action",
        check: SdrAgent.Audit.SQL.one_of("suggested_next_action", @next_actions)

      check_constraint :confidence, "reply_assessments_confidence_range",
        check: "confidence >= 0 AND confidence <= 1"

      check_constraint :source, "reply_assessments_source_provenance",
        check:
          "(source = 'agent' AND agent_run_id IS NOT NULL AND decision_id IS NOT NULL " <>
            "AND model_invocation_id IS NOT NULL) OR " <>
            "(source = 'human_override' AND reviewer_user_id IS NOT NULL " <>
            "AND reason IS NOT NULL AND supersedes_id IS NOT NULL)"
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("reply_assessments") do
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
      description "The current (unsuperseded) assessment of each reply in `reply_ids`."
      argument :reply_ids, {:array, :uuid}, allow_nil?: false
      filter expr(reply_id in ^arg(:reply_ids) and not exists(successors, true))
    end

    create :record do
      description "AGT: the agent's assessment of a reply (an LLM reply_classification Decision)."

      accept [
        :reply_id,
        :classification,
        :sentiment,
        :intent,
        :suggested_next_action,
        :confidence,
        :reason,
        :agent_run_id,
        :decision_id,
        :model_invocation_id,
        :supersedes_id
      ]

      change set_attribute(:source, :agent)
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change {SdrAgent.Audit.Changes.Supersedes, subject: [:tenant_id, :reply_id]}
      change SdrAgent.Outreach.Changes.AssessmentRules

      change {AppendEvent,
              event_type: "outreach.reply.assessed",
              category: :domain_change,
              links: [decision_id: :decision_id, agent_run_id: :agent_run_id]}
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

    attribute :classification, :atom do
      allow_nil? false
      constraints one_of: @classifications
      public? true
    end

    attribute :sentiment, :atom do
      allow_nil? false
      constraints one_of: @sentiments
      public? true
    end

    attribute :intent, :string, public?: true

    attribute :suggested_next_action, :atom do
      allow_nil? false
      constraints one_of: @next_actions
      public? true
    end

    attribute :confidence, :float do
      allow_nil? false
      constraints min: 0.0, max: 1.0
      public? true
    end

    attribute :source, :atom do
      allow_nil? false
      writable? false
      constraints one_of: [:agent, :human_override]
      public? true
    end

    attribute :reason, :string, public?: true
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

    belongs_to :reply, SdrAgent.Outreach.Reply do
      allow_nil? false
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

    belongs_to :reviewer_user, SdrAgent.Accounts.User do
      attribute_writable? false
      public? true
    end

    belongs_to :supersedes, __MODULE__ do
      attribute_writable? true
      public? true
    end

    has_many :successors, __MODULE__ do
      destination_attribute :supersedes_id
      public? true
    end
  end

  identities do
    identity :unique_root, [:reply_id], where: expr(is_nil(supersedes_id))
    identity :unique_supersedes, [:supersedes_id], where: expr(not is_nil(supersedes_id))
  end

  @doc "Reply classifications (S2, spec §16)."
  def classifications, do: @classifications

  @doc false
  def __sdr_audited__, do: true
end
