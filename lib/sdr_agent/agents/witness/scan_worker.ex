defmodule SdrAgent.Agents.Witness.ScanWorker do
  @moduledoc """
  Bounded maintenance scan (cron, every five minutes) scheduling
  wire-witness reconciliation as REC — only when a witness store is
  configured (`SdrAgent.Agents.Witness.store_root/0`); otherwise it does
  nothing. Nothing here calls a model.

  It considers the terminal `:claude_cli` invocations updated in the last
  24 hours (`SdrAgent.Clock`; at most 500 rows, which the ADR-0004 daily
  model-call cap normally keeps above the real window — see below), oldest
  first, decides
  eligibility for all of them, and then enqueues at most 50 per pass, so
  invocations that are settled or not yet eligible never starve later ones:

    * no `reconcile_model` Operation yet → generation 1;
    * re-drive (recovery of a witness that was missing, open or otherwise
      incomplete) → generation n + 1 only while the invocation has a live
      warning, its latest Operation is terminal and finished at least ten
      minutes ago, and fewer than `Witness.max_generations/0` exist.

  It also settles interrupted work truthfully, as the kind's own actor, only
  when the Operation's Oban job is confirmed dead (completed, discarded,
  cancelled or gone) and the Operation has not changed for ten minutes: a
  `running` one is failed with an `attempt_interrupted` Failure (discarded
  at its attempt limit) and a remaining `failed` one is cancelled. Live jobs
  (available, scheduled, retryable, executing) are never touched. A
  generation that ended discarded or cancelled is re-driven like a live
  warning, within the same bounds.

  The window is bounded by rows, not proven by the budget: terminal
  ModelInvocations are immutable, so `updated_at` is set once, at the
  terminal transition, and the ADR-0004 cap of 200 reservations per UTC day
  normally keeps a 24-hour window well below 500 rows. A crash-recovery
  backlog (many old `sent` calls marked `unknown` at once) could exceed it;
  rows beyond the first 500 then wait until earlier rows leave the window.
  """
  use Oban.Worker, queue: :reconciliation, max_attempts: 1

  require Ash.Query

  alias SdrAgent.Actor
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.Witness
  alias SdrAgent.Audit.GuardedCall
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Clock
  alias SdrAgent.Operations
  alias SdrAgent.Repo

  @batch 50
  @window_rows 500
  @window_hours 24
  @redrive_after_minutes 10
  @stale_after_minutes 10

  @doc "The scan's bounds."
  def bounds do
    %{
      batch: @batch,
      window_rows: @window_rows,
      window_hours: @window_hours,
      redrive_after_minutes: @redrive_after_minutes,
      stale_after_minutes: @stale_after_minutes,
      max_generations: Witness.max_generations()
    }
  end

  @impl Oban.Worker
  def perform(_job) do
    with root when is_binary(root) <- Witness.store_root(),
         {:ok, tenant_id} <- Kernel.singleton_tenant_id() do
      actor = Actor.system(:reconciler, tenant_id)
      now = Clock.utc_now()
      invocations = candidates(now, actor)
      operations = operations_by_invocation(invocations, actor)

      invocations
      |> Enum.map(&{&1, settle(Map.get(operations, &1.id, []), now, actor)})
      |> Enum.flat_map(fn {invocation, ops} -> next_generation(invocation, ops, now) end)
      |> Enum.take(@batch)
      |> Enum.each(fn {invocation, generation} ->
        {:ok, _} = Witness.enqueue(invocation.id, actor: actor, generation: generation)
      end)
    end

    :ok
  end

  defp candidates(now, actor) do
    since = DateTime.add(now, -@window_hours, :hour)

    ModelInvocation
    |> GuardedCall.read_query(actor: actor)
    |> Ash.Query.filter(
      provider == :claude_cli and status in [:completed, :failed, :unknown] and
        updated_at >= ^since
    )
    |> Ash.Query.sort(updated_at: :asc, id: :asc)
    |> Ash.Query.limit(@window_rows)
    |> Ash.read!()
  end

  defp operations_by_invocation([], _actor), do: %{}

  defp operations_by_invocation(invocations, actor) do
    ids = Enum.map(invocations, & &1.id)

    Operations.Operation
    |> GuardedCall.read_query(actor: actor)
    |> Ash.Query.filter(kind == :reconcile_model and subject_id in ^ids)
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.read!()
    |> Enum.group_by(& &1.subject_id)
  end

  defp next_generation(invocation, [], _now), do: [{invocation, 1}]

  # Re-drive after a bounded interval, at most `max_generations`: when the
  # latest generation ended without completing (discarded or cancelled —
  # exhausted or interrupted work), or completed while a warning remains.
  defp next_generation(invocation, operations, now) do
    latest = List.last(operations)

    if length(operations) < Witness.max_generations() and redrivable?(latest, now) and
         (latest.status in [:discarded, :cancelled] or Witness.live_warning?(invocation)),
       do: [{invocation, length(operations) + 1}],
       else: []
  end

  # Interrupted work of the latest Operation, settled by its kind's actor —
  # only when its Oban job is confirmed dead (completed, discarded, cancelled
  # or gone); available, scheduled, retryable and executing jobs are live
  # work and are left alone whatever their age.
  defp settle([], _now, _actor), do: []

  defp settle(operations, now, actor) do
    latest = List.last(operations)

    settled =
      if latest.status in [:running, :failed] and stale?(latest, now) and job_dead?(latest),
        do: abandon(latest, actor),
        else: latest

    List.replace_at(operations, -1, settled)
  end

  # running → failed (attempt_interrupted; discarded at its attempt limit),
  # then a failed Operation whose job is gone → cancelled.
  defp abandon(%{status: :running} = operation, actor) do
    {:ok, failed} = Operations.fail_operation(operation, interrupted(operation), actor: actor)
    abandon(failed, actor)
  end

  defp abandon(%{status: :failed} = operation, actor) do
    {:ok, cancelled} = Operations.cancel_operation(operation, actor: actor)
    cancelled
  end

  defp abandon(operation, _actor), do: operation

  # Oban's job row is framework-owned (not an Ash resource): read-only state check.
  defp job_dead?(%{oban_job_id: nil}), do: true

  defp job_dead?(%{oban_job_id: job_id}) do
    case Repo.get(Oban.Job, job_id) do
      nil -> true
      %Oban.Job{state: state} -> state in ["completed", "discarded", "cancelled"]
    end
  end

  defp interrupted(%{last_failure_id: id}) when is_binary(id), do: %{failure_id: id}

  defp interrupted(operation) do
    %{
      failure: %{
        class: :reconciliation_required,
        severity: :warning,
        message: "wire witness reconciliation attempt #{operation.attempts} was interrupted",
        retryable: true
      }
    }
  end

  defp stale?(%{updated_at: updated}, now),
    do: DateTime.diff(now, updated, :minute) >= @stale_after_minutes

  defp redrivable?(%{status: status, finished_at: %DateTime{} = finished}, now)
       when status in [:succeeded, :discarded, :cancelled],
       do: DateTime.diff(now, finished, :minute) >= @redrive_after_minutes

  defp redrivable?(_operation, _now), do: false
end
