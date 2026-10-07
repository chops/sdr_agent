defmodule SdrAgent.Agents.Witness.ScanWorker do
  @moduledoc """
  Bounded maintenance scan (cron, every five minutes) scheduling
  wire-witness reconciliation as REC — only when a witness store is
  configured (`SdrAgent.Agents.Witness.store_root/0`); otherwise it does
  nothing. Nothing here calls a model.

  It considers the terminal `:claude_cli` invocations updated in the last
  24 hours (`SdrAgent.Clock`; at most 500 rows, which the ADR-0004 daily
  model-call cap of 200 keeps above the real window), oldest first, decides
  eligibility for all of them, and then enqueues at most 50 per pass, so
  invocations that are settled or not yet eligible never starve later ones:

    * no `reconcile_model` Operation yet → generation 1;
    * re-drive (recovery of a witness that was missing, open or otherwise
      incomplete) → generation n + 1 only while the invocation has a live
      warning, its latest Operation is terminal and finished at least ten
      minutes ago, and fewer than `Witness.max_generations/0` exist.

  It also settles interrupted work truthfully, as the kind's own actor: a
  latest Operation still `running` ten minutes after its last update (its
  sixty-second job was killed) is failed with an `attempt_interrupted`
  Failure (and discarded at its attempt limit); one still `failed` ten
  minutes after its last update has no live job left and is cancelled. Both
  then become eligible for re-drive.
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

  defp next_generation(invocation, operations, now) do
    latest = List.last(operations)

    if length(operations) < Witness.max_generations() and redrivable?(latest, now) and
         Witness.live_warning?(invocation),
       do: [{invocation, length(operations) + 1}],
       else: []
  end

  # Interrupted work of the latest Operation, settled by its kind's actor.
  defp settle([], _now, _actor), do: []

  defp settle(operations, now, actor) do
    latest = List.last(operations)

    settled =
      cond do
        latest.status == :running and stale?(latest, now) ->
          {:ok, failed} =
            Operations.fail_operation(latest, interrupted(latest), actor: actor)

          failed

        latest.status == :failed and stale?(latest, now) ->
          {:ok, cancelled} = Operations.cancel_operation(latest, actor: actor)
          cancelled

        true ->
          latest
      end

    List.replace_at(operations, -1, settled)
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
