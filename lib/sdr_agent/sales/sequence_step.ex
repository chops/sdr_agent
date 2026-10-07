defmodule SdrAgent.Sales.SequenceStep do
  @moduledoc """
  One touch in a sequence (S2 row SequenceStep; MVP: an initial email and
  one follow-up).

  Attributes: `sequence_id`, `position` (≥ 1, unique per sequence),
  `channel` (`:email`), `delay_days` (≥ 0; position 1 must be 0),
  `instructions` (agent guidance), `requires_approval` and `stop_on_reply`
  (always true in the MVP — Tier 0; database check constraints).

  Steps are created (`:add`) and edited (`:update`) only while the parent
  sequence is draft; the parent row is locked for the check, so a step
  cannot be added while the sequence is being activated. No destroy.

  Actors: ADM add, update; SEED (dev/test only) `:seed`; ADM, REV, AUR, AGT,
  AUD read. Every write appends an AuditEvent (`sales.sequence_step.*`).
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Sales,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Changes.AppendEvent
  alias SdrAgent.Audit.Checks
  alias SdrAgent.Sales.Changes

  @fields [:position, :channel, :delay_days, :instructions, :requires_approval, :stop_on_reply]
  @draft_parent {Changes.RelatedInState,
                 resource: SdrAgent.Sales.Sequence,
                 id: :sequence_id,
                 in: [:draft],
                 lock: :for_update,
                 message: "steps change only while the sequence is draft"}

  postgres do
    table "sequence_steps"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :sequence, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "sequence_steps_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :delay_days, "sequence_steps_first_step_immediate",
        check: "position <> 1 OR delay_days = 0",
        message: "the first step has no delay"

      check_constraint :requires_approval, "sequence_steps_tier_zero",
        check: "requires_approval = true AND stop_on_reply = true",
        message: "every step requires approval and stops on reply (Tier 0)"

      check_constraint :channel, "sequence_steps_channel", check: "channel = 'email'"
    end
  end

  actions do
    defaults [:read]

    create :add do
      description "ADM: add a step to a draft sequence."
      accept [:sequence_id | @fields]
      change @draft_parent
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change {AppendEvent, event_type: "sales.sequence_step.created", category: :domain_change}
    end

    create :seed do
      description "SEED (dev/test only): add a step with a fixture id to a draft sequence."
      accept [:id, :sequence_id | @fields]
      change @draft_parent
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change {AppendEvent, event_type: "sales.sequence_step.created", category: :domain_change}
    end

    update :update do
      description "ADM: edit a step of a draft sequence."
      require_atomic? false
      accept [:channel, :delay_days, :instructions]
      change get_and_lock_for_update()
      change @draft_parent
      change {AppendEvent, event_type: "sales.sequence_step.updated", category: :domain_change}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action([:add, :update]) do
      authorize_if {Checks.ActorRole, roles: [:admin]}
    end

    policy action(:seed) do
      authorize_if Checks.SeedingAllowed
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer, :auditor]}

      authorize_if {Checks.ActorType,
                    types: [
                      :agent_runtime,
                      :auditor_cli,
                      :seeder,
                      :delivery_worker,
                      :reconciler,
                      :scheduler
                    ]}
    end
  end

  attributes do
    uuid_v7_primary_key :id, writable?: true

    attribute :position, :integer do
      allow_nil? false
      constraints min: 1
      public? true
    end

    attribute :channel, :atom do
      allow_nil? false
      constraints one_of: [:email]
      public? true
    end

    attribute :delay_days, :integer do
      allow_nil? false
      constraints min: 0
      public? true
    end

    attribute :instructions, :string, allow_nil?: false, public?: true
    attribute :requires_approval, :boolean, allow_nil?: false, default: true, public?: true
    attribute :stop_on_reply, :boolean, allow_nil?: false, default: true, public?: true
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

    belongs_to :sequence, SdrAgent.Sales.Sequence do
      allow_nil? false
      attribute_writable? true
      public? true
    end
  end

  identities do
    identity :unique_position, [:sequence_id, :position]
  end

  @doc false
  def __sdr_audited__, do: true
end
