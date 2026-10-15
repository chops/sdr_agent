defmodule SdrAgent.Agents.Changes.RequireAppliedSetting do
  @moduledoc """
  The write guard of `ModelProfileSwitch.:complete` (C2-02a): after
  authorization, the open `:apply` phase must already have applied this
  switch to the setting (evidence `:applied` and the switch locked under
  `:transition`, `SdrAgent.Agents.Changes.ApplyProfileSwitch`), so a switch
  is never marked completed without its setting change in the same
  transaction. Refused as invalid on `:id` otherwise.
  """
  use Ash.Resource.Change

  alias SdrAgent.Agents.Checks.ProfileSwitchContext

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      id = changeset.data.id

      case ProfileSwitchContext.fetch(changeset.context) do
        {:ok, %{evidence: %{applied: %{}, switch: %{id: ^id}}}} ->
          changeset

        _other ->
          Ash.Changeset.add_error(changeset,
            field: :id,
            message: "the setting was not applied in this phase"
          )
      end
    end)
  end
end
