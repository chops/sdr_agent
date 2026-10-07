defmodule SdrAgent.Sales.Checks.QualificationContext do
  @moduledoc """
  Policy check: the write is made from inside a Research Qualification
  create (S2 Lead: "Lead transitions to qualified/disqualified only in the
  same transaction as the Qualification create"; QualificationEvidence:
  "created only inside the Qualification create").

  `SdrAgent.Research` sets the private marker returned by `context/0` on the
  Lead transition and the evidence rows it writes in its own action; no
  public domain function sets it. Lives in Sales (the lower domain) so
  Research may depend on it, never the reverse.
  """
  use Ash.Policy.SimpleCheck

  @marker :sdr_qualification_write

  @impl true
  def describe(_opts), do: "write made by the Research qualification create"

  @impl true
  def match?(_actor, %{subject: %{context: context}}, _opts) when is_map(context),
    do: Map.get(context, @marker) == true

  def match?(_actor, _context, _opts), do: false

  @doc "The context map the qualification create attaches to its writes."
  def context, do: %{@marker => true}
end
