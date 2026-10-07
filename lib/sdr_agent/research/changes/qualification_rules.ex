defmodule SdrAgent.Research.Changes.QualificationRules do
  @moduledoc """
  Qualification invariants (S2 row Qualification), checked in the create
  transaction:

    * agent source — `agent_run_id` is present and equals the decision's
      run; the decision is an `:llm` decision of kind `:qualification` whose
      model invocation is `completed` with `validation_status: :valid`;
    * human override — `supersedes_id` is present; `created_by_user_id` is
      the acting user and `decision_id` is the superseded row's decision
      (humans never record Decisions);
    * cited evidence (`evidence_claim_ids`) — every claim exists and belongs
      to the same lead; `qualified: true` needs at least one `:accepted`
      claim.

  Option `:source` — `:agent` or `:human_override`.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Agents.Decision
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Research.EvidenceClaim

  @impl true
  def change(changeset, opts, context) do
    changeset
    |> Ash.Changeset.force_change_attribute(:source, opts[:source])
    |> source_setup(opts[:source], context.actor)
    |> Ash.Changeset.before_action(&check(&1, opts[:source]))
  end

  defp source_setup(changeset, :human_override, %{id: user_id}),
    do: Ash.Changeset.force_change_attribute(changeset, :created_by_user_id, user_id)

  defp source_setup(changeset, _source, _actor), do: changeset

  defp check(changeset, source) do
    {changeset, source_errors} = source_rules(changeset, source)

    Enum.reduce(source_errors ++ evidence_errors(changeset), changeset, fn {field, message},
                                                                           acc ->
      Ash.Changeset.add_error(acc, field: field, message: message)
    end)
  end

  defp source_rules(changeset, :agent), do: {changeset, agent_errors(changeset)}

  defp source_rules(changeset, :human_override) do
    case read(changeset.resource, Ash.Changeset.get_attribute(changeset, :supersedes_id)) do
      nil ->
        {changeset, [{:supersedes_id, "an override must supersede the current qualification"}]}

      superseded ->
        # The override cites the decision of the row it overrides.
        {Ash.Changeset.force_change_attribute(changeset, :decision_id, superseded.decision_id),
         []}
    end
  end

  defp agent_errors(changeset) do
    run_id = Ash.Changeset.get_attribute(changeset, :agent_run_id)

    case read(Decision, Ash.Changeset.get_attribute(changeset, :decision_id)) do
      nil ->
        [{:decision_id, "does not exist"}]

      decision ->
        [
          (decision.mode != :llm or decision.kind != :qualification) &&
            {:decision_id, "must be an llm qualification decision"},
          (is_nil(run_id) or decision.agent_run_id != run_id) &&
            {:agent_run_id, "must be the decision's agent run"},
          not valid_invocation?(decision.model_invocation_id) &&
            {:decision_id, "must cite a completed, valid model invocation"}
        ]
        |> Enum.filter(& &1)
    end
  end

  defp evidence_errors(changeset) do
    ids = Ash.Changeset.get_argument(changeset, :evidence_claim_ids) || []
    lead_id = Ash.Changeset.get_attribute(changeset, :lead_id)
    claims = if ids == [], do: [], else: read_claims(ids)

    [
      length(claims) != length(Enum.uniq(ids)) && {:evidence_claim_ids, "unknown claim"},
      Enum.any?(claims, &(&1.lead_id != lead_id)) &&
        {:evidence_claim_ids, "claims must belong to the same lead"},
      (Ash.Changeset.get_attribute(changeset, :qualified) == true and
         not Enum.any?(claims, &(&1.quality == :accepted))) &&
        {:evidence_claim_ids, "a qualified result needs an accepted claim"}
    ]
    |> Enum.filter(& &1)
  end

  defp valid_invocation?(nil), do: false

  defp valid_invocation?(id) do
    match?(%{status: :completed, validation_status: :valid}, read(ModelInvocation, id))
  end

  # Internal invariant reads (as Ash's get_and_lock_for_update); nothing is returned.
  defp read(_resource, nil), do: nil

  defp read(resource, id) do
    resource
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(authorize?: false)
  end

  defp read_claims(ids) do
    EvidenceClaim
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read!(authorize?: false)
  end
end
