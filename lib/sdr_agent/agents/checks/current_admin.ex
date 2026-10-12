defmodule SdrAgent.Agents.Checks.CurrentAdmin do
  @moduledoc """
  Policy check for real-model call grants (C9; G5-R0, OQ-2 = any active
  human admin): the actor is a human operator whose persisted row, re-read
  now, is `active`, has role `:admin` and belongs to the actor's tenant. A
  stale `SdrAgent.Accounts.User` struct (since disabled or demoted) is
  refused, and every system actor (`SdrAgent.Actor`) is refused.
  """
  use Ash.Policy.SimpleCheck

  alias SdrAgent.Accounts.User

  @impl true
  def describe(_opts), do: "actor is a currently active human admin"

  @impl true
  def match?(%User{id: id, tenant_id: tenant_id}, _context, _opts) when is_binary(id) do
    case Ash.get(User, id, authorize?: false) do
      {:ok, %User{status: :active, role: :admin, tenant_id: ^tenant_id}} -> true
      _ -> false
    end
  end

  def match?(_actor, _context, _opts), do: false
end
