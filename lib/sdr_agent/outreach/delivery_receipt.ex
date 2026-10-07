defmodule SdrAgent.Outreach.DeliveryReceipt do
  @moduledoc """
  Evidence of a capture, an acceptance or a final outcome of a delivery,
  tied to its idempotency key (S2 row DeliveryReceipt; ADR-0002).

  Attributes: `delivery_operation_id`, `idempotency_key` (= the
  operation's), `kind` (`captured` — the capture adapter's own record of the
  exact message it took; `accepted` — the delivery worker's record of the
  acceptance; `reconciled` — reconciliation's; `delivered`, `bounced` — S9
  webhooks), `provider`, `provider_message_id`, `rendered_sha256` (= the
  operation's; the full RFC 5322 bytes are a Payload, so "the sent email" is
  reconstructable from Postgres), `response_sha256`, `received_at`. One
  receipt per operation and kind: recording a kind again returns the stored
  row with no second event (the capture adapter is idempotent on the key).

  APPEND-ONLY (trigger). Actors: DLV (`captured`, `accepted`), REC
  (`reconciled`), WHK (`delivered`, `bounced`, S9). Reads: ADM, REV, AUR,
  DLV, REC, WHK, AUD. Audited: `outreach.delivery.receipt_recorded`.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Outreach,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Expr

  alias SdrAgent.Audit.Checks

  @kinds [:captured, :accepted, :delivered, :bounced, :reconciled]

  postgres do
    table "delivery_receipts"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :delivery_operation, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "delivery_receipts_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :kind, "delivery_receipts_kind",
        check: SdrAgent.Audit.SQL.one_of("kind", @kinds)

      check_constraint :provider, "delivery_receipts_capture_only",
        check:
          SdrAgent.Audit.SQL.one_of("provider", SdrAgent.Outreach.DeliveryOperation.providers())
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("delivery_receipts") do
        statement name do
          up up_sql
          down down_sql
        end
      end

      {name, up_sql, down_sql} =
        SdrAgent.Audit.SQL.payload_fk("delivery_receipts", :rendered_sha256)

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
      description "DLV, REC (WHK in S9): record a receipt; idempotent per operation and kind."

      accept [
        :delivery_operation_id,
        :idempotency_key,
        :kind,
        :provider,
        :provider_message_id,
        :rendered_sha256,
        :response_sha256
      ]

      upsert? true
      upsert_identity :unique_kind
      upsert_fields []
      upsert_condition Ash.Expr.expr(false)
      return_skipped_upsert? true
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change SdrAgent.Research.Changes.MarkExisting

      change {SdrAgent.Audit.Changes.AppendEvent,
              event_type: "outreach.delivery.receipt_recorded",
              category: :delivery,
              links: [idempotency_key: :idempotency_key]}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action(:record) do
      authorize_if {Checks.ActorType, types: [:delivery_worker, :reconciler]}
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer, :auditor]}

      authorize_if {Checks.ActorType,
                    types: [:delivery_worker, :reconciler, :webhook_ingestor, :auditor_cli]}
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :idempotency_key, :string, allow_nil?: false, public?: true

    attribute :kind, :atom do
      allow_nil? false
      constraints one_of: @kinds
      public? true
    end

    attribute :provider, :atom do
      allow_nil? false
      constraints one_of: [:capture]
      public? true
    end

    attribute :provider_message_id, :string, allow_nil?: false, public?: true
    attribute :rendered_sha256, :binary, allow_nil?: false, public?: true
    attribute :response_sha256, :binary, public?: true

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
  end

  relationships do
    belongs_to :tenant, SdrAgent.Audit.Tenant do
      allow_nil? false
      public? true
    end

    belongs_to :delivery_operation, SdrAgent.Outreach.DeliveryOperation do
      allow_nil? false
      attribute_writable? true
      public? true
    end
  end

  identities do
    identity :unique_kind, [:delivery_operation_id, :kind]
  end

  @doc false
  def __sdr_audited__, do: true
end
