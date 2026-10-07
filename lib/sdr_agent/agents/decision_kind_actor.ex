defmodule SdrAgent.Agents.Checks.DecisionKindActor do
  @moduledoc """
  Policy check for Decision creation: the system actor's type may record the
  decision's `kind` (see `SdrAgent.Agents.Decision.kind_actors/0`).
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor's type may record this decision kind"

  @impl true
  def match?(%SdrAgent.Actor{type: type}, %{subject: %Ash.Changeset{} = changeset}, _opts) do
    kind = Ash.Changeset.get_attribute(changeset, :kind)
    type in Map.get(SdrAgent.Agents.Decision.kind_actors(), kind, [])
  end

  def match?(_actor, _context, _opts), do: false
end
