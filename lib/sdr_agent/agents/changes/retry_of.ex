defmodule SdrAgent.Agents.Changes.RetryOf do
  @moduledoc """
  Builds an operator retry (S2 AgentRun: "the operator retry creates a new
  run (retry_of_id), never a loop"): copies the definition, subject,
  trigger, correlation, phase and budget limits of a terminal run in
  `failed`, `budget_exhausted` or `cancelled`, with fresh counters.
  """
  use Ash.Resource.Change

  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Audit.Kernel

  @retryable [:failed, :budget_exhausted, :cancelled]

  @impl true
  def change(changeset, _opts, context) do
    run_id = Ash.Changeset.get_argument(changeset, :run_id)
    tenant_id = SdrAgent.Audit.Changes.SetTenant.tenant_of(context.actor)

    case Ash.get(AgentRun, run_id, Kernel.opts(tenant_id)) do
      {:ok, %{status: status} = prior} when status in @retryable ->
        changeset
        |> Ash.Changeset.force_change_attributes(%{
          retry_of_id: prior.id,
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

      {:ok, %{status: status}} ->
        Ash.Changeset.add_error(changeset,
          field: :run_id,
          message: "only failed, budget_exhausted or cancelled runs can be retried (is #{status})"
        )

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end
end
