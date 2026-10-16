defmodule SdrAgent.Agents.Changes.SettingsSnapshotRow do
  @moduledoc """
  Fills a `SdrAgent.Agents.RunSettingsSnapshot` from the phase its creating
  run opened (`SdrAgent.Agents.Changes.BuildSettingsSnapshot`): the tenant,
  the five slots, the limits, the safeguards version, the hash version and
  `snapshot_sha256`, all computed by that change from one value. The action
  accepts no input, so nothing here comes from the caller. Outside an open
  phase it sets nothing; the policy then refuses the create
  (`SdrAgent.Agents.Checks.SettingsSnapshotContext`).
  """
  use Ash.Resource.Change

  alias SdrAgent.Agents.Changes.BuildSettingsSnapshot
  alias SdrAgent.Agents.RunSettingsSnapshot

  @impl true
  def change(changeset, _opts, _context) do
    case BuildSettingsSnapshot.phase(changeset.context) do
      {:ok, %{tenant_id: tenant_id, values: values}} ->
        Ash.Changeset.force_change_attributes(changeset, attributes(tenant_id, values))

      :error ->
        changeset
    end
  end

  defp attributes(tenant_id, values) do
    slots =
      Enum.flat_map(values.slots, fn {kind, slot} ->
        [
          {:"#{kind}_source", slot.source},
          {:"#{kind}_revision_id", slot.revision_id},
          {:"#{kind}_code_default_version", slot.code_default_version},
          {:"#{kind}_content_sha256", slot.content_sha256}
        ]
      end)

    Map.merge(Map.new(slots), %{
      tenant_id: tenant_id,
      limits: values.limits,
      safeguards_version: values.safeguards_version,
      hash_version: RunSettingsSnapshot.hash_version(),
      snapshot_sha256: values.snapshot_sha256
    })
  end
end
