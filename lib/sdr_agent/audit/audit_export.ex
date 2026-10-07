defmodule SdrAgent.Audit.AuditExport do
  @moduledoc "Terminal-immutable signed audit export request and result."
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Audit,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Checks
  @terminal ~w(completed failed)
  @mutable ~w(status from_sequence to_sequence bundle_sha256 bundle_path signature key_id assurance_level anchor_ids failure_reason updated_at trace_id span_id)

  postgres do
    table "audit_exports"
    repo SdrAgent.Repo
    migration_types from_sequence: :bigint, to_sequence: :bigint

    references do
      reference :tenant, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "audit_exports_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()
    end

    custom_statements do
      for {name, up_sql, down_sql} <-
            SdrAgent.Audit.SQL.terminal_immutable("audit_exports", @terminal, @mutable) do
        statement name do
          up up_sql
          down down_sql
        end
      end
    end
  end

  actions do
    defaults [:read]

    create :request do
      accept [:tenant_id, :requested_by_type, :requested_by_id, :scope, :scope_ref]
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds

      change {SdrAgent.Audit.Changes.AppendEvent,
              event_type: "audit.export.requested", category: :export}
    end

    update :complete do
      accept [
        :from_sequence,
        :to_sequence,
        :bundle_sha256,
        :bundle_path,
        :signature,
        :key_id,
        :assurance_level,
        :anchor_ids
      ]

      change {SdrAgent.Audit.Changes.Transition, from: [:building], to: :completed}

      change {SdrAgent.Audit.Changes.AppendEvent,
              event_type: "audit.export.completed", category: :export}
    end

    update :fail do
      accept [:failure_reason]
      change {SdrAgent.Audit.Changes.Transition, from: [:building], to: :failed}

      change {SdrAgent.Audit.Changes.AppendEvent,
              event_type: "audit.export.failed", category: :export}
    end
  end

  policies do
    policy action([:request, :complete, :fail]) do
      authorize_if {Checks.ActorRole, roles: [:admin, :auditor]}
      authorize_if {Checks.ActorType, types: [:auditor_cli]}
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :auditor]}
      authorize_if {Checks.ActorType, types: [:auditor_cli]}
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :requested_by_type, :atom, allow_nil?: false, public?: true
    attribute :requested_by_id, :string, allow_nil?: false, public?: true

    attribute :scope, :atom,
      allow_nil?: false,
      constraints: [one_of: [:lead, :agent_run, :draft, :sequence_range]],
      public?: true

    attribute :scope_ref, :string, allow_nil?: false, public?: true
    attribute :from_sequence, :integer, public?: true
    attribute :to_sequence, :integer, public?: true

    attribute :status, :atom,
      allow_nil?: false,
      default: :building,
      constraints: [one_of: [:building, :completed, :failed]],
      public?: true

    attribute :bundle_sha256, :binary, public?: true
    attribute :bundle_path, :string, public?: true
    attribute :signature, :binary, public?: true
    attribute :key_id, :string, public?: true

    attribute :assurance_level, :atom,
      constraints: [one_of: [:chain_verified, :signed, :git_anchored, :ots_anchored]],
      public?: true

    attribute :anchor_ids, {:array, :uuid}, default: [], public?: true
    attribute :failure_reason, :string, public?: true
    attribute :trace_id, :string, allow_nil?: false, public?: true
    attribute :span_id, :string, allow_nil?: false, public?: true
    timestamps type: :utc_datetime_usec
  end

  relationships do
    belongs_to :tenant, SdrAgent.Audit.Tenant,
      allow_nil?: false,
      attribute_writable?: true,
      public?: true
  end

  def transitions, do: %{building: [:completed, :failed], completed: [], failed: []}
  def __sdr_audited__, do: true
end
