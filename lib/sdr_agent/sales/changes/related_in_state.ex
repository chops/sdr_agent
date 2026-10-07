defmodule SdrAgent.Sales.Changes.RelatedInState do
  @moduledoc """
  Cross-row precondition checked inside the action's transaction: the row
  referenced by attribute `:id` (of `:resource`) must exist and have its
  `:attribute` (default `:status`) in `:in`. With `lock: :for_update` the
  referenced row is locked first, so a concurrent transition of it (e.g. a
  sequence's activation versus adding a step) serialises with this write.

  Options: `:resource`, `:id`, `:in`, `:attribute`, `:lock`, `:message`.

  The read is an internal invariant check (`authorize?: false`, as Ash's own
  `get_and_lock_for_update`); nothing it reads is returned to the caller.
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, &check(&1, opts))
  end

  @doc "The related row loaded by this change (stored in the changeset context)."
  def related(changeset, id_attribute), do: changeset.context[:"sdr_related_#{id_attribute}"]

  defp check(changeset, opts) do
    id = Ash.Changeset.get_attribute(changeset, opts[:id])
    attribute = Keyword.get(opts, :attribute, :status)

    case fetch(opts[:resource], id, opts[:lock]) do
      nil ->
        error(changeset, opts, "missing")

      related ->
        value = Map.get(related, attribute)

        if value in opts[:in],
          do: Ash.Changeset.put_context(changeset, :"sdr_related_#{opts[:id]}", related),
          else: error(changeset, opts, "#{value}")
    end
  end

  defp fetch(_resource, nil, _lock), do: nil

  defp fetch(resource, id, lock) do
    resource
    |> Ash.Query.filter(id == ^id)
    |> then(&if(lock, do: Ash.Query.lock(&1, lock), else: &1))
    |> Ash.read_one!(authorize?: false)
  end

  defp error(changeset, opts, found) do
    Ash.Changeset.add_error(changeset,
      field: opts[:id],
      message:
        Keyword.get(opts, :message, "must reference a row in #{inspect(opts[:in])}") <>
          " (found #{found})"
    )
  end
end
