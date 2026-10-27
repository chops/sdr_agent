defmodule SdrAgent.Agents.Changes.RevokeProvenance do
  @moduledoc """
  Provenance of `ModelCallGrant :revoke` (C2* S2; plan §2 AC5; Codex Q6),
  in a `before_action` hook after the preceding `get_and_lock_for_update`,
  so it reads the freshly locked row:

    * an `SdrAgent.Accounts.User` actor (the policy admits only a current
      admin) becomes the updater, as before;
    * the grant provisioner (PRV) may revoke only a row that is itself
      delegated AND belongs to the PRV's own (non-nil) tenant, and leaves
      `updated_by_id` NULL. The pre-lock policy
      (`SdrAgent.Agents.Checks.DelegatedRevoker`) reads the caller's struct,
      so a forged delegated struct of an owner-form row, or a struct whose
      `tenant_id` is forged to the actor's (Codex M1), passes it; either is
      refused here with `Ash.Error.Forbidden` on the actual locked row;
    * any other actor writes no provenance (the policy has refused it).
  """
  use Ash.Resource.Change

  alias Ash.Error.Forbidden
  alias SdrAgent.Accounts.User
  alias SdrAgent.Actor

  @impl true
  def change(changeset, _opts, %{actor: actor}) do
    Ash.Changeset.before_action(changeset, &provenance(&1, actor))
  end

  defp provenance(changeset, %User{id: id}) when is_binary(id),
    do: Ash.Changeset.force_change_attribute(changeset, :updated_by_id, id)

  defp provenance(changeset, %Actor{type: :grant_provisioner, tenant_id: tenant_id}) do
    if is_binary(tenant_id) and changeset.data.provisioning == :delegated and
         changeset.data.tenant_id == tenant_id,
       do: changeset,
       else: Ash.Changeset.add_error(changeset, Forbidden.exception([]))
  end

  defp provenance(changeset, _actor), do: changeset
end
