defmodule SdrAgent.Outreach.WebhookWorker do
  @moduledoc """
  Oban worker (queue `integration`, spec §13) that processes one verified
  WebhookEvent (`SdrAgent.Outreach.Webhooks.process/2`). The job is inserted
  in the transaction that records the event (outbox), only for a new valid
  event. Processing is idempotent by the event's state under its row lock;
  a crash rolls the processing back and the job is retried (bounded).
  """
  use Oban.Worker, queue: :integration, max_attempts: 3

  alias SdrAgent.Outreach.Webhooks

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"webhook_event_id" => id, "tenant_id" => tenant_id}}),
    do: Webhooks.process(id, tenant_id)
end
