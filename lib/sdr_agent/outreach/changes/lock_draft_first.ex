defmodule SdrAgent.Outreach.Changes.LockDraftFirst do
  @moduledoc """
  Approval `:revoke`: locks the approval's draft `FOR UPDATE` in a
  `before_action` hook declared before `get_and_lock_for_update`, so the
  revoke takes its row locks in the Outreach lock order — draft → approval
  → chain head (the order of the Suppression side effects and of the
  grant) — and never waits for a row lock while holding the chain head.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Outreach.Draft

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      draft_id = changeset.data.draft_id

      # Internal lock of the row the revoke will move; nothing is returned.
      _draft =
        Draft
        |> Ash.Query.filter(id == ^draft_id)
        |> Ash.Query.lock(:for_update)
        |> Ash.read_one!(authorize?: false)

      changeset
    end)
  end
end
