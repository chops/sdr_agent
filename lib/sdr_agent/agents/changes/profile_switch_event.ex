defmodule SdrAgent.Agents.Changes.ProfileSwitchEvent do
  @moduledoc """
  Appends a `model.profile.switch_*` AuditEvent for a `ModelProfileSwitch`
  write, in the action's transaction, after the chain head (C2-02a,
  "Events"). The payload is flat, as the interface documents it, instead
  of `SdrAgent.Audit.Changes.AppendEvent`'s nested `changes`:
  `from_profile_id`, `to_profile_id`, `server_generation`,
  `setting_revision` (the setting's revision after the change),
  `failure_reason`, the `action` and `record_sha256` of the stored row.

  On `:request`, when this transaction inserted the setting row (evidence
  `:initialized` of the `:initialize` phase), it first appends
  `model.profile.setting_initialized` (tenant, `desired_profile_id`,
  revision 1 and the requesting switch's id).

  Option `event_type:` (required).
  """
  use Ash.Resource.Change

  alias SdrAgent.Agents.Checks.ProfileSwitchContext
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Audit.RecordHash

  @impl true
  def change(changeset, opts, context) do
    actor = context.actor

    Ash.Changeset.after_action(changeset, fn changeset, switch ->
      with {:ok, binding} <- open_binding(changeset),
           :ok <- initialized(binding.evidence, switch, actor),
           {:ok, _event} <- append(event(changeset, switch, binding, opts), switch, actor) do
        {:ok, switch}
      end
    end)
  end

  defp open_binding(changeset) do
    case ProfileSwitchContext.fetch(changeset.context) do
      {:ok, binding} -> {:ok, binding}
      :error -> {:error, :no_profile_switch_phase}
    end
  end

  defp initialized(%{initialized: setting}, switch, actor) do
    event = %{
      event_type: "model.profile.setting_initialized",
      category: :model,
      subject_resource: inspect(setting.__struct__),
      subject_id: setting.id,
      action: "initialize",
      authorization: %{
        decision: :authorized,
        action: "#{inspect(setting.__struct__)}.initialize"
      },
      payload: %{
        tenant_id: setting.tenant_id,
        desired_profile_id: setting.desired_profile_id,
        revision: setting.revision,
        switch_id: switch.id,
        record_sha256: RecordHash.hex(setting)
      }
    }

    with {:ok, _event} <- append(event, switch, actor), do: :ok
  end

  defp initialized(_evidence, _switch, _actor), do: :ok

  defp event(changeset, %resource{} = switch, binding, opts) do
    action = to_string(changeset.action.name)

    %{
      event_type: Keyword.fetch!(opts, :event_type),
      category: :model,
      subject_resource: inspect(resource),
      subject_id: switch.id,
      action: action,
      authorization: %{decision: :authorized, action: "#{inspect(resource)}.#{action}"},
      payload: %{
        action: action,
        from_profile_id: switch.from_profile_id,
        to_profile_id: switch.to_profile_id,
        server_generation: switch.server_generation,
        setting_revision: setting_revision(binding.evidence),
        failure_reason: switch.failure_reason,
        record_sha256: RecordHash.hex(switch)
      }
    }
  end

  # After the change: the applied setting on complete, otherwise the
  # setting as locked or initialized by this phase.
  defp setting_revision(%{applied: setting}), do: setting.revision
  defp setting_revision(%{setting: setting}), do: setting.revision
  defp setting_revision(%{initialized: setting}), do: setting.revision
  defp setting_revision(_evidence), do: nil

  defp append(event, switch, actor),
    do: Kernel.append(event, actor: actor, tenant_id: switch.tenant_id)
end
