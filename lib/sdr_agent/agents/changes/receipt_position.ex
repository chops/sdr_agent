defmodule SdrAgent.Agents.Changes.ReceiptPosition do
  @moduledoc """
  `SdrAgent.Agents.RemoteCallReceipt :append` (S-B2; as
  `SdrAgent.Prototype.Changes.RelocationAppend`): a `before_action` hook,
  after authorization and inside the action's transaction, whose caller
  (`SdrAgent.Agents.RemoteCalls.complete/5`) already holds the call's row
  lock. It takes the tenant's chain-head lock
  (`SdrAgent.Audit.Kernel.lock_head/1`), counts the call's recorded
  receipts (a read in the same RemoteCalls scope) and force-sets `position`
  to that count plus one, then `recorded_at` to the clock read after the
  locks. A rolled-back append consumes no position. A failed lock or read
  is added to the changeset as itself.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Agents.RemoteCallReceipt
  alias SdrAgent.Agents.RemoteCalls
  alias SdrAgent.Audit.Kernel, as: AuditKernel

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, &assign(&1, context.actor))
  end

  defp assign(changeset, actor) do
    tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)
    call_id = Ash.Changeset.get_attribute(changeset, :call_id)

    with {:ok, _head} <- AuditKernel.lock_head(tenant_id),
         {:ok, count} <- count(call_id, tenant_id, actor, changeset.context) do
      changeset
      |> Ash.Changeset.force_change_attribute(:position, count + 1)
      |> Ash.Changeset.force_change_attribute(:recorded_at, SdrAgent.Clock.utc_now())
    else
      {:error, %{} = error} ->
        Ash.Changeset.add_error(changeset, error)

      {:error, reason} ->
        Ash.Changeset.add_error(changeset, field: :call_id, message: inspect(reason))
    end
  end

  defp count(call_id, tenant_id, actor, context) do
    RemoteCallReceipt
    |> Ash.Query.for_read(:read, %{}, actor: actor, context: RemoteCalls.scope_of(context))
    |> Ash.Query.filter(call_id == ^call_id and tenant_id == ^tenant_id)
    |> Ash.count()
  end
end
