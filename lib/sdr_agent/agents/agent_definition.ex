defmodule SdrAgent.Agents.AgentDefinition do
  @moduledoc """
  Versioned, hashed definition of an agent (S2 row AgentDefinition): allowed
  actions, prompt and schema refs and model policy, as a canonical map.

  Attributes: `name`, `version` (identity `(tenant_id, name, version)`),
  `module`, `definition`, `definition_sha256` (canonical hash, computed),
  `status` (`active` → `retired`, terminal).

  Actions: `:register` (KRN; registering the same name/version with a
  different hash is refused by `SdrAgent.Agents.register_definition/2`),
  `:retire` (KRN). Only `status` ever changes. Every write is audited
  (`agents.definition.registered`, `agents.definition.retired`).
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Checks

  @transitions [{:retire, [:active], :retired}]
  @statuses [:active, :retired]

  postgres do
    table "agent_definitions"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "agent_definitions_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :status, "agent_definitions_status",
        check: SdrAgent.Audit.SQL.one_of("status", [:active, :retired])
    end
  end

  actions do
    defaults [:read]

    create :register do
      accept [:name, :version, :module, :definition]
      change SdrAgent.Audit.Changes.SetTenant

      change fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :definition) do
          definition when is_map(definition) ->
            Ash.Changeset.force_change_attribute(
              changeset,
              :definition_sha256,
              SdrAgent.Audit.Canonical.sha256(definition)
            )

          _ ->
            changeset
        end
      end

      change SdrAgent.Audit.Changes.TraceIds

      change {SdrAgent.Audit.Changes.AppendEvent,
              event_type: "agents.definition.registered", category: :domain_change}
    end

    update :retire do
      change {SdrAgent.Audit.Changes.Transition, from: [:active], to: :retired}

      change {SdrAgent.Audit.Changes.AppendEvent,
              event_type: "agents.definition.retired", category: :domain_change}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action([:register, :retire]) do
      authorize_if {Checks.ActorType, types: [:kernel]}
    end

    policy action_type(:read) do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true

    attribute :version, :integer do
      allow_nil? false
      constraints min: 1
      public? true
    end

    attribute :module, :string, allow_nil?: false, public?: true
    attribute :definition, :map, allow_nil?: false, public?: true
    attribute :definition_sha256, :binary, allow_nil?: false, writable?: false, public?: true

    attribute :status, :atom do
      allow_nil? false
      default :active
      writable? false
      constraints one_of: @statuses
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

    has_many :agent_runs, SdrAgent.Agents.AgentRun, public?: true
  end

  identities do
    identity :unique_name_version, [:tenant_id, :name, :version]
  end

  @doc "Declared lifecycle transitions `{action, from, to}` (ADR-0010)."
  def transitions, do: @transitions

  @doc false
  def __sdr_audited__, do: true
end
