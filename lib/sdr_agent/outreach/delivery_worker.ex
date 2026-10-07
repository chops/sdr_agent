defmodule SdrAgent.Outreach.DeliveryWorker do
  @moduledoc """
  Oban worker (queue `delivery`, bounded concurrency in config) that runs one
  delivery attempt (`SdrAgent.Outreach.Delivery.attempt/2`) as the delivery
  worker (DLV). Inserted by the approval grant (outbox), by a deferral at
  `not_before`, and by a scheduled retry. Running it twice is harmless: the
  claim only moves a pending or retryable delivery, under a row lock. Run
  early (before `not_before`) it snoozes. A crash after the hand-off leaves
  the delivery `attempting` for the sweeper — never a blind resend.
  """
  use Oban.Worker, queue: :delivery, max_attempts: 3

  alias SdrAgent.Outreach.Delivery

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_operation_id" => id, "tenant_id" => tenant_id}}),
    do: Delivery.attempt(id, tenant_id)
end
