defmodule SdrAgent.Outreach.RevisionCitation do
  @moduledoc """
  Which accepted evidence claim a claim or personalization sentence of a
  revision rests on (S2 row RevisionCitation; spec §9/§10 "click a sentence
  → see evidence").

  Attributes: `draft_revision_id`, `evidence_claim_id`, `kind` (`:claim` |
  `:personalization`), `text` (verbatim in the revision body), `confidence`.
  Unique per (revision, claim, kind, text).

  APPEND-ONLY (trigger). Created only inside its DraftRevision create
  (`SdrAgent.Outreach.Checks.InternalWrite`); the claim must be an accepted
  EvidenceClaim of the draft's lead and the text must appear verbatim in the
  body (`SdrAgent.Outreach.Changes.CitationRules`). Covered by the parent
  revision's event payload (no event of its own). Reads: ADM, REV, AUR, AGT,
  DLV, AUD.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Outreach,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Checks
  alias SdrAgent.Outreach.Checks.InternalWrite

  postgres do
    table "revision_citations"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :draft_revision, on_delete: :restrict
      reference :evidence_claim, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "revision_citations_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :kind, "revision_citations_kind",
        check: SdrAgent.Audit.SQL.one_of("kind", [:claim, :personalization])
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("revision_citations") do
        statement name do
          up up_sql
          down down_sql
        end
      end
    end
  end

  actions do
    defaults [:read]

    create :create do
      description "Inside a DraftRevision create only."
      accept [:draft_revision_id, :evidence_claim_id, :kind, :text, :confidence]
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Outreach.Changes.CitationRules
      change SdrAgent.Audit.Changes.TraceIds
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action(:create) do
      forbid_unless InternalWrite
      authorize_if {Checks.ActorType, types: [:agent_runtime]}
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer]}
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer, :auditor]}
      authorize_if {Checks.ActorType, types: [:agent_runtime, :delivery_worker, :auditor_cli]}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :kind, :atom do
      allow_nil? false
      constraints one_of: [:claim, :personalization]
      public? true
    end

    attribute :text, :string do
      allow_nil? false
      constraints trim?: false
      public? true
    end

    attribute :confidence, :float do
      constraints min: 0.0, max: 1.0
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
  end

  relationships do
    belongs_to :tenant, SdrAgent.Audit.Tenant do
      allow_nil? false
      public? true
    end

    belongs_to :draft_revision, SdrAgent.Outreach.DraftRevision do
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
    identity :unique_citation, [:draft_revision_id, :evidence_claim_id, :kind, :text]
  end
end
