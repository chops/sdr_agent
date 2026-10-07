defmodule SdrAgent.Outreach.StaleDeliverySweeper do
  @moduledoc """
  Oban cron worker (queue `reconciliation`, every minute): hands deliveries
  left `attempting` longer than `SdrAgent.Outreach.Compliance.stale_after_seconds/0`
  (a crash between the hand-off and the recorded outcome) to reconciliation
  (`SdrAgent.Outreach.Delivery.sweep/1`) for the singleton tenant. Does
  nothing before the tenant is bootstrapped.
  """
  use Oban.Worker, queue: :reconciliation, max_attempts: 1

  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Outreach.Delivery

  @impl Oban.Worker
  def perform(_job) do
    case Kernel.singleton_tenant_id() do
      {:ok, tenant_id} -> Delivery.sweep(tenant_id)
      {:error, _not_bootstrapped} -> :ok
    end
  end
end
