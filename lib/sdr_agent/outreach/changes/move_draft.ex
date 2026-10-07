defmodule SdrAgent.Outreach.Changes.MoveDraft do
  @moduledoc """
  Approval `after_action`: moves the approval's draft through Draft
  `:action` (`:queue` on a grant, `:reject` on a rejection, `:unqueue` on a
  revoke) in the same transaction, as the same actor, with the private
  `SdrAgent.Outreach.Checks.InternalWrite` marker. With `reason: field`, the
  approval's `field` becomes the draft's `status_reason`. If the draft
  cannot move, the approval rolls back.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Outreach.Checks.InternalWrite
  alias SdrAgent.Outreach.Draft

  @impl true
  def change(changeset, opts, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, approval ->
      attrs = if field = opts[:reason], do: %{status_reason: Map.get(approval, field)}, else: %{}

      Draft
      |> Ash.Query.filter(id == ^approval.draft_id)
      |> Ash.read_one!(authorize?: false)
      |> Ash.Changeset.for_update(opts[:action], attrs,
        actor: context.actor,
        context: InternalWrite.context()
      )
      |> Ash.update(return_notifications?: true)
      |> case do
        {:ok, _draft, _notifications} -> {:ok, approval}
        {:error, error} -> {:error, error}
      end
    end)
  end
end
