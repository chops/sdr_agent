defmodule SdrAgent.Operations.Changes.ResolveOperationFailures do
  @moduledoc """
  Operation `:succeed` change (S2 "Operator attention": clearing the causing
  condition resolves its Failure): after the operation succeeds — e.g. a
  bounded retry after a failed attempt — every live (open or acknowledged)
  Failure of *this* operation's condition is resolved in the same
  transaction, as the succeeding actor, with a system note: its
  `last_failure_id`, Failures carrying its `operation_id`, and Failures whose
  subject is the operation. Unrelated Failures are untouched. If a
  resolution cannot be written, the success rolls back with it.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations.Failure

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, operation ->
      with {:ok, failures} <- owned(operation),
           :ok <- resolve_all(failures, operation, context.actor) do
        {:ok, operation}
      end
    end)
  end

  defp owned(operation) do
    %{id: id, tenant_id: tenant_id, last_failure_id: last} = operation
    subject = inspect(operation.__struct__)
    ids = Enum.reject([last], &is_nil/1)

    Failure
    |> Ash.Query.for_read(:attention, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^tenant_id and
        (id in ^ids or operation_id == ^id or
           (subject_resource == ^subject and subject_id == ^id))
    )
    |> Ash.read()
  end

  defp resolve_all(failures, operation, actor) do
    note = "operation #{operation.id} succeeded on attempt #{operation.attempts}"

    Enum.reduce_while(failures, :ok, fn failure, :ok ->
      failure
      |> Ash.Changeset.for_update(:resolve, %{resolution_note: note}, actor: actor)
      |> Ash.update()
      |> case do
        {:ok, _resolved} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end
end
