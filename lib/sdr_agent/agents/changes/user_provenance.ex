defmodule SdrAgent.Agents.Changes.UserProvenance do
  @moduledoc """
  Records the acting human operator as a grant's creator or updater (C2* S2
  scope correction A; replaces `relate_actor/1` on `ModelCallGrant`).
  Option `attributes:` lists the user-id attributes to set (e.g.
  `[:created_by_id, :updated_by_id]`).

  Only an `SdrAgent.Accounts.User` actor's id is written, in a
  `before_action` hook: after authorization, and on an update after the row
  lock, so it is compared with the locked row. A system actor's id (a
  string such as `"bin/agent-env authorize"`) is never cast into a user
  attribute, so the call reaches the action's policies and is refused
  there as `Forbidden` instead of failing a UUID cast before them.
  Skipping the assignment grants nothing: the policies decide who may
  write, and the database's provenance CHECK refuses a row without its
  required user ids. Agents-owned, after the
  `SdrAgent.Outreach.Changes.ActorUser` precedent.
  """
  use Ash.Resource.Change

  alias SdrAgent.Accounts.User

  @impl true
  def change(changeset, opts, %{actor: %User{id: id}}) when is_binary(id) do
    attributes = Keyword.fetch!(opts, :attributes)

    Ash.Changeset.before_action(changeset, fn changeset ->
      Enum.reduce(attributes, changeset, &Ash.Changeset.force_change_attribute(&2, &1, id))
    end)
  end

  def change(changeset, _opts, _context), do: changeset
end
