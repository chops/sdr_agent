defmodule SdrAgent.Outreach.Changes.CheckSuppressionSource do
  @moduledoc """
  A suppression that cites a Decision must cite one that decided it (S2:
  "unsubscribe_reply by rule" for WHK, "from classification only" for AGT;
  spec §8): the decision exists in the tenant, is of `:decision_kind`, has
  outcome `"unsubscribe"`, and — for `unsubscribe_reply` — is about the
  cited reply. Checked inside the create transaction (internal read; nothing
  is returned to the caller).
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Agents.Decision

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case Ash.Changeset.get_attribute(changeset, :decision_id) do
        nil -> changeset
        id -> check(changeset, read(changeset, id), opts[:decision_kind])
      end
    end)
  end

  defp check(changeset, %Decision{kind: kind, outcome: "unsubscribe"} = decision, kind) do
    reply_id = Ash.Changeset.get_attribute(changeset, :reply_id)

    if Ash.Changeset.get_attribute(changeset, :reason) == :unsubscribe_reply and
         decision.subject_id != reply_id,
       do: invalid(changeset, "must be a decision about the cited reply"),
       else: changeset
  end

  defp check(changeset, _decision, kind),
    do: invalid(changeset, "must be an #{kind} decision with outcome unsubscribe")

  defp read(changeset, id) do
    tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)

    Decision
    |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp invalid(changeset, message),
    do: Ash.Changeset.add_error(changeset, field: :decision_id, message: message)
end
