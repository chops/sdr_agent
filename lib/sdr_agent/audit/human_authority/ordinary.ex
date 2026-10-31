defmodule SdrAgent.Audit.HumanAuthority.Ordinary do
  @moduledoc """
  Ordinary-build human eligibility: retain the existing human role
  semantics without a prototype dependency. Hosted scoped User writes are
  unavailable in this build. ActorRole still decides its exact role list.
  """
  @behaviour SdrAgent.Audit.HumanAuthority

  @impl true
  def role_allowed?(%{role: role}) when role in [:admin, :reviewer, :auditor], do: true
  def role_allowed?(_actor), do: false

  @impl true
  def valid_write_scope?(_actor, _subject), do: false

  @impl true
  def human_read?(%SdrAgent.Accounts.User{}), do: true
  def human_read?(_actor), do: false

  @impl true
  def hosted_owner?(_actor), do: false
end
