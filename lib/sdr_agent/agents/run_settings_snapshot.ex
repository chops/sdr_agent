defmodule SdrAgent.Agents.RunSettingsSnapshot do
  @moduledoc """
  The exact run settings one agent run (and its retries) uses (C4,
  `docs/product/c4/readiness.md` sections 3.1, 3.2, 3.7, 4 and 12).
  APPEND-ONLY: a database trigger rejects every UPDATE, DELETE and TRUNCATE.

  For each settings kind K it records one slot: `K_source` (`:revision`,
  `:code_default` or `:absent`), `K_revision_id`, `K_code_default_version`
  and `K_content_sha256`, plus a database-generated `K_kind` column (never
  an attribute, never writable). A `:revision` slot names a revision and its
  content hash; a `:code_default` slot (brief, guide and limits only) names
  a released built-in default by version and hash; an `:absent` slot
  (offering profile and booking link only) names nothing. A per-kind check
  constraint enforces those combinations, and a composite foreign key
  `(K_revision_id, tenant_id, K_kind, K_content_sha256)` makes the database
  refuse a revision of another tenant, another kind or another content hash.

  Also: `limits` (`SdrAgent.Agents.RunSettings.SnapshotLimits`, the twelve
  limits in effect), `safeguards_version`, `hash_version`
  (`"c4-run-settings-snapshot/1"`) and `snapshot_sha256` (section 3.7, over
  the tenant, the safeguards version, the five slots and the limits).

  The only write is `:create`, run only inside `AgentRun :create` by
  `SdrAgent.Agents.Changes.BuildSettingsSnapshot`: it accepts no input (any
  supplied input is ignored), and every value is taken from the phase that
  change opened in its own process
  (`SdrAgent.Agents.Checks.SettingsSnapshotContext`). Any other create —
  direct, with supplied attributes, with a forged or copied context, or
  from another process — is Forbidden for every actor. Audited:
  `settings.snapshot.created` (references, hashes and limits only). Reads:
  admin, reviewer, auditor (audited by the views), `agent_runtime`,
  `auditor_cli`, kernel, each in its own tenant.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Agents.Checks.SettingsSnapshotContext
  alias SdrAgent.Audit.Changes.AppendEvent
  alias SdrAgent.Audit.Checks

  @kinds [:offering_profile, :booking_link, :writing_guide, :research_brief, :operational_limits]
  @defaulted [:writing_guide, :research_brief, :operational_limits]
  @sources [:revision, :code_default, :absent]
  @hash_version "c4-run-settings-snapshot/1"

  postgres do
    table "run_settings_snapshots"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "run_settings_snapshots_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :hash_version, "run_settings_snapshots_hash_version",
        check: "hash_version = '#{@hash_version}'"

      check_constraint :snapshot_sha256, "run_settings_snapshots_snapshot_sha256_hex",
        check: "snapshot_sha256 ~ '^[0-9a-f]{64}$'"

      for kind <- @kinds do
        revision =
          "(#{kind}_source = 'revision' AND #{kind}_revision_id IS NOT NULL AND " <>
            "#{kind}_content_sha256 IS NOT NULL AND #{kind}_content_sha256 ~ '^[0-9a-f]{64}$' " <>
            "AND #{kind}_code_default_version IS NULL)"

        other =
          if kind in @defaulted,
            do:
              "(#{kind}_source = 'code_default' AND #{kind}_revision_id IS NULL AND " <>
                "#{kind}_code_default_version IS NOT NULL AND " <>
                "#{kind}_content_sha256 IS NOT NULL AND " <>
                "#{kind}_content_sha256 ~ '^[0-9a-f]{64}$')",
            else:
              "(#{kind}_source = 'absent' AND #{kind}_revision_id IS NULL AND " <>
                "#{kind}_code_default_version IS NULL AND #{kind}_content_sha256 IS NULL)"

        check_constraint :"#{kind}_source", "run_settings_snapshots_#{kind}_slot",
          check: "#{revision} OR #{other}"
      end
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("run_settings_snapshots") do
        statement name do
          up up_sql
          down down_sql
        end
      end

      # Target of the AgentRun (settings_snapshot_id, tenant_id) foreign key.
      statement :run_settings_snapshots_id_tenant_key do
        up "ALTER TABLE run_settings_snapshots ADD CONSTRAINT " <>
             "run_settings_snapshots_id_tenant_key UNIQUE (id, tenant_id)"

        down "ALTER TABLE run_settings_snapshots DROP CONSTRAINT " <>
               "run_settings_snapshots_id_tenant_key"
      end

      for kind <- @kinds do
        statement :"run_settings_snapshots_#{kind}_kind" do
          up "ALTER TABLE run_settings_snapshots ADD COLUMN #{kind}_kind text " <>
               "GENERATED ALWAYS AS ('#{kind}') STORED"

          down "ALTER TABLE run_settings_snapshots DROP COLUMN #{kind}_kind"
        end

        statement :"run_settings_snapshots_#{kind}_revision_fkey" do
          up "ALTER TABLE run_settings_snapshots ADD CONSTRAINT " <>
               "run_settings_snapshots_#{kind}_revision_fkey " <>
               "FOREIGN KEY (#{kind}_revision_id, tenant_id, #{kind}_kind, " <>
               "#{kind}_content_sha256) REFERENCES settings_revisions " <>
               "(id, tenant_id, kind, content_sha256) MATCH SIMPLE ON DELETE RESTRICT"

          down "ALTER TABLE run_settings_snapshots DROP CONSTRAINT " <>
                 "run_settings_snapshots_#{kind}_revision_fkey"
        end
      end
    end
  end

  actions do
    defaults [:read]

    create :create do
      description """
      Only inside `AgentRun :create` (`BuildSettingsSnapshot`): every value
      comes from that change's open phase; supplied inputs are ignored.
      """

      accept []
      skip_unknown_inputs :*
      change SdrAgent.Agents.Changes.SettingsSnapshotRow
      change SdrAgent.Audit.Changes.TraceIds

      change {AppendEvent, event_type: "settings.snapshot.created", category: :domain_change}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      authorize_if SettingsSnapshotContext
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if Checks.IntegrityRead
      forbid_unless expr(tenant_id == ^actor(:tenant_id))
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer, :auditor]}

      authorize_if {Checks.ActorType, types: [:agent_runtime, :auditor_cli, :kernel]}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    for kind <- @kinds do
      attribute :"#{kind}_source", :atom do
        allow_nil? false
        writable? false
        public? true
        constraints one_of: @sources
      end

      attribute :"#{kind}_revision_id", :uuid, writable?: false, public?: true
      attribute :"#{kind}_code_default_version", :string, writable?: false, public?: true
      attribute :"#{kind}_content_sha256", :string, writable?: false, public?: true
    end

    attribute :limits, SdrAgent.Agents.RunSettings.SnapshotLimits do
      allow_nil? false
      writable? false
      public? true
    end

    attribute :safeguards_version, :string, allow_nil?: false, writable?: false, public?: true
    attribute :hash_version, :string, allow_nil?: false, writable?: false, public?: true
    attribute :snapshot_sha256, :string, allow_nil?: false, writable?: false, public?: true
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
      attribute_writable? false
      public? true
    end

    has_many :agent_runs, SdrAgent.Agents.AgentRun do
      destination_attribute :settings_snapshot_id
      public? true
    end
  end

  @doc "The snapshot hash schema version (`hash_version`)."
  def hash_version, do: @hash_version

  @doc false
  def __sdr_audited__, do: true
end
