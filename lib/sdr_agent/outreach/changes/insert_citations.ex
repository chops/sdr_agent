defmodule SdrAgent.Outreach.Changes.InsertCitations do
  @moduledoc """
  DraftRevision create, `after_action`: inserts one RevisionCitation per
  entry of the `citations` argument (`evidence_claim_id`, `kind`, `text`,
  optional `confidence`) in the same transaction, as the same actor, with the
  private `SdrAgent.Outreach.Checks.InternalWrite` marker. Any refused
  citation rolls the revision (and the draft write that made it) back.
  """
  use Ash.Resource.Change

  alias SdrAgent.Outreach.Checks.InternalWrite
  alias SdrAgent.Outreach.RevisionCitation

  @fields ~w(evidence_claim_id kind text confidence)a

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn changeset, revision ->
      changeset
      |> Ash.Changeset.get_argument(:citations)
      |> List.wrap()
      |> Enum.reduce_while({:ok, revision}, &insert(&1, &2, revision, context.actor))
    end)
  end

  defp insert(citation, ok, revision, actor) do
    attrs = citation |> take() |> Map.put(:draft_revision_id, revision.id)

    RevisionCitation
    |> Ash.Changeset.for_create(:create, attrs, actor: actor, context: InternalWrite.context())
    |> Ash.create(return_notifications?: true)
    |> case do
      {:ok, _citation, _notifications} -> {:cont, ok}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp take(citation) do
    Map.new(@fields, fn field ->
      {field, Map.get(citation, field, Map.get(citation, Atom.to_string(field)))}
    end)
  end
end
