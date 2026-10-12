defmodule SdrAgent.Agents.Changes.LinkRefusalAttention do
  @moduledoc """
  AgentRun `:fail` / `:exhaust_budget` change for a run stopped by a refused
  real-model reservation (C9; status reasons `:grant_unavailable` and
  `:grant_exhausted`): instead of opening a second operator-attention
  Failure, the run links the refusal's own deduplicated Failure (argument
  `refusal_failure_id`, opened by `SdrAgent.Agents.Admission.record_refusal/1`)
  as its `attention_failure_id`, and through it its Operation (the Failure
  carries the run's `operation_id`).

  In a `before_action`, with the run row already locked, the Failure is read
  `FOR UPDATE` (lock order run → Failure → chain head, as Operation `:fail`
  and Failure `:resolve` take Failure → head) and must be live (open or
  acknowledged), of the run's tenant, of class `budget_exhausted` and have
  this run as its subject; anything else refuses the transition.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations.Failure

  @live [:open, :acknowledged]

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      if changeset.valid?, do: link(changeset), else: changeset
    end)
  end

  defp link(changeset) do
    run = changeset.data
    id = Ash.Changeset.get_argument(changeset, :refusal_failure_id)

    Failure
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(Kernel.opts(run.tenant_id))
    |> case do
      {:ok, %Failure{} = failure} ->
        if refusal_of?(failure, run),
          do: Ash.Changeset.force_change_attribute(changeset, :attention_failure_id, failure.id),
          else: invalid(changeset)

      _ ->
        invalid(changeset)
    end
  end

  defp refusal_of?(failure, run) do
    failure.tenant_id == run.tenant_id and failure.status in @live and
      failure.class == :budget_exhausted and
      failure.subject_resource == inspect(run.__struct__) and failure.subject_id == run.id
  end

  defp invalid(changeset) do
    Ash.Changeset.add_error(changeset,
      field: :refusal_failure_id,
      message: "must be a live reservation-refusal Failure of this run"
    )
  end
end
