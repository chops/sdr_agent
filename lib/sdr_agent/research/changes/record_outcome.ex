defmodule SdrAgent.Research.Changes.RecordOutcome do
  @moduledoc """
  After a Qualification row is inserted, in the same transaction:

    1. creates one `QualificationEvidence` row per cited claim
       (`evidence_claim_ids`), and
    2. for an agent qualification, moves the lead qualifying → qualified or
       disqualified (S2: "only in the same transaction as the Qualification
       create"), citing the qualification's decision.

  Both writes carry the private `SdrAgent.Sales.Checks.QualificationContext`
  marker, which their policies require; if either fails, the whole
  qualification rolls back. Option `:transition_lead?`.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Research.QualificationEvidence
  alias SdrAgent.Sales.Checks.QualificationContext
  alias SdrAgent.Sales.Lead

  @impl true
  def change(changeset, opts, context) do
    Ash.Changeset.after_action(changeset, fn changeset, qualification ->
      ids = changeset |> Ash.Changeset.get_argument(:evidence_claim_ids) |> List.wrap()

      with :ok <- link_evidence(qualification, Enum.uniq(ids), context.actor),
           :ok <- transition_lead(opts[:transition_lead?], qualification, context.actor) do
        {:ok, qualification}
      end
    end)
  end

  defp link_evidence(qualification, ids, actor) do
    Enum.reduce_while(ids, :ok, fn claim_id, :ok ->
      QualificationEvidence
      |> Ash.Changeset.for_create(
        :link,
        %{qualification_id: qualification.id, evidence_claim_id: claim_id},
        actor: actor,
        context: QualificationContext.context()
      )
      |> Ash.create(return_notifications?: true)
      |> case do
        {:ok, _row, _notifications} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp transition_lead(true, qualification, actor) do
    action = if qualification.qualified, do: :qualify, else: :disqualify

    # Internal read of the row to transition; the transition itself is
    # authorized (AGT + the qualification context) and re-reads under lock.
    lead =
      Lead
      |> Ash.Query.filter(id == ^qualification.lead_id)
      |> Ash.read_one!(authorize?: false)

    lead
    |> Ash.Changeset.for_update(action, %{decision_id: qualification.decision_id},
      actor: actor,
      context: QualificationContext.context()
    )
    |> Ash.update(return_notifications?: true)
    |> case do
      {:ok, _lead, _notifications} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp transition_lead(_no, _qualification, _actor), do: :ok
end
