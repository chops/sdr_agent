defmodule SdrAgent.Operations.WebhookEvent do
  @moduledoc """
  Every inbound webhook request, verified and deduplicated before any
  effect (S2 row WebhookEvent; spec §16, checklist 4.3).

  Attributes: `provider` (`:capture_sim`, the only simulated provider),
  `event_type` (`reply`, `unsubscribe`, `bounce`, `delivered`,
  `complaint`), `external_event_id`, `signature_verdict` (`valid`,
  `invalid`, `missing`, `stale`), `signature_key_id`, `signed_timestamp`,
  `raw_body_sha256` (the exact bytes are a Payload, stored first),
  `headers` (allowlisted, no secrets), `processing_status`, `processed_at`,
  `failure_id`, `received_at`.

  Dedupe identity: `(tenant_id, provider, external_event_id)` for *valid*
  events only, so a forged event cannot pre-claim a real event's id.

  Lifecycle (`transitions/0`): created `received` (`:receive`, valid) or
  `rejected` (T) (`:reject`, any other verdict — never processed; opens a
  `signature_invalid` Failure in the same transaction); received →
  processed (T), received → failed (opens a Failure), failed → processed
  (retry; resolves it). A duplicate valid `:receive` inserts no row and
  appends `webhook.duplicate_ignored` naming the original. Terminal rows
  never change, other rows change only their lifecycle columns, nothing is
  deleted (trigger).

  Writes: WHK only. Reads: ADM, REV, AUR, AUD, WHK. Audited:
  `webhook.received` (with the verdict), `webhook.processed`,
  `webhook.failed`, `webhook.duplicate_ignored`.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Operations,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Expr

  alias SdrAgent.Audit.Changes.AppendEvent
  alias SdrAgent.Audit.Changes.Stamp
  alias SdrAgent.Audit.Changes.Transition
  alias SdrAgent.Audit.Checks
  alias SdrAgent.Operations.Changes

  @event_types [:reply, :unsubscribe, :bounce, :delivered, :complaint]
  @verdicts [:valid, :invalid, :missing, :stale]
  @statuses [:received, :processed, :failed, :rejected]
  @transitions [
    {:mark_processed, [:received, :failed], :processed},
    {:mark_failed, [:received], :failed}
  ]
  @accepted [
    :provider,
    :event_type,
    :external_event_id,
    :signature_key_id,
    :signed_timestamp,
    :raw_body_sha256,
    :headers
  ]
  @received [event_type: "webhook.received", category: :domain_change]
  @lifecycle [category: :domain_change, previous: [:processing_status]]

  postgres do
    table "webhook_events"
    repo SdrAgent.Repo

    identity_wheres_to_sql unique_valid_event: "signature_verdict = 'valid'"

    references do
      reference :tenant, on_delete: :restrict
      reference :failure, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "webhook_events_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :provider, "webhook_events_provider",
        check: SdrAgent.Audit.SQL.one_of("provider", [:capture_sim])

      check_constraint :event_type, "webhook_events_event_type",
        check: SdrAgent.Audit.SQL.one_of("event_type", @event_types)

      check_constraint :signature_verdict, "webhook_events_verdict",
        check: SdrAgent.Audit.SQL.one_of("signature_verdict", @verdicts)

      check_constraint :processing_status, "webhook_events_status",
        check: SdrAgent.Audit.SQL.one_of("processing_status", @statuses)

      check_constraint :processing_status, "webhook_events_rejected_iff_not_valid",
        check: "(signature_verdict = 'valid') = (processing_status <> 'rejected')"
    end

    custom_statements do
      for {name, up_sql, down_sql} <-
            SdrAgent.Audit.SQL.terminal_immutable(
              "webhook_events",
              [:processed, :rejected],
              [:processing_status, :processed_at, :failure_id, :updated_at],
              "processing_status"
            ) do
        statement name do
          up up_sql
          down down_sql
        end
      end

      {name, up_sql, down_sql} =
        SdrAgent.Audit.SQL.payload_fk("webhook_events", :raw_body_sha256)

      statement name do
        up up_sql
        down down_sql
        after_tables ["payloads"]
      end
    end
  end

  actions do
    defaults [:read]

    create :receive do
      description "WHK: a validly signed event; a duplicate (same provider and id) returns the original."
      accept @accepted
      upsert? true
      upsert_identity :unique_valid_event
      upsert_fields []
      upsert_condition Ash.Expr.expr(false)
      return_skipped_upsert? true
      change set_attribute(:signature_verdict, :valid)
      change set_attribute(:processing_status, :received)
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change SdrAgent.Research.Changes.MarkExisting
      change {AppendEvent, @received}
      change Changes.AppendDuplicate
    end

    create :reject do
      description "WHK: an event whose signature is invalid, missing or stale — stored, never processed."
      accept [:signature_verdict | @accepted]
      validate attribute_does_not_equal(:signature_verdict, :valid)
      change set_attribute(:processing_status, :rejected)
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change Changes.OpenRejection
      change {AppendEvent, @received}
    end

    update :mark_processed do
      description "WHK: received | failed → processed (T); a failed event's Failure is resolved."
      require_atomic? false
      change get_and_lock_for_update()

      change {Transition,
              from: [:received, :failed],
              to: :processed,
              locked?: true,
              attribute: :processing_status}

      change {Stamp, fields: [:processed_at]}
      change {SdrAgent.Operations.Changes.ResolveAttention, note: "webhook event processed:"}
      change {AppendEvent, [event_type: "webhook.processed"] ++ @lifecycle}
    end

    update :mark_failed do
      description "WHK: received → failed, opening a Failure (operator attention)."
      require_atomic? false
      argument :class, :atom, allow_nil?: false, constraints: [one_of: [:validation_error]]
      argument :reason, :string, allow_nil?: false
      change get_and_lock_for_update()

      change {Transition,
              from: [:received], to: :failed, locked?: true, attribute: :processing_status}

      change {SdrAgent.Operations.Changes.OpenAttention,
              class: {:arg, :class},
              severity: :warning,
              message: {__MODULE__, :failed_message},
              field: :failure_id}

      change {AppendEvent,
              [event_type: "webhook.failed", arguments: [:class, :reason]] ++ @lifecycle}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action_type([:create, :update]) do
      authorize_if {Checks.ActorType, types: [:webhook_ingestor]}
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer, :auditor]}
      authorize_if {Checks.ActorType, types: [:webhook_ingestor, :auditor_cli]}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :provider, :atom do
      allow_nil? false
      constraints one_of: [:capture_sim]
      public? true
    end

    attribute :event_type, :atom do
      allow_nil? false
      constraints one_of: @event_types
      public? true
    end

    attribute :external_event_id, :string do
      allow_nil? false
      constraints max_length: 200
      public? true
    end

    attribute :signature_verdict, :atom do
      allow_nil? false
      constraints one_of: @verdicts
      public? true
    end

    attribute :signature_key_id, :string, public?: true
    attribute :signed_timestamp, :utc_datetime_usec, public?: true
    attribute :raw_body_sha256, :binary, allow_nil?: false, public?: true
    attribute :headers, :map, allow_nil?: false, default: %{}, public?: true

    attribute :processing_status, :atom do
      allow_nil? false
      writable? false
      constraints one_of: @statuses
      public? true
    end

    attribute :processed_at, :utc_datetime_usec, writable?: false, public?: true

    attribute :received_at, :utc_datetime_usec do
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

    belongs_to :failure, SdrAgent.Operations.Failure do
      attribute_writable? false
      public? true
    end
  end

  identities do
    identity :unique_valid_event, [:tenant_id, :provider, :external_event_id],
      where: expr(signature_verdict == :valid)
  end

  @doc "Webhook event types (S2)."
  def event_types, do: @event_types

  @doc "Declared lifecycle transitions `{action, from, to}` (ADR-0010)."
  def transitions, do: @transitions

  @doc false
  def failed_message(changeset),
    do: "webhook event not processed: #{Ash.Changeset.get_argument(changeset, :reason)}"

  @doc false
  def __sdr_audited__, do: true
end
