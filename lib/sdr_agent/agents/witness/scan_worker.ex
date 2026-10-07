defmodule SdrAgent.Agents.Witness.ScanWorker do
  @moduledoc """
  Bounded maintenance scan (cron) scheduling wire-witness reconciliation
  as REC — only when a witness store is configured
  (`SdrAgent.Agents.Witness.store_root/0`); otherwise it does nothing.

  For at most #{50} terminal `:claude_cli` invocations updated in the last
  24 hours (`SdrAgent.Clock`), oldest first:

    * none reconciled yet → enqueue generation 1;
    * re-drive (recovery of a witness that was missing, open or otherwise
      incomplete): enqueue generation n + 1 only while the invocation has a
      live warning attention condition, its latest `reconcile_model`
      Operation is terminal and finished at least ten minutes ago, and
      fewer than four generations exist.

  Enqueueing is idempotent per generation; nothing here calls a model.
  """
  use Oban.Worker, queue: :reconciliation, max_attempts: 1

  require Ash.Query

  alias SdrAgent.Actor
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.Witness
  alias SdrAgent.Audit.GuardedCall
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Clock

  @batch 50
  @window_hours 24
  @redrive_after_minutes 10
  @max_generations 4

  @doc "Bounds: `%{batch:, window_hours:, redrive_after_minutes:, max_generations:}`."
  def bounds do
    %{
      batch: @batch,
      window_hours: @window_hours,
      redrive_after_minutes: @redrive_after_minutes,
      max_generations: @max_generations
    }
  end

  @impl Oban.Worker
  def perform(_job) do
    with root when is_binary(root) <- Witness.store_root(),
         {:ok, tenant_id} <- Kernel.singleton_tenant_id() do
      actor = Actor.system(:reconciler, tenant_id)
      now = Clock.utc_now()
      Enum.each(candidates(now, actor), &schedule(&1, now, actor))
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
    |> Ash.Query.limit(@batch)
    |> Ash.read!()
  end

  defp schedule(invocation, now, actor) do
    {:ok, operations} = Witness.operations(invocation.id, actor)

    case operations do
      [] ->
        {:ok, _} = Witness.enqueue(invocation.id, actor: actor, generation: 1)

      _ ->
        latest = List.last(operations)

        if length(operations) < @max_generations and redrivable?(latest, now) and
             Witness.live_warning?(invocation) do
          {:ok, _} =
            Witness.enqueue(invocation.id, actor: actor, generation: length(operations) + 1)
        end
    end
  end

  defp redrivable?(%{status: status, finished_at: %DateTime{} = finished}, now)
       when status in [:succeeded, :discarded],
       do: DateTime.diff(now, finished, :minute) >= @redrive_after_minutes

  defp redrivable?(_operation, _now), do: false
end
