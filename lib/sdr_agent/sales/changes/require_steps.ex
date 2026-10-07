defmodule SdrAgent.Sales.Changes.RequireSteps do
  @moduledoc """
  `Sequence :activate`: a sequence needs at least one step (S2). Counted in
  a `before_action` hook while the sequence row is locked, so it agrees with
  the steps that exist when the activation commits.
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      id = changeset.data.id

      steps =
        SdrAgent.Sales.SequenceStep
        |> Ash.Query.filter(sequence_id == ^id)
        |> Ash.count!(authorize?: false)

      if steps >= 1,
        do: changeset,
        else:
          Ash.Changeset.add_error(changeset, field: :status, message: "a sequence needs a step")
    end)
  end
end
