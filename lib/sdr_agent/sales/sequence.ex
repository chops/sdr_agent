defmodule SdrAgent.Sales.Sequence do
  @moduledoc """
  A versioned, ordered set of outreach steps used by a campaign (S2 row
  Sequence; placed in Sales so Campaign can reference it without a
  Sales → Outreach cycle).

  Attributes: `name`, `version` (≥ 1; unique per tenant and name),
  `status`. Steps: `SdrAgent.Sales.SequenceStep`.

  Lifecycle (`transitions/0`): draft → active → retired (T). Activation
  needs at least one step; steps are created and edited only while the
  sequence is draft (a change after activation is a new version, i.e. a new
  sequence row with the next version). Activation locks the row, and step
  writes lock it too, so a step cannot slip in during activation.

  Actors: ADM create, update (draft), activate, retire; SEED (dev/test only)
  `:seed` and `:activate`; ADM, REV, AUR, AGT, AUD read. Every write appends
  an AuditEvent (`sales.sequence.*`).

  OPR `:seed_prototype` (D-237 seed, slice B; seed design D4 and D6 as
  ruled by Codex b8d624fe): the live prototype operator's version-1 draft
  sequence of the GTM seed. It accepts only `name`, derives the tenant and
  trace ids as `:create` does, and requires `seed_provenance_sha256`
  (exactly 64 lowercase hex characters, never trimmed or coerced), which its
  one `sales.sequence.created` event records as an argument. Policy:
  `OperatorAction(:seed_settings)` only. Its raw `name` and its stored
  value must pass `SdrAgent.Agents.RunSettings.ContentRules.text/1`
  (`SdrAgent.Sales.Validations.SeedText`, its first before-action check:
  after authorization, before any other hook).
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Sales,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Changes.AppendEvent
  alias SdrAgent.Audit.Changes.Transition
  alias SdrAgent.Audit.Checks
  alias SdrAgent.Sales.Changes

  @statuses [:draft, :active, :retired]
  @transitions [{:activate, [:draft], :active}, {:retire, [:active], :retired}]

  postgres do
    table "sequences"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "sequences_trace_ids", check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :status, "sequences_status",
        check: SdrAgent.Audit.SQL.one_of("status", @statuses)

      check_constraint :version, "sequences_version_positive", check: "version >= 1"
    end
  end

  actions do
    defaults [:read]

    create :create do
      description "ADM: create a draft sequence (version defaults to 1)."
      accept [:name, :version]
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change {AppendEvent, event_type: "sales.sequence.created", category: :domain_change}
    end

    create :seed do
      description "SEED (dev/test only): create a sequence with a fixture id."
      accept [:id, :name, :version]
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change {AppendEvent, event_type: "sales.sequence.created", category: :domain_change}
    end

    # D-237 slice B (seed design D4, D6; Codex b8d624fe): the operator's
    # version-1 draft sequence, with the seed's provenance digest on its event.
    create :seed_prototype do
      description "OPR (D-237): the GTM seed's version-1 draft sequence, with its provenance digest."
      accept [:name]

      argument :seed_provenance_sha256, :string,
        allow_nil?: false,
        constraints: [match: ~r/\A[0-9a-f]{64}\z/, trim?: false]

      validate {SdrAgent.Sales.Validations.SeedText, fields: [:name]}, before_action?: true

      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds

      change {AppendEvent,
              event_type: "sales.sequence.created",
              category: :domain_change,
              arguments: [:seed_provenance_sha256],
              context_links: [correlation_id: :sdr_seed_run_id]}
    end

    update :update do
      description "ADM: rename a draft sequence."
      require_atomic? false
      accept [:name]
      change get_and_lock_for_update()
      change {Changes.RequireState, in: [:draft]}
      change {AppendEvent, event_type: "sales.sequence.updated", category: :domain_change}
    end

    update :activate do
      description "ADM, SEED: draft → active; needs at least one step; freezes the steps."
      require_atomic? false
      change get_and_lock_for_update()
      change {Transition, from: [:draft], to: :active, locked?: true}
      change Changes.RequireSteps

      change {AppendEvent,
              event_type: "sales.sequence.activated",
              category: :domain_change,
              previous: [:status]}
    end

    update :retire do
      description "ADM: active → retired (terminal)."
      require_atomic? false
      change get_and_lock_for_update()
      change {Transition, from: [:active], to: :retired, locked?: true}

      change {AppendEvent,
              event_type: "sales.sequence.retired", category: :domain_change, previous: [:status]}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action([:create, :update, :retire]) do
      authorize_if {Checks.ActorRole, roles: [:admin]}
    end

    policy action(:activate) do
      authorize_if {Checks.ActorRole, roles: [:admin]}
      authorize_if Checks.SeedingAllowed
      authorize_if SdrAgent.Prototype.Checks.SeedScope
    end

    policy action(:seed) do
      authorize_if Checks.SeedingAllowed
    end

    # D-237 slice B: the live prototype operator only (its own line; the
    # broad create policy above authorizes always, so this one decides).
    policy action(:seed_prototype) do
      authorize_if {SdrAgent.Prototype.Checks.OperatorAction, action: :seed_settings}
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer, :auditor]}
      authorize_if {Checks.ActorType, types: [:agent_runtime, :auditor_cli, :seeder]}
    end
  end

  attributes do
    uuid_v7_primary_key :id, writable?: true
    attribute :name, :string, allow_nil?: false, public?: true

    attribute :version, :integer do
      allow_nil? false
      default 1
      constraints min: 1
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      default :draft
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

    has_many :steps, SdrAgent.Sales.SequenceStep do
      sort position: :asc
      public? true
    end
  end

  identities do
    identity :unique_name_version, [:tenant_id, :name, :version]
  end

  @doc "Declared lifecycle transitions `{action, from, to}` (ADR-0010)."
  def transitions, do: @transitions

  @doc false
  def __sdr_audited__, do: true
end
