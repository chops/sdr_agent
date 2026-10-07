defmodule SdrAgent.Sales.Changes.RequireState do
  @moduledoc """
  Refuses a non-transition update unless the row is in one of the `:in`
  states (e.g. edits only while `draft`, nothing after `archived`).

  Checked in a `before_action` hook on the row re-read by a preceding
  `get_and_lock_for_update`, so a stale struct cannot edit a row that has
  since moved on. Options: `:in` (states), `:attribute` (default `:status`).
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    attribute = Keyword.get(opts, :attribute, :status)

    Ash.Changeset.before_action(changeset, fn changeset ->
      current = Map.get(changeset.data, attribute)

      if current in opts[:in] do
        changeset
      else
        Ash.Changeset.add_error(changeset,
          field: attribute,
          message: "cannot be changed while #{current}"
        )
      end
    end)
  end
end
