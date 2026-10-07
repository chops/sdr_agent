defmodule SdrAgent.Operations.Checks.OperationKindActor do
  @moduledoc """
  Policy check for Operation writes: the actor is the system actor that owns
  the operation's `kind` (`SdrAgent.Operations.Operation.kind_actors/0`;
  S2: "AGT, DLV, REC, WHK, SCH, ANC create/transition own kinds").
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor's type owns this operation kind"

  @impl true
  def match?(%SdrAgent.Actor{type: type}, %{subject: %Ash.Changeset{} = changeset}, _opts) do
    kind = Ash.Changeset.get_attribute(changeset, :kind)
    type in Map.get(SdrAgent.Operations.Operation.kind_actors(), kind, [])
  end

  def match?(_actor, _context, _opts), do: false
end
