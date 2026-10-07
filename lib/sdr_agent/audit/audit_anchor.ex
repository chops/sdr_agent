defmodule SdrAgent.Audit.AuditAnchor do
  @moduledoc "Append-only signed observation of a tenant audit-chain head."
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Audit,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Checks

  postgres do
    table "audit_anchors"
    repo SdrAgent.Repo
    migration_types anchor_number: :bigint, from_sequence: :bigint, to_sequence: :bigint

    references do
      reference :tenant, on_delete: :restrict
      reference :prior_anchor, on_delete: :restrict
    end

    check_constraints do
      check_constraint :to_sequence, "audit_anchors_valid_range",
        check: "to_sequence >= from_sequence"

      check_constraint :anchor_hash, "audit_anchors_hash_lengths",
        check:
          "octet_length(head_event_hash) = 32 AND octet_length(anchor_hash) = 32 AND (prior_anchor_hash IS NULL OR octet_length(prior_anchor_hash) = 32)"

      check_constraint :signature, "audit_anchors_signature_length",
        check: "octet_length(signature) = 64"

      check_constraint :trace_id, "audit_anchors_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("audit_anchors") do
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
      accept [
        :tenant_id,
        :anchor_number,
        :from_sequence,
        :to_sequence,
        :head_event_hash,
        :prior_anchor_id,
        :prior_anchor_hash,
        :statement_bytes,
        :anchor_hash,
        :signature,
        :key_id,
        :key_status_at_signing,
        :canonicalization_version,
        :sdr_agent_git_sha,
        :trigger
      ]

      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds

      change {SdrAgent.Audit.Changes.AppendEvent,
              event_type: "audit.anchor.created", category: :anchor}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action(:record), authorize_if: {Checks.ActorType, types: [:anchorer]}

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :auditor]}
      authorize_if {Checks.ActorType, types: [:auditor_cli, :anchorer]}
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :anchor_number, :integer, allow_nil?: false, constraints: [min: 1], public?: true
    attribute :from_sequence, :integer, allow_nil?: false, constraints: [min: 1], public?: true
    attribute :to_sequence, :integer, allow_nil?: false, constraints: [min: 1], public?: true
    attribute :head_event_hash, :binary, allow_nil?: false, public?: true
    attribute :prior_anchor_hash, :binary, public?: true
    attribute :statement_bytes, :binary, allow_nil?: false, public?: true
    attribute :anchor_hash, :binary, allow_nil?: false, public?: true
    attribute :signature, :binary, allow_nil?: false, public?: true
    attribute :key_id, :string, allow_nil?: false, public?: true

    attribute :key_status_at_signing, :atom,
      allow_nil?: false,
      constraints: [one_of: [:active, :rotated, :revoked]],
      public?: true

    attribute :canonicalization_version, :string, allow_nil?: false, public?: true
    attribute :sdr_agent_git_sha, :string, allow_nil?: false, public?: true

    attribute :trigger, :atom,
      allow_nil?: false,
      constraints: [one_of: [:event_count, :interval, :export]],
      public?: true

    attribute :trace_id, :string, allow_nil?: false, public?: true
    attribute :span_id, :string, allow_nil?: false, public?: true

    attribute :inserted_at, :utc_datetime_usec,
      allow_nil?: false,
      writable?: false,
      default: &SdrAgent.Clock.utc_now/0,
      public?: true
  end

  relationships do
    belongs_to :tenant, SdrAgent.Audit.Tenant,
      allow_nil?: false,
      attribute_writable?: true,
      public?: true

    belongs_to :prior_anchor, __MODULE__, attribute_writable?: true, public?: true

    belongs_to :signing_key, SdrAgent.Audit.AuditSigningKey do
      source_attribute :key_id
      destination_attribute :key_id
      define_attribute? false
      public? true
    end

    has_many :sink_receipts, SdrAgent.Audit.AnchorSinkReceipt do
      destination_attribute :anchor_id
      public? true
    end
  end

  identities do
    identity :unique_number, [:tenant_id, :anchor_number]
    identity :unique_head, [:tenant_id, :to_sequence]
  end

  def __sdr_audited__, do: true
end
