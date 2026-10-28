defmodule SdrAgent.Prototype.Checks.PrototypeRuntime do
  @moduledoc """
  Policy check: the VM runs in D-237 prototype runtime
  (`SdrAgent.Prototype.runtime/0 == :prototype`). Used as
  `forbid_if SdrAgent.Prototype.Checks.PrototypeRuntime` on the actions that
  prototype runtime refuses for every actor (interfaces r6 IF-2, IF-3): user
  administration, and grant creation, term changes and releases.

  RED stage (D-237 S1): never matches.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the VM runs in prototype runtime"

  @impl true
  def match?(_actor, _context, _opts), do: red(false)

  # RED stub result, typed dynamic() so callers compile against the stub
  # (Elixir 1.20 infers literal returns); nothing sets the key.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
