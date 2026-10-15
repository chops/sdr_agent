defmodule SdrAgent.Agents.Changes.ProfileSwitchEvent do
  @moduledoc """
  Appends a `model.profile.switch_*` AuditEvent for a `ModelProfileSwitch`
  write, in the action's transaction, after the chain head (C2-02a,
  "Events"). The payload is flat, as the interface documents it, instead
  of `SdrAgent.Audit.Changes.AppendEvent`'s nested `changes`:
  `from_profile_id`, `to_profile_id`, `server_generation`,
  `setting_revision` (the stored setting's revision after the change,
  read in this transaction),
  `failure_reason`, the `action` and `record_sha256` of the stored row.

  On `:request`, when this transaction inserted the setting row (evidence
  `:initialized` of the `:initialize` phase, matched against the stored
  row), it first appends
  `model.profile.setting_initialized` (tenant, `desired_profile_id`,
  revision 1 and the requesting switch's id).

  Option `event_type:` (required).
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Agents.ModelProfileSetting
  alias SdrAgent.Agents.ProfileSwitches
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Audit.RecordHash

  @impl true
  def change(changeset, opts, context) do
    actor = context.actor

    Ash.Changeset.after_action(changeset, fn changeset, switch ->
      with {:ok, binding} <- open_binding(changeset),
           {:ok, setting} <- stored_setting(switch.tenant_id),
           :ok <- initialized(binding.evidence, setting, switch, actor),
           {:ok, _event} <- append(event(changeset, switch, setting, opts), switch, actor) do
        {:ok, switch}
      end
    end)
  end

  defp open_binding(changeset) do
    case ProfileSwitches.phase(changeset.context) do
      {:ok, binding} -> {:ok, binding}
      :error -> {:error, :no_profile_switch_phase}
    end
  end

  # The tenant's setting as stored now, in this transaction: the revision
  # the event reports is the persisted one, never in-memory evidence.
  defp stored_setting(tenant_id) do
    ModelProfileSetting
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(tenant_id == ^tenant_id)
    |> Ash.read_one()
    |> case do
      {:ok, %ModelProfileSetting{} = setting} -> {:ok, setting}
      _other -> {:error, :no_stored_profile_setting}
    end
  end

  # Only when the stored row is the one this transaction inserted.
  defp initialized(%{initialized: %{id: id}}, %{id: id} = setting, switch, actor) do
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

  defp initialized(%{initialized: _}, _setting, _switch, _actor),
    do: {:error, :initialized_setting_not_stored}

  defp initialized(_evidence, _setting, _switch, _actor), do: :ok

  defp event(changeset, %resource{} = switch, setting, opts) do
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
        setting_revision: setting.revision,
        failure_reason: switch.failure_reason,
        record_sha256: RecordHash.hex(switch)
      }
    }
  end

  defp append(event, switch, actor),
    do: Kernel.append(event, actor: actor, tenant_id: switch.tenant_id)
end
