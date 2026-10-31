defmodule SdrAgent.Operations.Changes.RecheckMacWorkerControl do
  @moduledoc """
  Revalidates MacWorker control at the existing audit-head serialization
  point, after get_and_lock_for_update on updates. Owner disable uses the
  same head, so a disable that commits first forbids the waiting control.
  No owner/User/run/call locks are acquired. Refusal writes no worker event.
  """
  use Ash.Resource.Change

  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations.Checks.MacWorkerControl

  @impl true
  def change(changeset, _opts, %{actor: actor}) do
    Ash.Changeset.before_action(changeset, fn locked ->
      with {:ok, _head} <- Kernel.lock_head(Map.get(actor, :tenant_id)),
           true <- MacWorkerControl.match?(actor, %{subject: locked}, []) do
        locked
      else
        {:error, error} -> Ash.Changeset.add_error(locked, error)
        _refused -> Ash.Changeset.add_error(locked, Ash.Error.Forbidden.exception([]))
      end
    end)
  end
end
