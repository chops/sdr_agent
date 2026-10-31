defmodule SdrAgent.Operations.Checks.HostedOwnerWriteScope do
  @moduledoc """
  Pure policy check for the Operations orchestrator's exact owner/User write.
  A scope is registered privately in the current process and transaction;
  context booleans, hand-built refs, other actors/rows/actions and a scope
  copied to another process do not grant authority. No constructor is public.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the hosted-owner orchestrator's exact transaction-bound write"

  @impl true
  def match?(actor, %{subject: subject}, _opts),
    do: SdrAgent.Operations.HostedOwners.valid_write_scope?(actor, subject)

  def match?(_actor, _authorizer, _opts), do: false
end
