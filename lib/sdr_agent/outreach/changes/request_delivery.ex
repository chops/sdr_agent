defmodule SdrAgent.Outreach.Changes.RequestDelivery do
  @moduledoc """
  Approval `:approve`, `after_action` (S2: "A granted approval inserts its
  DeliveryOperation and Oban delivery job in the same transaction
  (outbox)"): inserts the pending DeliveryOperation — idempotency key
  `"delivery:" <> approval_id`, the binding copied from the approval, the
  draft's enrollment — and its `delivery` queue job, as the approver, with
  the private `SdrAgent.Outreach.Checks.InternalWrite` marker. If either
  cannot be written the grant rolls back.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Outreach.Checks.InternalWrite
  alias SdrAgent.Outreach.DeliveryOperation
  alias SdrAgent.Outreach.DeliveryWorker
  alias SdrAgent.Outreach.Draft

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, approval ->
      draft =
        Draft |> Ash.Query.filter(id == ^approval.draft_id) |> Ash.read_one!(authorize?: false)

      attrs = %{
        approval_id: approval.id,
        draft_id: approval.draft_id,
        draft_revision_id: approval.draft_revision_id,
        enrollment_id: draft.enrollment_id,
        campaign_id: approval.campaign_id,
        recipient_contact_id: approval.recipient_contact_id,
        revision_content_sha256: approval.revision_content_sha256,
        recipient_email: approval.recipient_email,
        idempotency_key: "delivery:#{approval.id}"
      }

      with {:ok, op} <- request(attrs, context.actor),
           {:ok, _job} <-
             Oban.insert(
               DeliveryWorker.new(%{
                 "delivery_operation_id" => op.id,
                 "tenant_id" => op.tenant_id
               })
             ) do
        {:ok, approval}
      end
    end)
  end

  defp request(attrs, actor) do
    DeliveryOperation
    |> Ash.Changeset.for_create(:request, attrs, actor: actor, context: InternalWrite.context())
    |> Ash.create()
  end
end
