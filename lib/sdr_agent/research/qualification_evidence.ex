defmodule SdrAgent.Research.QualificationEvidence do
  @moduledoc """
  Join row: an evidence claim a qualification cites (S2 row
  QualificationEvidence).

  Attributes: `qualification_id`, `evidence_claim_id` (unique together).
  APPEND-ONLY (trigger); created only inside the Qualification create
  (`:link` requires the private `SdrAgent.Sales.Checks.QualificationContext`
  marker that `SdrAgent.Research.Changes.RecordOutcome` sets), which also
  checks that the claim belongs to the qualification's lead. Covered by the
  parent's AuditEvent (cited claim ids), so it appends none of its own.
  Reads: ADM, REV, AUR, AGT, AUD.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Research,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Checks

  postgres do
    table "qualification_evidences"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :qualification, on_delete: :restrict
      reference :evidence_claim, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "qualification_evidences_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("qualification_evidences") do
        statement name do
          up up_sql
          down down_sql
        end
      end
    end
  end

  actions do
    defaults [:read]

    create :link do
      description "Inside the Qualification create only: link a cited claim."
      accept [:qualification_id, :evidence_claim_id]
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action(:link) do
      forbid_unless SdrAgent.Sales.Checks.QualificationContext
      authorize_if {Checks.ActorType, types: [:agent_runtime]}
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer]}
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer, :auditor]}
      authorize_if {Checks.ActorType, types: [:agent_runtime, :auditor_cli]}
    end
  end

  attributes do
    uuid_v7_primary_key :id
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
      public? true
    end

    belongs_to :qualification, SdrAgent.Research.Qualification do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :evidence_claim, SdrAgent.Research.EvidenceClaim do
      allow_nil? false
      attribute_writable? true
      public? true
    end
  end

  identities do
    identity :unique_citation, [:qualification_id, :evidence_claim_id]
  end
end
