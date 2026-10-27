defmodule SdrAgent.Agents.Checks.ProvisioningAttested do
  @moduledoc """
  Policy check for `ModelCallGrant :provision_delegated` (C2* S2; plan
  `claude-c2star-s2-provisioning-plan-r1.md` §5): the actor is the grant
  provisioner (PRV) of a configured agent environment, and the calling
  process holds an active provisioning attestation
  (`SdrAgent.AgentEnv.Provisioning`) that verifies, whose level is
  `:provisioning` or `:spend_ready`, that names the action's
  `authorization_id`, and whose attested tenant is the actor's. Any other
  actor, a level-`:none` or ended registration, another id or another
  tenant is refused.
  """
  use Ash.Policy.SimpleCheck

  alias SdrAgent.Actor
  alias SdrAgent.AgentEnv
  alias SdrAgent.AgentEnv.Provisioning

  @impl true
  def describe(_opts),
    do: "actor is the grant provisioner attested for this authorization and tenant"

  @impl true
  def match?(%Actor{type: :grant_provisioner, tenant_id: tenant_id}, %{subject: subject}, _opts)
      when is_binary(tenant_id) do
    with true <- AgentEnv.configured?(),
         {:ok, registration} <- Provisioning.current(),
         {:ok, ^registration} <- Provisioning.verify(registration),
         true <- registration.level in [:provisioning, :spend_ready],
         true <- registration.tenant_id == tenant_id do
      registration.authorization_id == Ash.Changeset.get_argument(subject, :authorization_id)
    else
      _other -> false
    end
  end

  def match?(_actor, _context, _opts), do: false
end
