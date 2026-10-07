defmodule SdrAgent.Agents.Witness.ReconcileWorker do
  @moduledoc """
  Oban worker (queue `reconciliation`, concurrency 1 — shared with delivery
  reconciliation, S12 C8) running one `reconcile_model` Operation:
  `SdrAgent.Agents.Witness.reconcile/2` as the reconciler (REC).

  The Operation is written with the job by `SdrAgent.Agents.Witness.enqueue/2`.
  Every transition uses the reviewed lifecycle as REC, the kind's owner.
  Before running, the Operation is brought level with Oban's attempt
  number, so its `attempts` stay truthful even after a killed (timed-out)
  or crashed attempt:

    * enqueued → running (`start_operation`) for the first attempt;
    * an earlier attempt that never settled (`running`) is recorded as
      failed (`attempt_interrupted`, linking the Operation's live Failure
      once it has one), and the Operation is retried (failed → running) up
      to the current attempt.

  Success succeeds the Operation. An error **or exception** fails it and is
  returned so Oban retries; at the last attempt the failure also discards
  it. A final attempt killed by the timeout is settled later by
  `SdrAgent.Agents.Witness.ScanWorker`. Three attempts of sixty seconds;
  never calls a model.
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
  def perform(%Oban.Job{id: job_id, attempt: attempt, args: %{"tenant_id" => tenant_id} = args}) do
    actor = Actor.system(:reconciler, tenant_id)

    with {:ok, %Operations.Operation{} = operation} <-
           Operations.find_operation(job_id, actor: actor),
         {:ok, operation} <- level(operation, attempt, actor) do
      run(operation, args["model_invocation_id"], actor)
    else
      {:ok, nil} -> {:cancel, :operation_missing}
      {:done, _operation} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  # Brings the Operation to `running` at Oban's attempt number.
  defp level(%{status: status} = operation, _attempt, _actor)
       when status in [:succeeded, :discarded, :cancelled],
       do: {:done, operation}

  defp level(%{status: :enqueued} = operation, attempt, actor) do
    with {:ok, started} <- Operations.start_operation(operation, actor: actor),
         do: level(started, attempt, actor)
  end

  defp level(%{status: :running, attempts: done} = operation, attempt, _actor)
       when done >= attempt,
       do: {:ok, operation}

  defp level(%{status: :running} = operation, attempt, actor) do
    with {:ok, failed} <-
           Operations.fail_operation(operation, failure(operation, :attempt_interrupted),
             actor: actor
           ),
         do: level(failed, attempt, actor)
  end

  defp level(%{status: :failed} = operation, attempt, actor) do
    with {:ok, running} <- Operations.retry_operation(operation, actor: actor),
         do: level(running, attempt, actor)
  end

  defp run(operation, invocation_id, actor) do
    case safely(fn -> Witness.reconcile(invocation_id, actor: actor) end) do
      {:ok, _summary} ->
        with {:ok, _} <- Operations.succeed_operation(operation, actor: actor), do: :ok

      {:error, reason} ->
        {:ok, _failed} =
          Operations.fail_operation(operation, failure(operation, reason), actor: actor)

        {:error, reason}
    end
  end

  defp safely(fun) do
    fun.()
  rescue
    exception -> {:error, exception}
  catch
    kind, _reason -> {:error, kind}
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
  defp describe(%{__exception__: true} = error), do: inspect(error.__struct__)
  defp describe(_reason), do: "error"
end
