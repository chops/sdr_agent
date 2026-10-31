defmodule SdrAgent.Audit.Checks.HostedOwnerAccess do
  @moduledoc """
  Lower-owned live-owner identity check. Resources independently constrain
  tenant rows. No owner persistence is queried or owned by this layer;
  the compile-time selected authority implementation resolves it freshly.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the currently active hosted owner of the live activation"

  @impl true
  def match?(actor, _authorizer, _opts), do: SdrAgent.Audit.HumanAuthority.hosted_owner?(actor)
end
