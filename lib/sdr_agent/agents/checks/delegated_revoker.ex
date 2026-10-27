defmodule SdrAgent.Agents.Checks.DelegatedRevoker do
  @moduledoc """
  Policy check for `ModelCallGrant :revoke` (C2* S2; plan §2 AC5): the
  actor is the grant provisioner (PRV) of a configured agent environment,
  revoking a grant of its own tenant whose subject record is delegated.
  This pre-lock check reads the caller's record; after the row lock
  `SdrAgent.Agents.Changes.RevokeProvenance` refuses PRV again unless the
  locked row itself is delegated and of the actor's tenant, so a forged
  struct (provenance or tenant) gains nothing.
  """
  use Ash.Policy.SimpleCheck

  alias SdrAgent.Actor
  alias SdrAgent.AgentEnv

  @impl true
  def describe(_opts), do: "actor is the grant provisioner revoking a delegated grant"

  @impl true
  def match?(
        %Actor{type: :grant_provisioner, tenant_id: tenant_id},
        %{subject: %{data: %{provisioning: :delegated, tenant_id: tenant_id}}},
        _opts
      )
      when is_binary(tenant_id),
      do: AgentEnv.configured?()

  def match?(_actor, _context, _opts), do: false
end
