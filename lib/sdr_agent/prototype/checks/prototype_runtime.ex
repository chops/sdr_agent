defmodule SdrAgent.Prototype.Checks.PrototypeRuntime do
  @moduledoc """
  Policy check: the VM runs in D-237 prototype runtime
  (`SdrAgent.Prototype.runtime/0 == :prototype`). Used as
  `forbid_if SdrAgent.Prototype.Checks.PrototypeRuntime` on the actions that
  prototype runtime refuses for every actor (interfaces r6 IF-2, IF-3):
  grant creation, term changes and releases (D3), and user administration.

  In a build without the prototype authority (the production build) it
  never matches.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the VM runs in prototype runtime"

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    @impl true
    def match?(_actor, _context, _opts), do: SdrAgent.Prototype.runtime() == :prototype
  else
    @impl true
    def match?(_actor, _context, _opts), do: false
  end
end
