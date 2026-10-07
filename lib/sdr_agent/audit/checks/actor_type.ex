defmodule SdrAgent.Audit.Checks.ActorType do
  @moduledoc "Policy check: the actor is an `SdrAgent.Actor` whose `type` is one of `types`."
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(opts), do: "actor is a system actor of type in #{inspect(opts[:types])}"

  @impl true
  def match?(%SdrAgent.Actor{type: type}, _context, opts), do: type in List.wrap(opts[:types])
  def match?(_actor, _context, _opts), do: false
end
