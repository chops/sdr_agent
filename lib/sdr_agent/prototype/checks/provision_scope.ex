defmodule SdrAgent.Prototype.Checks.ProvisionScope do
  @moduledoc """
  Policy check for `SdrAgent.Agents.ModelCallAllocation :create` (Codex
  4281bb5c R1; design note r2): the D-237 operator's one planned allocation
  write, authorized only by the registered, transaction-bound
  `SdrAgent.Prototype.ProvisionScope` that `ModelCallGrant
  :provision_prototype` forwards in the changeset context under
  `:sdr_prototype_provision_scope`. The check is PURE
  (`ProvisionScope.valid?/3`): evaluating it any number of times consumes
  nothing; `SdrAgent.Prototype.Changes.ConsumeProvisionScope` consumes the
  scope once, in the action. A public Boolean, a copied, hand-built, stale,
  consumed or cross-process scope never matches. In a build without the
  prototype authority (the production build) it never matches.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the operator's registered provisioning scope for this exact write"

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    @impl true
    def match?(actor, %{subject: %Ash.Changeset{context: %{} = context} = changeset}, _opts) do
      SdrAgent.Prototype.ProvisionScope.valid?(
        Map.get(context, :sdr_prototype_provision_scope),
        changeset,
        actor
      )
    end

    def match?(_actor, _authorizer, _opts), do: false
  else
    @impl true
    def match?(_actor, _authorizer, _opts), do: false
  end
end
