defmodule SdrAgent.Research.DossierEntry do
  @moduledoc """
  One imported row of a D-237 prototype dossier (interfaces r6 IF-6
  "Tables"; plan r3 `dossier_entries`): the account, contact and lead it
  created, and the provenance that admitted it.

  Attributes: `dossier_sha256` and `row_id` (the import key, with the
  tenant UNIQUE), `spotcheck_sha256` (the spot-check manifest digest);
  `email_kind` (only `:personal_work` is importable), `contact_classification`
  (always `:unverified`, never promoted), `contact_confidence` (`:high`,
  `:medium`, `:low`); `claims_sha256` (→ Payload: exactly the three claim
  records with their source type, basis, attribution excerpt, URLs, check
  time, result and relation) and `notes_sha256` (→ Payload: the labelled
  targeting notes); `imported_at` and the trace ids.

  Relationships: Tenant, Lead, Account, Contact and the importing
  `PrototypeDelegation`, all RESTRICT; both payload hashes are composite
  `(tenant_id, sha256)` foreign keys to `payloads`.

  APPEND-ONLY (trigger). Every entry counts toward the binding-wide contact
  cap. The schema is frozen by S1 (D-237 freeze); the `:import` shell (its
  name, empty accept list, server-derived tenant, trace ids and the
  `OperatorAction(:import_dossier)` policy) is S1's and refuses every call
  until S3 delivers its body (`SdrAgent.Research.Changes.ImportPending`).
  Reads here: the audit kernel.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Research,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Checks

  @email_kinds [:personal_work]
  @classifications [:unverified]
  @confidences [:high, :medium, :low]

  postgres do
    table "dossier_entries"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :lead, on_delete: :restrict
      reference :account, on_delete: :restrict
      reference :contact, on_delete: :restrict
      reference :delegation, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "dossier_entries_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :dossier_sha256, "dossier_entries_digests",
        check: "dossier_sha256 ~ '^[0-9a-f]{64}$' AND spotcheck_sha256 ~ '^[0-9a-f]{64}$'"

      check_constraint :row_id, "dossier_entries_row_id",
        check: "row_id ~ '^[a-z0-9][a-z0-9-]{0,31}$'"

      check_constraint :email_kind, "dossier_entries_email_kind",
        check: SdrAgent.Audit.SQL.one_of("email_kind", @email_kinds)

      check_constraint :contact_classification, "dossier_entries_contact_classification",
        check: SdrAgent.Audit.SQL.one_of("contact_classification", @classifications)

      check_constraint :contact_confidence, "dossier_entries_contact_confidence",
        check: SdrAgent.Audit.SQL.one_of("contact_confidence", @confidences)

      check_constraint :claims_sha256, "dossier_entries_payload_lengths",
        check: "octet_length(claims_sha256) = 32 AND octet_length(notes_sha256) = 32"
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("dossier_entries") do
        statement name do
          up up_sql
          down down_sql
        end
      end

      for column <- [:claims_sha256, :notes_sha256] do
        {name, up_sql, down_sql} = SdrAgent.Audit.SQL.payload_fk("dossier_entries", column)

        statement name do
          up up_sql
          down down_sql
          after_tables ["payloads"]
        end
      end
    end
  end

  actions do
    defaults [:read]

    # D-237 shell (S1; Codex d4196c02): the name, an explicit empty accept
    # list, the server-derived tenant and trace ids, and the operator policy.
    # S3 replaces the pending refusal with the body (accepted inputs,
    # arguments, validated changes, audit, replay and cap).
    create :import do
      accept []
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change SdrAgent.Research.Changes.ImportPending
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if Checks.KernelContext
    end

    policy action(:import) do
      authorize_if {SdrAgent.Prototype.Checks.OperatorAction, action: :import_dossier}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :dossier_sha256, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :row_id, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A[a-z0-9][a-z0-9-]{0,31}\z/]

    attribute :spotcheck_sha256, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :email_kind, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: @email_kinds]

    attribute :contact_classification, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: @classifications]

    attribute :contact_confidence, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: @confidences]

    attribute :claims_sha256, :binary, allow_nil?: false, public?: true
    attribute :notes_sha256, :binary, allow_nil?: false, public?: true

    attribute :imported_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      default &SdrAgent.Clock.utc_now/0
      public? true
    end

    attribute :trace_id, :string, allow_nil?: false, public?: true
    attribute :span_id, :string, allow_nil?: false, public?: true
  end

  relationships do
    belongs_to :tenant, SdrAgent.Audit.Tenant, allow_nil?: false, public?: true
    belongs_to :lead, SdrAgent.Sales.Lead, allow_nil?: false, public?: true
    belongs_to :account, SdrAgent.Sales.Account, allow_nil?: false, public?: true
    belongs_to :contact, SdrAgent.Sales.Contact, allow_nil?: false, public?: true

    belongs_to :delegation, SdrAgent.Operations.PrototypeDelegation,
      allow_nil?: false,
      public?: true

    has_many :sources, SdrAgent.Research.DossierSource,
      destination_attribute: :entry_id,
      public?: true
  end

  identities do
    identity :unique_dossier_row, [:tenant_id, :dossier_sha256, :row_id]
  end
end
