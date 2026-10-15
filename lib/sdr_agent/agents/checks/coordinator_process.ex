defmodule SdrAgent.Agents.Checks.CoordinatorProcess do
  @moduledoc """
  Policy check for the C2-02b2α ledger writes (`docs/product/r0/c2-02b2-interface.md`,
  section 1a): true only when the action runs **in the registered model
  coordinator process**, a direct child of the registered profile
  supervisor, as `model_runtime`. It is a registry lookup in the caller's
  own process, never a call to the coordinator, so a copied id or a forged
  context in any other process is refused. The stored boot fence is checked
  separately, inside the transaction (`SdrAgent.Agents.ServerStarts`).
  """
  use Ash.Policy.SimpleCheck

  @coordinator SdrAgent.AI.ModelProvider.Coordinator
  @profile_supervisor SdrAgent.AI.ModelProvider.ProfileSupervisor

  @impl true
  def describe(_opts), do: "runs in the registered model coordinator, as model_runtime"

  @impl true
  def match?(%SdrAgent.Actor{type: :model_runtime, tenant_id: tenant}, _context, _opts)
      when is_binary(tenant),
      do: coordinator?()

  def match?(_actor, _context, _opts), do: false

  @doc "Whether the calling process is the registered coordinator under its supervisor."
  def coordinator? do
    self() == Process.whereis(@coordinator) and
      Process.info(self(), :parent) == {:parent, Process.whereis(@profile_supervisor)}
  end
end
