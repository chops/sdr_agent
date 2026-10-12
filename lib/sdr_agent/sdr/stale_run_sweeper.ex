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

  Recovery, per run, in one transaction, as the agent runtime through
  existing actions only. The run, its Operation, its Oban job row and all
  its `sent` invocations are locked `FOR UPDATE` before the first append
  (ADR-0009), and the run's staleness and the job's liveness are decided
  again under those locks (the first, unlocked observation is only a
  prefilter; a job made live meanwhile is left alone, review #25). A lookup
  error is never read as a missing job: the run is skipped.

    1. every `sent` ModelInvocation of the run → `unknown` (never re-sent;
       it still counts against the budgets), and every `reserved` one →
       `failed` with `sent_at` nil (C9-03: never launched — a launch is
       sent before any process starts and needs this run lock and a
       running run — so never unknown; its charged attempt is kept and no
       use is settled); both are locked in one statement, in sequence
       order;
    2. the run → `failed` with `status_reason: :crash` and a redacted
       `failure_reason` naming the job state; this opens the run's
       attention Failure (operator retry: `SDR.retry_run/2`, S13b);
    3. a `running` Operation → `failed` linking that Failure (discarded at
       its one attempt).

  Idempotent: a recovered run is `failed`, so a later sweep skips it.
  Integration-queue reply runs have no Operation (S9 choice 12); their job is
  found by its `run_id` argument.

  **Reservations of terminal runs (C9-03, case (b); R0 readiness packet,
  entity PASS 2026-10-12).** Then, per terminal run (`succeeded`, `failed`,
  `budget_exhausted`, `cancelled`) that has a `reserved` ModelInvocation
  reserved strictly before the stale cutoff (`reserved_at < now −
  stale_after_seconds/0`, a grace period for a live caller to settle it
  itself), one transaction: the run `FOR UPDATE` (its terminal status
  re-read), then those invocations `FOR UPDATE` in sequence order (status
  and age re-read), each → `failed` with `sent_at` nil. The locked terminal
  run plus the locked `reserved` state is the proof that it never launched
  and never will (launch admission refuses a non-running run). The run, its
  cause and its Operation are not written; no Failure is opened; the
  attempt stays charged. Selection is by the `reserved` state, so a later
  pass still finds a row that has since aged past the cutoff, and a failed
  row is never touched again. Queued and running runs are never in this
  case.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  import Ecto.Query, only: [from: 2]

  require Ash.Query

  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Clock
  alias SdrAgent.Operations
  alias SdrAgent.Operations.Operation
  alias SdrAgent.Repo

  @live_states ~w(available scheduled executing retryable)
  @terminal [:succeeded, :failed, :budget_exhausted, :cancelled]

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

    with {:ok, runs} <- Agents.list_runs(actor: actor),
         :ok <-
           runs
           |> Enum.filter(
             &(&1.status == :running and stale?(&1, cutoff) and maybe_abandoned?(&1, actor))
           )
           |> each_ok(&recovered(recover(&1, cutoff, actor))),
         {:ok, run_ids} <- old_reservation_runs(cutoff, actor) do
      each_ok(run_ids, &recovered(recover_stopped(&1, cutoff, actor)))
    end
  end

  # Skips: the run stopped, became fresh, or its job is live under the lock
  # (case (b): the run is not terminal under its lock).
  defp recovered({:error, skip}) when skip in [:not_running, :job_live, :not_terminal], do: :ok
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

  # Unlocked prefilter only (saves a transaction per live run); recovery
  # decides again under its locks. A lookup error is not a missing job: the
  # run is skipped.
  defp maybe_abandoned?(run, actor) do
    case job_state(run, actor, nil) do
      {:ok, state} -> state not in @live_states
      {:error, _} -> false
    end
  end

  # Assignment runs: the job of their Operation (`oban_job_id`). Reply runs
  # (no Operation): the ReplyWorker jobs naming the run. `{:ok, "missing"}`
  # only when the bound job row is gone; with `lock`, the rows are locked.
  defp job_state(%{operation_id: operation_id}, actor, lock) when is_binary(operation_id) do
    case Operations.get_operation(operation_id, actor: actor) do
      {:ok, %{oban_job_id: job_id}} when is_integer(job_id) ->
        from(j in Oban.Job, where: j.id == ^job_id, select: j.state)
        |> locking(lock)
        |> Repo.all()
        |> states()

      {:ok, _unbound} ->
        {:error, :job_unbound}

      error ->
        error
    end
  end

  defp job_state(%{id: run_id}, _actor, lock) do
    from(j in Oban.Job,
      where:
        j.worker == "SdrAgent.SDR.ReplyWorker" and
          fragment("?->>'run_id' = ?", j.args, ^run_id),
      order_by: [asc: j.id],
      select: j.state
    )
    |> locking(lock)
    |> Repo.all()
    |> states()
  end

  defp locking(query, nil), do: query
  defp locking(query, :for_update), do: from(j in query, lock: "FOR UPDATE")

  defp states([]), do: {:ok, "missing"}

  defp states(states),
    do: {:ok, Enum.find(states, List.last(states), &(&1 in @live_states))}

  # One transaction; every row it writes is locked before the first append
  # (ADR-0009): run → Operation → job → all `sent` and `reserved`
  # invocations. Staleness
  # and job liveness are decided again under those locks; Oban's own job
  # transitions (lifeline, staging, `retry_job`) wait on the job row lock.
  defp recover(run, cutoff, actor) do
    Audit.transaction(fn ->
      with {:ok, run} <- lock(AgentRun, run.id, actor),
           :ok <- abandoned(run, cutoff),
           {:ok, operation} <- lock_operation(run, actor),
           {:ok, state} <- job_state(run, actor, :for_update),
           :ok <- not_live(state),
           {:ok, invocations} <- lock_unsettled_invocations(run, actor),
           :ok <- each_ok(invocations, &recover_invocation(&1, "run_abandoned", actor)),
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

  defp abandoned(%{status: :running} = run, cutoff),
    do: if(stale?(run, cutoff), do: :ok, else: {:error, :not_running})

  defp abandoned(_run, _cutoff), do: {:error, :not_running}

  defp not_live(state) when state in @live_states, do: {:error, :job_live}
  defp not_live(_state), do: :ok

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

  # The run's `sent` and `reserved` invocations, in one statement, in
  # sequence order.
  defp lock_unsettled_invocations(run, actor) do
    ModelInvocation
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(agent_run_id == ^run.id and status in [:sent, :reserved])
    |> Ash.Query.sort(sequence_in_run: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ash.read()
  end

  defp recover_invocation(%{status: :sent} = invocation, _reason, actor) do
    case Agents.mark_model_invocation_unknown(invocation, actor: actor) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # Never launched (C9-03): failed, never unknown; nothing is settled.
  defp recover_invocation(%{status: :reserved} = invocation, reason, actor) do
    attrs = %{error: %{"kind" => "abandoned_before_launch", "reason" => reason}}

    case Agents.fail_model_invocation(invocation, attrs, actor: actor) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # Case (b) prefilter (unlocked): runs with a reservation older than the
  # cutoff; recovery decides again under its locks.
  defp old_reservation_runs(cutoff, actor) do
    ModelInvocation
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(
      tenant_id == ^actor.tenant_id and status == :reserved and reserved_at < ^cutoff
    )
    |> Ash.Query.select([:agent_run_id])
    |> Ash.read()
    |> case do
      {:ok, rows} -> {:ok, rows |> Enum.map(& &1.agent_run_id) |> Enum.uniq() |> Enum.sort()}
      error -> error
    end
  end

  # Case (b): run → its old reserved invocations → appends (ADR-0009).
  defp recover_stopped(run_id, cutoff, actor) do
    Audit.transaction(fn ->
      with {:ok, run} <- lock(AgentRun, run_id, actor),
           :ok <- terminal(run),
           {:ok, invocations} <- lock_old_reservations(run, cutoff, actor),
           :ok <- each_ok(invocations, &recover_invocation(&1, "run_stopped", actor)) do
        length(invocations)
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  defp terminal(%{status: status}) when status in @terminal, do: :ok
  defp terminal(_run), do: {:error, :not_terminal}

  defp lock_old_reservations(run, cutoff, actor) do
    ModelInvocation
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(agent_run_id == ^run.id and status == :reserved and reserved_at < ^cutoff)
    |> Ash.Query.sort(sequence_in_run: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ash.read()
  end

  defp fail_operation(%{status: :running} = operation, failed, actor),
    do:
      Operations.fail_operation(operation, %{failure_id: failed.attention_failure_id},
        actor: actor
      )

  defp fail_operation(_operation, _failed, _actor), do: {:ok, :no_running_operation}
end
