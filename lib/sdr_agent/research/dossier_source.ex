defmodule SdrAgent.Research.DossierSource do
  @moduledoc """
  One source of an imported D-237 dossier entry that has at least one
  verified excerpt (interfaces r6 IF-6 "Tables"; plan r3 `dossier_sources`).

  Attributes: `source_id` (the dossier's `s<n>`), `original_url` and
  `final_url` (https), `source_type` (`:company_site`, `:person_authored`,
  `:attributed_third_party`, `:directory`, `:third_party`, kept exactly as
  declared and spot-checked), `retrieved_on`, `checked_at` (from the
  spot-check), `content_sha256` (→ Payload: only that source's verified
  excerpts), `inserted_at` and the trace ids.

  Relationships: Tenant, Lead and the owning `DossierEntry`, all RESTRICT;
  the payload hash is a composite `(tenant_id, sha256)` foreign key to
  `payloads`. UNIQUE `(entry_id, source_id)`.

  APPEND-ONLY (trigger). The schema is frozen by S1 (D-237 freeze); the
  `:import` shell (its name, empty accept list, server-derived tenant, trace
  ids and the `OperatorAction(:import_dossier)` policy) is S1's and refuses
  every call until S3 delivers its body
  (`SdrAgent.Research.Changes.ImportPending`). Reads here: the audit kernel.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Research,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Checks

  @source_types [
    :company_site,
    :person_authored,
    :attributed_third_party,
    :directory,
    :third_party
  ]

  postgres do
    table "dossier_sources"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :lead, on_delete: :restrict
      reference :entry, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "dossier_sources_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :source_id, "dossier_sources_source_id",
        check: "source_id ~ '^s[0-9]{1,2}$'"

      check_constraint :final_url, "dossier_sources_https",
        check: "original_url ~ '^https://' AND final_url ~ '^https://'"

      check_constraint :source_type, "dossier_sources_source_type",
        check: SdrAgent.Audit.SQL.one_of("source_type", @source_types)

      check_constraint :content_sha256, "dossier_sources_content_sha256_length",
        check: "octet_length(content_sha256) = 32"
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("dossier_sources") do
        statement name do
          up up_sql
          down down_sql
        end
      end

      {name, up_sql, down_sql} = SdrAgent.Audit.SQL.payload_fk("dossier_sources", :content_sha256)

      statement name do
        up up_sql
        down down_sql
        after_tables ["payloads"]
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

    attribute :source_id, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\As[0-9]{1,2}\z/]

    attribute :original_url, :string,
      allow_nil?: false,
      public?: true,
      constraints: [trim?: false]

    attribute :final_url, :string, allow_nil?: false, public?: true, constraints: [trim?: false]

    attribute :source_type, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: @source_types]

    attribute :retrieved_on, :date, allow_nil?: false, public?: true
    attribute :checked_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :content_sha256, :binary, allow_nil?: false, public?: true

    attribute :inserted_at, :utc_datetime_usec do
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
    belongs_to :entry, SdrAgent.Research.DossierEntry, allow_nil?: false, public?: true
  end

  identities do
    identity :unique_entry_source, [:entry_id, :source_id]
  end

  @doc "The declared source types (interfaces r6 IF-6 \"Source types, defined\")."
  @spec source_types() :: [atom()]
  def source_types, do: @source_types
end
