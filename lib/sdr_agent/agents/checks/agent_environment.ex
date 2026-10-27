defmodule SdrAgent.Agents.Checks.AgentEnvironment do
  @moduledoc """
  Policy check (C2* S2; ADR-0004 agent-environment item 9 "no other
  route"): an agent environment is configured
  (`SdrAgent.AgentEnv.configured?/0`, any mode). `ModelCallGrant` forbids
  its owner-form routes (`:create`, `:update_terms`, `:release_allocation`)
  for every actor when it holds; with no configuration they are unchanged.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "an agent environment is configured"

  @impl true
  def match?(_actor, _context, _opts), do: SdrAgent.AgentEnv.configured?()
end
