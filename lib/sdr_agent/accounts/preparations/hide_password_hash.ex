defmodule SdrAgent.Accounts.Preparations.HidePasswordHash do
  @moduledoc """
  Deselects `hashed_password` when a human operator reads users, so no
  operator — admin included — ever receives a password hash. The kernel
  (chain verifier), internal re-reads without an actor and the
  AshAuthentication sign-in/session actions still load it.
  """
  use Ash.Resource.Preparation

  @impl true
  def prepare(query, _opts, %{actor: %SdrAgent.Accounts.User{}}),
    do: Ash.Query.deselect(query, [:hashed_password])

  def prepare(query, _opts, _context), do: query
end
