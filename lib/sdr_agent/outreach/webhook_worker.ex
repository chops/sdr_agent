defmodule SdrAgent.Outreach.WebhookWorker do
  @moduledoc """
  Oban worker (queue `integration`, spec §13) that processes one verified
  WebhookEvent (`SdrAgent.Outreach.Webhooks.process/2`). The job is inserted
  in the transaction that records the event (outbox), only for a new valid
  event, and carries the received bytes (`raw_body`, base64), which the
  processor checks against the event's hash — it never reads Payload
  content. Processing is idempotent by the event's state under its row
  lock; a transient failure rolls back and is retried (bounded); the last
  attempt records it as a `crash` Failure on the event.
  """
  use Oban.Worker, queue: :integration, max_attempts: 3

  alias SdrAgent.Outreach.Webhooks

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"webhook_event_id" => id, "tenant_id" => tenant_id} = args} = job) do
    raw_body =
      case Base.decode64(Map.get(args, "raw_body", "")) do
        {:ok, raw} -> raw
        :error -> nil
      end

    Webhooks.process(id, tenant_id, raw_body, final?: job.attempt >= job.max_attempts)
  end
end
