defmodule SdrAgent.AgentEnv.ModeRefused do
  @moduledoc """
  Raised by `SdrAgent.AgentEnv.OperationSnapshot.enter/2` at an operation
  snapshot entry in a non-run agent-environment mode (`:check`,
  `:bootstrap`, `:provisioning`), before the entry's body runs (plan r2
  section 6.2, L6). It carries only the mode and the entry atom: no path,
  value or business content.
  """

  defexception [:mode, :entry]

  @impl true
  def message(%__MODULE__{mode: mode, entry: entry}),
    do: "agent environment: #{inspect(entry)} is refused in #{inspect(mode)} mode"
end
