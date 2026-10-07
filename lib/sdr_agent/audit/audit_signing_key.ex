defmodule SdrAgent.Audit.AuditSigningKey do
  @moduledoc "Public Ed25519 audit signing-key provenance; private material is never stored."
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Audit,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Checks

  postgres do
    table "audit_signing_keys"
    repo SdrAgent.Repo
    identity_wheres_to_sql one_active: "status = 'active'"

    check_constraints do
      check_constraint :public_key, "audit_signing_keys_public_key_length",
        check: "octet_length(public_key) = 32"

      check_constraint :trace_id, "audit_signing_keys_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()
    end
  end

  actions do
    defaults [:read]

    create :register do
      accept [:key_id, :public_key, :activated_at]
      change SdrAgent.Audit.Changes.TraceIds

      change {SdrAgent.Audit.Changes.AppendEvent,
              event_type: "audit.signing_key.registered", category: :anchor}
    end

    update :rotate do
      accept []
      change {SdrAgent.Audit.Changes.Transition, from: [:active], to: :rotated}
      change set_attribute(:retired_at, &SdrAgent.Clock.utc_now/0)

      change {SdrAgent.Audit.Changes.AppendEvent,
              event_type: "audit.signing_key.rotated", category: :anchor}
    end

    update :revoke do
      accept [:revocation_reason]
      change {SdrAgent.Audit.Changes.Transition, from: [:active, :rotated], to: :revoked}
      change set_attribute(:revoked_at, &SdrAgent.Clock.utc_now/0)

      change {SdrAgent.Audit.Changes.AppendEvent,
              event_type: "audit.signing_key.revoked", category: :anchor}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action(:register), authorize_if: Checks.KernelContext
    policy action([:rotate, :revoke]), authorize_if: {Checks.ActorRole, roles: [:admin]}

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :auditor]}
      authorize_if {Checks.ActorType, types: [:auditor_cli, :anchorer]}
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :key_id, :string, allow_nil?: false, public?: true

    attribute :algorithm, :atom,
      allow_nil?: false,
      default: :ed25519,
      constraints: [one_of: [:ed25519]],
      public?: true

    attribute :public_key, :binary, allow_nil?: false, public?: true

    attribute :status, :atom,
      allow_nil?: false,
      default: :active,
      constraints: [one_of: [:active, :rotated, :revoked]],
      public?: true

    attribute :activated_at, :utc_datetime_usec,
      allow_nil?: false,
      default: &SdrAgent.Clock.utc_now/0,
      public?: true

    attribute :retired_at, :utc_datetime_usec, public?: true
    attribute :revoked_at, :utc_datetime_usec, public?: true
    attribute :revocation_reason, :string, public?: true
    attribute :trace_id, :string, allow_nil?: false, public?: true
    attribute :span_id, :string, allow_nil?: false, public?: true
    timestamps type: :utc_datetime_usec
  end

  relationships do
    has_many :anchors, SdrAgent.Audit.AuditAnchor do
      source_attribute :key_id
      destination_attribute :key_id
      public? true
    end
  end

  identities do
    identity :unique_key_id, [:key_id]
    identity :one_active, [:status], where: expr(status == :active)
  end

  def transitions, do: %{active: [:rotated, :revoked], rotated: [:revoked], revoked: []}

  def __sdr_audited__, do: true
end
