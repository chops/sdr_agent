defmodule SdrAgent.Agents.Changes.ProfileSwitchGuard do
  @moduledoc """
  The write guard of the internal profile switch writes (C2-02a): the
  setting's `:apply_switch` and the switch's `:complete`, `:fail` and
  `:block`. It runs after authorization, inside the action's transaction,
  and trusts no in-memory state as proof of a database effect:

    1. the open phase (`SdrAgent.Agents.Checks.ProfileSwitchContext`)
       must have locked this tenant's setting and then this switch through
       `:lock_for_transition` (`SdrAgent.Agents.Preparations.TransitionLock`),
       which also gives the revision it locked;
    2. it re-locks both stored rows `FOR UPDATE` now, setting first (a lock
       already held is kept; one lost to a rolled-back savepoint is taken
       again, so the values read are current);
    3. on those stored rows: the switch is `pending`, of the tenant, with
       the phase's `server_generation`; then, by write:
       * `:apply` — the setting is unchanged since the lock (the locked
         revision, desired = the switch's `from`) and `to` differs; it sets
         `desired_profile_id := to` and `revision := locked + 1`;
       * `:complete` — the setting already holds the change: `to` and
         exactly the locked revision + 1 (a rolled-back apply fails this);
       * `:fail`, `:block` — the setting is unchanged since the lock.

  So a finished switch is never relabelled, and a switch is completed only
  when its setting change is present in the same transaction. Anything else
  is refused as invalid (on `:switch_id` for `:apply`, `:id` otherwise).

  Option `write:` — `:apply`, `:complete`, `:fail` or `:block`.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias Ash.Error.Changes.InvalidArgument
  alias Ash.Error.Changes.InvalidAttribute
  alias SdrAgent.Agents.ModelProfileSetting
  alias SdrAgent.Agents.ModelProfileSwitch
  alias SdrAgent.Agents.ProfileSwitches
  alias SdrAgent.Audit.Kernel

  @impl true
  def change(changeset, opts, _context) do
    write = Keyword.fetch!(opts, :write)
    Ash.Changeset.before_action(changeset, &guard(&1, write))
  end

  defp guard(changeset, write) do
    switch_id = switch_id(changeset, write)

    with {:ok, binding} <- open_phase(changeset),
         {:ok, locked_revision} <- transition_locked(binding.evidence, switch_id),
         {:ok, setting} <- lock_setting(binding.tenant_id),
         {:ok, switch} <- lock_switch(binding.tenant_id, switch_id),
         :ok <- open_switch(switch, binding),
         :ok <- written(write, switch, setting, locked_revision) do
      apply_change(changeset, write, switch, setting)
    else
      {:refused, message} -> refuse(changeset, write, message)
    end
  end

  defp switch_id(changeset, :apply), do: Ash.Changeset.get_argument(changeset, :switch_id)
  defp switch_id(changeset, _write), do: changeset.data.id

  defp open_phase(changeset) do
    case ProfileSwitches.phase(changeset.context) do
      {:ok, binding} -> {:ok, binding}
      :error -> {:refused, "is not in an open profile switch phase"}
    end
  end

  defp transition_locked(
         %{setting: %{revision: revision}, switch: %{id: switch_id}},
         switch_id
       ),
       do: {:ok, revision}

  defp transition_locked(_evidence, _switch_id),
    do: {:refused, "was not locked under :transition in this phase"}

  defp lock_setting(tenant_id) do
    ModelProfileSetting
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(tenant_id == ^tenant_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one()
    |> stored()
  end

  defp lock_switch(tenant_id, switch_id) do
    ModelProfileSwitch
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(id == ^switch_id and tenant_id == ^tenant_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one()
    |> stored()
  end

  defp stored({:ok, %{} = record}), do: {:ok, record}
  defp stored(_result), do: {:refused, "has no stored row"}

  defp open_switch(switch, binding) do
    cond do
      switch.status != :pending -> {:refused, "is not pending"}
      switch.server_generation != binding.server_generation -> {:refused, "is stale"}
      true -> :ok
    end
  end

  # `locked` is the setting revision the phase locked under `:transition`.
  defp written(:apply, switch, setting, locked) do
    cond do
      setting.revision != locked -> {:refused, "is stale"}
      switch.from_profile_id != setting.desired_profile_id -> {:refused, "is stale"}
      switch.to_profile_id == setting.desired_profile_id -> {:refused, "changes nothing"}
      true -> :ok
    end
  end

  defp written(:complete, switch, setting, locked) do
    if setting.desired_profile_id == switch.to_profile_id and setting.revision == locked + 1,
      do: :ok,
      else: {:refused, "was not applied to the setting in this transaction"}
  end

  defp written(_fail_or_block, switch, setting, locked) do
    if setting.revision == locked and switch.from_profile_id == setting.desired_profile_id,
      do: :ok,
      else: {:refused, "is stale"}
  end

  defp apply_change(changeset, :apply, switch, setting) do
    changeset
    |> Ash.Changeset.force_change_attribute(:desired_profile_id, switch.to_profile_id)
    |> Ash.Changeset.force_change_attribute(:revision, setting.revision + 1)
  end

  defp apply_change(changeset, _write, _switch, _setting), do: changeset

  defp refuse(changeset, :apply, message) do
    Ash.Changeset.add_error(
      changeset,
      InvalidArgument.exception(field: :switch_id, message: message)
    )
  end

  defp refuse(changeset, _write, message) do
    Ash.Changeset.add_error(changeset, InvalidAttribute.exception(field: :id, message: message))
  end
end
