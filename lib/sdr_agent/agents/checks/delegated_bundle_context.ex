defmodule SdrAgent.Agents.Checks.DelegatedBundleContext do
  @moduledoc """
  Policy check for `ModelCallAllocation :create` (C2* S2; plan §2 AC4 and
  scope correction Q7): the narrow alternative that satisfies both
  allocation write policies for a delegated grant. It holds only when all
  of these hold:

    * the actor is the grant provisioner (PRV) and the action is a create;
    * the changeset carries a delegated-bundle context
      (`SdrAgent.Agents.Changes.GrantBundle.Delegated.context/1`) that
      verifies against the active registration in this process and
      transaction (`Delegated.verify/1`);
    * the allocation's `grant_id` and `tenant_id`, and the actor's tenant,
      are the context's;
    * the actual parent grant, read by that id in that tenant, is delegated
      with the context's authorization id and digest.

  It never authorizes an update, a release or a destroy, nor an owner-form
  parent, nor a parent that cannot be read.
  """
  use Ash.Policy.SimpleCheck

  alias SdrAgent.Actor
  alias SdrAgent.Agents.Changes.GrantBundle.Delegated
  alias SdrAgent.Agents.Checks.DelegatedGrant
  alias SdrAgent.Agents.ModelCallGrant

  @impl true
  def describe(_opts), do: "allocation created by the grant provisioner's delegated bundle"

  @impl true
  def match?(
        %Actor{type: :grant_provisioner, tenant_id: tenant_id},
        %{subject: %Ash.Changeset{action_type: :create} = changeset},
        _opts
      )
      when is_binary(tenant_id) do
    with {:ok, context} <- Delegated.verify(Delegated.carried(changeset.context)),
         true <- context.tenant_id == tenant_id,
         true <- Ash.Changeset.get_attribute(changeset, :tenant_id) == context.tenant_id,
         true <- Ash.Changeset.get_attribute(changeset, :grant_id) == context.grant_id,
         {:ok, %ModelCallGrant{provisioning: :delegated} = parent} <-
           DelegatedGrant.parent(changeset) do
      parent.delegated_authorization_id == context.authorization_id and
        parent.delegated_authorization_sha256 == context.authorization_sha256
    else
      _other -> false
    end
  end

  def match?(_actor, _context, _opts), do: false
end
