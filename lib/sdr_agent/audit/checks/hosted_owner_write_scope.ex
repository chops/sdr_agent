defmodule SdrAgent.Audit.Checks.HostedOwnerWriteScope do
  @moduledoc """
  Lower-owned policy check for the exact hosted owner/User write scope.
  A scope is registered privately in the current process and transaction;
  context booleans, hand-built refs, other actors/rows/actions and a scope
  copied to another process do not grant authority. The configured
  HumanAuthority implementation owns the registry; this lower check knows
  no upper persistence implementation. No constructor is public.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the hosted-owner orchestrator's exact transaction-bound write"

  @impl true
  def match?(actor, %{subject: subject}, _opts),
    do: SdrAgent.Audit.HumanAuthority.valid_write_scope?(actor, subject)

  def match?(_actor, _authorizer, _opts), do: false
end
