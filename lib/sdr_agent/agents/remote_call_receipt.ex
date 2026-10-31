defmodule SdrAgent.Agents.RemoteCallReceipt do
  @moduledoc """
  The append-only visibility log of remote completions (S-B2; entity/plan
  r2 "RemoteCallReceipt"; r4a C3).

  Attributes: `id`; `tenant_id`; `call_id` (the composite `(call_id,
  tenant_id)` → `remote_model_calls (id, tenant_id)`); `kind`, one of
  `kinds/0`; `transcript_sha256` (the server digest of the received bytes,
  nullable; never content); `position` (positive, never caller input: set
  by `SdrAgent.Agents.Changes.ReceiptPosition` under the call's lock, after
  the chain-head lock, to the call's receipt count plus one, so it is
  gap-free over committed appends and a rolled-back append consumes none);
  `recorded_at` (set after the locks; informational only).

  Keys: UNIQUE `(call_id, position)`. `:append` is reached only from
  `SdrAgent.Agents.RemoteCalls.complete/5` inside the RemoteCalls scope
  (`SdrAgent.Agents.Checks.RemoteCallsScope`), never changes the call's
  state, and appends one AuditEvent `remote_call.receipt_appended`. A
  trigger refuses UPDATE, DELETE and TRUNCATE.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Agents.Checks.RemoteCallsScope

  @kinds [:accepted, :duplicate_same, :conflict, :late, :refused_disabled, :refused_mismatch]

  postgres do
    table "remote_call_receipts"
    repo SdrAgent.Repo

    references do
      reference :call,
        on_delete: :restrict,
        match_with: [tenant_id: :tenant_id],
        match_type: :full
    end

    check_constraints do
      check_constraint :kind, "remote_call_receipts_kind",
        check: SdrAgent.Audit.SQL.one_of("kind", @kinds)

      check_constraint :position, "remote_call_receipts_position_positive", check: "position > 0"
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("remote_call_receipts") do
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
      description "S-B2: one completion receipt of a remote call."
      accept [:call_id, :kind, :transcript_sha256]
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Agents.Changes.ReceiptPosition

      change {SdrAgent.Audit.Changes.AppendEvent,
              event_type: "remote_call.receipt_appended", category: :domain_change}
    end
  end

  policies do
    policy always() do
      authorize_if RemoteCallsScope
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :tenant_id, :uuid, allow_nil?: false, writable?: false, public?: true
    attribute :kind, :atom, allow_nil?: false, public?: true, constraints: [one_of: @kinds]
    attribute :transcript_sha256, :binary, public?: true

    attribute :position, :integer,
      allow_nil?: false,
      writable?: false,
      public?: true,
      constraints: [min: 1]

    attribute :recorded_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      default &SdrAgent.Clock.utc_now/0
      public? true
    end
  end

  relationships do
    belongs_to :call, SdrAgent.Agents.RemoteModelCall do
      allow_nil? false
      attribute_writable? true
      public? true
    end
  end

  identities do
    identity :unique_call_position, [:call_id, :position]
  end

  @doc "The receipt kinds."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds
end
