defmodule SdrAgent.Agents.Changes.GrantRevision do
  @moduledoc """
  Optimistic concurrency for grant changes (C9): after the preceding
  `get_and_lock_for_update`, refuses the change unless the locked row's
  `revision` equals the `expected_revision` argument, then bumps it. A form
  opened before someone else's change therefore cannot overwrite it.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      current = changeset.data.revision
      expected = Ash.Changeset.get_argument(changeset, :expected_revision)

      if current == expected do
        Ash.Changeset.force_change_attribute(changeset, :revision, current + 1)
      else
        Ash.Changeset.add_error(changeset,
          field: :expected_revision,
          message: "is stale: the grant is at revision %{current}",
          # Ash keeps the whole keyword as the message vars.
          current: current
        )
      end
    end)
  end
end
