defmodule SdrAgent.Agents.Changes.RevokeUpdatedBy do
  @moduledoc """
  Sets `updated_by` on `SdrAgent.Agents.ModelCallGrant :revoke`: the acting
  user, exactly as `relate_actor(:updated_by)` does for a belongs-to; for
  the D-237 prototype operator (D3: revoke is the operator's), the
  binding's anchor from the boot snapshot (closure note r1 "Policies").
  Any other actor, or no actor, is an error raised in a `before_action`,
  i.e. after authorization, so the policies' `Forbidden` (and its audit)
  comes first, as with `relate_actor`. In a build without the prototype
  authority there is no operator branch.
  """
  use Ash.Resource.Change

  @compiled Application.compile_env(:sdr_agent, :prototype_authority_compiled, false)

  @impl true
  def change(changeset, _opts, %{actor: %SdrAgent.Accounts.User{id: id}}),
    do: Ash.Changeset.force_change_attribute(changeset, :updated_by_id, id)

  if @compiled do
    def change(changeset, _opts, %{actor: %SdrAgent.Actor{type: :prototype_operator}}),
      do: Ash.Changeset.before_action(changeset, &anchor_updater/1)
  end

  def change(changeset, _opts, _context),
    do: Ash.Changeset.before_action(changeset, &no_updater/1)

  if @compiled do
    defp anchor_updater(changeset) do
      case SdrAgent.Prototype.binding() do
        {:ok, snapshot} ->
          Ash.Changeset.force_change_attribute(
            changeset,
            :updated_by_id,
            snapshot.operator_user_id
          )

        _ordinary ->
          no_updater(changeset)
      end
    end
  end

  defp no_updater(changeset),
    do:
      Ash.Changeset.add_error(changeset,
        field: :updated_by_id,
        message: "no updater for this actor"
      )
end
