defmodule SdrAgent.Operations.Changes.FailOperation do
  @moduledoc """
  Operation `:fail` change (S2 "Entering failed … opens a Failure in the
  same transaction (last_failure_id)"): with argument `failure_id` it links
  that existing Failure of the same tenant (the condition already has its
  queue entry); otherwise it opens a Failure from argument `failure`
  (`class`, `severity`, `message`, optional `retryable`, `detail`) with the
  operation as subject. Runs before the update, inside its transaction.
  """
  use Ash.Resource.Change

  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations.Attention
  alias SdrAgent.Operations.Failure

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      if changeset.valid?, do: link(changeset, context.actor), else: changeset
    end)
  end

  defp link(changeset, actor) do
    operation = changeset.data

    result =
      case Ash.Changeset.get_argument(changeset, :failure_id) do
        nil -> open(changeset, operation, actor)
        id -> Ash.get(Failure, id, Kernel.opts(operation.tenant_id))
      end

    case result do
      {:ok, %Failure{tenant_id: tenant_id} = failure} when tenant_id == operation.tenant_id ->
        Ash.Changeset.force_change_attribute(changeset, :last_failure_id, failure.id)

      {:ok, _other} ->
        Ash.Changeset.add_error(changeset, field: :failure_id, message: "unknown failure")

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  defp open(changeset, operation, actor) do
    case Ash.Changeset.get_argument(changeset, :failure) do
      %{} = failure ->
        failure
        |> Map.new(fn {key, value} -> {to_atom(key), value} end)
        |> Map.take([:class, :severity, :message, :retryable, :detail])
        |> Map.merge(%{
          operation_id: operation.id,
          subject_resource: inspect(operation.__struct__),
          subject_id: operation.id
        })
        |> Attention.open(actor)

      _ ->
        {:error,
         Ash.Error.Changes.InvalidArgument.exception(
           field: :failure,
           message: "failure or failure_id is required"
         )}
    end
  end

  defp to_atom(key) when is_atom(key), do: key
  defp to_atom(key) when is_binary(key), do: String.to_existing_atom(key)
end
