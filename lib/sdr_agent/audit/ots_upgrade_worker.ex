defmodule SdrAgent.Audit.OtsUpgradeWorker do
  @moduledoc """
  S11b public-proof maintenance. A ten-minute cron invocation enqueues at
  most 25 unresolved anchors (configurable up to 100). Child jobs are unique
  by anchor and pending receipt while available/scheduled/executing/retryable.

  Dispatch selects the newest pending receipt; each child upgrades that
  exact proof as the anchorer actor through Anchoring.
  Confirmation appends exactly one immutable receipt, replay is a no-op,
  incomplete proofs stay pending, and errors persist failed sink evidence
  and flow to Oban's bounded retries. No private signing key is needed.
  Disabled OTS cancels queued child work and makes dispatch a no-op.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:anchor_id, :pending_receipt_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  require Ash.Query

  alias SdrAgent.Actor
  alias SdrAgent.Audit.Anchoring
  alias SdrAgent.Audit.AnchorSinkReceipt
  alias SdrAgent.Audit.AuditAnchor
  alias SdrAgent.Audit.Kernel

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case ots_sink() do
      nil -> if(args["anchor_id"], do: {:cancel, :ots_sink_disabled}, else: :ok)
      {_name, sink, options} -> perform_enabled(args, sink, options)
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: min(60 * max(attempt, 1), 600)

  @impl Oban.Worker
  def timeout(_job), do: 60_000

  defp perform_enabled(args, sink, options) do
    with {:ok, tenant_id} <- Kernel.singleton_tenant_id() do
      actor = Actor.system(:anchorer, tenant_id)
      if args["anchor_id"], do: upgrade(args, actor, sink, options), else: dispatch(actor)
    end
  end

  defp dispatch(actor) do
    limit = Application.get_env(:sdr_agent, :ots_upgrade_batch_size, 25)

    if is_integer(limit) and limit in 1..100 do
      with {:ok, anchors} <- unresolved_anchors(actor, limit) do
        Enum.reduce_while(anchors, :ok, &enqueue(&1, &2, actor))
      end
    else
      {:error, :invalid_ots_upgrade_batch_size}
    end
  end

  defp unresolved_anchors(actor, limit) do
    AuditAnchor
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(
      tenant_id == ^actor.tenant_id and
        exists(sink_receipts, sink == :ots and status == :pending) and
        not exists(sink_receipts, sink == :ots and status == :confirmed)
    )
    |> Ash.Query.sort(anchor_number: :asc)
    |> Ash.Query.limit(limit)
    |> Ash.read()
  end

  defp enqueue(anchor, :ok, actor) do
    with {:ok, pending} <- latest_pending(anchor.id, actor),
         {:ok, _job} <-
           __MODULE__.new(%{anchor_id: anchor.id, pending_receipt_id: pending.id})
           |> Oban.insert() do
      {:cont, :ok}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp upgrade(args, actor, sink, options) do
    with {:ok, anchor} <- fetch_anchor(args["anchor_id"], actor),
         {:ok, pending} <- fetch_pending(args["pending_receipt_id"], anchor.id, actor) do
      case Anchoring.upgrade_ots(anchor,
             actor: actor,
             sink: sink,
             sink_options: options,
             pending_receipt_id: pending.id
           ) do
        {:ok, _receipt} -> :ok
        {:error, :ots_pending} -> :ok
        {:error, _} = error -> error
      end
    end
  end

  defp fetch_anchor(id, actor) do
    AuditAnchor
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(id == ^id and tenant_id == ^actor.tenant_id)
    |> Ash.read_one()
    |> require_row(:anchor_not_found)
  end

  defp latest_pending(anchor_id, actor) do
    AnchorSinkReceipt
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(anchor_id == ^anchor_id and sink == :ots and status == :pending)
    |> Ash.Query.sort(recorded_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one()
    |> require_row(:pending_ots_receipt_not_found)
  end

  defp fetch_pending(id, anchor_id, actor) do
    AnchorSinkReceipt
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(
      id == ^id and anchor_id == ^anchor_id and sink == :ots and status == :pending
    )
    |> Ash.read_one()
    |> require_row(:pending_ots_receipt_not_found)
  end

  defp require_row({:ok, nil}, error), do: {:error, error}
  defp require_row(result, _error), do: result

  defp ots_sink do
    :sdr_agent |> Application.get_env(:anchor_sinks, []) |> Enum.find(&(elem(&1, 0) == :ots))
  end
end
