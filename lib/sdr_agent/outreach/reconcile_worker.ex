defmodule SdrAgent.Outreach.ReconcileWorker do
  @moduledoc """
  Oban worker (queue `reconciliation`) that reconciles one `unknown`
  delivery as the reconciler (REC): `SdrAgent.Outreach.Delivery.reconcile/2`.
  Inserted when a delivery's outcome becomes unknown. Idempotent: anything
  but an unknown delivery is left alone.
  """
  use Oban.Worker, queue: :reconciliation, max_attempts: 3

  alias SdrAgent.Outreach.Delivery

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_operation_id" => id, "tenant_id" => tenant_id}}),
    do: Delivery.reconcile(id, tenant_id)
end
