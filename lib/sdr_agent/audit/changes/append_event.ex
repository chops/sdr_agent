defmodule SdrAgent.Audit.Changes.AppendEvent do
  @moduledoc """
  The shared same-transaction audit change (ADR-0009 "Audit coupling", S2
  "AE").

  Added to an audited action, it appends one AuditEvent through
  `SdrAgent.Audit.Kernel.append/2` in an `after_action` hook, i.e. inside
  the action's database transaction: if the append fails, the domain write
  rolls back. Works for atomic updates (the hook runs on the row returned by
  the atomic `UPDATE ... RETURNING`).

  A record marked `:sdr_replayed` in its metadata (an identical idempotent
  replay that wrote nothing, see `SdrAgent.Agents.Changes.Replay`) appends
  no event.

  The event payload carries the action name, the changed attributes
  (after-image; all attributes on create), the listed non-sensitive
  arguments and `record_sha256` — the canonical hash of the full row after
  the write. Attributes marked `sensitive?` (e.g. a password hash) are left
  out of the after-image and named under `redacted`; `record_sha256` still
  covers them.

  Options:

    * `:event_type` (required) — e.g. `"agents.run.started"`
    * `:category` (required) — AuditEvent category
    * `:links` — keyword of `event_field: record_field` copied onto the event
      (e.g. `[agent_run_id: :id, correlation_id: :correlation_id]`)
    * `:context_links` — keyword of `event_field: context_key` copied from
      the changeset context, for correlation a change derived from a parent
      row the resource has no column for (e.g. a WireWitnessLink's run id)
    * `:tenant` — record field holding the tenant id (default `:tenant_id`)
    * `:arguments` — action arguments to include in the payload
    * `:version_refs` — `{module, function}` called with the record, returning
      a map merged into the event's `version_refs`
    * `:previous` — attributes whose value *before* the update is recorded
      under `previous` (e.g. a lifecycle from-state or an old email). The
      value comes from the changeset's data, so the action should lock and
      re-read the row first (`get_and_lock_for_update`) for it to be exact.
  """
  use Ash.Resource.Change

  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Audit.RecordHash

  @impl true
  def change(changeset, opts, context), do: add_hook(changeset, opts, context)

  @impl true
  def atomic(changeset, opts, context), do: {:ok, add_hook(changeset, opts, context)}

  defp add_hook(changeset, opts, context) do
    actor = context.actor

    Ash.Changeset.after_action(changeset, fn changeset, record ->
      if Ash.Resource.get_metadata(record, :sdr_replayed) do
        # An identical idempotent replay wrote nothing; its event already exists.
        {:ok, record}
      else
        append(changeset, record, opts, actor)
      end
    end)
  end

  defp append(changeset, record, opts, actor) do
    tenant_id = Map.get(record, Keyword.get(opts, :tenant, :tenant_id))

    case Kernel.append(event(changeset, record, opts), actor: actor, tenant_id: tenant_id) do
      {:ok, _event} -> {:ok, record}
      {:error, error} -> {:error, error}
    end
  end

  defp event(changeset, %resource{} = record, opts) do
    canonical = RecordHash.canonical_map(record)
    action = to_string(changeset.action.name)

    changes =
      if changeset.action_type == :create do
        canonical
      else
        Map.take(canonical, Map.keys(changeset.attributes) ++ Keyword.keys(changeset.atomics))
      end

    sensitive =
      resource
      |> Ash.Resource.Info.attributes()
      |> Enum.filter(& &1.sensitive?)
      |> Enum.map(& &1.name)

    redacted = Enum.filter(sensitive, &Map.has_key?(changes, &1))
    changes = Map.drop(changes, sensitive)

    links =
      opts
      |> Keyword.get(:links, [])
      |> Map.new(fn {event_field, record_field} ->
        {event_field, Map.get(record, record_field)}
      end)
      |> Map.merge(
        opts
        |> Keyword.get(:context_links, [])
        |> Map.new(fn {event_field, key} -> {event_field, Map.get(changeset.context, key)} end)
      )

    version_refs =
      case Keyword.get(opts, :version_refs) do
        {module, function} -> apply(module, function, [record])
        nil -> %{}
      end

    Map.merge(links, %{
      event_type: Keyword.fetch!(opts, :event_type),
      category: Keyword.fetch!(opts, :category),
      subject_resource: inspect(resource),
      subject_id: to_string(record.id),
      action: action,
      authorization: %{decision: :authorized, action: "#{inspect(resource)}.#{action}"},
      version_refs: version_refs,
      payload:
        %{
          action: action,
          changes: changes,
          arguments: Map.take(changeset.arguments, Keyword.get(opts, :arguments, [])),
          record_sha256: RecordHash.hex(record)
        }
        |> put_unless_empty(:redacted, redacted)
        |> put_unless_empty(:previous, previous(changeset, resource, opts))
    })
  end

  defp previous(%{action_type: :update, data: data}, resource, opts) do
    opts
    |> Keyword.get(:previous, [])
    |> Map.new(&{&1, RecordHash.attribute_value(resource, &1, Map.get(data, &1))})
  end

  defp previous(_changeset, _resource, _opts), do: %{}

  defp put_unless_empty(payload, _key, empty) when empty == [] or empty == %{}, do: payload
  defp put_unless_empty(payload, key, value), do: Map.put(payload, key, value)
end
