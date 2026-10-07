defmodule SdrAgent.Audit.AnchorSinkReceipt do
  @moduledoc "Append-only evidence returned by an anchor publication sink."
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Audit,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Checks

  postgres do
    table "anchor_sink_receipts"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :anchor, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "anchor_sink_receipts_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("anchor_sink_receipts") do
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
      accept [:tenant_id, :anchor_id, :sink, :status, :receipt, :recorded_at]
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds

      change {SdrAgent.Audit.Changes.AppendEvent,
              event_type: "audit.anchor.sink_recorded", category: :anchor}
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

    attribute :sink, :atom,
      allow_nil?: false,
      constraints: [one_of: [:file, :git, :ots]],
      public?: true

    attribute :status, :atom,
      allow_nil?: false,
      constraints: [one_of: [:pending, :confirmed, :failed]],
      public?: true

    attribute :receipt, :map, allow_nil?: false, public?: true

    attribute :recorded_at, :utc_datetime_usec,
      allow_nil?: false,
      default: &SdrAgent.Clock.utc_now/0,
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

    belongs_to :anchor, SdrAgent.Audit.AuditAnchor,
      allow_nil?: false,
      attribute_writable?: true,
      public?: true
  end

  def __sdr_audited__, do: true
end
