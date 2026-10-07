defmodule SdrAgent.Audit.ProvenanceSnapshot do
  @moduledoc """
  Build and runtime provenance referenced by every AuditEvent (ADR-0002;
  S2 row ProvenanceSnapshot). Deployment-level: no `tenant_id`; its
  `system.provenance.recorded` event appends to the singleton tenant's chain.

  Attributes: `snapshot_sha256` (globally unique), `git_sha`, `git_dirty`,
  `mix_lock_sha256`, OTP/ERTS/Elixir/app versions, `config_sha256`
  (canonical redacted runtime config), `canonicalization_version`,
  `schema_version` (newest migration), `recorded_at`. Collected by
  `SdrAgent.Audit.Provenance`.

  Actions: `:record` — kernel only, insert-if-absent on `snapshot_sha256`;
  `:read` for any actor. Append-only (trigger).
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Audit,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Expr

  alias SdrAgent.Audit.Checks

  postgres do
    table "provenance_snapshots"
    repo SdrAgent.Repo

    check_constraints do
      check_constraint :trace_id, "provenance_snapshots_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("provenance_snapshots") do
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
        :snapshot_sha256,
        :git_sha,
        :git_dirty,
        :mix_lock_sha256,
        :otp_release,
        :erts_version,
        :elixir_version,
        :app_version,
        :config_sha256,
        :canonicalization_version,
        :schema_version
      ]

      upsert? true
      upsert_identity :unique_snapshot
      upsert_fields []
      upsert_condition Ash.Expr.expr(false)
      return_skipped_upsert? true
      change SdrAgent.Audit.Changes.TraceIds
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
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :snapshot_sha256, :binary, allow_nil?: false, public?: true
    attribute :git_sha, :string, allow_nil?: false, public?: true
    attribute :git_dirty, :boolean, allow_nil?: false, public?: true
    attribute :mix_lock_sha256, :binary, allow_nil?: false, public?: true
    attribute :otp_release, :string, allow_nil?: false, public?: true
    attribute :erts_version, :string, allow_nil?: false, public?: true
    attribute :elixir_version, :string, allow_nil?: false, public?: true
    attribute :app_version, :string, allow_nil?: false, public?: true
    attribute :config_sha256, :binary, allow_nil?: false, public?: true
    attribute :canonicalization_version, :string, allow_nil?: false, public?: true
    attribute :schema_version, :string, allow_nil?: false, public?: true
    attribute :trace_id, :string, allow_nil?: false, public?: true
    attribute :span_id, :string, allow_nil?: false, public?: true

    attribute :recorded_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      default &SdrAgent.Clock.utc_now/0
      public? true
    end

    attribute :inserted_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      default &SdrAgent.Clock.utc_now/0
      public? true
    end
  end

  identities do
    identity :unique_snapshot, [:snapshot_sha256]
  end

  @doc false
  def __sdr_audited__, do: true
end
