defmodule SdrAgent.Operations.PrototypeDatabaseBinding do
  @moduledoc """
  The singleton D-237 prototype database binding (interfaces r6 IF-2;
  amendment item 2 "The binding"): the one row that makes a database the
  prototype database.

  Attributes: `id`; `singleton` and `prototype` (both always true); the
  tenant; `operator_user_id` (the credential-less anchor) and
  `auditor_user_id` (optional, never the anchor), each a composite
  `(user, tenant_id)` foreign key to `users (id, tenant_id)` so both are
  users of the binding's tenant; `instance_id` (the switch's instance);
  the fixed `dataset_class` `real_prototype`, `policy_id`
  `d237-prototype/1`, `funding_id` `d237-funding/1`, `witness_mode`
  `absent` and `database` `sdr_agent_prototype`; `policy_entry_sha256`
  (lowercase hex of the compiled entry's `sdr-canonical-json/1` digest);
  the live `database_oid` and the cluster's `system_identifier`; `bound_at`
  and the trace ids. The database checks every fixed value.

  Keys: UNIQUE `singleton` (one row per database) and UNIQUE `(id,
  tenant_id, operator_user_id)`, the composite foreign-key target of
  `SdrAgent.Operations.PrototypeDelegation`, and UNIQUE `(id, tenant_id)`, the
  composite foreign-key target of `SdrAgent.Operations.MacWorker` (S-B2).

  CREATE-ONLY: a trigger rejects update, delete and truncate; foreign keys
  are RESTRICT. Rows are written only by setup phase 2 (event
  `prototype.binding.created`) through `:create`, which only a kernel
  request carrying the prototype `:setup` marker
  (`SdrAgent.Prototype.Checks.KernelMarker`) passes. Reads: the audit kernel (the boot check and
  the operator resolver read the row as plain kernel reads).
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Operations,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Checks

  @dataset_class "real_prototype"
  @policy_id "d237-prototype/1"
  @funding_id "d237-funding/1"
  @witness_mode "absent"
  @database "sdr_agent_prototype"

  postgres do
    table "prototype_database_bindings"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict

      reference :operator_user,
        on_delete: :restrict,
        match_with: [tenant_id: :tenant_id],
        match_type: :full

      reference :auditor_user, on_delete: :restrict, match_with: [tenant_id: :tenant_id]
    end

    check_constraints do
      check_constraint :trace_id, "prototype_database_bindings_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :singleton, "prototype_database_bindings_singleton",
        check: "singleton IS TRUE"

      check_constraint :prototype, "prototype_database_bindings_prototype",
        check: "prototype IS TRUE"

      check_constraint :auditor_user_id, "prototype_database_bindings_auditor_not_operator",
        check: "auditor_user_id IS NULL OR auditor_user_id <> operator_user_id"

      check_constraint :dataset_class, "prototype_database_bindings_dataset_class",
        check: "dataset_class = '#{@dataset_class}'"

      check_constraint :policy_id, "prototype_database_bindings_policy_id",
        check: "policy_id = '#{@policy_id}'"

      check_constraint :policy_entry_sha256, "prototype_database_bindings_policy_entry_sha256",
        check: "policy_entry_sha256 ~ '^[0-9a-f]{64}$'"

      check_constraint :funding_id, "prototype_database_bindings_funding_id",
        check: "funding_id = '#{@funding_id}'"

      check_constraint :witness_mode, "prototype_database_bindings_witness_mode",
        check: "witness_mode = '#{@witness_mode}'"

      check_constraint :database, "prototype_database_bindings_database",
        check: "database = '#{@database}'"

      check_constraint :database_oid, "prototype_database_bindings_database_oid",
        check: "database_oid > 0"
    end

    custom_statements do
      for {name, up_sql, down_sql} <-
            SdrAgent.Audit.SQL.append_only("prototype_database_bindings") do
        statement name do
          up up_sql
          down down_sql
        end
      end
    end
  end

  actions do
    defaults [:read]

    # D-237 setup phase 2 only: authorized solely by
    # `SdrAgent.Prototype.Checks.KernelMarker` with the `:setup` marker. The
    # caller supplies the instance, the anchor and optional auditor, the
    # compiled policy entry's digest and the live identity it read inside
    # the same transaction; every fixed value is set here, and the tenant is
    # the kernel actor's.
    create :create do
      description "D-237 setup: the singleton prototype database binding."

      accept [
        :instance_id,
        :operator_user_id,
        :auditor_user_id,
        :policy_entry_sha256,
        :database_oid,
        :system_identifier
      ]

      change set_attribute(:dataset_class, @dataset_class)
      change set_attribute(:policy_id, @policy_id)
      change set_attribute(:funding_id, @funding_id)
      change set_attribute(:witness_mode, @witness_mode)
      change set_attribute(:database, @database)
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds

      change {SdrAgent.Audit.Changes.AppendEvent,
              event_type: "prototype.binding.created", category: :domain_change}
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if Checks.KernelContext
    end

    policy action(:create) do
      authorize_if {SdrAgent.Prototype.Checks.KernelMarker, marker: :setup}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :singleton, :boolean do
      allow_nil? false
      default true
      writable? false
      public? true
    end

    attribute :prototype, :boolean do
      allow_nil? false
      default true
      writable? false
      public? true
    end

    attribute :instance_id, :uuid, allow_nil?: false, public?: true

    attribute :dataset_class, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\Areal_prototype\z/]

    attribute :policy_id, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\Ad237-prototype\/1\z/]

    attribute :policy_entry_sha256, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :funding_id, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\Ad237-funding\/1\z/]

    attribute :witness_mode, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\Aabsent\z/]

    attribute :database, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\Asdr_agent_prototype\z/]

    attribute :database_oid, :integer, allow_nil?: false, public?: true, constraints: [min: 1]
    attribute :system_identifier, :integer, allow_nil?: false, public?: true

    attribute :bound_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      default &SdrAgent.Clock.utc_now/0
      public? true
    end

    attribute :trace_id, :string, allow_nil?: false, public?: true
    attribute :span_id, :string, allow_nil?: false, public?: true
  end

  relationships do
    belongs_to :tenant, SdrAgent.Audit.Tenant do
      allow_nil? false
      public? true
    end

    belongs_to :operator_user, SdrAgent.Accounts.User do
      allow_nil? false
      public? true
    end

    belongs_to :auditor_user, SdrAgent.Accounts.User do
      public? true
    end
  end

  identities do
    identity :unique_singleton, [:singleton]
    identity :unique_id_tenant_operator, [:id, :tenant_id, :operator_user_id]
    # S-B2: the composite foreign-key target of `SdrAgent.Operations.MacWorker`
    # (index `prototype_database_bindings_unique_id_tenant_index`).
    identity :unique_id_tenant, [:id, :tenant_id]
  end

  @doc "The fixed values the database checks, by column."
  @spec fixed_values() :: %{atom() => String.t()}
  def fixed_values do
    %{
      dataset_class: @dataset_class,
      policy_id: @policy_id,
      funding_id: @funding_id,
      witness_mode: @witness_mode,
      database: @database
    }
  end
end
