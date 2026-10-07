defmodule SdrAgent.Audit.AuditEvent do
  @moduledoc """
  The append-only, hash-chained, gap-free ledger entry — the system of
  record (ADR-0002; S2 row AuditEvent).

  Per tenant, `sequence` runs 1, 2, 3, … with no gaps; `prev_hash` is the
  previous event's `event_hash` (genesis: 32 zero bytes); `event_hash =
  sha256(canonical_bytes)`, where `canonical_bytes` (version
  `canonicalization_version`, see `SdrAgent.Audit.Canonical`) encode every
  other column. Each event records the actor (`actor_type`, `actor_id`,
  `actor_role`), the `authorization` decision, `occurred_at` and its
  `clock_source`, the `provenance_snapshot_id` and `version_refs`,
  causation/correlation/idempotency/attempt, `trace_id`/`span_id`, and plain
  links to agent runs, decisions and invocations (Audit depends on no higher
  domain).

  Actions: `:append` — authorized only for the audit kernel
  (`SdrAgent.Audit.Kernel`), never called directly; `:read` (ADM, REV, AUR,
  AUD); `:verify_chain` (ADM, AUR, AUD) — runs the verifier and records an
  AuditAccess. No update or destroy; the table is append-only (trigger).
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Audit,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Checks

  @string [trim?: false, allow_empty?: true]

  postgres do
    table "audit_events"
    repo SdrAgent.Repo

    migration_types sequence: :bigint

    references do
      reference :tenant, on_delete: :restrict
      reference :provenance_snapshot, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "audit_events_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :sequence, "audit_events_sequence_positive", check: "sequence >= 1"
      check_constraint :hash_algorithm, "audit_events_sha256", check: "hash_algorithm = 'sha256'"

      check_constraint :event_hash, "audit_events_hash_lengths",
        check: "octet_length(event_hash) = 32 AND octet_length(prev_hash) = 32"
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("audit_events") do
        statement name do
          up up_sql
          down down_sql
        end
      end
    end
  end

  actions do
    defaults [:read]

    create :append do
      description "Kernel only: insert a fully computed event."
      accept :*
    end

    action :verify_chain, :map do
      description "Verify the actor's tenant chain and record the verification as an AuditAccess."
      # The kernel opens (or joins) the transaction itself, so a refusal does
      # not abort a caller's enclosing transaction.
      transaction? false

      run fn _input, context ->
        SdrAgent.Audit.Kernel.verify_and_record(context.actor)
      end
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      authorize_if action(:verify_chain)
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action(:append) do
      authorize_if Checks.KernelContext
    end

    policy action(:verify_chain) do
      authorize_if {Checks.ActorRole, roles: [:admin, :auditor]}
      authorize_if {Checks.ActorType, types: [:auditor_cli]}
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer, :auditor]}
      authorize_if {Checks.ActorType, types: [:auditor_cli]}
    end
  end

  attributes do
    uuid_v7_primary_key :id, writable?: true, public?: true

    attribute :sequence, :integer do
      allow_nil? false
      constraints min: 1
      public? true
    end

    attribute :prev_hash, :binary, allow_nil?: false, public?: true
    attribute :event_hash, :binary, allow_nil?: false, public?: true
    attribute :canonical_bytes, :binary, allow_nil?: false, public?: true

    attribute :canonicalization_version, :string,
      allow_nil?: false,
      public?: true,
      constraints: @string

    attribute :hash_algorithm, :string, allow_nil?: false, public?: true, constraints: @string
    attribute :event_type, :string, allow_nil?: false, public?: true, constraints: @string

    attribute :category, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :domain_change,
                    :decision,
                    :model,
                    :tool,
                    :delivery,
                    :access,
                    :export,
                    :anchor,
                    :retention,
                    :auth,
                    :signal,
                    :system
                  ]
    end

    attribute :subject_resource, :string, public?: true, constraints: @string
    attribute :subject_id, :string, public?: true, constraints: @string
    attribute :action, :string, public?: true, constraints: @string
    attribute :payload, :map, allow_nil?: false, default: %{}, public?: true

    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true

    attribute :clock_source, :atom do
      allow_nil? false
      constraints one_of: [:system_utc, :test_fixed]
      public? true
    end

    attribute :actor_type, :atom do
      allow_nil? false
      constraints one_of: [:user, :anonymous | SdrAgent.Actor.types()]
      public? true
    end

    attribute :actor_id, :string, public?: true, constraints: @string

    attribute :actor_role, :atom do
      constraints one_of: [:admin, :reviewer, :auditor]
      public? true
    end

    attribute :authorization, SdrAgent.Audit.Authorization, allow_nil?: false, public?: true
    attribute :version_refs, :map, allow_nil?: false, default: %{}, public?: true
    attribute :causation_id, :uuid, public?: true
    attribute :correlation_id, :uuid, public?: true
    attribute :idempotency_key, :string, public?: true, constraints: @string

    attribute :attempt, :integer do
      allow_nil? false
      default 0
      constraints min: 0
      public? true
    end

    attribute :trace_id, :string, allow_nil?: false, public?: true, constraints: @string
    attribute :span_id, :string, allow_nil?: false, public?: true, constraints: @string
    attribute :request_id, :string, public?: true, constraints: @string
    attribute :agent_run_id, :uuid, public?: true
    attribute :decision_id, :uuid, public?: true
    attribute :model_invocation_id, :uuid, public?: true
    attribute :tool_invocation_id, :uuid, public?: true

    attribute :inserted_at, :utc_datetime_usec, allow_nil?: false, public?: true
  end

  relationships do
    belongs_to :tenant, SdrAgent.Audit.Tenant do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :provenance_snapshot, SdrAgent.Audit.ProvenanceSnapshot do
      allow_nil? false
      attribute_writable? true
      public? true
    end
  end

  identities do
    identity :unique_sequence, [:tenant_id, :sequence]
    identity :unique_event_hash, [:tenant_id, :event_hash]
  end
end
