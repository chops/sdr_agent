defmodule SdrAgent.Outreach.Changes.MoveDraft do
  @moduledoc """
  `after_action` of an Approval or DeliveryOperation write: moves the
  record's draft (`draft_id`) through Draft `:action` (`:queue` on a grant,
  `:reject` on a rejection, `:unqueue` on a revoke, `:cancel` on a
  `cancel_retry`) in the same transaction, as the same actor, with the
  private `SdrAgent.Outreach.Checks.InternalWrite` marker. With
  `reason: field` the record's `field`, or with `reason_text:` a fixed text,
  becomes the draft's `status_reason`. If the draft cannot move, the write
  rolls back.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Outreach.Checks.InternalWrite
  alias SdrAgent.Outreach.Draft

  @impl true
  def change(changeset, opts, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      attrs =
        cond do
          field = opts[:reason] -> %{status_reason: Map.get(record, field)}
          text = opts[:reason_text] -> %{status_reason: text}
          true -> %{}
        end

      Draft
      |> Ash.Query.filter(id == ^record.draft_id)
      |> Ash.read_one!(authorize?: false)
      |> Ash.Changeset.for_update(opts[:action], attrs,
        actor: context.actor,
        context: InternalWrite.context()
      )
      |> Ash.update(return_notifications?: true)
      |> case do
        {:ok, _draft, _notifications} -> {:ok, record}
        {:error, error} -> {:error, error}
      end
    end)
  end
end
