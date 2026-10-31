defmodule SdrAgent.Audit.Checks.ActorRole do
  @moduledoc """
  Policy check: the actor is a human operator (not an `SdrAgent.Actor`)
  whose `role` is one of `roles`.

  Ordinary runtime retains its historical role semantics. In prototype
  runtime only a fresh persisted nonowner User can use a role grant;
  HostedOwner history always takes precedence over inherited roles.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(opts), do: "actor is a human with role in #{inspect(opts[:roles])}"

  @impl true
  def match?(%SdrAgent.Actor{}, _context, _opts), do: false

  def match?(%{role: role} = actor, _context, opts) do
    role in List.wrap(opts[:roles]) and SdrAgent.Audit.HumanAuthority.role_allowed?(actor)
  end

  def match?(_actor, _context, _opts), do: false
end
