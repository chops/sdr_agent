defmodule SdrAgent.Operations.Changes.FailOperation do
  @moduledoc """
  Operation `:fail` change (S2 "Entering failed … opens a Failure in the
  same transaction (last_failure_id)"), run before the update inside its
  transaction.

  With argument `failure_id` it links an existing Failure only if that
  Failure is *live* (open or acknowledged) and belongs to this operation's
  condition — its `operation_id` is this operation (e.g. the attention
  Failure of the AgentRun the operation runs, which carries the run's
  operation id) or its subject is this operation. Anything else (resolved,
  another tenant, another condition) refuses the transition, so a failed
  Operation always has a live queue entry. The Failure is read `FOR UPDATE`
  so a concurrent resolution cannot slip between this check and the link. Without `failure_id` it opens a
  Failure from argument `failure` (`class`, `severity`, `message`, optional
  `retryable`, `detail`; string or atom keys, unknown keys ignored) with the
  operation as subject.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations.Attention
  alias SdrAgent.Operations.Failure

  @failure_keys [:class, :severity, :message, :retryable, :detail]
  @live [:open, :acknowledged]

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
        id -> existing(id, operation)
      end

    case result do
      {:ok, failure} ->
        Ash.Changeset.force_change_attribute(changeset, :last_failure_id, failure.id)

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  # The Failure is read under FOR UPDATE in the transition's transaction
  # (lock order Operation → Failure → chain head, as Operation :succeed and
  # Failure :resolve take them), so a concurrent resolve either commits first
  # — and is seen here — or waits until this link has committed.
  defp existing(id, operation) do
    Failure
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(operation.tenant_id))
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one()
    |> case do
      {:ok, %Failure{} = failure} ->
        if failure.tenant_id == operation.tenant_id and failure.status in @live and
             owned?(failure, operation),
           do: {:ok, failure},
           else: {:error, invalid("must be a live Failure of this operation's condition")}

      _ ->
        {:error, invalid("unknown failure")}
    end
  end

  defp owned?(failure, operation) do
    failure.operation_id == operation.id or
      (failure.subject_resource == inspect(operation.__struct__) and
         failure.subject_id == operation.id)
  end

  defp open(changeset, operation, actor) do
    case Ash.Changeset.get_argument(changeset, :failure) do
      %{} = failure ->
        failure
        |> known_keys()
        |> Map.merge(%{
          operation_id: operation.id,
          subject_resource: inspect(operation.__struct__),
          subject_id: operation.id
        })
        |> Attention.open(actor)

      _ ->
        {:error, invalid("failure or failure_id is required", :failure)}
    end
  end

  defp known_keys(map) do
    for key <- @failure_keys, value = fetch(map, key), value != nil, into: %{}, do: {key, value}
  end

  defp fetch(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp invalid(message, field \\ :failure_id),
    do: Ash.Error.Changes.InvalidArgument.exception(field: field, message: message)
end
