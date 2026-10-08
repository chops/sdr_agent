defmodule SdrAgent.Agents.Changes.RetryOf do
  @moduledoc """
  Builds an operator retry (S2 AgentRun: "the operator retry creates a new
  run (retry_of_id), never a loop"; S13b): copies the definition, subject,
  trigger, correlation, phase and budget limits (never raised) of a
  terminal run in `failed`, `budget_exhausted` or `cancelled`, with fresh
  counters.

  `operation_id` binds the new run to the Operation created for it in the
  same transaction (assignment retries): it must be `enqueued`, of kind
  `research_lead` on queue `research`, of the run's tenant, with the run's
  lead as subject, and bound to no other run. An assignment
  (`sdr.lead.assigned`) retry requires it; a reply retry must not carry one.

  Outside the retry orchestration (no `RetryContext` marker) the change does
  nothing but refuse: the action is Forbidden, never an input error, so a
  direct call learns nothing about the prior run.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias Ash.Error.Forbidden
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.Checks.RetryContext
  alias SdrAgent.Audit.Changes.SetTenant
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations.Operation

  @retryable [:failed, :budget_exhausted, :cancelled]

  @impl true
  def change(changeset, _opts, context) do
    if RetryContext.marked?(changeset.context),
      do: build(changeset, context),
      else: Ash.Changeset.add_error(changeset, Forbidden.exception([]))
  end

  defp build(changeset, context) do
    run_id = Ash.Changeset.get_argument(changeset, :run_id)
    operation_id = Ash.Changeset.get_argument(changeset, :operation_id)
    tenant_id = SetTenant.tenant_of(context.actor)

    case Ash.get(AgentRun, run_id, Kernel.opts(tenant_id)) do
      {:ok, %{status: status} = prior} when status in @retryable ->
        case operation(prior, operation_id, tenant_id) do
          :ok ->
            copy(changeset, prior, operation_id)

          {:error, message} ->
            Ash.Changeset.add_error(changeset, field: :operation_id, message: message)
        end

      {:ok, %{status: status}} ->
        Ash.Changeset.add_error(changeset,
          field: :run_id,
          message: "only failed, budget_exhausted or cancelled runs can be retried (is #{status})"
        )

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  defp copy(changeset, prior, operation_id) do
    Ash.Changeset.force_change_attributes(changeset, %{
      retry_of_id: prior.id,
      operation_id: operation_id,
      agent_definition_id: prior.agent_definition_id,
      lead_id: prior.lead_id,
      campaign_id: prior.campaign_id,
      trigger_signal_type: prior.trigger_signal_type,
      trigger_signal_id: prior.trigger_signal_id,
      correlation_id: prior.correlation_id,
      phase: prior.phase,
      budget: %{
        max_model_calls: prior.budget.max_model_calls,
        max_tool_calls: prior.budget.max_tool_calls,
        max_tokens: prior.budget.max_tokens
      }
    })
  end

  defp operation(%{trigger_signal_type: "sdr.lead.assigned"}, nil, _tenant_id),
    do: {:error, "an assignment retry needs its new Operation"}

  defp operation(%{trigger_signal_type: "sdr.lead.assigned"} = prior, operation_id, tenant_id) do
    opts = Kernel.opts(tenant_id)

    with {:ok, %Operation{} = op} <- Ash.get(Operation, operation_id, opts),
         true <-
           op.status == :enqueued and op.kind == :research_lead and op.queue == :research and
             op.tenant_id == tenant_id and op.subject_id == prior.lead_id,
         {:ok, nil} <-
           AgentRun
           |> Ash.Query.for_read(:read, %{}, opts)
           |> Ash.Query.filter(operation_id == ^operation_id)
           |> Ash.read_one() do
      :ok
    else
      _ -> {:error, "the Operation is not an unbound enqueued research Operation of this lead"}
    end
  end

  defp operation(_prior, nil, _tenant_id), do: :ok

  defp operation(_prior, _operation_id, _tenant_id),
    do: {:error, "only an assignment retry takes an Operation"}
end
