defmodule SdrAgent.Audit.Changes.InitChainHead do
  @moduledoc """
  Creates a tenant's genesis `AuditChainHead` (sequence 0, 32 zero bytes)
  in the same transaction as the tenant, before the genesis event is
  appended.
  """
  use Ash.Resource.Change

  alias SdrAgent.Audit.AuditChainHead
  alias SdrAgent.Audit.Kernel

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, tenant ->
      AuditChainHead
      |> Ash.Changeset.for_create(
        :init,
        %{tenant_id: tenant.id, last_sequence: 0, last_event_hash: Kernel.zero_hash()},
        Kernel.opts(tenant.id)
      )
      |> Ash.create(return_notifications?: true)
      |> case do
        {:ok, _head, _ledger_notifications} -> {:ok, tenant}
        {:error, error} -> {:error, error}
      end
    end)
  end
end
