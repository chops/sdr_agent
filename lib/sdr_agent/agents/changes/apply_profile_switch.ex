defmodule SdrAgent.Agents.Changes.ApplyProfileSwitch do
  @moduledoc """
  The write guard of `ModelProfileSetting.:apply_switch` (C2-02a, phase
  `:apply`). After authorization, inside the action's transaction, it
  requires that this phase locked this setting and this switch under
  `:transition` (`SdrAgent.Agents.Preparations.TransitionLock`), then
  re-reads both stored rows and requires: the switch is `pending`, in the
  same tenant, from the current desired profile to another one, and the
  setting's revision is the locked one. Only then it sets
  `desired_profile_id := to` and `revision := locked revision + 1`.
  Anything else is refused as invalid on `:switch_id`.

  The applied setting is recorded as evidence `:applied`, which the
  switch's `:complete` write requires.
  """
  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidArgument
  alias SdrAgent.Agents.Checks.ProfileSwitchContext
  alias SdrAgent.Agents.ModelProfileSwitch
  alias SdrAgent.Audit.Kernel

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&guard/1)
    |> Ash.Changeset.after_action(fn changeset, setting ->
      with :ok <- ProfileSwitchContext.put_evidence(changeset.context, :applied, setting),
           do: {:ok, setting}
    end)
  end

  defp guard(changeset) do
    switch_id = Ash.Changeset.get_argument(changeset, :switch_id)

    with {:ok, %{evidence: evidence}} <- ProfileSwitchContext.fetch(changeset.context),
         :ok <- locked(evidence, changeset.data.id, switch_id),
         {:ok, setting} <- stored(changeset.data.__struct__, changeset.data),
         {:ok, switch} <-
           stored(ModelProfileSwitch, %{id: switch_id, tenant_id: setting.tenant_id}),
         :ok <- applicable(setting, switch, evidence.setting.revision) do
      changeset
      |> Ash.Changeset.force_change_attribute(:desired_profile_id, switch.to_profile_id)
      |> Ash.Changeset.force_change_attribute(:revision, setting.revision + 1)
    else
      {:refused, message} -> refuse(changeset, message)
      _other -> refuse(changeset, "is not an open :apply phase")
    end
  end

  defp locked(%{setting: %{id: setting_id}, switch: %{id: switch_id}}, setting_id, switch_id),
    do: :ok

  defp locked(_evidence, _setting_id, _switch_id),
    do: {:refused, "was not locked under :transition in this transaction"}

  defp stored(resource, %{id: id, tenant_id: tenant_id}) do
    case Ash.get(resource, id, Kernel.opts(tenant_id)) do
      {:ok, record} -> {:ok, record}
      {:error, _} -> {:refused, "has no stored row"}
    end
  end

  defp applicable(setting, switch, locked_revision) do
    cond do
      switch.status != :pending -> {:refused, "is not pending"}
      switch.tenant_id != setting.tenant_id -> {:refused, "belongs to another tenant"}
      switch.from_profile_id != setting.desired_profile_id -> {:refused, "is stale"}
      switch.to_profile_id == setting.desired_profile_id -> {:refused, "changes nothing"}
      setting.revision != locked_revision -> {:refused, "is stale"}
      true -> :ok
    end
  end

  defp refuse(changeset, message) do
    Ash.Changeset.add_error(
      changeset,
      InvalidArgument.exception(field: :switch_id, message: message)
    )
  end
end
