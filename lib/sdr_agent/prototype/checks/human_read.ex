defmodule SdrAgent.Prototype.Checks.HumanRead do
  @moduledoc """
  Independent strict metadata restriction for human actors. In prototype
  runtime a User must resolve freshly as a current hosted owner or a
  persisted legacy nonowner. Ordinary runtime is unchanged. This check
  does not itself grant access or change system/delegation read policy.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the human retains fresh persisted metadata authority"

  @impl true
  def match?(actor, _authorizer, _opts),
    do: SdrAgent.Operations.HostedOwners.human_read?(actor)
end
