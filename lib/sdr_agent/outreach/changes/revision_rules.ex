defmodule SdrAgent.Outreach.Changes.RevisionRules do
  @moduledoc """
  DraftRevision create invariants (S2), inside the create transaction:

    * `content_sha256` = canonical sha256 of `{subject, body_text}` and
      `canonicalization_version` are computed here, never taken as input;
    * lineage: a revision without a parent is number 1; otherwise its parent
      is a revision of the same draft and its number is the parent's + 1;
    * agent provenance: `decision_id` is an `llm` `draft_proposal` Decision
      of `agent_run_id`, and `model_invocation_id` is that decision's
      invocation (filled in when absent).

  Human provenance (`author_user_id`, a parent) is a database constraint.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Agents.Decision
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Outreach.DraftRevision

  @impl true
  def change(changeset, _opts, _context) do
    subject = Ash.Changeset.get_attribute(changeset, :subject)
    body = Ash.Changeset.get_attribute(changeset, :body_text)

    changeset
    |> then(fn cs ->
      if is_binary(subject) and is_binary(body) do
        cs
        |> Ash.Changeset.force_change_attribute(
          :content_sha256,
          Canonical.sha256(%{subject: subject, body_text: body})
        )
        |> Ash.Changeset.force_change_attribute(:canonicalization_version, Canonical.version())
      else
        cs
      end
    end)
    |> Ash.Changeset.before_action(&lineage/1)
    |> Ash.Changeset.before_action(&provenance/1)
  end

  defp lineage(changeset) do
    get = &Ash.Changeset.get_attribute(changeset, &1)

    case {get.(:parent_revision_id), get.(:revision_number)} do
      {nil, 1} ->
        changeset

      {nil, _n} ->
        error(changeset, :revision_number, "a first revision is number 1")

      {parent_id, n} ->
        draft_id = get.(:draft_id)

        case read(DraftRevision, parent_id) do
          %{draft_id: ^draft_id, revision_number: m} when n == m + 1 ->
            changeset

          _ ->
            error(
              changeset,
              :parent_revision_id,
              "must be the previous revision of the same draft"
            )
        end
    end
  end

  defp provenance(changeset) do
    get = &Ash.Changeset.get_attribute(changeset, &1)

    if get.(:author_type) == :agent do
      run_id = get.(:agent_run_id)

      case read(Decision, get.(:decision_id)) do
        %{kind: :draft_proposal, mode: :llm, agent_run_id: ^run_id} = decision
        when not is_nil(run_id) ->
          check_invocation(changeset, decision, get.(:model_invocation_id))

        _ ->
          error(
            changeset,
            :decision_id,
            "must be an llm draft_proposal decision of the agent run"
          )
      end
    else
      changeset
    end
  end

  defp check_invocation(changeset, decision, nil),
    do:
      Ash.Changeset.force_change_attribute(
        changeset,
        :model_invocation_id,
        decision.model_invocation_id
      )

  defp check_invocation(changeset, %{model_invocation_id: id}, id), do: changeset

  defp check_invocation(changeset, _decision, _other),
    do: error(changeset, :model_invocation_id, "must be the decision's model invocation")

  defp read(_resource, nil), do: nil

  # Internal invariant reads; nothing read here is returned to the caller.
  defp read(resource, id),
    do: resource |> Ash.Query.filter(id == ^id) |> Ash.read_one!(authorize?: false)

  defp error(changeset, field, message),
    do: Ash.Changeset.add_error(changeset, field: field, message: message)
end
