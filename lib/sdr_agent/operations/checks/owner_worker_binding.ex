defmodule SdrAgent.Operations.Checks.OwnerWorkerBinding do
  @moduledoc """
  Row filter for the explicit owner-only worker list. The independent
  OperatorAction strict check establishes fresh owner authority; this
  filter narrows rows to that tenant and its boot binding. Default worker
  reads do not use this action or gain any human access.
  """
  use Ash.Policy.FilterCheck

  @impl true
  def describe(_opts), do: "the worker belongs to the owner's current tenant and binding"

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    @impl true
    def filter(%{tenant_id: tenant_id}, _authorizer, _opts) do
      case SdrAgent.Prototype.binding() do
        {:ok, %{id: id, tenant_id: ^tenant_id}} ->
          expr(tenant_id == ^tenant_id and binding_id == ^id)

        _refused ->
          false
      end
    end

    def filter(_actor, _authorizer, _opts), do: false
  else
    @impl true
    def filter(_actor, _authorizer, _opts), do: false
  end
end
