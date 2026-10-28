defmodule SdrAgent.Prototype.Changes.ConsumeProvisionScope do
  @moduledoc """
  On `SdrAgent.Agents.ModelCallAllocation :create` (Codex e006f70a D1):
  when the changeset carries a D-237 provisioning scope
  (`:sdr_prototype_provision_scope`), a `before_action`, which runs after
  authorization and before the insert and its audit event, re-verifies and
  consumes it exactly once (`SdrAgent.Prototype.ProvisionScope.consume/3`).
  A refusal there is `Ash.Error.Forbidden`. Without a scope (every admin
  bundle write) it does nothing. In a build without the prototype authority
  it does nothing.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    case Map.get(changeset.context, :sdr_prototype_provision_scope) do
      nil -> changeset
      scope -> Ash.Changeset.before_action(changeset, &consume(&1, scope, context.actor))
    end
  end

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    defp consume(changeset, scope, actor) do
      case SdrAgent.Prototype.ProvisionScope.consume(scope, changeset, actor) do
        :ok -> changeset
        :refused -> Ash.Changeset.add_error(changeset, Ash.Error.Forbidden.exception([]))
      end
    end
  else
    defp consume(changeset, _scope, _actor),
      do: Ash.Changeset.add_error(changeset, Ash.Error.Forbidden.exception([]))
  end
end
