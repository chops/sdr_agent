defmodule SdrAgent.Agents.Changes.LinkRefusalAttention do
  @moduledoc """
  AgentRun `:fail` / `:exhaust_budget` change for a run stopped by a refused
  real-model reservation (C9; status reasons `:grant_unavailable` and
  `:grant_exhausted`): instead of opening a second operator-attention
  Failure, the run links the exact Failure of that refusal (the receipt's
  `refusal_failure_id` and `refusal_request_id`, from
  `SdrAgent.Agents.Admission.record_refusal/1`) as its
  `attention_failure_id`.

  In a `before_action`, with the run row already locked, the Failure is read
  `FOR UPDATE` (lock order run → Failure → chain head, as Operation `:fail`
  and Failure `:resolve` take Failure → head). It must be this refusal's:

    * of the run's tenant, class `budget_exhausted`, with this run as its
      subject and the run's Operation (or none) as its `operation_id`;
    * named, with this request id, by a `model.reservation.refused` event of
      this run (the immutable refusal provenance), whose recorded reason is of
      the stop reason's category: a grant, grant-day or allocation cap for
      `:grant_exhausted`, anything else for `:grant_unavailable`.

  Its status does not matter: if an admin resolved the refusal before the
  run stopped, the run still stops with the grant reason and records that
  same Failure as its cause; no new Failure is opened.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Audit.AuditEvent
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations.Failure

  @caps ["grant_exhausted", "grant_day_exhausted", "allocation_exhausted"]
  @unavailable ["no_eligible_grant", "no_allocation", "ambiguous_allocation", "no_usage_origin"]

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      if changeset.valid?, do: link(changeset), else: changeset
    end)
  end

  defp link(changeset) do
    run = changeset.data
    id = Ash.Changeset.get_argument(changeset, :refusal_failure_id)
    request_id = Ash.Changeset.get_argument(changeset, :refusal_request_id)
    stop = Ash.Changeset.get_argument(changeset, :status_reason)

    with {:ok, %Failure{} = failure} <- lock_failure(id, run.tenant_id),
         true <- condition_of?(failure, run),
         true <- refused_with?(failure, run, request_id, stop) do
      Ash.Changeset.force_change_attribute(changeset, :attention_failure_id, failure.id)
    else
      _ -> invalid(changeset)
    end
  end

  defp lock_failure(id, tenant_id) do
    Failure
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(Kernel.opts(tenant_id))
  end

  defp condition_of?(failure, run) do
    failure.tenant_id == run.tenant_id and failure.class == :budget_exhausted and
      failure.subject_resource == inspect(run.__struct__) and failure.subject_id == run.id and
      failure.operation_id == run.operation_id
  end

  defp refused_with?(failure, run, request_id, stop) do
    AuditEvent
    |> Ash.Query.filter(
      tenant_id == ^run.tenant_id and event_type == "model.reservation.refused" and
        agent_run_id == ^run.id and idempotency_key == ^request_id
    )
    |> Ash.read!(Kernel.opts(run.tenant_id))
    |> Enum.any?(
      &(&1.payload["failure_id"] == failure.id and category?(&1.payload["reason"], stop))
    )
  end

  defp category?(reason, :grant_exhausted), do: reason in @caps
  defp category?(reason, :grant_unavailable), do: reason in @unavailable
  defp category?(_reason, _stop), do: false

  defp invalid(changeset) do
    Ash.Changeset.add_error(changeset,
      field: :refusal_failure_id,
      message: "must be the Failure of this run's reservation refusal, of the stop's reason"
    )
  end
end
