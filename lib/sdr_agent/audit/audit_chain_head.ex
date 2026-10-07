defmodule SdrAgent.Audit.AuditChainHead do
  @moduledoc """
  Per-tenant head of the audit chain (S2 row AuditChainHead). Keyed by
  `tenant_id`; holds `last_sequence` and `last_event_hash`.

  The kernel locks this row `FOR UPDATE` for every append, which serialises
  a tenant's appends and makes the sequence gap-free. Created with the
  tenant (`:init`, sequence 0, zero hash) and advanced only by the kernel
  (`:advance`, guarded on the expected sequence) in the same transaction as
  each AuditEvent. Not audited itself (derived); the verifier checks that
  it equals the newest event. KRN writes; ADM, AUR, AUD read.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Audit,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Checks

  postgres do
    table "audit_chain_heads"
    repo SdrAgent.Repo

    migration_types last_sequence: :bigint

    references do
      reference :tenant, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "audit_chain_heads_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :last_event_hash, "audit_chain_heads_hash_length",
        check: "octet_length(last_event_hash) = 32"
    end
  end

  actions do
    defaults [:read]

    create :init do
      accept [:tenant_id, :last_sequence, :last_event_hash]
      change SdrAgent.Audit.Changes.TraceIds
    end

    update :advance do
      accept [:last_sequence, :last_event_hash]
      argument :expected_sequence, :integer, allow_nil?: false
      validate SdrAgent.Audit.Validations.ExpectedSequence
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action([:init, :advance]) do
      authorize_if Checks.KernelContext
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :auditor]}
      authorize_if {Checks.ActorType, types: [:auditor_cli]}
    end
  end

  attributes do
    attribute :last_sequence, :integer do
      allow_nil? false
      constraints min: 0
      public? true
    end

    attribute :last_event_hash, :binary, allow_nil?: false, public?: true
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
      primary_key? true
      allow_nil? false
      attribute_writable? true
      public? true
    end
  end
end
