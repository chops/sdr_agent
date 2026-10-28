defmodule SdrAgent.Agents.Changes.RevokeUpdatedBy do
  @moduledoc """
  Sets `updated_by` on `SdrAgent.Agents.ModelCallGrant :revoke`: the acting
  user, exactly as `relate_actor(:updated_by)` does for a belongs-to; for
  the D-237 prototype operator (D3: revoke is the operator's), the
  binding's anchor from the boot snapshot (closure note r1 "Policies").
  Any other actor, or no actor, is an error (the policies refuse them
  first). In a build without the prototype authority there is no operator
  branch.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, %{actor: %SdrAgent.Accounts.User{id: id}}),
    do: Ash.Changeset.force_change_attribute(changeset, :updated_by_id, id)

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    def change(changeset, _opts, %{actor: %SdrAgent.Actor{type: :prototype_operator}}) do
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

  def change(changeset, _opts, _context), do: no_updater(changeset)

  defp no_updater(changeset),
    do:
      Ash.Changeset.add_error(changeset,
        field: :updated_by_id,
        message: "no updater for this actor"
      )
end
