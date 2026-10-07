defmodule SdrAgent.Agents.WireWitnessLink do
  @moduledoc """
  Durable corroboration of one observed HTTP exchange of a ClaudeCLI model
  call by the independent local proxy witness (S2 row WireWitnessLink;
  ADR-0005 S12 amendment; S12 entity ruling R1, C1–C5).

  Attributes: `model_invocation_id` (required FK, RESTRICT),
  `proxy_record_ref` (the proxy's opaque lowercase record UUID — never a
  path), `proxy_request_sha256` / `proxy_response_sha256` (32-byte digests
  of the raw bodies in the proxy store, nullable), `link_status`
  (`:inferred`, `:reconciled`, `:mismatch`), `method` (`:time_window`,
  `:propagated_id`), bounded allowlisted `evidence`
  (`SdrAgent.Agents.WitnessEvidence`), `supersedes_id`, `recorded_at` and the
  trace ids. Status is **exchange-scoped**: it never claims that all traffic
  of a call was captured (the invocation-level answer is S12c's
  `witness_status`).

  APPEND-ONLY with supersedes lineage per exchange `(tenant,
  model_invocation_id, proxy_record_ref)`: one root per exchange, each row
  superseded at most once, the current row has no successor. Upgrades and
  corrections append a successor of the current head that states its
  `supersede_reason`; a `mismatch` is superseded only under a different
  projection version (C3). Enforced by `SdrAgent.Agents.Changes.WitnessLineage`
  under a lock of the parent invocation, and in the database by partial
  unique indexes, a same-exchange composite foreign key, an insert trigger
  for C3 and the append-only triggers.

  Only terminal `:claude_cli` invocations can be linked. Writes: `:link`, REC
  only (through `SdrAgent.Agents.link_wire_witness/2`); reads: any actor
  that may read ModelInvocation metadata, scoped to its tenant by the
  domain functions. Audited: `agents.witness.linked` (invocation and run
  correlation, `record_sha256`) in the same transaction.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Changes.AppendEvent
  alias SdrAgent.Audit.Checks

  @statuses [:inferred, :reconciled, :mismatch]
  @methods [:time_window, :propagated_id]
  @record_ref "^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"

  postgres do
    table "wire_witness_links"
    repo SdrAgent.Repo

    identity_wheres_to_sql unique_root: "supersedes_id IS NULL",
                           unique_supersedes: "supersedes_id IS NOT NULL"

    references do
      reference :tenant, on_delete: :restrict
      reference :model_invocation, on_delete: :restrict
      reference :supersedes, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "wire_witness_links_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :link_status, "wire_witness_links_link_status",
        check: SdrAgent.Audit.SQL.one_of("link_status", @statuses)

      check_constraint :method, "wire_witness_links_method",
        check: SdrAgent.Audit.SQL.one_of("method", @methods)

      check_constraint :proxy_record_ref, "wire_witness_links_record_ref",
        check: "proxy_record_ref ~ '#{@record_ref}'"

      check_constraint :proxy_request_sha256, "wire_witness_links_digests",
        check:
          "(proxy_request_sha256 IS NULL OR octet_length(proxy_request_sha256) = 32) AND " <>
            "(proxy_response_sha256 IS NULL OR octet_length(proxy_response_sha256) = 32)"

      check_constraint :evidence, "wire_witness_links_evidence_object",
        check: "jsonb_typeof(evidence) = 'object' AND octet_length(evidence::text) <= 8192"
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("wire_witness_links") do
        statement name do
          up up_sql
          down down_sql
        end
      end

      for {name, up_sql, down_sql} <- SdrAgent.Agents.WitnessSQL.lineage() do
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
      description "REC: record (or supersede) the link of one witnessed exchange."

      accept [
        :model_invocation_id,
        :proxy_record_ref,
        :proxy_request_sha256,
        :proxy_response_sha256,
        :link_status,
        :method,
        :evidence,
        :supersedes_id
      ]

      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change SdrAgent.Agents.Changes.WitnessLineage

      change {AppendEvent,
              event_type: "agents.witness.linked",
              category: :model,
              links: [model_invocation_id: :model_invocation_id],
              context_links: [agent_run_id: :wire_witness_agent_run_id]}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action(:link) do
      authorize_if {Checks.ActorType, types: [:reconciler]}
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :proxy_record_ref, :string do
      allow_nil? false

      constraints match:
                    ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

      public? true
    end

    attribute :proxy_request_sha256, :binary, public?: true
    attribute :proxy_response_sha256, :binary, public?: true

    attribute :link_status, :atom do
      allow_nil? false
      constraints one_of: @statuses
      public? true
    end

    attribute :method, :atom do
      allow_nil? false
      constraints one_of: @methods
      public? true
    end

    attribute :evidence, :map, allow_nil?: false, default: %{}, public?: true

    attribute :recorded_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      default &SdrAgent.Clock.utc_now/0
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

    belongs_to :model_invocation, SdrAgent.Agents.ModelInvocation do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :supersedes, __MODULE__ do
      attribute_writable? true
      public? true
    end

    has_many :successors, __MODULE__ do
      destination_attribute :supersedes_id
      public? true
    end
  end

  identities do
    identity :unique_root, [:tenant_id, :model_invocation_id, :proxy_record_ref],
      where: expr(is_nil(supersedes_id))

    identity :unique_supersedes, [:supersedes_id], where: expr(not is_nil(supersedes_id))
  end

  @doc false
  def __sdr_audited__, do: true
end
