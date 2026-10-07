defmodule SdrAgent.Operations.Changes.OpenRejection do
  @moduledoc """
  WebhookEvent `:reject`: opens the `signature_invalid` Failure (operator
  attention, warning) whose subject is the rejected event, in the same
  transaction, and stores its id on the row (S2: "WebhookEvent → failed"
  needs a human; checklist 4.3: invalid signatures are rejected visibly).
  The event id is fixed before the insert so the Failure can name it.
  """
  use Ash.Resource.Change

  alias SdrAgent.Operations.Attention

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      changeset = ensure_id(changeset)

      attrs = %{
        subject_resource: inspect(changeset.resource),
        subject_id: Ash.Changeset.get_attribute(changeset, :id),
        class: :signature_invalid,
        severity: :warning,
        message:
          "webhook rejected: signature #{Ash.Changeset.get_attribute(changeset, :signature_verdict)}",
        retryable: false
      }

      case Attention.open(attrs, context.actor) do
        {:ok, failure} -> Ash.Changeset.force_change_attribute(changeset, :failure_id, failure.id)
        {:error, error} -> Ash.Changeset.add_error(changeset, error)
      end
    end)
  end

  defp ensure_id(changeset) do
    case Ash.Changeset.get_attribute(changeset, :id) do
      nil -> Ash.Changeset.force_change_attribute(changeset, :id, Ash.UUIDv7.generate())
      _id -> changeset
    end
  end
end
