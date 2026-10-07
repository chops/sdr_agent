defmodule SdrAgent.Outreach.Changes.CountAttempt do
  @moduledoc """
  DeliveryOperation `:claim`: counts the attempt on the row re-read under
  `FOR UPDATE` (`attempt_count + 1`); the `attempt_count <= max_attempts`
  check constraint bounds it.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      Ash.Changeset.force_change_attribute(
        changeset,
        :attempt_count,
        changeset.data.attempt_count + 1
      )
    end)
  end
end
