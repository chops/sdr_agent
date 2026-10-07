defmodule SdrAgent.Audit.Checks.ActorRole do
  @moduledoc """
  Policy check: the actor is a human operator (not an `SdrAgent.Actor`)
  whose `role` is one of `roles`.

  Reads `actor.role` (`:admin`, `:reviewer`, `:auditor`) from the actor, an
  `SdrAgent.Accounts.User`.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(opts), do: "actor is a human with role in #{inspect(opts[:roles])}"

  @impl true
  def match?(%SdrAgent.Actor{}, _context, _opts), do: false
  def match?(%{role: role}, _context, opts), do: role in List.wrap(opts[:roles])
  def match?(_actor, _context, _opts), do: false
end
