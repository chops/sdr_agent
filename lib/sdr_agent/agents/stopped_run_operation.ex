defmodule SdrAgent.Agents.StoppedRunOperation do
  @moduledoc """
  The Operation outcome rule for a run stopped on a refusal or result-gate
  cause (C9, R0-07 slices B and C), shared by the SDR worker
  (`SdrAgent.SDR.AgentWorker.fail_operation/3`), the stale-run sweeper and
  the profile switch drain (C2-02b1). It is owned by the Agents domain, so
  the drain never calls up into a worker.

  In one transaction (joining the caller's, if any), in lock order
  Operation → Failure → chain head:
    * the run's Operation is locked `FOR UPDATE` and, **under that lock**,
      must still be `running`. An Operation already settled (by the worker,
      the sweeper or the drain) is left alone, so a contended or retried
      settlement settles it exactly once;
    * the run's cause Failure is locked `FOR UPDATE`. While it is live, the
      Operation fails linking it. Once it is resolved, the Operation fails
      with its own new Failure naming it: `provider_error` for
      `:model_not_admitted`, `reconciliation_required` for a gate stop
      (critical for `:witness_mismatch`), else `budget_exhausted`.

  So exactly one live attention item remains. A missing or unreadable cause
  is never read as resolved: it raises.

  Option `step:` (the drain's budget): run before each lock and the write,
  `:ok` or `{:error, reason}` to roll back unchanged.

  Option `before_write:` (the profile switch drain only): a function run
  after both locks and before the Operation changes, returning `:ok` or
  `{:error, reason}` to roll the transaction back unchanged. The drain uses
  it to take the chain head and revalidate its named switch (Operation →
  Failure → head). The worker and the sweeper pass none.
  """
  require Ash.Query

  alias SdrAgent.Audit
  alias SdrAgent.Operations
  alias SdrAgent.Repo

  @gate [:witness_mismatch, :witness_unreconciled]

  @doc """
  Fails `operation_id`'s Operation for the stopped `run` (its
  `status_reason` and `attention_failure_id`) as `actor`. Returns `:ok` (also
  when the Operation was already settled), or `{:error, error}` when the
  Operation transaction failed (nothing was changed).
  """
  def settle(operation_id, run, actor, opts \\ []) do
    before_write = Keyword.get(opts, :before_write, &ok/0)
    step = Keyword.get(opts, :step, &ok/0)

    fn ->
      with :ok <- step.(),
           {:ok, %{status: :running} = operation} <- lock_operation(operation_id, actor),
           :ok <- step.() do
        fail(operation, run, actor, before_write)
      else
        {:ok, _settled_or_missing} -> :ok
        {:error, error} -> Repo.rollback(error)
      end
    end
    |> Audit.transaction()
    |> case do
      {:ok, :ok} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp fail(operation, run, actor, before_write) do
    attrs =
      if live_failure?(run.attention_failure_id, actor),
        do: %{failure_id: run.attention_failure_id},
        else: %{failure: resolved_cause_failure(run)}

    with :ok <- before_write.(),
         {:ok, _operation} <- Operations.fail_operation(operation, attrs, actor: actor) do
      :ok
    else
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp ok, do: :ok

  defp lock_operation(id, actor) do
    Operations.Operation
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one()
  end

  # Read FOR UPDATE, so a resolution cannot slip between this check and the
  # Operation's link of the same Failure.
  defp live_failure?(id, actor) do
    Operations.Failure
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one()
    |> case do
      {:ok, %{status: status}} ->
        status in [:open, :acknowledged]

      # A missing row or a read error is not a human resolution: fail loudly
      # rather than open a Failure that claims the cause was resolved.
      {:ok, nil} ->
        raise "cause Failure #{id} not found for its run"

      {:error, error} ->
        raise "could not read cause Failure #{id}: #{Exception.message(error)}"
    end
  end

  defp resolved_cause_failure(%{status_reason: reason} = run) when reason in @gate do
    %{
      class: :reconciliation_required,
      severity: if(reason == :witness_mismatch, do: :critical, else: :warning),
      retryable: false,
      message:
        "agent run #{run.status}: #{run.status_reason}; its result gate cause " <>
          "(Failure #{run.attention_failure_id}) was resolved before the run stopped"
    }
  end

  # R0-07 slice B (row B1): an admission refusal's cause is a provider_error.
  defp resolved_cause_failure(%{status_reason: :model_not_admitted} = run) do
    %{
      class: :provider_error,
      severity: :critical,
      retryable: false,
      message:
        "agent run #{run.status}: #{run.status_reason}; its model call admission " <>
          "refusal (Failure #{run.attention_failure_id}) was resolved before the run stopped"
    }
  end

  defp resolved_cause_failure(run) do
    %{
      class: :budget_exhausted,
      severity: :critical,
      retryable: false,
      message:
        "agent run #{run.status}: #{run.status_reason}; its model call reservation " <>
          "refusal (Failure #{run.attention_failure_id}) was resolved before the run stopped"
    }
  end
end
