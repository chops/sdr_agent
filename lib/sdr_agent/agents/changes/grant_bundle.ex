defmodule SdrAgent.Agents.Changes.GrantBundle do
  @moduledoc """
  Applies a grant and its allocation changes as one validated bundle (C9).

  Runs on `ModelCallGrant :create` and `:update_terms` (option `mode:
  :create | :update`) and `:release_allocation` (`mode: :release`). In a
  `before_action`, with the grant row already locked by the action
  (`get_and_lock_for_update`) and its revision already checked
  (`GrantRevision`), it:

    1. locks the grant's allocation rows (`FOR UPDATE`, grant first, then
       allocations, the only lock order);
    2. computes the **complete final state**: the stored allocations with
       the requested changes applied (matched by `{key, profile_id}`;
       unmatched pairs are created; none is deleted);
    3. validates that final state against the final grant terms: allocations
       sum to at most `total_attempts`, every allocation `profile_id` is one
       of `profile_ids`, and `{key, profile_id}` pairs are unique.

  Only then, in an `after_action` on the same transaction, does it write the
  allocations through their own actions, marked with
  `SdrAgent.Agents.Checks.GrantContext` and stamped with the grant's new
  `revision`. The order in which a caller lists changes never matters, and no
  invalid intermediate state is written.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Agents.Checks.GrantContext
  alias SdrAgent.Agents.ModelCallAllocation

  @allocation_terms [:applies_to, :attempts, :available_from, :available_until]

  @impl true
  def change(changeset, opts, context) do
    mode = Keyword.fetch!(opts, :mode)

    changeset
    |> Ash.Changeset.before_action(&plan(&1, mode))
    |> Ash.Changeset.after_action(&apply_plan(&1, &2, context.actor))
  end

  defp plan(changeset, mode) do
    stored = if mode == :create, do: [], else: lock_allocations(changeset.data.id)

    case final_state(changeset, mode, stored) do
      {:ok, writes, final} ->
        changeset
        |> validate(final)
        |> Ash.Changeset.put_context(:grant_bundle_writes, writes)

      {:error, field, message} ->
        Ash.Changeset.add_error(changeset, field: field, message: message)
    end
  end

  defp final_state(changeset, :release, stored) do
    key = Ash.Changeset.get_argument(changeset, :key)
    profile_id = Ash.Changeset.get_argument(changeset, :profile_id)

    case Enum.find(stored, &same?(&1, key, profile_id)) do
      nil ->
        {:error, :key, "no such allocation"}

      %{released_at: released} when not is_nil(released) ->
        {:error, :key, "allocation is already released"}

      allocation ->
        {:ok, [{:release, allocation}], stored}
    end
  end

  defp final_state(changeset, _mode, stored) do
    requested = Ash.Changeset.get_argument(changeset, :allocations) || []

    Enum.reduce_while(requested, {:ok, [], stored}, fn request, {:ok, writes, final} ->
      request = Map.new(request)
      key = request[:key]
      profile_id = request[:profile_id]

      case Enum.find(final, &same?(&1, key, profile_id)) do
        nil ->
          new =
            Map.merge(%{key: key, profile_id: profile_id}, Map.take(request, @allocation_terms))

          {:cont, {:ok, [{:create, new} | writes], final ++ [new]}}

        %ModelCallAllocation{} = allocation ->
          changes = Map.take(request, @allocation_terms)
          updated = Map.merge(allocation, changes)
          final = Enum.map(final, &if(&1 == allocation, do: updated, else: &1))
          {:cont, {:ok, [{:update, allocation, changes} | writes], final}}

        %{} ->
          {:halt, {:error, :allocations, "lists the same key and profile twice"}}
      end
    end)
    |> case do
      {:ok, writes, final} -> {:ok, Enum.reverse(writes), final}
      error -> error
    end
  end

  defp validate(changeset, final) do
    total = Ash.Changeset.get_attribute(changeset, :total_attempts)
    profiles = Ash.Changeset.get_attribute(changeset, :profile_ids) || []
    sum = final |> Enum.map(&(Map.get(&1, :attempts) || 0)) |> Enum.sum()

    cond do
      is_integer(total) and sum > total ->
        Ash.Changeset.add_error(changeset,
          field: :allocations,
          message: "allocations total %{sum}, above the grant total of %{total}",
          vars: [sum: sum, total: total]
        )

      Enum.any?(final, &(not is_nil(Map.get(&1, :profile_id)) and &1.profile_id not in profiles)) ->
        Ash.Changeset.add_error(changeset,
          field: :allocations,
          message: "an allocation's profile must be one of the grant's profiles"
        )

      true ->
        changeset
    end
  end

  defp apply_plan(changeset, grant, actor) do
    writes = changeset.context[:grant_bundle_writes] || []

    Enum.reduce_while(writes, {:ok, grant}, fn write, {:ok, grant} ->
      case write(write, grant, actor) do
        {:ok, _allocation} -> {:cont, {:ok, grant}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp write({:create, attrs}, grant, actor) do
    attrs = Map.merge(attrs, %{grant_id: grant.id, grant_revision: grant.revision})

    ModelCallAllocation
    |> Ash.Changeset.for_create(:create, attrs, actor: actor, context: GrantContext.context())
    |> Ash.create()
  end

  defp write({:update, allocation, changes}, grant, actor) do
    allocation
    |> Ash.Changeset.for_update(:update_terms, Map.put(changes, :grant_revision, grant.revision),
      actor: actor,
      context: GrantContext.context()
    )
    |> Ash.update()
  end

  defp write({:release, allocation}, grant, actor) do
    allocation
    |> Ash.Changeset.for_update(:release, %{grant_revision: grant.revision},
      actor: actor,
      context: GrantContext.context()
    )
    |> Ash.update()
  end

  defp same?(allocation, key, profile_id),
    do: Map.get(allocation, :key) == key and Map.get(allocation, :profile_id) == profile_id

  defp lock_allocations(grant_id) do
    ModelCallAllocation
    |> Ash.Query.filter(grant_id == ^grant_id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock("FOR UPDATE")
    |> Ash.read!(authorize?: false)
  end
end
