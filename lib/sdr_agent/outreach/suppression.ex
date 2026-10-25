defmodule SdrAgent.Outreach.Suppression do
  @moduledoc """
  A deterministic do-not-contact entry, checked before every enrollment and
  every send (S2 row Suppression; spec §8: the model never decides legal
  suppression).

  Attributes: `scope` (`:email` or `:domain`), `value` (normalised: trimmed,
  lowercase; unique per tenant and scope), `reason` (`unsubscribe_link`,
  `unsubscribe_reply`, `hard_bounce`, `complaint`, `manual`), the source
  matching the reason (`created_by_user_id` for manual; `decision_id` and
  `reply_id` for unsubscribe_reply; `webhook_event_id` for unsubscribe_link
  and complaint; `delivery_operation_id` for hard_bounce — DB checks),
  `effective_at`.

  APPEND-ONLY and monotonic: no update, destroy or lift exists. Creating a
  suppression that already exists returns the stored row with no event and
  no side effects. A new suppression, in the same transaction
  (`SdrAgent.Outreach.Changes.ApplySuppression`): stops the matching
  contacts' open leads and active/paused enrollments, invalidates their
  granted approvals and cancels their pending-review or queued drafts.

  Actions: `:manual` (ADM; the creator is recorded), `:seed` (SEED,
  dev/test only), `:from_webhook` (WHK, S9: unsubscribe link, unsubscribe
  reply by the deterministic `unsubscribe_rule` Decision, hard bounce,
  complaint — always naming the WebhookEvent), `:from_classification` (AGT,
  S9b: an LLM `reply_classification` of `unsubscribe` may only *add* the
  reply's `unsubscribe_reply` suppression). Reads: ADM, REV, AUR, AGT, DLV, WHK, AUD, SEED;
  SCH only `:followup_matching`, its own tenant's covering rows (D-206). Audited:
  `outreach.suppression.created`.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Outreach,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Expr

  alias SdrAgent.Audit.Changes.AppendEvent
  alias SdrAgent.Audit.Checks
  alias SdrAgent.Outreach.Changes
  alias SdrAgent.Outreach.Checks.FollowupSuppressionRead
  alias SdrAgent.Outreach.Preparations.FollowupTenantScope
  alias SdrAgent.Outreach.SuppressionMatch

  @reasons [:unsubscribe_link, :unsubscribe_reply, :hard_bounce, :complaint, :manual]
  @event [event_type: "outreach.suppression.created", category: :domain_change]

  postgres do
    table "suppressions"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :created_by, on_delete: :restrict
      reference :decision, on_delete: :restrict
      reference :delivery_operation, on_delete: :restrict
      reference :reply, on_delete: :restrict
      reference :webhook_event, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "suppressions_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :scope, "suppressions_scope",
        check: SdrAgent.Audit.SQL.one_of("scope", [:email, :domain])

      check_constraint :reason, "suppressions_reason",
        check: SdrAgent.Audit.SQL.one_of("reason", @reasons)

      check_constraint :value, "suppressions_value_normalised",
        check: "value::text = lower(btrim(value::text)) AND value::text <> ''"

      check_constraint :decision_id, "suppressions_reply_source",
        check:
          "reason <> 'unsubscribe_reply' OR (decision_id IS NOT NULL AND reply_id IS NOT NULL)"

      check_constraint :delivery_operation_id, "suppressions_bounce_source",
        check: "reason <> 'hard_bounce' OR delivery_operation_id IS NOT NULL"

      check_constraint :webhook_event_id, "suppressions_link_source",
        check: "reason <> 'unsubscribe_link' OR webhook_event_id IS NOT NULL"

      check_constraint :webhook_event_id, "suppressions_complaint_source",
        check: "reason <> 'complaint' OR webhook_event_id IS NOT NULL"
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("suppressions") do
        statement name do
          up up_sql
          down down_sql
        end
      end
    end
  end

  actions do
    defaults [:read]

    read :matching do
      description "Suppressions covering `email`: the email itself or its domain."
      argument :email, :string, allow_nil?: false

      filter SuppressionMatch.filter(Ash.Expr.expr(^arg(:email)))

      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    read :followup_matching do
      description "SCH (the follow-up lookup only): the scheduler's own tenant's suppressions covering `email`: the email itself or its domain."
      argument :email, :string, allow_nil?: false

      # D-206: the tenant scope is a preparation — never a policy-filtered
      # `[]`, and never an actor template, which would fail an absent or
      # malformed actor with an invalid query before the strict policy
      # refuses it as Forbidden.
      prepare FollowupTenantScope
      filter SuppressionMatch.filter(Ash.Expr.expr(^arg(:email)))

      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    create :manual do
      description "ADM: suppress an email or domain (reason manual; the creator is recorded)."
      accept [:scope, :value]
      upsert? true
      upsert_identity :unique_value
      upsert_fields []
      upsert_condition Ash.Expr.expr(false)
      return_skipped_upsert? true
      change set_attribute(:reason, :manual)
      change {Changes.ActorUser, field: :created_by_user_id}
      change Changes.NormalizeSuppression
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change SdrAgent.Research.Changes.MarkExisting
      change {AppendEvent, @event}
      change Changes.ApplySuppression
    end

    create :from_webhook do
      description "WHK: a provider-signalled suppression (unsubscribe link or reply rule, hard bounce, complaint) with its sources."

      accept [
        :scope,
        :value,
        :reason,
        :decision_id,
        :reply_id,
        :webhook_event_id,
        :delivery_operation_id
      ]

      validate attribute_in(:reason, [
                 :unsubscribe_link,
                 :unsubscribe_reply,
                 :hard_bounce,
                 :complaint
               ])

      validate present(:webhook_event_id)
      upsert? true
      upsert_identity :unique_value
      upsert_fields []
      upsert_condition Ash.Expr.expr(false)
      return_skipped_upsert? true
      change Changes.NormalizeSuppression
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change {Changes.CheckSuppressionSource, decision_kind: :unsubscribe_rule}
      change SdrAgent.Research.Changes.MarkExisting
      change {AppendEvent, @event}
      change Changes.ApplySuppression
    end

    create :from_classification do
      description "AGT: ensure the unsubscribe_reply suppression of a reply the model classified as unsubscribe (add-only)."
      accept [:scope, :value, :decision_id, :reply_id]
      require_attributes [:decision_id, :reply_id]
      upsert? true
      upsert_identity :unique_value
      upsert_fields []
      upsert_condition Ash.Expr.expr(false)
      return_skipped_upsert? true
      change set_attribute(:reason, :unsubscribe_reply)
      change Changes.NormalizeSuppression
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change {Changes.CheckSuppressionSource, decision_kind: :reply_classification}
      change SdrAgent.Research.Changes.MarkExisting
      change {AppendEvent, @event}
      change Changes.ApplySuppression
    end

    create :seed do
      description "SEED (dev/test only): a fixture suppression (reason manual) with a fixture id."
      accept [:id, :scope, :value]
      upsert? true
      upsert_identity :unique_value
      upsert_fields []
      upsert_condition Ash.Expr.expr(false)
      return_skipped_upsert? true
      change set_attribute(:reason, :manual)
      change Changes.NormalizeSuppression
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change SdrAgent.Research.Changes.MarkExisting
      change {AppendEvent, @event}
      change Changes.ApplySuppression
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action(:manual) do
      authorize_if {Checks.ActorRole, roles: [:admin]}
    end

    policy action(:seed) do
      authorize_if Checks.SeedingAllowed
    end

    policy action(:from_webhook) do
      authorize_if {Checks.ActorType, types: [:webhook_ingestor]}
    end

    policy action(:from_classification) do
      authorize_if {Checks.ActorType, types: [:agent_runtime]}
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer, :auditor]}

      authorize_if {Checks.ActorType,
                    types: [
                      :agent_runtime,
                      :delivery_worker,
                      :webhook_ingestor,
                      :auditor_cli,
                      :seeder
                    ]}

      # SCH: `:followup_matching` only (the check names the action).
      authorize_if FollowupSuppressionRead
    end

    # Strict (D-206): the follow-up scheduler's tenant-bound lookup and no
    # one else — every other caller is refused as Forbidden, never read as
    # empty (precedent: ModelProfileSetting `:lock_for_transition`).
    policy action(:followup_matching) do
      access_type :strict
      authorize_if FollowupSuppressionRead
    end
  end

  attributes do
    uuid_v7_primary_key :id, writable?: true

    attribute :scope, :atom do
      allow_nil? false
      constraints one_of: [:email, :domain]
      public? true
    end

    attribute :value, :ci_string, allow_nil?: false, public?: true

    attribute :reason, :atom do
      allow_nil? false
      constraints one_of: @reasons
      public? true
    end

    attribute :effective_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      default &SdrAgent.Clock.utc_now/0
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

    belongs_to :created_by, SdrAgent.Accounts.User do
      source_attribute :created_by_user_id
      attribute_writable? false
      public? true
    end

    belongs_to :decision, SdrAgent.Agents.Decision do
      attribute_writable? true
      public? true
    end

    belongs_to :delivery_operation, SdrAgent.Outreach.DeliveryOperation do
      attribute_writable? true
      public? true
    end

    belongs_to :reply, SdrAgent.Outreach.Reply do
      attribute_writable? true
      public? true
    end

    belongs_to :webhook_event, SdrAgent.Operations.WebhookEvent do
      attribute_writable? true
      public? true
    end
  end

  identities do
    identity :unique_value, [:tenant_id, :scope, :value]
  end

  @doc "The suppression reasons (S2)."
  def reasons, do: @reasons

  @doc false
  def __sdr_audited__, do: true
end
