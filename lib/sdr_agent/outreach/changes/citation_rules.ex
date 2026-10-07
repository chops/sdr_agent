defmodule SdrAgent.Outreach.Changes.CitationRules do
  @moduledoc """
  RevisionCitation create invariants (S2), checked in the create
  transaction: the cited claim is an `accepted` EvidenceClaim of the draft's
  lead, and the cited text appears verbatim in the revision body.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Outreach.Draft
  alias SdrAgent.Outreach.DraftRevision
  alias SdrAgent.Research.EvidenceClaim

  @impl true
  def change(changeset, _opts, _context), do: Ash.Changeset.before_action(changeset, &check/1)

  defp check(changeset) do
    get = &Ash.Changeset.get_attribute(changeset, &1)
    revision = read(DraftRevision, get.(:draft_revision_id))
    draft = revision && read(Draft, revision.draft_id)
    claim = read(EvidenceClaim, get.(:evidence_claim_id))
    text = get.(:text)

    cond do
      is_nil(draft) ->
        error(changeset, :draft_revision_id, "does not exist")

      is_nil(claim) or claim.lead_id != draft.lead_id or claim.quality != :accepted ->
        error(
          changeset,
          :evidence_claim_id,
          "must be an accepted evidence claim of the draft's lead"
        )

      not (is_binary(text) and String.contains?(revision.body_text, text)) ->
        error(changeset, :text, "must appear verbatim in the revision body")

      true ->
        changeset
    end
  end

  defp read(_resource, nil), do: nil

  # Internal invariant reads; nothing read here is returned to the caller.
  defp read(resource, id),
    do: resource |> Ash.Query.filter(id == ^id) |> Ash.read_one!(authorize?: false)

  defp error(changeset, field, message),
    do: Ash.Changeset.add_error(changeset, field: field, message: message)
end
