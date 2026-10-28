defmodule SdrAgent.Prototype.Checks.PrototypeGrantRevoke do
  @moduledoc """
  Policy check for `SdrAgent.Agents.ModelCallGrant :revoke` (D-237 D3;
  closure note r2): the resolved prototype operator
  (`SdrAgent.Prototype.Checks.OperatorAction`, `:revoke_grant`) revoking
  THIS binding's grant, identified by its original provisioned event
  (`SdrAgent.Prototype.Provisioning.lookup/1`), whatever its current name.
  A foreign or ordinary grant, or a grant of untrusted provenance, is not
  matched even for a valid operator. In a build without the prototype
  authority (the production build) it never matches.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the prototype operator revoking this binding's own grant"

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    alias SdrAgent.Agents.ModelCallGrant
    alias SdrAgent.Prototype.Checks.OperatorAction
    alias SdrAgent.Prototype.Provisioning

    @impl true
    def match?(
          actor,
          %{subject: %Ash.Changeset{data: %ModelCallGrant{id: id}}} = authorizer,
          _opts
        ) do
      OperatorAction.match?(actor, authorizer, action: :revoke_grant) and this_binding_grant?(id)
    end

    def match?(_actor, _authorizer, _opts), do: false

    defp this_binding_grant?(id) do
      with {:ok, snapshot} <- SdrAgent.Prototype.binding(),
           {:one, ^id, _event} <- Provisioning.lookup(snapshot) do
        true
      else
        _other -> false
      end
    end
  else
    @impl true
    def match?(_actor, _authorizer, _opts), do: false
  end
end
