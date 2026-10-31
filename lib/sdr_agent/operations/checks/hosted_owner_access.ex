defmodule SdrAgent.Operations.Checks.HostedOwnerAccess do
  @moduledoc """
  Revalidates a hosted reviewer's persisted status, tenant and current live
  activation. User identity/role or a previously connected socket alone is
  not authority. Used with row/tenant filters where a resource owns rows.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the currently active hosted owner of the live activation"

  @impl true
  def match?(actor, _authorizer, _opts),
    do: SdrAgent.Operations.HostedOwners.active?(actor)
end
