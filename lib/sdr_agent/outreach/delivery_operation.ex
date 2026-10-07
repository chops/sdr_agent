defmodule SdrAgent.Outreach.DeliveryOperation do
  @moduledoc """
  The transactional outbox entry for one approved send (S2 row
  DeliveryOperation; spec §14).

  Attributes: `idempotency_key` (`"delivery:" <> approval_id`, unique per
  tenant), `approval_id` (1:1), the binding copied from the approval
  (`draft_id`, `draft_revision_id`, `revision_content_sha256`,
  `recipient_contact_id`, `recipient_email`, `campaign_id`) plus
  `enrollment_id`; `provider` (`:capture` only — `providers/0`),
  `provider_message_id`, `send_quota_date`, `state`, `attempt_count`,
  `max_attempts` (3), `not_before`, `requested_at`, `attempting_at`,
  `accepted_at`, `confirmed_at`, `unknown_since`, `rendered_sha256` (the
  exact RFC 5322 bytes, a Payload), `footer_template_version`, `last_error`,
  `last_decision_id`, `attention_failure_id`.

  Lifecycle (`transitions/0`; driven by `SdrAgent.Outreach.Delivery`):
  pending, failed_retryable → attempting (`:claim`, DLV, after the send gate
  passes; the first claim also consumes the approval and a quota unit);
  attempting → accepted | unknown | failed_retryable | failed_permanent (T)
  (DLV); unknown → accepted | failed_retryable | failed_permanent (REC,
  with a `delivery_reconciliation` Decision — never a blind resend);
  accepted → delivered (T) | bounced (T) (WHK, S9); pending,
  failed_retryable → cancelled (T) (gate refusal, approval revoke,
  suppression); failed_retryable → cancelled (T) (`:cancel_retry`, ADM/REV,
  guarded). `:defer` keeps pending/failed_retryable and sets `not_before`
  (quiet hours, daily cap). Entering unknown opens a `reconciliation_required`
  Failure and entering failed_permanent or bounced a `delivery_failed` one,
  in the same transaction; reconciling an unknown delivery resolves its
  Failure (a reconciliation that ends permanently keeps it as the attention
  item).

  Created only by the Approval grant (`:request`, private
  `SdrAgent.Outreach.Checks.InternalWrite` marker). Binding columns never
  change, terminal rows never change at all, and nothing is deleted
  (trigger). Reads: ADM, REV, AUR, AGT, DLV, REC, WHK, SCH, AUD. Every write
  appends an AuditEvent (`outreach.delivery.*`).
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Outreach,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Changes.AppendEvent
  alias SdrAgent.Audit.Changes.Stamp
  alias SdrAgent.Audit.Changes.Transition
  alias SdrAgent.Audit.Checks
  alias SdrAgent.Operations.Changes.OpenAttention
  alias SdrAgent.Operations.Changes.ResolveAttention
  alias SdrAgent.Outreach.Checks.InternalWrite

  @providers [:capture]
  @states [
    :pending,
    :attempting,
    :accepted,
    :unknown,
    :failed_retryable,
    :failed_permanent,
    :delivered,
    :bounced,
    :cancelled
  ]
  @terminal [:failed_permanent, :delivered, :bounced, :cancelled]
  @mutable [
    :state,
    :attempt_count,
    :not_before,
    :attempting_at,
    :accepted_at,
    :confirmed_at,
    :unknown_since,
    :provider_message_id,
    :send_quota_date,
    :rendered_sha256,
    :footer_template_version,
    :last_error,
    :last_decision_id,
    :attention_failure_id,
    :updated_at
  ]
  @transitions [
    {:claim, [:pending, :failed_retryable], :attempting},
    {:record_accepted, [:attempting], :accepted},
    {:record_unknown, [:attempting], :unknown},
    {:record_retryable, [:attempting], :failed_retryable},
    {:record_failed, [:attempting], :failed_permanent},
    {:reconcile_accepted, [:unknown], :accepted},
    {:reconcile_retryable, [:unknown], :failed_retryable},
    {:reconcile_failed, [:unknown], :failed_permanent},
    {:mark_delivered, [:accepted], :delivered},
    {:mark_bounced, [:accepted], :bounced},
    {:cancel, [:pending, :failed_retryable], :cancelled},
    {:cancel_retry, [:failed_retryable], :cancelled}
  ]
  @delivery_event [
    category: :delivery,
    previous: [:state],
    links: [idempotency_key: :idempotency_key, decision_id: :last_decision_id]
  ]

  postgres do
    table "delivery_operations"
    repo SdrAgent.Repo

    identity_wheres_to_sql unique_provider_message: "provider_message_id IS NOT NULL"

    references do
      reference :tenant, on_delete: :restrict
      reference :approval, on_delete: :restrict
      reference :draft, on_delete: :restrict
      reference :draft_revision, on_delete: :restrict
      reference :enrollment, on_delete: :restrict
      reference :campaign, on_delete: :restrict
      reference :recipient_contact, on_delete: :restrict
      reference :last_decision, on_delete: :restrict
      reference :attention_failure, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "delivery_operations_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :state, "delivery_operations_state",
        check: SdrAgent.Audit.SQL.one_of("state", @states)

      check_constraint :provider, "delivery_operations_capture_only",
        check: SdrAgent.Audit.SQL.one_of("provider", @providers)

      check_constraint :attempt_count, "delivery_operations_attempts",
        check: "attempt_count >= 0 AND attempt_count <= max_attempts"

      check_constraint :provider_message_id, "delivery_operations_accepted_has_message_id",
        check:
          "state NOT IN ('accepted', 'delivered', 'bounced') OR provider_message_id IS NOT NULL"
    end

    custom_statements do
      for {name, up_sql, down_sql} <-
            SdrAgent.Audit.SQL.terminal_immutable(
              "delivery_operations",
              @terminal,
              @mutable,
              "state"
            ) do
        statement name do
          up up_sql
          down down_sql
        end
      end

      {name, up_sql, down_sql} =
        SdrAgent.Audit.SQL.payload_fk("delivery_operations", :rendered_sha256)

      statement name do
        up up_sql
        down down_sql
        after_tables ["payloads"]
      end
    end
  end

  actions do
    defaults [:read]

    read :stale_attempts do
      description "Deliveries claimed before `before` and still attempting (crash recovery)."
      argument :before, :utc_datetime_usec, allow_nil?: false
      filter expr(state == :attempting and attempting_at < ^arg(:before))
      prepare build(sort: [attempting_at: :asc, id: :asc])
    end

    create :request do
      description "Inside an Approval grant only: the pending outbox entry for the approval."

      accept [
        :approval_id,
        :draft_id,
        :draft_revision_id,
        :enrollment_id,
        :campaign_id,
        :recipient_contact_id,
        :revision_content_sha256,
        :recipient_email,
        :idempotency_key
      ]

      change set_attribute(:provider, :capture)
      change {Stamp, fields: [:requested_at]}
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds

      change {AppendEvent,
              event_type: "outreach.delivery.requested",
              category: :delivery,
              links: [idempotency_key: :idempotency_key]}
    end

    update :defer do
      description "DLV: the gate deferred the send (quiet hours, daily cap) until `not_before`."
      require_atomic? false
      accept [:not_before, :last_decision_id]
      change get_and_lock_for_update()

      change {SdrAgent.Sales.Changes.RequireState,
              in: [:pending, :failed_retryable], attribute: :state}

      change {AppendEvent, event_type: "outreach.delivery.deferred", category: :delivery}
    end

    update :claim do
      description "DLV: the send gate passed: pending | failed_retryable → attempting."
      require_atomic? false
      accept [:last_decision_id, :send_quota_date, :rendered_sha256, :footer_template_version]
      change get_and_lock_for_update()

      change {Transition,
              from: [:pending, :failed_retryable],
              to: :attempting,
              locked?: true,
              attribute: :state}

      change SdrAgent.Outreach.Changes.CountAttempt
      change set_attribute(:not_before, nil)
      change {Stamp, fields: [:attempting_at]}
      change {AppendEvent, [event_type: "outreach.delivery.claimed"] ++ @delivery_event}
    end

    update :record_accepted do
      description "DLV: the adapter accepted the message: attempting → accepted."
      require_atomic? false
      accept [:provider_message_id]
      require_attributes [:provider_message_id]
      change get_and_lock_for_update()
      change {Transition, from: [:attempting], to: :accepted, locked?: true, attribute: :state}
      change {Stamp, fields: [:accepted_at]}
      change {AppendEvent, [event_type: "outreach.delivery.accepted"] ++ @delivery_event}
    end

    update :record_unknown do
      description "DLV, REC: the outcome is unknown: attempting → unknown (attention)."
      require_atomic? false
      accept [:last_error]
      change get_and_lock_for_update()
      change {Transition, from: [:attempting], to: :unknown, locked?: true, attribute: :state}
      change {Stamp, fields: [:unknown_since]}

      change {OpenAttention,
              class: :reconciliation_required,
              severity: :critical,
              message: {__MODULE__, :unknown_message},
              field: :attention_failure_id}

      change {AppendEvent, [event_type: "outreach.delivery.unknown"] ++ @delivery_event}
    end

    update :record_retryable do
      description "DLV: a retryable failure: attempting → failed_retryable (retry at `not_before`)."
      require_atomic? false
      accept [:last_error, :not_before]
      change get_and_lock_for_update()

      change {Transition,
              from: [:attempting], to: :failed_retryable, locked?: true, attribute: :state}

      change {AppendEvent, [event_type: "outreach.delivery.failed_retryable"] ++ @delivery_event}
    end

    update :record_failed do
      description "DLV: a permanent failure or exhausted retries: attempting → failed_permanent (T)."
      require_atomic? false
      accept [:last_error]
      change get_and_lock_for_update()

      change {Transition,
              from: [:attempting], to: :failed_permanent, locked?: true, attribute: :state}

      change {OpenAttention,
              class: :delivery_failed,
              severity: :critical,
              message: {__MODULE__, :failed_message},
              field: :attention_failure_id}

      change {AppendEvent, [event_type: "outreach.delivery.failed_permanent"] ++ @delivery_event}
    end

    update :reconcile_accepted do
      description "REC: reconciliation found the message accepted: unknown → accepted."
      require_atomic? false
      accept [:provider_message_id, :last_decision_id]
      require_attributes [:provider_message_id, :last_decision_id]
      change get_and_lock_for_update()
      change {Transition, from: [:unknown], to: :accepted, locked?: true, attribute: :state}
      change {Stamp, fields: [:accepted_at]}
      change {ResolveAttention, note: "delivery reconciled as accepted:"}

      change {AppendEvent,
              [event_type: "outreach.delivery.reconciled_accepted"] ++ @delivery_event}
    end

    update :reconcile_retryable do
      description "REC: reconciliation found nothing accepted: unknown → failed_retryable."
      require_atomic? false
      accept [:last_decision_id, :not_before]
      require_attributes [:last_decision_id]
      change get_and_lock_for_update()

      change {Transition,
              from: [:unknown], to: :failed_retryable, locked?: true, attribute: :state}

      change {ResolveAttention, note: "delivery reconciled as not accepted (retry):"}

      change {AppendEvent,
              [event_type: "outreach.delivery.reconciled_retryable"] ++ @delivery_event}
    end

    update :reconcile_failed do
      description "REC: nothing accepted and no attempt left: unknown → failed_permanent (T)."
      require_atomic? false
      accept [:last_decision_id, :last_error]
      require_attributes [:last_decision_id]
      change get_and_lock_for_update()

      change {Transition,
              from: [:unknown], to: :failed_permanent, locked?: true, attribute: :state}

      change {AppendEvent, [event_type: "outreach.delivery.reconciled_failed"] ++ @delivery_event}
    end

    update :mark_delivered do
      description "WHK (S9): the provider confirmed delivery: accepted → delivered (T)."
      require_atomic? false
      change get_and_lock_for_update()
      change {Transition, from: [:accepted], to: :delivered, locked?: true, attribute: :state}
      change {Stamp, fields: [:confirmed_at]}
      change {AppendEvent, [event_type: "outreach.delivery.delivered"] ++ @delivery_event}
    end

    update :mark_bounced do
      description "WHK (S9): the provider reported a bounce: accepted → bounced (T) (attention)."
      require_atomic? false
      accept [:last_error]
      change get_and_lock_for_update()
      change {Transition, from: [:accepted], to: :bounced, locked?: true, attribute: :state}
      change {Stamp, fields: [:confirmed_at]}

      change {OpenAttention,
              class: :delivery_failed,
              severity: :critical,
              message: {__MODULE__, :bounced_message},
              field: :attention_failure_id}

      change {AppendEvent, [event_type: "outreach.delivery.bounced"] ++ @delivery_event}
    end

    update :cancel do
      description "DLV (gate refusal) or inside a revoke/suppression: pending | failed_retryable → cancelled (T)."
      require_atomic? false
      accept [:last_error, :last_decision_id]
      change get_and_lock_for_update()

      change {Transition,
              from: [:pending, :failed_retryable],
              to: :cancelled,
              locked?: true,
              attribute: :state}

      change {AppendEvent, [event_type: "outreach.delivery.cancelled"] ++ @delivery_event}
    end

    update :cancel_retry do
      description "ADM, REV: stop a retryable delivery: failed_retryable → cancelled (T); the draft is cancelled."
      require_atomic? false
      change SdrAgent.Outreach.Changes.LockDraftFirst
      change get_and_lock_for_update()

      change {Transition,
              from: [:failed_retryable], to: :cancelled, locked?: true, attribute: :state}

      change {AppendEvent, [event_type: "outreach.delivery.retry_cancelled"] ++ @delivery_event}

      change {SdrAgent.Outreach.Changes.MoveDraft,
              action: :cancel, reason_text: "retry cancelled by an operator"}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action(:request) do
      authorize_if InternalWrite
    end

    policy action([:defer, :claim, :record_accepted, :record_retryable, :record_failed]) do
      authorize_if {Checks.ActorType, types: [:delivery_worker]}
    end

    policy action(:record_unknown) do
      authorize_if {Checks.ActorType, types: [:delivery_worker, :reconciler]}
    end

    policy action([:reconcile_accepted, :reconcile_retryable, :reconcile_failed]) do
      authorize_if {Checks.ActorType, types: [:reconciler]}
    end

    policy action([:mark_delivered, :mark_bounced]) do
      authorize_if {Checks.ActorType, types: [:webhook_ingestor]}
    end

    policy action(:cancel) do
      authorize_if {Checks.ActorType, types: [:delivery_worker]}
      authorize_if InternalWrite
    end

    policy action(:cancel_retry) do
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer]}
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer, :auditor]}

      authorize_if {Checks.ActorType,
                    types: [
                      :agent_runtime,
                      :delivery_worker,
                      :reconciler,
                      :webhook_ingestor,
                      :scheduler,
                      :auditor_cli
                    ]}
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :idempotency_key, :string, allow_nil?: false, public?: true
    attribute :revision_content_sha256, :binary, allow_nil?: false, public?: true
    attribute :recipient_email, :ci_string, allow_nil?: false, public?: true

    attribute :provider, :atom do
      allow_nil? false
      writable? false
      constraints one_of: @providers
      public? true
    end

    attribute :provider_message_id, :string, public?: true
    attribute :send_quota_date, :date, public?: true

    attribute :state, :atom do
      allow_nil? false
      default :pending
      writable? false
      constraints one_of: @states
      public? true
    end

    attribute :attempt_count, :integer do
      allow_nil? false
      default 0
      writable? false
      constraints min: 0
      public? true
    end

    attribute :max_attempts, :integer do
      allow_nil? false
      default 3
      writable? false
      constraints min: 1
      public? true
    end

    attribute :not_before, :utc_datetime_usec, public?: true
    attribute :requested_at, :utc_datetime_usec, writable?: false, public?: true
    attribute :attempting_at, :utc_datetime_usec, writable?: false, public?: true
    attribute :accepted_at, :utc_datetime_usec, writable?: false, public?: true
    attribute :confirmed_at, :utc_datetime_usec, writable?: false, public?: true
    attribute :unknown_since, :utc_datetime_usec, writable?: false, public?: true
    attribute :rendered_sha256, :binary, public?: true
    attribute :footer_template_version, :string, public?: true
    attribute :last_error, :map, public?: true
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

    belongs_to :approval, SdrAgent.Outreach.Approval do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :draft, SdrAgent.Outreach.Draft do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :draft_revision, SdrAgent.Outreach.DraftRevision do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :enrollment, SdrAgent.Sales.CampaignEnrollment do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :campaign, SdrAgent.Sales.Campaign do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :recipient_contact, SdrAgent.Sales.Contact do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :last_decision, SdrAgent.Agents.Decision do
      attribute_writable? true
      public? true
    end

    belongs_to :attention_failure, SdrAgent.Operations.Failure do
      attribute_writable? false
      public? true
    end

    has_many :receipts, SdrAgent.Outreach.DeliveryReceipt, public?: true
  end

  identities do
    identity :unique_idempotency_key, [:tenant_id, :idempotency_key]
    identity :unique_approval, [:approval_id]

    identity :unique_provider_message, [:tenant_id, :provider, :provider_message_id],
      where: expr(not is_nil(provider_message_id))
  end

  @doc "The only delivery providers that exist (ADR-0001: no real delivery path)."
  def providers, do: @providers

  @doc "Declared lifecycle transitions `{action, from, to}` (ADR-0010)."
  def transitions, do: @transitions

  @doc false
  def unknown_message(changeset),
    do: "delivery outcome unknown, reconciliation required: #{reason(changeset)}"

  @doc false
  def failed_message(changeset), do: "delivery failed permanently: #{reason(changeset)}"

  @doc false
  def bounced_message(changeset), do: "delivery bounced: #{reason(changeset)}"

  defp reason(changeset) do
    case Ash.Changeset.get_attribute(changeset, :last_error) do
      %{"reason" => reason} -> reason
      %{reason: reason} -> reason
      _ -> "no detail"
    end
  end

  @doc false
  def __sdr_audited__, do: true
end
