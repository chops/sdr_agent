defmodule SdrAgent.SDR.StaleRunSweeper do
  @moduledoc """
  Oban cron worker (queue `default`, every 5 minutes): recovers AgentRuns
  abandoned by a crash the worker could not record (S7 choice 11/15, S9b
  review item 3) — a VM crash, a killed process, or a crash of the
  terminal write itself — which leave the run (and its Operation)
  `running` and a model call `sent`.

  A run is *abandoned* when it has been `running` for longer than
  `stale_after_seconds/0` (default 1800 s; `config :sdr_agent,
  SdrAgent.SDR.StaleRunSweeper, stale_after_seconds:`) **and** its Oban job
  is no longer live (not `available`, `scheduled`, `executing` or
  `retryable` — after a restart Oban's lifeline discards an orphaned
  one-attempt agent job — or gone). A run whose job is still live is never
  touched.

  Recovery, per run, in one transaction (the run and its Operation are
  locked `FOR UPDATE` before the first append, ADR-0009), as the agent
  runtime through existing actions only:

    1. every `sent` ModelInvocation of the run → `unknown` (never re-sent;
       it still counts against the budgets);
    2. the run → `failed` with `status_reason: :crash` and a redacted
       `failure_reason` naming the job state; this opens the run's
       attention Failure (operator retry: `SDR.retry_run/2`, S13b);
    3. a `running` Operation → `failed` linking that Failure (discarded at
       its one attempt).

  Idempotent: a recovered run is `failed`, so a later sweep skips it.
  Integration-queue reply runs have no Operation (S9 choice 12); their job is
  found by its `run_id` argument.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  import Ecto.Query, only: [from: 2]

  require Ash.Query

  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Clock
  alias SdrAgent.Operations
  alias SdrAgent.Operations.Operation
  alias SdrAgent.Repo

  @live_states ~w(available scheduled executing retryable)

  @impl Oban.Worker
  def perform(_job) do
    case Kernel.singleton_tenant_id() do
      {:ok, tenant_id} -> sweep(tenant_id)
      {:error, _not_bootstrapped} -> :ok
    end
  end

  @doc "Seconds a run may be `running` before it can be judged abandoned."
  @spec stale_after_seconds() :: pos_integer()
  def stale_after_seconds do
    :sdr_agent |> Application.get_env(__MODULE__, []) |> Keyword.get(:stale_after_seconds, 1800)
  end

  @doc "Recovers the tenant's abandoned runs (see the moduledoc). Returns `:ok`."
  @spec sweep(String.t()) :: :ok | {:error, term()}
  def sweep(tenant_id) do
    actor = Actor.system(:agent_runtime, tenant_id)
    cutoff = DateTime.add(Clock.utc_now(), -stale_after_seconds(), :second)

    with {:ok, runs} <- Agents.list_runs(actor: actor) do
      runs
      |> Enum.filter(&(&1.status == :running and stale?(&1, cutoff)))
      |> Enum.reject(&job_live?({&1, actor}))
      |> each_ok(&recovered(recover(&1, actor)))
    end
  end

  # A run that stopped running meanwhile was handled by its own worker.
  defp recovered({:error, :not_running}), do: :ok
  defp recovered({:ok, _}), do: :ok
  defp recovered(error), do: error

  # Applies `fun` (returning :ok | {:error, _}) to each item; stops at the first error.
  defp each_ok(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp stale?(%{started_at: %DateTime{} = started}, cutoff),
    do: DateTime.compare(started, cutoff) == :lt

  defp stale?(_run, _cutoff), do: false

  defp job_live?({run, actor}), do: job_state(run, actor) in @live_states

  # Assignment runs: the job of their Operation. Reply runs (no Operation):
  # the ReplyWorker job naming the run.
  defp job_state(%{operation_id: operation_id}, actor) when is_binary(operation_id) do
    case Operations.get_operation(operation_id, actor: actor) do
      {:ok, %{oban_job_id: job_id}} when is_integer(job_id) ->
        Repo.one(from(j in Oban.Job, where: j.id == ^job_id, select: j.state))

      _ ->
        nil
    end
  end

  defp job_state(%{id: run_id}, _actor) do
    Repo.one(
      from(j in Oban.Job,
        where:
          j.worker == "SdrAgent.SDR.ReplyWorker" and
            fragment("?->>'run_id' = ?", j.args, ^run_id),
        order_by: [desc: j.id],
        limit: 1,
        select: j.state
      )
    )
  end

  defp recover(run, actor) do
    state = job_state(run, actor) || "missing"

    Audit.transaction(fn ->
      with {:ok, run} <- lock(AgentRun, run.id, actor),
           :ok <- running(run),
           {:ok, operation} <- lock_operation(run, actor),
           :ok <- unknown_invocations(run, actor),
           {:ok, failed} <-
             Agents.fail_run(
               run,
               %{
                 status_reason: :crash,
                 failure_reason:
                   "abandoned: the worker exited without recording an outcome (job #{state})"
               },
               actor: actor
             ),
           {:ok, _} <- fail_operation(operation, failed, actor) do
        failed
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  defp running(%{status: :running}), do: :ok
  defp running(_run), do: {:error, :not_running}

  defp lock(resource, id, actor) do
    resource
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, :not_running}
      other -> other
    end
  end

  defp lock_operation(%{operation_id: nil}, _actor), do: {:ok, nil}
  defp lock_operation(%{operation_id: id}, actor), do: lock(Operation, id, actor)

  defp unknown_invocations(run, actor) do
    with {:ok, invocations} <- Agents.list_model_invocations(run.id, actor: actor) do
      invocations
      |> Enum.filter(&(&1.status == :sent))
      |> each_ok(&mark_unknown(&1, actor))
    end
  end

  defp mark_unknown(invocation, actor) do
    case Agents.mark_model_invocation_unknown(invocation, actor: actor) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp fail_operation(%{status: :running} = operation, failed, actor),
    do:
      Operations.fail_operation(operation, %{failure_id: failed.attention_failure_id},
        actor: actor
      )

  defp fail_operation(_operation, _failed, _actor), do: {:ok, :no_running_operation}
end
