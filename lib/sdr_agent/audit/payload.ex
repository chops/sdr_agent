defmodule SdrAgent.Audit.Payload do
  @moduledoc """
  Content-addressed store of full bodies (S2 row Payload; ADR-0002
  "ModelPayload", generalised): model requests/responses, tool I/O, decision
  inputs, artifact content, rendered messages, webhook bodies.

  Keyed by `(tenant_id, sha256)`; `byte_size`, `content_type` and the
  verbatim `content` (never truncated or redacted — synthetic data only).

  Actions:

    * `:store` — system actors (AGT, DLV, WHK, REC, KRN, SEED);
      insert-if-absent: the sha256 is computed from the content and an
      existing row is returned unchanged. No AuditEvent (every referencing
      event carries the hash).
    * `:read` — metadata for ADM, REV, AUR, AUD; `content` is hidden by a
      field policy.
    * `:read_content` — ADM, REV, AUR, AUD: returns the content after
      appending an AuditAccess (`payload_view`) and its event in the same
      transaction (fail closed). A guarded action (denials are audited).
    * `:read_reconciliation_content` — REC only, and only inside the private
      scope `SdrAgent.Agents.read_reconciliation_payloads/2` attaches
      (`SdrAgent.Audit.Checks.ReconciliationScope`): one invocation's
      request/response hashes in the actor's tenant. Takes no purpose — the
      recorded purpose is fixed by the scope. Same fail-closed
      `payload_view` access as `:read_content`, under REC's own identity
      (S12 supplementary ruling S1–S3).

  Append-only (trigger).
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Audit,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Expr

  alias SdrAgent.Audit.Checks

  postgres do
    table "payloads"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "payloads_trace_ids", check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :sha256, "payloads_sha256_length",
        check: "octet_length(sha256) = 32 AND byte_size >= 0"
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("payloads") do
        statement name do
          up up_sql
          down down_sql
        end
      end
    end
  end

  field_policies do
    field_policy :content do
      authorize_if Checks.KernelContext
    end

    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    defaults [:read]

    create :store do
      accept [:content, :content_type]
      upsert? true
      upsert_fields []
      upsert_condition Ash.Expr.expr(false)
      return_skipped_upsert? true
      change SdrAgent.Audit.Changes.SetTenant

      change fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :content) do
          content when is_binary(content) ->
            changeset
            |> Ash.Changeset.force_change_attribute(:sha256, :crypto.hash(:sha256, content))
            |> Ash.Changeset.force_change_attribute(:byte_size, byte_size(content))

          _ ->
            changeset
        end
      end

      change SdrAgent.Audit.Changes.TraceIds
    end

    action :read_content, :binary do
      description "Return a payload's content, recording a payload_view AuditAccess first."
      # The kernel opens (or joins) the transaction itself, so a refusal does
      # not abort a caller's enclosing transaction.
      transaction? false
      argument :sha256, :binary, allow_nil?: false
      argument :purpose, :string

      run fn input, context ->
        SdrAgent.Audit.Kernel.read_content(
          input.arguments.sha256,
          Map.get(input.arguments, :purpose),
          context.actor
        )
      end
    end

    action :read_reconciliation_content, :binary do
      description "REC: return one scoped invocation payload, recording a payload_view first."
      transaction? false
      argument :sha256, :binary, allow_nil?: false

      run fn input, context ->
        {:ok, scope} = Checks.ReconciliationScope.fetch(input.context)

        SdrAgent.Audit.Kernel.read_content(
          input.arguments.sha256,
          Checks.ReconciliationScope.purpose(scope),
          context.actor
        )
      end
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      authorize_if action(:read_content)
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action(:store) do
      authorize_if {Checks.ActorType,
                    types: [
                      :agent_runtime,
                      :delivery_worker,
                      :webhook_ingestor,
                      :reconciler,
                      :kernel,
                      :seeder
                    ]}
    end

    policy action(:read_content) do
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer, :auditor]}
      authorize_if {Checks.ActorType, types: [:auditor_cli]}
    end

    policy action(:read_reconciliation_content) do
      authorize_if Checks.ReconciliationScope
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer, :auditor]}
      authorize_if {Checks.ActorType, types: [:auditor_cli]}
    end
  end

  attributes do
    attribute :sha256, :binary do
      primary_key? true
      allow_nil? false
      writable? false
      public? true
    end

    attribute :byte_size, :integer do
      allow_nil? false
      writable? false
      constraints min: 0
      public? true
    end

    attribute :content_type, :string, allow_nil?: false, public?: true
    attribute :content, :binary, allow_nil?: false, public?: true
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
      primary_key? true
      allow_nil? false
      public? true
    end
  end
end
