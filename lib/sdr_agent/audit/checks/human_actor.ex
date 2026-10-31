defmodule SdrAgent.Audit.Checks.HumanActor do
  @moduledoc """
  Pure User-type condition for the independent human metadata restriction.
  It grants no authority and does not change system/delegation semantics.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the actor is an Accounts.User"

  @impl true
  def match?(%SdrAgent.Accounts.User{}, _authorizer, _opts), do: true
  def match?(_actor, _authorizer, _opts), do: false
end
