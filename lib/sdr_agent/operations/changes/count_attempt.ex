defmodule SdrAgent.Operations.Changes.CountAttempt do
  @moduledoc """
  Operation `:start` / `:retry` change: counts one attempt on the row
  re-read under `FOR UPDATE` and refuses an attempt beyond `max_attempts`
  (bounded retries only, S2).
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      %{attempts: attempts, max_attempts: max} = changeset.data

      if attempts < max do
        Ash.Changeset.force_change_attribute(changeset, :attempts, attempts + 1)
      else
        Ash.Changeset.add_error(changeset, field: :attempts, message: "max attempts reached")
      end
    end)
  end
end
