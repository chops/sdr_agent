defmodule SdrAgent.Audit.Changes.OwnerIntakeEvent do
  @moduledoc """
  Same-transaction owner-intake audit commitment: real actor, identity and
  canonical row hash only. Never emits names, addresses, URLs or excerpts.
  Legacy action events are unchanged.
  """
  use Ash.Resource.Change
  alias SdrAgent.Audit
  alias SdrAgent.Audit.RecordHash

  @impl true
  def change(changeset, opts, context) do
    Ash.Changeset.after_action(changeset, fn changeset, %resource{} = record ->
      attrs = %{
        event_type: Keyword.fetch!(opts, :event_type),
        category: :domain_change,
        subject_resource: inspect(resource),
        subject_id: record.id,
        action: to_string(changeset.action.name),
        authorization: %{decision: :authorized},
        payload: %{record_id: record.id, record_sha256: RecordHash.hex(record)}
      }

      case Audit.append(attrs, actor: context.actor, tenant_id: record.tenant_id) do
        {:ok, _event} -> {:ok, record}
        error -> error
      end
    end)
  end
end
