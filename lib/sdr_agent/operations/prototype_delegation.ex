defmodule SdrAgent.Operations.PrototypeDelegation do
  @moduledoc """
  One acting agent session of the D-237 prototype operator (interfaces r6
  IF-3; amendment item 3 "The delegation"). Its id is the operator actor's
  id (`SdrAgent.Actor` type `:prototype_operator`).

  Attributes: `id`, `tenant_id`, `binding_id`, `operator_user_id` (the
  binding's anchor), `delegation_ref` (always `D-243`), `agent`
  (`claude_code` or `codex_cli`), `session_correlation` (an audit label
  matching `^[A-Za-z0-9._:-]{8,128}$`, not an authority), `started_at` and
  the trace ids.

  Keys: the composite foreign key `(binding_id, tenant_id,
  operator_user_id)` → `prototype_database_bindings (id, tenant_id,
  operator_user_id)` RESTRICT, so the database refuses a delegation naming
  any other anchor or tenant; UNIQUE `(binding_id, agent,
  session_correlation)`.

  CREATE-ONLY: a trigger rejects update, delete and truncate. Rows are
  written only by setup phase 2 (`:create_setup`, the kernel with the
  prototype `:setup` marker, `SdrAgent.Prototype.Checks.KernelMarker`) and
  by `SdrAgent.Prototype.enter_session/2` (event
  `prototype.delegation.created`). Reads: the audit kernel (the
  operator resolver's plain kernel read).
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Operations,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Checks

  @agents ["claude_code", "codex_cli"]
  @correlation ~r/\A[A-Za-z0-9._:-]{8,128}\z/

  postgres do
    table "prototype_delegations"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict

      reference :binding,
        on_delete: :restrict,
        match_with: [tenant_id: :tenant_id, operator_user_id: :operator_user_id],
        match_type: :full
    end

    check_constraints do
      check_constraint :trace_id, "prototype_delegations_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :delegation_ref, "prototype_delegations_ref",
        check: "delegation_ref = 'D-243'"

      check_constraint :agent, "prototype_delegations_agent",
        check: SdrAgent.Audit.SQL.one_of("agent", @agents)

      check_constraint :session_correlation, "prototype_delegations_session_correlation",
        check: "session_correlation ~ '^[A-Za-z0-9._:-]{8,128}$'"
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("prototype_delegations") do
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
    # `SdrAgent.Prototype.Checks.KernelMarker` with the `:setup` marker. It
    # accepts only the agent and the correlation; the binding, tenant and
    # anchor come from the singleton binding row.
    create :create_setup do
      description "D-237 setup: the setup session's delegation."
      accept [:agent, :session_correlation]
      change {SdrAgent.Operations.Changes.BindDelegation, from: :row}
      change SdrAgent.Audit.Changes.TraceIds

      change {SdrAgent.Audit.Changes.AppendEvent,
              event_type: "prototype.delegation.created", category: :domain_change}
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if Checks.KernelContext
    end

    policy action(:create_setup) do
      authorize_if {SdrAgent.Prototype.Checks.KernelMarker, marker: :setup}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :operator_user_id, :uuid, allow_nil?: false, public?: true

    attribute :delegation_ref, :string,
      allow_nil?: false,
      default: "D-243",
      writable?: false,
      public?: true

    attribute :agent, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A(claude_code|codex_cli)\z/]

    attribute :session_correlation, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: @correlation, trim?: false]

    attribute :started_at, :utc_datetime_usec do
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

    belongs_to :binding, SdrAgent.Operations.PrototypeDatabaseBinding do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_session, [:binding_id, :agent, :session_correlation]
  end

  @doc "The agents a delegation may name."
  @spec agents() :: [String.t()]
  def agents, do: @agents
end
