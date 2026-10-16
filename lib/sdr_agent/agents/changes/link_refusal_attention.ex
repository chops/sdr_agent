defmodule SdrAgent.Agents.Changes.LinkRefusalAttention do
  @moduledoc """
  AgentRun `:fail` / `:exhaust_budget` change for a run stopped by a refused
  real-model call (C9; status reasons `:grant_unavailable` and
  `:grant_exhausted`; R0-07 slice B, row B1: `:model_not_admitted`):
  instead of opening a second operator-attention Failure, the run links the
  exact Failure of that refusal (the receipt's `refusal_failure_id` and
  `refusal_request_id`, from `SdrAgent.Agents.Admission.record_refusal/1`
  or `SdrAgent.Agents.admit_launch/3`) as its `attention_failure_id`.

  In a `before_action`, with the run row already locked, the Failure is read
  `FOR UPDATE` (lock order run → Failure → chain head, as Operation `:fail`
  and Failure `:resolve` take Failure → head). It must be this refusal's —
  of the run's tenant, with this run as its subject and the run's Operation
  (or none) as its `operation_id` — and of the stop reason's category, each
  with its own immutable provenance:

    * **budget** (`:grant_exhausted`, `:grant_unavailable`): class
      `budget_exhausted`, named with this request id by a
      `model.reservation.refused` event of this run whose recorded reason is
      a grant, grant-day or allocation cap for `:grant_exhausted`, any other
      grant reason for `:grant_unavailable`;
    * **admission before reservation** (`:model_not_admitted`): class
      `provider_error`, named with this request id by a
      `model.reservation.refused` event of this run whose recorded reason is
      one of the admission-gate reasons or the profile switch fence's
      (`:profile_switch_fenced`, C2-02b1);
    * **launch** (`:model_not_admitted`): class `provider_error`, named by a
      `model.launch.refused` event of this run with this request id and a
      launch reason, whose invocation is this run's, carries this request
      id as its own `idempotency_key` and was failed by that launch refusal.
      A valid invocation of the same run under another request is not
      enough; an identity-refusal event names no Failure and is never a
      cause.

  Its status does not matter: if an admin resolved the refusal before the
  run stopped, the run still stops with its reason and records that same
  Failure as its cause; no new Failure is opened.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Agents.Admission.Gate
  alias SdrAgent.Agents.Admission.SwitchFence
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Audit.AuditEvent
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations.Failure

  @caps ["grant_exhausted", "grant_day_exhausted", "allocation_exhausted"]
  @unavailable ["no_eligible_grant", "no_allocation", "ambiguous_allocation", "no_usage_origin"]
  @admission Enum.map(Gate.reasons() ++ SwitchFence.reasons(), &Atom.to_string/1)
  @launch @admission ++
            [
              "grant_ineligible_at_launch",
              "legacy_invocation_without_grant",
              "profile_mismatch_at_launch"
            ]

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
         true <- condition_of?(failure, run, stop),
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

  defp condition_of?(failure, run, stop) do
    failure.tenant_id == run.tenant_id and failure.class == class(stop) and
      failure.subject_resource == inspect(run.__struct__) and failure.subject_id == run.id and
      failure.operation_id == run.operation_id
  end

  defp class(:model_not_admitted), do: :provider_error
  defp class(_stop), do: :budget_exhausted

  defp refused_with?(failure, run, request_id, :model_not_admitted),
    do:
      reservation_refused?(failure, run, request_id, @admission) or
        launch_refused?(failure, run, request_id)

  defp refused_with?(failure, run, request_id, :grant_exhausted),
    do: reservation_refused?(failure, run, request_id, @caps)

  defp refused_with?(failure, run, request_id, :grant_unavailable),
    do: reservation_refused?(failure, run, request_id, @unavailable)

  defp refused_with?(_failure, _run, _request_id, _stop), do: false

  defp reservation_refused?(failure, run, request_id, reasons) do
    run
    |> events("model.reservation.refused", request_id)
    |> Enum.any?(&(&1.payload["failure_id"] == failure.id and &1.payload["reason"] in reasons))
  end

  defp launch_refused?(failure, run, request_id) do
    run
    |> events("model.launch.refused", request_id)
    |> Enum.any?(fn event ->
      event.payload["failure_id"] == failure.id and event.payload["reason"] in @launch and
        launch_failed?(event, run, request_id)
    end)
  end

  # The event's invocation is this run's, of this request, failed by the
  # launch refusal the event records.
  defp launch_failed?(%{model_invocation_id: id} = event, run, request_id) when is_binary(id) do
    case ModelInvocation
         |> Ash.Query.filter(id == ^id and tenant_id == ^run.tenant_id)
         |> Ash.Query.select([:id, :agent_run_id, :idempotency_key, :status, :error])
         |> Ash.read_one(Kernel.opts(run.tenant_id)) do
      {:ok, %{} = invocation} ->
        invocation.agent_run_id == run.id and invocation.idempotency_key == request_id and
          invocation.status == :failed and
          match?(%{"kind" => "launch_refused"}, invocation.error) and
          invocation.error["reason"] == event.payload["reason"]

      _missing ->
        false
    end
  end

  defp launch_failed?(_event, _run, _request_id), do: false

  defp events(run, event_type, request_id) do
    AuditEvent
    |> Ash.Query.filter(
      tenant_id == ^run.tenant_id and event_type == ^event_type and agent_run_id == ^run.id and
        idempotency_key == ^request_id
    )
    |> Ash.read!(Kernel.opts(run.tenant_id))
  end

  defp invalid(changeset) do
    Ash.Changeset.add_error(changeset,
      field: :refusal_failure_id,
      message: "must be the Failure of this run's refusal, of the stop's reason"
    )
  end
end
