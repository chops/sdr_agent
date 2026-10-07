defmodule SdrAgent.Accounts.Checks.IsSelf do
  @moduledoc """
  Filter check: the user row is the acting user itself. Matches nothing for
  system actors and anonymous callers (their ids are not user ids).
  """
  use Ash.Policy.FilterCheck

  @impl true
  def describe(_opts), do: "the user is the actor"

  @impl true
  def filter(%SdrAgent.Accounts.User{id: id}, _context, _opts) when is_binary(id),
    do: expr(id == ^id)

  def filter(_actor, _context, _opts), do: expr(false)
end
