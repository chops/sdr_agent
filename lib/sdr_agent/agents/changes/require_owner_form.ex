defmodule SdrAgent.Agents.Changes.RequireOwnerForm do
  @moduledoc """
  Refuses a change to a delegated grant's terms or allocations (C2* S2;
  plan §2 AC5; Codex Q6). Runs in a `before_action` hook after the
  preceding `get_and_lock_for_update`, so it reads the freshly locked row,
  never the caller's struct: a forged owner-form struct of a delegated row
  is refused here although it passed the pre-lock policy
  (`SdrAgent.Agents.Checks.DelegatedGrant`). The refusal is
  `Ash.Error.Forbidden` (a guarded call audits it once), and nothing is
  written.
  """
  use Ash.Resource.Change

  alias Ash.Error.Forbidden

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      if changeset.data.provisioning == :owner_form,
        do: changeset,
        else: Ash.Changeset.add_error(changeset, Forbidden.exception([]))
    end)
  end
end
