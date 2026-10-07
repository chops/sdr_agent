defmodule SdrAgent.Outreach.Changes.NewRevision do
  @moduledoc """
  Draft `:propose` / `:edit`: makes the draft's next immutable DraftRevision
  in the same transaction (S8 choice 1).

  `before_action`: picks the new revision's UUIDv7 and writes it as the
  draft's `current_revision_id` (the FK is deferred to commit). For a human
  edit it reads the current revision (the parent; the draft row is already
  locked), the AI baseline (the latest agent revision of the lineage), and
  computes the line diffs (`SdrAgent.Outreach.Diff`) plus the carried-forward
  citations: the parent's citations whose text is still verbatim in the new
  body. Citations of the compared version that are not carried are listed
  at the end of each diff (`# dropped citation (<kind>): <text>`).

  `after_action`: inserts the revision (and its citations) as the same actor
  with the private `SdrAgent.Outreach.Checks.InternalWrite` marker.

  Option `:author` — `:agent` (propose: revision 1 from the action
  arguments) or `:human` (edit; the author is the acting operator).
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Outreach.Checks.InternalWrite
  alias SdrAgent.Outreach.Diff
  alias SdrAgent.Outreach.DraftRevision
  alias SdrAgent.Outreach.RevisionCitation

  @impl true
  def change(changeset, opts, context) do
    changeset
    |> Ash.Changeset.before_action(&plan(&1, opts[:author], context.actor))
    |> Ash.Changeset.after_action(fn changeset, draft ->
      insert(changeset.context[:sdr_new_revision], draft, context.actor)
    end)
  end

  defp plan(changeset, author, actor) do
    id = Ash.UUIDv7.generate()
    arg = &Ash.Changeset.get_argument(changeset, &1)

    attrs =
      case author do
        :agent ->
          %{
            revision_number: 1,
            author_type: :agent,
            agent_run_id: Ash.Changeset.get_attribute(changeset, :origin_agent_run_id),
            decision_id: arg.(:decision_id),
            model_invocation_id: arg.(:model_invocation_id),
            subject: arg.(:subject),
            body_text: arg.(:body_text),
            angle: arg.(:angle),
            cta: arg.(:cta),
            risk_flags: arg.(:risk_flags) || [],
            citations: arg.(:citations) || []
          }

        :human ->
          human(changeset.data.current_revision_id, arg, actor)
      end

    changeset
    |> Ash.Changeset.force_change_attribute(:current_revision_id, id)
    |> Ash.Changeset.put_context(:sdr_new_revision, Map.put(attrs, :id, id))
  end

  defp human(parent_id, arg, actor) do
    parent = read(DraftRevision, parent_id)

    baseline_id =
      if parent.author_type == :agent, do: parent.id, else: parent.ai_baseline_revision_id

    baseline = if baseline_id == parent.id, do: parent, else: read(DraftRevision, baseline_id)

    new = %{
      subject: arg.(:subject),
      body_text: arg.(:body_text),
      angle: arg.(:angle) || parent.angle,
      cta: arg.(:cta) || parent.cta
    }

    carried =
      for citation <- citations(parent),
          is_binary(new.body_text) and String.contains?(new.body_text, citation.text),
          do: Map.take(citation, [:evidence_claim_id, :kind, :text, :confidence])

    Map.merge(new, %{
      revision_number: parent.revision_number + 1,
      parent_revision_id: parent.id,
      author_type: :human,
      author_user_id: actor.id,
      risk_flags: parent.risk_flags,
      ai_baseline_revision_id: baseline.id,
      diff_from_parent: diff(parent, new, carried),
      diff_from_ai_baseline: diff(baseline, new, carried),
      citations: carried
    })
  end

  defp diff(old, new, carried) do
    kept = MapSet.new(carried, &{&1.evidence_claim_id, &1.kind, &1.text})

    dropped =
      for c <- citations(old),
          not MapSet.member?(kept, {c.evidence_claim_id, c.kind, c.text}),
          do: "# dropped citation (#{c.kind}): #{c.text}"

    Enum.join([Diff.lines(old, %{new | body_text: new.body_text || ""}) | dropped], "\n")
  end

  defp insert(attrs, draft, actor) do
    DraftRevision
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :draft_id, draft.id),
      actor: actor,
      context: InternalWrite.context()
    )
    |> Ash.create(return_notifications?: true)
    |> case do
      {:ok, _revision, _notifications} -> {:ok, draft}
      {:error, error} -> {:error, error}
    end
  end

  # Internal reads of the lineage being extended; nothing read here is
  # returned to the caller.
  defp read(resource, id),
    do: resource |> Ash.Query.filter(id == ^id) |> Ash.read_one!(authorize?: false)

  defp citations(revision) do
    RevisionCitation
    |> Ash.Query.filter(draft_revision_id == ^revision.id)
    |> Ash.Query.sort(kind: :asc, id: :asc)
    |> Ash.read!(authorize?: false)
  end
end
