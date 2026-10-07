defmodule SdrAgent.Audit.AuditAccess do
  @moduledoc """
  Queryable log of who viewed, verified or exported audit data and payloads
  (S2 row AuditAccess).

  Attributes: `actor_type`/`actor_id`, `access_kind` (payload_view,
  timeline_view, record_view, chain_verify, export, payload_download),
  `target_resource`, `target_ref` (id or payload sha256 hex), `purpose`,
  `accessed_at`, `audit_event_id` (its AuditEvent).

  Always written by the kernel (`SdrAgent.Audit.Kernel.record_access/6`) in
  the same transaction as its AuditEvent; if the write fails the content is
  not returned (fail closed). ADM, AUR, AUD read. Append-only (trigger).
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Audit,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Checks

  postgres do
    table "audit_accesses"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :audit_event, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "audit_accesses_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("audit_accesses") do
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
      description "Kernel only, in the transaction of its AuditEvent."

      accept [
        :tenant_id,
        :actor_type,
        :actor_id,
        :access_kind,
        :target_resource,
        :target_ref,
        :purpose,
        :accessed_at,
        :audit_event_id,
        :trace_id,
        :span_id
      ]
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action(:record) do
      authorize_if Checks.KernelContext
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :auditor]}
      authorize_if {Checks.ActorType, types: [:auditor_cli]}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :actor_type, :atom do
      allow_nil? false
      constraints one_of: [:user | SdrAgent.Actor.types()]
      public? true
    end

    attribute :actor_id, :string, allow_nil?: false, public?: true

    attribute :access_kind, :atom do
      allow_nil? false

      constraints one_of: [
                    :payload_view,
                    :timeline_view,
                    :record_view,
                    :chain_verify,
                    :export,
                    :payload_download
                  ]

      public? true
    end

    attribute :target_resource, :string, allow_nil?: false, public?: true
    attribute :target_ref, :string, allow_nil?: false, public?: true
    attribute :purpose, :string, public?: true
    attribute :accessed_at, :utc_datetime_usec, allow_nil?: false, public?: true
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
      attribute_writable? true
      public? true
    end

    belongs_to :audit_event, SdrAgent.Audit.AuditEvent do
      allow_nil? false
      attribute_writable? true
      public? true
    end
  end
end
