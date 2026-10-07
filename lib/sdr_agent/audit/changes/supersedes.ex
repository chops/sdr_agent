defmodule SdrAgent.Audit.Changes.Supersedes do
  @moduledoc """
  Append-only lineage (S2 convention "supersedes"): a correction is a new
  row with `supersedes_id = current_row.id`. Validates, inside the action
  transaction, that the first row of a subject supersedes nothing and every
  later row supersedes exactly the subject's current row (the row with no
  successor). Partial unique indexes back this up under concurrency.

  Option `:subject` — the attributes identifying the subject.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Audit.Kernel

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      subject = Map.new(opts[:subject], &{&1, Ash.Changeset.get_attribute(changeset, &1)})
      supersedes_id = Ash.Changeset.get_attribute(changeset, :supersedes_id)

      case {current(changeset.resource, subject), supersedes_id} do
        {nil, nil} -> changeset
        {%{id: id}, id} -> changeset
        {nil, _} -> invalid(changeset, "the first row of a subject cannot supersede another row")
        {_current, _} -> invalid(changeset, "must supersede the current row of this subject")
      end
    end)
  end

  defp current(resource, subject) do
    resource
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(subject[:tenant_id]))
    |> Ash.Query.do_filter(Map.to_list(subject))
    |> Ash.Query.filter(not exists(successors, true))
    |> Ash.read_one!()
  end

  defp invalid(changeset, message),
    do: Ash.Changeset.add_error(changeset, field: :supersedes_id, message: message)
end
