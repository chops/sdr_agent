defmodule SdrAgent.Outreach.Changes.ActorUser do
  @moduledoc """
  Sets attribute `:field` to the acting human operator's id (e.g. a manual
  suppression's `created_by_user_id`, an approval's `approver_id`). The
  action's policy admits only human operators, so the actor is a User; any
  other actor leaves the attribute unset and the row's own constraints
  refuse it.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, %{actor: %SdrAgent.Accounts.User{id: id}}),
    do: Ash.Changeset.force_change_attribute(changeset, opts[:field], id)

  def change(changeset, _opts, _context), do: changeset

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
