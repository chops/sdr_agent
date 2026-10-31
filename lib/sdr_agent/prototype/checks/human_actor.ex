defmodule SdrAgent.Prototype.Checks.HumanActor do
  @moduledoc """
  Conditions the independent human read restriction on actual User actors.
  System/delegation metadata semantics are not changed by a human guard.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the actor is an Accounts.User"

  @impl true
  def match?(%SdrAgent.Accounts.User{}, _authorizer, _opts), do: true
  def match?(_actor, _authorizer, _opts), do: false
end
