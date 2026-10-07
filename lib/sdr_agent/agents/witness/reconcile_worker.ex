defmodule SdrAgent.Agents.Witness.ReconcileWorker do
  @moduledoc """
  Oban worker (queue `reconciliation`, concurrency 1 — shared with delivery
  reconciliation, S12 C8) running one `reconcile_model` Operation:
  `SdrAgent.Agents.Witness.reconcile/2` as the reconciler (REC).

  The Operation is written with the job by `SdrAgent.Agents.Witness.enqueue/2`.
  Lifecycle, all as REC (the kind's owner): enqueued → running on the first
  attempt, failed → running (`retry_operation`) on a later one; success
  succeeds the Operation; an error fails it — opening its Failure once and
  linking that live Failure on later attempts — and is returned so Oban
  retries, with the Operation discarded at the last attempt. Bounded:
  three attempts, sixty seconds each. Never calls a model.
  """
  use Oban.Worker, queue: :reconciliation, max_attempts: 3

  alias SdrAgent.Actor
  alias SdrAgent.Agents.Witness
  alias SdrAgent.Operations

  @doc "Attempts per job (also the Operation's `max_attempts`)."
  def max_attempts, do: 3

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(60)

  @impl Oban.Worker
  def perform(%Oban.Job{id: job_id, args: %{"tenant_id" => tenant_id} = args}) do
    actor = Actor.system(:reconciler, tenant_id)

    with {:ok, %Operations.Operation{} = operation} <-
           Operations.find_operation(job_id, actor: actor),
         {:ok, operation} <- begin(operation, actor) do
      run(operation, args["model_invocation_id"], actor)
    else
      {:ok, nil} -> {:cancel, :operation_missing}
      {:done, _operation} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp begin(%{status: :enqueued} = operation, actor),
    do: Operations.start_operation(operation, actor: actor)

  defp begin(%{status: :failed} = operation, actor),
    do: Operations.retry_operation(operation, actor: actor)

  defp begin(%{status: :running} = operation, _actor), do: {:ok, operation}
  defp begin(operation, _actor), do: {:done, operation}

  defp run(operation, invocation_id, actor) do
    case Witness.reconcile(invocation_id, actor: actor) do
      {:ok, _summary} ->
        with {:ok, _} <- Operations.succeed_operation(operation, actor: actor), do: :ok

      {:error, reason} ->
        {:ok, _failed} =
          Operations.fail_operation(operation, failure(operation, reason), actor: actor)

        {:error, reason}
    end
  end

  defp failure(%{last_failure_id: id}, _reason) when is_binary(id), do: %{failure_id: id}

  defp failure(operation, reason) do
    %{
      failure: %{
        class: :reconciliation_required,
        severity: :warning,
        message:
          "wire witness reconciliation attempt #{operation.attempts} failed: #{describe(reason)}",
        retryable: true
      }
    }
  end

  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(%{__exception__: true} = error), do: error.__struct__ |> inspect()
  defp describe(_reason), do: "error"
end
