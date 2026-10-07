defmodule SdrAgent.Audit.Kernel do
  @moduledoc """
  The audit kernel: the only code that writes the ledger (ADR-0002,
  ADR-0009). Callers use `SdrAgent.Audit.append/2` or the shared
  `SdrAgent.Audit.Changes.AppendEvent` change; both land here.

  ## Append algorithm

  Inside the caller's database transaction (or a new one when none is open):

    1. lock the tenant's `AuditChainHead` row `FOR UPDATE` — this serialises
       all appends of a tenant, so the sequence is gap-free without a
       Postgres `SEQUENCE` (a rolled-back append also rolls back its head
       advance);
    2. resolve the current `ProvenanceSnapshot` (inserted if absent);
    3. build the event: `sequence = head + 1`, `prev_hash = head hash`,
       actor, authorization decision, clock time and source, version refs,
       causation/correlation/idempotency, and the trace/span ids of the
       current span (an `sdr.audit.append` span is opened if none is active);
    4. `canonical_bytes = Canonical.encode!(hashed columns)`,
       `event_hash = sha256(canonical_bytes)`;
    5. insert the AuditEvent and advance the head (guarded on the expected
       sequence);
    6. queue the event's commit-time notification for live views
       (`SdrAgent.LiveEvents.notify/1`; delivered only if the transaction
       commits);
    7. if the provenance snapshot was new, append `system.provenance.recorded`
       right after.

  Every kernel request runs as a `:kernel` `SdrAgent.Actor` with the kernel
  context marker (`SdrAgent.Audit.Checks.KernelContext`); ledger resources
  authorize writes only through that check.
  """

  require Ash.Query

  alias SdrAgent.Actor
  alias SdrAgent.Audit.AuditAccess
  alias SdrAgent.Audit.AuditChainHead
  alias SdrAgent.Audit.AuditEvent
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Audit.Checks.KernelContext
  alias SdrAgent.Audit.Payload
  alias SdrAgent.Audit.Provenance
  alias SdrAgent.Audit.ProvenanceSnapshot
  alias SdrAgent.Audit.RecordHash
  alias SdrAgent.Audit.Tenant
  alias SdrAgent.Audit.Trace
  alias SdrAgent.Audit.Verifier
  alias SdrAgent.Clock
  alias SdrAgent.LiveEvents
  alias SdrAgent.Repo

  @zero_hash <<0::256>>
  @policy_version "sdr-policy/1"

  # Every AuditEvent column except `event_hash` and `canonical_bytes`.
  @hashed_fields [
    :id,
    :tenant_id,
    :sequence,
    :prev_hash,
    :canonicalization_version,
    :hash_algorithm,
    :event_type,
    :category,
    :subject_resource,
    :subject_id,
    :action,
    :payload,
    :occurred_at,
    :inserted_at,
    :clock_source,
    :actor_type,
    :actor_id,
    :actor_role,
    :authorization,
    :provenance_snapshot_id,
    :version_refs,
    :causation_id,
    :correlation_id,
    :idempotency_key,
    :attempt,
    :trace_id,
    :span_id,
    :request_id,
    :agent_run_id,
    :decision_id,
    :model_invocation_id,
    :tool_invocation_id
  ]

  @doc "Version of the authorization policy set recorded on every event."
  def policy_version, do: @policy_version

  @doc "Genesis `prev_hash` (32 zero bytes)."
  def zero_hash, do: @zero_hash

  @doc "Columns covered by `canonical_bytes`."
  def hashed_fields, do: @hashed_fields

  @doc "Options for an Ash request made by the kernel for `tenant_id`."
  def opts(tenant_id \\ nil) do
    [actor: Actor.system(:kernel, tenant_id), context: KernelContext.context()]
  end

  @doc "Appends one event. See the moduledoc; `opts`: `:actor`, `:tenant_id`."
  @spec append(map() | keyword(), keyword()) :: {:ok, struct()} | {:error, term()}
  def append(attrs, opts) do
    traced_transaction(fn -> do_append(Map.new(attrs), opts) end)
  end

  @doc "Runs `fun` (returning `{:ok, v} | {:error, e}`) in the open transaction or a new one."
  def in_transaction(fun) do
    if Repo.in_transaction?() do
      fun.()
    else
      fn -> unwrap(fun.()) end
      |> Repo.transaction()
      |> normalize()
    end
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, error}), do: Repo.rollback(error)

  defp traced_transaction(fun), do: Trace.with_span(fn -> in_transaction(fun) end)

  # Ash rolls an enclosing transaction back with the failed changeset;
  # surface it as the usual Ash error class.
  defp normalize({:error, %Ash.Changeset{errors: errors}}),
    do: {:error, Ash.Error.to_error_class(errors)}

  defp normalize(result), do: result

  @doc """
  Appends an `authz.denied` event for a refused guarded action. Records the
  actor (anonymous when nil or invalid), resource, action and the attempted
  subject id as an untrusted string capped at 64 bytes; never arguments or
  content.
  """
  def append_denial(%{resource: resource, action: action} = meta, actor) do
    resource = if is_atom(resource), do: inspect(resource), else: to_string(resource)

    append(
      %{
        event_type: "authz.denied",
        category: :auth,
        subject_resource: resource,
        subject_id: cap(meta[:subject_id]),
        action: to_string(action),
        authorization: %{decision: :denied, action: "#{resource}.#{action}"},
        payload: %{resource: resource, action: to_string(action)}
      },
      actor: actor
    )
  end

  @doc """
  Appends an access event and its AuditAccess row in one transaction
  (S2 AuditAccess: fail closed — callers serve content only on `{:ok, _}`).
  """
  def record_access(kind, target_resource, target_ref, purpose, actor, extra \\ %{}) do
    traced_transaction(fn ->
      do_record_access(kind, target_resource, target_ref, purpose, actor, extra)
    end)
  end

  defp do_record_access(kind, target_resource, target_ref, purpose, actor, extra) do
    attrs = %{
      event_type: "audit.access.#{kind}",
      category: :access,
      subject_resource: target_resource,
      subject_id: target_ref,
      action: to_string(kind),
      payload:
        Map.merge(extra, %{
          access_kind: kind,
          target_resource: target_resource,
          target_ref: target_ref,
          purpose: purpose
        })
    }

    with {:ok, event} <- do_append(attrs, actor: actor) do
      AuditAccess
      |> Ash.Changeset.for_create(
        :record,
        %{
          tenant_id: event.tenant_id,
          actor_type: event.actor_type,
          actor_id: event.actor_id,
          access_kind: kind,
          target_resource: target_resource,
          target_ref: target_ref,
          purpose: purpose,
          accessed_at: event.occurred_at,
          audit_event_id: event.id,
          trace_id: event.trace_id,
          span_id: event.span_id
        },
        opts(event.tenant_id)
      )
      |> Ash.create(return_notifications?: true)
      |> ledger_write()
    end
  end

  @doc """
  Returns a payload's content for `actor` after recording a `payload_view`
  access (fail closed: no access record, no content).
  """
  def read_content(sha256, purpose, actor) do
    traced_transaction(fn -> do_read_content(sha256, purpose, actor) end)
  end

  defp do_read_content(sha256, purpose, actor) do
    with {:ok, tenant_id} <- resolve_tenant(%{}, actor, []),
         {:ok, payload} <- fetch_payload(tenant_id, sha256),
         {:ok, _access} <-
           do_record_access(
             :payload_view,
             inspect(Payload),
             Base.encode16(sha256, case: :lower),
             purpose,
             actor,
             %{}
           ) do
      {:ok, payload.content}
    end
  end

  defp fetch_payload(tenant_id, sha256) do
    Payload
    |> Ash.Query.for_read(:read, %{}, opts(tenant_id))
    |> Ash.Query.filter(tenant_id == ^tenant_id and sha256 == ^sha256)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, Ash.Error.Query.NotFound.exception(resource: Payload)}
      other -> other
    end
  end

  @doc """
  Verifies the actor's tenant chain while holding the head lock, then
  records a `chain_verify` access. Returns the verifier report.
  """
  def verify_and_record(actor) do
    traced_transaction(fn -> do_verify_and_record(actor) end)
  end

  defp do_verify_and_record(actor) do
    with {:ok, tenant_id} <- resolve_tenant(%{}, actor, []),
         {:ok, head} <- lock_head(tenant_id),
         report = Verifier.verify(tenant_id, head),
         {:ok, _access} <-
           do_record_access(
             :chain_verify,
             "SdrAgent.Audit.AuditEvent",
             "sequence:1-#{report.last_sequence}",
             "verify",
             actor,
             %{valid: report.valid?, issue_count: length(report.issues)}
           ) do
      {:ok, report}
    end
  end

  @doc "Canonical map of an event (or event fields): the input of `canonical_bytes`."
  def canonical_map(event) do
    Map.new(@hashed_fields, fn field -> {field, canonical_value(field, Map.get(event, field))} end)
  end

  @doc "The singleton tenant id (MVP), if bootstrapped."
  def singleton_tenant_id do
    case Tenant
         |> Ash.Query.for_read(:read, %{}, opts())
         |> Ash.Query.filter(singleton == true)
         |> Ash.read_one() do
      {:ok, %{id: id}} -> {:ok, id}
      {:ok, nil} -> {:error, :tenant_not_bootstrapped}
      {:error, error} -> {:error, error}
    end
  end

  @doc "Locks and returns the tenant's chain head."
  def lock_head(tenant_id) do
    AuditChainHead
    |> Ash.Query.for_read(:read, %{}, opts(tenant_id))
    |> Ash.Query.filter(tenant_id == ^tenant_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, :chain_not_initialized}
      other -> other
    end
  end

  defp do_append(attrs, opts) do
    actor = Keyword.get(opts, :actor)

    with {:ok, tenant_id} <- resolve_tenant(attrs, actor, opts),
         {:ok, head} <- lock_head(tenant_id),
         {:ok, snapshot, new?} <- ensure_provenance(tenant_id),
         {:ok, event} <- insert_event(attrs, actor, tenant_id, head, snapshot),
         {:ok, _head} <- advance_head(head, event),
         :ok <- LiveEvents.notify(event),
         :ok <- record_new_provenance(new?, snapshot, tenant_id) do
      {:ok, event}
    end
  end

  defp resolve_tenant(attrs, actor, opts) do
    case attrs[:tenant_id] || opts[:tenant_id] || actor_tenant(actor) do
      nil -> singleton_tenant_id()
      tenant_id -> {:ok, tenant_id}
    end
  end

  defp actor_tenant(%{tenant_id: tenant_id}) when is_binary(tenant_id), do: tenant_id
  defp actor_tenant(_actor), do: nil

  defp ensure_provenance(tenant_id) do
    attrs = Provenance.current()

    ProvenanceSnapshot
    |> Ash.Query.for_read(:read, %{}, opts(tenant_id))
    |> Ash.Query.filter(snapshot_sha256 == ^attrs.snapshot_sha256)
    |> Ash.read_one()
    |> case do
      {:ok, nil} ->
        ProvenanceSnapshot
        |> Ash.Changeset.for_create(:record, attrs, opts(tenant_id))
        |> Ash.create(return_notifications?: true)
        |> ledger_write()
        |> case do
          {:ok, snapshot} -> {:ok, snapshot, true}
          {:error, error} -> {:error, error}
        end

      {:ok, snapshot} ->
        {:ok, snapshot, false}

      {:error, error} ->
        {:error, error}
    end
  end

  defp record_new_provenance(false, _snapshot, _tenant_id), do: :ok

  defp record_new_provenance(true, snapshot, tenant_id) do
    attrs = %{
      event_type: "system.provenance.recorded",
      category: :system,
      subject_resource: inspect(ProvenanceSnapshot),
      subject_id: snapshot.id,
      action: "record",
      payload: %{
        record_sha256: RecordHash.hex(snapshot),
        snapshot_sha256: Base.encode16(snapshot.snapshot_sha256, case: :lower),
        git_sha: snapshot.git_sha
      }
    }

    case do_append(attrs, actor: Actor.system(:kernel, tenant_id), tenant_id: tenant_id) do
      {:ok, _event} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp insert_event(attrs, actor, tenant_id, head, snapshot) do
    now = Clock.utc_now()
    {trace_id, span_id} = Trace.current_ids()
    {actor_type, actor_id, actor_role} = actor_fields(actor)
    action = attrs[:action] && to_string(attrs[:action])

    fields = %{
      id: Ash.UUIDv7.generate(),
      tenant_id: tenant_id,
      sequence: head.last_sequence + 1,
      prev_hash: head.last_event_hash,
      canonicalization_version: Canonical.version(),
      hash_algorithm: "sha256",
      event_type: Map.fetch!(attrs, :event_type),
      category: Map.fetch!(attrs, :category),
      subject_resource: attrs[:subject_resource],
      subject_id: attrs[:subject_id] && to_string(attrs[:subject_id]),
      action: action,
      payload: Canonical.normalize(attrs[:payload] || %{}),
      occurred_at: now,
      inserted_at: now,
      clock_source: Clock.source(),
      actor_type: actor_type,
      actor_id: actor_id,
      actor_role: actor_role,
      authorization:
        Map.merge(
          %{decision: :authorized, action: action, policy_version: @policy_version},
          attrs[:authorization] || %{}
        ),
      provenance_snapshot_id: snapshot.id,
      version_refs:
        Canonical.normalize(
          Map.merge(
            %{
              config_sha256: Base.encode16(snapshot.config_sha256, case: :lower),
              schema_version: snapshot.schema_version
            },
            attrs[:version_refs] || %{}
          )
        ),
      causation_id: attrs[:causation_id],
      correlation_id: attrs[:correlation_id],
      idempotency_key: attrs[:idempotency_key],
      attempt: attrs[:attempt] || 0,
      trace_id: trace_id,
      span_id: span_id,
      request_id: attrs[:request_id] || request_id(),
      agent_run_id: attrs[:agent_run_id],
      decision_id: attrs[:decision_id],
      model_invocation_id: attrs[:model_invocation_id],
      tool_invocation_id: attrs[:tool_invocation_id]
    }

    bytes = fields |> canonical_map() |> Canonical.encode!()

    AuditEvent
    |> Ash.Changeset.for_create(
      :append,
      Map.merge(fields, %{canonical_bytes: bytes, event_hash: :crypto.hash(:sha256, bytes)}),
      opts(tenant_id)
    )
    |> Ash.create(return_notifications?: true)
    |> ledger_write()
  end

  defp advance_head(head, event) do
    head
    |> Ash.Changeset.for_update(
      :advance,
      %{
        last_sequence: event.sequence,
        last_event_hash: event.event_hash,
        expected_sequence: head.last_sequence
      },
      opts(head.tenant_id)
    )
    |> Ash.update(return_notifications?: true)
    |> ledger_write()
  end

  # Ledger resources have no notifiers; their (empty) notifications are dropped
  # so writes inside the caller's transaction do not warn about missed ones.
  defp ledger_write({:ok, record, _notifications}), do: {:ok, record}
  defp ledger_write(other), do: other

  defp canonical_value(:prev_hash, bin) when is_binary(bin), do: Base.encode16(bin, case: :lower)

  defp canonical_value(:authorization, auth) when is_map(auth) do
    %{
      decision: Map.get(auth, :decision),
      action: Map.get(auth, :action),
      policy_version: Map.get(auth, :policy_version)
    }
  end

  defp canonical_value(_field, value), do: value

  defp actor_fields(%Actor{type: type, id: id}), do: {type, to_string(id || type), nil}

  defp actor_fields(%{id: id, role: role}) when not is_nil(id) and is_atom(role),
    do: {:user, to_string(id), role}

  defp actor_fields(_actor), do: {:anonymous, nil, nil}

  defp request_id do
    case Logger.metadata()[:request_id] do
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  defp cap(nil), do: nil

  defp cap(value) do
    value
    |> to_string()
    |> binary_slice(0, 64)
    |> String.replace_invalid("")
  end
end
