defmodule SdrAgent.Operations.Checks.MacWorkerControl do
  @moduledoc """
  MacWorker control authority: preserve the marked ordinary console, or
  require the fresh hosted owner and the exact current tenant/binding of
  the changeset. No role, delegation, worker actor or stale row is proof.
  The action repeats this check after row and audit-head locks.
  """
  use Ash.Policy.SimpleCheck

  alias SdrAgent.Prototype.Checks.KernelMarker

  @impl true
  def describe(_opts), do: "the marked console or current owner controls its bound MacWorker"

  @impl true
  def match?(%SdrAgent.Actor{type: :kernel} = actor, authorizer, _opts) do
    SdrAgent.Prototype.runtime() == :ordinary and
      KernelMarker.match?(actor, authorizer, marker: :mac_worker)
  end

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    alias SdrAgent.Prototype.Checks.OperatorAction

    def match?(%SdrAgent.Accounts.User{} = actor, %{subject: %Ash.Changeset{} = subject}, _opts) do
      with true <- OperatorAction.match?(actor, %{}, action: :mac_worker_control),
           {:ok, binding} <- SdrAgent.Prototype.binding() do
        Ash.Changeset.get_attribute(subject, :tenant_id) == actor.tenant_id and
          actor.tenant_id == binding.tenant_id and
          Ash.Changeset.get_attribute(subject, :binding_id) == binding.id
      else
        _refused -> false
      end
    end
  end

  def match?(_actor, _authorizer, _opts), do: false
end
