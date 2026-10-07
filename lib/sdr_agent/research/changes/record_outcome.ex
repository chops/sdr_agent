defmodule SdrAgent.Research.Changes.RecordOutcome do
  @moduledoc """
  After a Qualification row is inserted, in the same transaction:

    1. creates one `QualificationEvidence` row per cited claim
       (`evidence_claim_ids`), and
    2. moves the lead in the same transaction (S2: "Lead transitions to
       qualified/disqualified only in the same transaction as the
       Qualification create"), so the current qualification and the lead
       never disagree:
       * `transition_lead: :agent` — qualifying → qualified or disqualified,
         citing the qualification's decision;
       * `transition_lead: :override` — only when the override flips the
         superseded outcome: qualified → disqualified
         (`:disqualify_by_override`) or disqualified → qualified
         (`:requalify_by_override`). Any other lead state refuses the
         override and names the operator action instead (`:stop` once
         outreach has begun). An override keeping the outcome moves nothing.

  These writes carry the private `SdrAgent.Sales.Checks.QualificationContext`
  marker, which their policies require; if any fails, the whole
  qualification rolls back.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias Ash.Error.Changes.InvalidAttribute
  alias SdrAgent.Research.Qualification
  alias SdrAgent.Research.QualificationEvidence
  alias SdrAgent.Sales.Checks.QualificationContext
  alias SdrAgent.Sales.Lead

  @impl true
  def change(changeset, opts, context) do
    Ash.Changeset.after_action(changeset, fn changeset, qualification ->
      ids = changeset |> Ash.Changeset.get_argument(:evidence_claim_ids) |> List.wrap()

      with :ok <- link_evidence(qualification, Enum.uniq(ids), context.actor),
           :ok <- transition_lead(opts[:transition_lead], qualification, context.actor) do
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

  defp transition_lead(:agent, qualification, actor) do
    action = if qualification.qualified, do: :qualify, else: :disqualify

    move_lead(
      read(Lead, qualification.lead_id),
      action,
      %{decision_id: qualification.decision_id},
      actor
    )
  end

  defp transition_lead(:override, qualification, actor) do
    superseded = read(Qualification, qualification.supersedes_id)
    lead = read(Lead, qualification.lead_id)

    cond do
      superseded.qualified == qualification.qualified ->
        :ok

      qualification.qualified and lead.status == :disqualified ->
        move_lead(lead, :requalify_by_override, %{status_reason: qualification.reason}, actor)

      not qualification.qualified and lead.status == :qualified ->
        move_lead(lead, :disqualify_by_override, %{status_reason: qualification.reason}, actor)

      qualification.qualified ->
        refuse(
          "the lead is #{lead.status}: an override re-qualifies only a disqualified lead " <>
            "(a reopened lead is re-qualified by the agent; to end it use Sales :stop)"
        )

      true ->
        refuse(
          "the lead is #{lead.status}: an override disqualifies only a qualified lead; " <>
            "once outreach has begun, end the lead with Sales :stop instead"
        )
    end
  end

  defp transition_lead(_none, _qualification, _actor), do: :ok

  defp move_lead(lead, action, attrs, actor) do
    lead
    |> Ash.Changeset.for_update(action, attrs,
      actor: actor,
      context: QualificationContext.context()
    )
    |> Ash.update(return_notifications?: true)
    |> case do
      {:ok, _lead, _notifications} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp refuse(message),
    do: {:error, InvalidAttribute.exception(field: :lead_id, message: message)}

  # Internal reads of the rows to compare and move; the transitions themselves
  # are authorized (actor + the qualification context) and re-read under lock.
  defp read(resource, id) do
    resource
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(authorize?: false)
  end
end
