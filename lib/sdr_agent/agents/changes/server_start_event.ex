defmodule SdrAgent.Agents.Changes.ServerStartEvent do
  @moduledoc """
  Appends a `model.server.start_*` AuditEvent for a `ModelServerStart`
  write, in the action's transaction, after the chain head (C2-02b2α,
  entity table "Events"). The payload is closed: the start's id, tenant,
  generation, boot, profile, reason, optional switch, status,
  `ready_evidence`, the `action` and the stored row's `record_sha256`.
  The observed pids are never in it. Option `event_type:` (required).
  """
  use Ash.Resource.Change

  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Audit.RecordHash

  @impl true
  def change(changeset, opts, context) do
    Ash.Changeset.after_action(changeset, fn changeset, %resource{} = start ->
      action = to_string(changeset.action.name)

      event = %{
        event_type: Keyword.fetch!(opts, :event_type),
        category: :model,
        subject_resource: inspect(resource),
        subject_id: start.id,
        action: action,
        authorization: %{decision: :authorized, action: "#{inspect(resource)}.#{action}"},
        payload: %{
          action: action,
          start_id: start.id,
          tenant_id: start.tenant_id,
          generation: start.generation,
          boot_id: start.boot_id,
          profile_id: start.profile_id,
          reason: start.reason,
          switch_id: start.switch_id,
          status: start.status,
          ready_evidence: start.ready_evidence,
          record_sha256: RecordHash.hex(start)
        }
      }

      with {:ok, _event} <-
             Kernel.append(event, actor: context.actor, tenant_id: start.tenant_id),
           do: {:ok, start}
    end)
  end
end
