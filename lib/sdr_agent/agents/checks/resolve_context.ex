defmodule SdrAgent.Agents.Checks.ResolveContext do
  @moduledoc """
  Policy check for the attended resolution of a blocked model profile
  switch (C2-02b2β, `docs/product/r0/c2-02b2b-interface.md`, the entity
  table): an active human admin decides, the registered coordinator
  executes. True only when **both** hold:

    * the action runs in the registered model coordinator process under its
      supervisor — `SdrAgent.Agents.Checks.CoordinatorProcess.coordinator?/0`,
      the process-only part of the b2α check (a registry lookup in the
      caller's own process, never a call to the coordinator), whose own
      `model_runtime` rule is unchanged and grants nothing here;
    * the actor is a human operator whose persisted row, re-read now, is an
      active admin of the actor's tenant (`SdrAgent.Agents.Checks.CurrentAdmin`).

  So a direct `resolve_blocked` from any other process, even by an admin,
  and any `model_runtime` or other system actor, are refused. The phase
  (`SdrAgent.Agents.Checks.ProfileSwitchContext`, `:resolve`) and the write
  guard (`SdrAgent.Agents.Changes.ProfileSwitchGuard`) are checked as well;
  this check is never the only proof.
  """
  use Ash.Policy.SimpleCheck

  alias SdrAgent.Agents.Checks.CoordinatorProcess
  alias SdrAgent.Agents.Checks.CurrentAdmin

  @impl true
  def describe(_opts),
    do: "runs in the registered model coordinator, as a currently active human admin"

  @impl true
  def match?(actor, _context, _opts),
    do: CoordinatorProcess.coordinator?() and CurrentAdmin.match?(actor, %{}, [])
end
