defmodule SdrAgent.Audit do
  @moduledoc """
  Audit bounded context — the lowest domain (ADR-0009 layering) and the
  system of record (ADR-0002).

  Resources: `Tenant`, `Payload`, `AuditEvent`, `AuditChainHead`,
  `ProvenanceSnapshot`, `AuditAccess`, `RetentionMarker` (S3; anchors and
  exports arrive in S11). Audit holds FKs only to its own resources and
  stores every higher-domain id as a plain value.

  ## Public kernel API (used by every other domain)

    * `bootstrap/1` — KRN: create the singleton tenant and genesis chain.
    * `append/2` — **the single entry point** for appending an AuditEvent;
      joins the caller's transaction. Domain actions normally use the shared
      change `SdrAgent.Audit.Changes.AppendEvent` instead, which calls it in
      the action's transaction.
    * `transaction/1` — a transaction that defers `authz.denied` appends of
      guarded calls made inside it until it has finished.
    * `put_payload/3`, `read_content/2` — content-addressed bodies;
      reading content is audited (AuditAccess) and fails closed.
    * `verify_chain/1` — verify the actor's tenant chain (ADM, AUR, AUD);
      recorded as an AuditAccess.
    * `record_access/5` — record an audit-data view (S10 timeline views,
      S11 exports) as AuditAccess + AuditEvent in one transaction.
    * reads: `list_events/1`, `list_payloads/1`, `list_accesses/1`,
      `list_exports/1`,
      `get_chain_head/1`, `get_provenance_snapshot/2`,
      `current_retention_marker/3`; write: `set_retention_marker/2`.

  Every function takes `actor:`; guarded calls go through
  `SdrAgent.Audit.Guard`, so denials of guarded actions and every refused
  auditor (AUR) mutation are themselves audited.
  """
  use Ash.Domain,
    otp_app: :sdr_agent

  require Ash.Query

  alias SdrAgent.Actor
  alias SdrAgent.Audit.AuditAccess
  alias SdrAgent.Audit.AuditAnchor
  alias SdrAgent.Audit.AuditChainHead
  alias SdrAgent.Audit.AuditEvent
  alias SdrAgent.Audit.AuditExport
  alias SdrAgent.Audit.AuditSigningKey
  alias SdrAgent.Audit.AnchorSinkReceipt
  alias SdrAgent.Audit.Guard
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Audit.Payload
  alias SdrAgent.Audit.ProvenanceSnapshot
  alias SdrAgent.Audit.RetentionMarker
  alias SdrAgent.Audit.Tenant

  resources do
    resource SdrAgent.Audit.Tenant
    resource SdrAgent.Audit.Payload
    resource SdrAgent.Audit.AuditEvent
    resource SdrAgent.Audit.AuditChainHead
    resource SdrAgent.Audit.ProvenanceSnapshot
    resource SdrAgent.Audit.AuditAccess
    resource SdrAgent.Audit.RetentionMarker
    resource SdrAgent.Audit.AuditSigningKey
    resource SdrAgent.Audit.AuditAnchor
    resource SdrAgent.Audit.AnchorSinkReceipt
    resource SdrAgent.Audit.AuditExport
  end

  @doc "Version of the authorization policy set recorded on every event."
  def policy_version, do: Kernel.policy_version()

  @doc """
  Creates the singleton tenant (`slug:`, `name:`), its genesis chain head and
  the genesis event, or returns the existing tenant. Runs as KRN.
  """
  def bootstrap(opts) do
    kernel = Actor.system(:kernel, nil)

    case Tenant
         |> Ash.Query.for_read(:read, %{}, actor: kernel)
         |> Ash.Query.filter(singleton == true)
         |> Ash.read_one() do
      {:ok, nil} ->
        Tenant
        |> Ash.Changeset.for_create(
          :bootstrap,
          %{slug: Keyword.fetch!(opts, :slug), name: Keyword.fetch!(opts, :name)},
          actor: kernel
        )
        |> Ash.create()

      other ->
        other
    end
  end

  @doc """
  Appends one AuditEvent (see `SdrAgent.Audit.Kernel`). `attrs`:
  `event_type`, `category`, optional `subject_resource`, `subject_id`,
  `action`, `payload`, `causation_id`, `correlation_id`, `idempotency_key`,
  `attempt`, `version_refs`, `agent_run_id`, `decision_id`,
  `model_invocation_id`, `tool_invocation_id`. `opts`: `actor:` (recorded;
  nil = anonymous), `tenant_id:`.
  """
  defdelegate append(attrs, opts), to: Kernel

  @doc "Runs `fun` in a transaction; guarded denials inside it are appended after it ends."
  defdelegate transaction(fun), to: Guard

  @doc "Stores `content` (insert-if-absent by sha256). System actors only."
  def put_payload(content, content_type, opts) do
    actor = Keyword.get(opts, :actor)

    Guard.run(%{resource: Payload, action: :store}, actor, fn ->
      Payload
      |> Ash.Changeset.for_create(:store, %{content: content, content_type: content_type},
        actor: actor
      )
      |> Ash.create()
    end)
  end

  @doc "Returns a payload's content after recording a payload_view access (guarded)."
  def read_content(sha256, opts) do
    actor = Keyword.get(opts, :actor)
    meta = %{resource: Payload, action: :read_content, guarded?: true, subject_id: hex(sha256)}

    Guard.run(meta, actor, fn ->
      Payload
      |> Ash.ActionInput.for_action(
        :read_content,
        %{sha256: sha256, purpose: Keyword.get(opts, :purpose)},
        actor: actor
      )
      |> Ash.run_action()
    end)
  end

  @doc """
  Verifies the actor's tenant chain (ADM, AUR, AUD; guarded) and records the
  verification. Returns `{:ok, %{valid?:, issues:, last_sequence:,
  events_checked:}}`; see `SdrAgent.Audit.Verifier` for the issue types.
  """
  def verify_chain(opts \\ []) do
    actor = Keyword.get(opts, :actor)

    Guard.run(%{resource: AuditEvent, action: :verify_chain, guarded?: true}, actor, fn ->
      AuditEvent
      |> Ash.ActionInput.for_action(:verify_chain, %{}, actor: actor)
      |> Ash.run_action()
    end)
  end

  @doc """
  Records that `actor` viewed audit data (`kind`: `:timeline_view`,
  `:record_view`, `:payload_download`, `:export`, …) as an AuditAccess and
  its AuditEvent in one transaction. Callers must serve the data only on
  `{:ok, access}` (fail closed).
  """
  def record_access(kind, target_resource, target_ref, purpose, opts) do
    Kernel.record_access(kind, target_resource, target_ref, purpose, Keyword.get(opts, :actor))
  end

  @doc "Registers public signing-key provenance. Private key material is rejected by the resource API."
  def register_signing_key(attrs, opts) do
    AuditSigningKey
    |> Ash.Changeset.for_create(:register, attrs, Kernel.opts())
    |> Ash.create(actor: Keyword.get(opts, :actor))
  end

  @doc "Marks a signing key rotated."
  def rotate_signing_key(id, opts) do
    with {:ok, key} <- Ash.get(AuditSigningKey, id, actor: Keyword.get(opts, :actor)) do
      key
      |> Ash.Changeset.for_update(:rotate, %{}, actor: Keyword.get(opts, :actor))
      |> Ash.update()
    end
  end

  @doc "Revokes a signing key with an operator-visible reason."
  def revoke_signing_key(id, reason, opts) do
    with {:ok, key} <- Ash.get(AuditSigningKey, id, actor: Keyword.get(opts, :actor)) do
      key
      |> Ash.Changeset.for_update(:revoke, %{revocation_reason: reason},
        actor: Keyword.get(opts, :actor)
      )
      |> Ash.update()
    end
  end

  @doc "S11 resource modules exposed for internal orchestration and audits."
  def s11_resources, do: [AuditSigningKey, AuditAnchor, AnchorSinkReceipt, AuditExport]

  @doc "Sets a retention marker (ADM); corrections must supersede the current marker."
  def set_retention_marker(attrs, opts) do
    actor = Keyword.get(opts, :actor)

    Guard.run(%{resource: RetentionMarker, action: :set}, actor, fn ->
      RetentionMarker
      |> Ash.Changeset.for_create(:set, attrs, actor: actor)
      |> Ash.create()
    end)
  end

  @doc "The current retention marker of a target, or `{:ok, nil}`."
  def current_retention_marker(target_resource, target_ref, opts) do
    RetentionMarker
    |> Ash.Query.for_read(
      :current,
      %{target_resource: target_resource, target_ref: target_ref},
      actor: Keyword.get(opts, :actor)
    )
    |> tenant_scope(Keyword.get(opts, :actor))
    |> Ash.read_one()
  end

  @doc "The actor's tenant's events in sequence order."
  def list_events(opts) do
    actor = Keyword.get(opts, :actor)

    AuditEvent
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> tenant_scope(actor)
    |> Ash.Query.sort(sequence: :asc)
    |> Ash.read()
  end

  @doc "Payload metadata of the actor's tenant (content hidden)."
  def list_payloads(opts) do
    actor = Keyword.get(opts, :actor)

    Payload
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> tenant_scope(actor)
    |> Ash.read()
  end

  @doc "AuditAccess rows of the actor's tenant."
  def list_accesses(opts) do
    actor = Keyword.get(opts, :actor)

    AuditAccess
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> tenant_scope(actor)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read()
  end

  @doc "AuditExport rows of the actor's tenant, newest first (S10 exports view; ADM, AUR, AUD)."
  def list_exports(opts) do
    actor = Keyword.get(opts, :actor)

    AuditExport
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> tenant_scope(actor)
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.read()
  end

  @doc "The actor's tenant chain head."
  def get_chain_head(opts) do
    actor = Keyword.get(opts, :actor)

    AuditChainHead
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> tenant_scope(actor)
    |> Ash.read_one()
  end

  @doc "A provenance snapshot by id."
  def get_provenance_snapshot(id, opts) do
    Ash.get(ProvenanceSnapshot, id, actor: Keyword.get(opts, :actor))
  end

  defp tenant_scope(query, %{tenant_id: tenant_id}) when is_binary(tenant_id),
    do: Ash.Query.filter(query, tenant_id == ^tenant_id)

  # An operator without a tenant reads nothing (fail closed).
  defp tenant_scope(query, %SdrAgent.Accounts.User{}), do: Ash.Query.filter(query, false)
  defp tenant_scope(query, _actor), do: query

  defp hex(bin) when is_binary(bin), do: Base.encode16(bin, case: :lower)
  defp hex(_other), do: nil
end
