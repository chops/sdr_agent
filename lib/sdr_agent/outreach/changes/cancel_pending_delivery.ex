defmodule SdrAgent.Outreach.Changes.CancelPendingDelivery do
  @moduledoc """
  Approval `:revoke` (S2: "granted → revoked (T) only while the delivery is
  still pending: the revoke transaction first cancels the delivery … and
  fails with a stale-state error if a worker already claimed it").

  `before_action` (declared after `LockDraftFirst`, before the approval's own
  lock): locks the approval's delivery `FOR UPDATE` — lock order draft →
  delivery → approval, as the delivery worker's claim — and refuses unless
  it is pending. `after_action`: cancels it (reason `approval_revoked`) with
  the private `SdrAgent.Outreach.Checks.InternalWrite` marker. A claim that
  wins the race consumes the approval first, so the revoke's own
  granted → revoked guard refuses as well.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Outreach.Checks.InternalWrite
  alias SdrAgent.Outreach.DeliveryOperation

  @impl true
  def change(changeset, _opts, context) do
    changeset
    |> Ash.Changeset.before_action(&lock_pending/1)
    |> Ash.Changeset.after_action(fn changeset, approval ->
      case changeset.context[:sdr_revoked_delivery] do
        nil -> {:ok, approval}
        op -> cancel(op, approval, context.actor)
      end
    end)
  end

  defp lock_pending(changeset) do
    approval_id = changeset.data.id

    DeliveryOperation
    |> Ash.Query.filter(approval_id == ^approval_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil ->
        changeset

      %{state: :pending} = op ->
        Ash.Changeset.put_context(changeset, :sdr_revoked_delivery, op)

      %{state: state} ->
        Ash.Changeset.add_error(changeset,
          field: :status,
          message: "the delivery is already #{state}: stop it with cancel_retry, not revoke"
        )
    end
  end

  defp cancel(op, approval, actor) do
    op
    |> Ash.Changeset.for_update(:cancel, %{last_error: %{"reason" => "approval_revoked"}},
      actor: actor,
      context: InternalWrite.context()
    )
    |> Ash.update()
    |> case do
      {:ok, _op} -> {:ok, approval}
      error -> error
    end
  end
end
