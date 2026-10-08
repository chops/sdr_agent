defmodule SdrAgent.Operations.WebhookRetryLedger do
  @moduledoc """
  The bounded operator-retry ledger of a WebhookEvent (S13b, soft-stop v3
  B1–B4), read from the event's own AuditEvents: `webhook.retry_requested`
  (ordinal 1..3, the re-enqueued job) and `webhook.retry_failed` (the
  ordinal it consumed). Callers hold the event's row lock, so the reads are
  authoritative for the transaction.

  Also locks the event's exact original `WebhookWorker` job (matched by its
  `webhook_event_id` argument; the worker is named, not referenced, since
  Operations sits below Outreach).
  """

  import Ecto.Query, only: [from: 2]

  require Ash.Query

  alias SdrAgent.Audit.AuditEvent
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Repo

  @worker "SdrAgent.Outreach.WebhookWorker"
  @limit 3
  @live_states ~w(available scheduled executing retryable)

  @doc "Operator requests allowed per event."
  def limit, do: @limit

  @doc "Oban job states in which the original work is still live."
  def live_states, do: @live_states

  @doc "The event's retry ledger entries, newest first."
  def entries(event) do
    AuditEvent
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(event.tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^event.tenant_id and subject_id == ^event.id and
        event_type in ["webhook.retry_requested", "webhook.retry_failed"]
    )
    |> Ash.Query.sort(sequence: :desc)
    |> Ash.read!()
  end

  @doc "Requests made so far (the next request's ordinal is this plus one)."
  def requested(event),
    do: event |> entries() |> Enum.count(&(&1.event_type == "webhook.retry_requested"))

  @doc """
  The ordinal of the unconsumed request — the latest entry is a
  `webhook.retry_requested` — or nil.
  """
  def pending(event) do
    case entries(event) do
      [%{event_type: "webhook.retry_requested"} = latest | _] ->
        latest.payload["arguments"]["ordinal"]

      _ ->
        nil
    end
  end

  @doc """
  Locks the event's original job `FOR UPDATE`: `{:ok, job}`,
  `{:error, :retry_window_expired}` (pruned) or `{:error, :ambiguous_job}`.
  """
  def lock_original_job(event) do
    from(j in Oban.Job,
      where: j.worker == @worker and fragment("?->>'webhook_event_id' = ?", j.args, ^event.id),
      lock: "FOR UPDATE"
    )
    |> Repo.all()
    |> case do
      [job] -> {:ok, job}
      [] -> {:error, :retry_window_expired}
      _ -> {:error, :ambiguous_job}
    end
  end
end
