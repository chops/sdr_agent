defmodule SdrAgent.Agents.Checks.GrantContext do
  @moduledoc """
  Policy check for `ModelCallAllocation` writes (C9): an allocation is
  created or changed only by its grant's own action, which has already
  locked the grant row, checked the expected revision and validated the
  complete final state (`SdrAgent.Agents.Changes.GrantBundle`). That action
  sets this marker on the allocation changeset; nothing else does, so a
  direct allocation action is refused before it takes any lock (same
  pattern as `SdrAgent.Agents.Checks.RetryContext`).
  """
  use Ash.Policy.SimpleCheck

  @marker :sdr_agent_grant_bundle

  @impl true
  def describe(_opts), do: "allocation written by its grant's own action"

  @impl true
  def match?(_actor, %{subject: %{context: context}}, _opts), do: marked?(context)
  def match?(_actor, _context, _opts), do: false

  @doc "Whether a changeset context carries the grant-bundle marker."
  def marked?(context) when is_map(context), do: Map.get(context, @marker) == true
  def marked?(_context), do: false

  @doc "The context map a grant action attaches to its allocation writes."
  def context, do: %{@marker => true}
end
