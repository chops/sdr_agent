defmodule SdrAgent.Operations.Changes.ResolvedBy do
  @moduledoc """
  Failure `:resolve` change: records who resolved it — `resolved_by_type:
  :user` and `resolved_by_id` for a human operator, or the system actor's
  type (and no user id) when the causing condition cleared.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    {type, id} =
      case context.actor do
        %SdrAgent.Actor{type: type} -> {type, nil}
        %{id: id} -> {:user, id}
      end

    changeset
    |> Ash.Changeset.force_change_attribute(:resolved_by_type, type)
    |> Ash.Changeset.force_change_attribute(:resolved_by_id, id)
  end
end
