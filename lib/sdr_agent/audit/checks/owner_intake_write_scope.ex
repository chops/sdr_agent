defmodule SdrAgent.Audit.Checks.OwnerIntakeWriteScope do
  @moduledoc """
  The owner's exact process/transaction-bound intake action. Context maps,
  reviewer roles, copied references and caller tenants do not grant authority.
  Only the coordinator privately registers a scope and rechecks the owner.
  """
  use Ash.Policy.SimpleCheck
  @impl true
  def describe(_opts), do: "the current owner's exact intake transaction action"
  @impl true
  def match?(actor, %{subject: subject}, _opts),
    do: SdrAgent.Prototype.OwnerIntake.valid_write_scope?(actor, subject)

  def match?(_actor, _subject, _opts), do: false
end
