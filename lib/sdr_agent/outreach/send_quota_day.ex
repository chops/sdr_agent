defmodule SdrAgent.Outreach.SendQuotaDay do
  @moduledoc """
  The authoritative tenant-wide daily send-cap counter (S2 row SendQuotaDay;
  checklist 1.6: 25 sends per day).

  Attributes: `local_date` (the calendar date in the compliance time zone,
  `SdrAgent.Outreach.Compliance.timezone/0`), `timezone`, `cap` (1..25, a
  snapshot of `Compliance.daily_send_cap/0` when the day's row is created),
  `consumed` (0..cap). One row per tenant and local date.

  `:open` is an insert-if-absent of the day's row; `:consume` takes one unit
  on the row re-read `FOR UPDATE` and is refused at the cap, so two
  concurrent claims cannot both take the last unit. Both run inside a
  DeliveryOperation's first claim (`SdrAgent.Outreach.Delivery`). Units are
  never released (conservative: the cap bounds attempts). Derived counter:
  no AuditEvent per change; the `quota_check` Decision records day, cap and
  consumed, and a verifier can recompute it from claimed deliveries.

  Actors: DLV open/consume; reads ADM, REV, AUR, AUD, DLV.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Outreach,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Expr

  alias SdrAgent.Audit.Checks

  postgres do
    table "send_quota_days"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "send_quota_days_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :cap, "send_quota_days_cap", check: "cap BETWEEN 1 AND 25"

      check_constraint :consumed, "send_quota_days_consumed",
        check: "consumed >= 0 AND consumed <= cap"
    end
  end

  actions do
    defaults [:read]

    create :open do
      description "DLV: the day's counter row, inserted if absent (cap and zone snapshotted)."
      accept [:local_date, :timezone, :cap]
      upsert? true
      upsert_identity :unique_day
      upsert_fields []
      upsert_condition Ash.Expr.expr(false)
      return_skipped_upsert? true
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
    end

    update :consume do
      description "DLV: take one unit; refused at the cap."
      require_atomic? false
      change get_and_lock_for_update()
      change SdrAgent.Outreach.Changes.ConsumeUnit
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action([:open, :consume]) do
      authorize_if {Checks.ActorType, types: [:delivery_worker]}
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer, :auditor]}
      authorize_if {Checks.ActorType, types: [:delivery_worker, :auditor_cli]}
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :local_date, :date, allow_nil?: false, public?: true
    attribute :timezone, :string, allow_nil?: false, public?: true

    attribute :cap, :integer do
      allow_nil? false
      constraints min: 1, max: 25
      public? true
    end

    attribute :consumed, :integer do
      allow_nil? false
      default 0
      writable? false
      constraints min: 0
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
  end

  identities do
    identity :unique_day, [:tenant_id, :local_date]
  end
end
