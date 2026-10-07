defmodule SdrAgent.Outreach.Checks.InternalWrite do
  @moduledoc """
  Policy check: the write is made by another Outreach action of the same
  transaction — a revision or citation inserted by the Draft create/edit, a
  Draft moved by an Approval grant, rejection or revoke, or an Approval
  invalidated / Draft cancelled by a Suppression create (S2: "created only
  inside", "same-transaction side effects").

  The marker returned by `context/0` is set only by the Outreach changes that
  make those writes; no public domain function sets it, so these
  transitions are unreachable on their own.
  """
  use Ash.Policy.SimpleCheck

  @marker :sdr_outreach_internal_write

  @impl true
  def describe(_opts), do: "write made inside another Outreach action"

  @impl true
  def match?(_actor, %{subject: %{context: context}}, _opts) when is_map(context),
    do: Map.get(context, @marker) == true

  def match?(_actor, _context, _opts), do: false

  @doc "The context map Outreach attaches to its internal writes."
  def context, do: %{@marker => true}
end
