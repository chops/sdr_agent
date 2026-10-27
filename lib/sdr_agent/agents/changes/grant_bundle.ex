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

  Mode `:delegated` (C2* S2, `ModelCallGrant :provision_delegated`): the
  requests are the registry entry's allocations that
  `SdrAgent.Agents.Changes.DelegatedProvisioning` put in the changeset
  context, planned and validated as a create. They are written as the
  grant provisioner inside a registered delegated-bundle context
  (`SdrAgent.Agents.Changes.GrantBundle.Delegated.run/2`, carried by
  `Delegated.context/1`) bound to the new grant, its tenant, authorization
  id and digest and the environment binding, in place of the owner-form
  marker. An identical replay (`:sdr_replayed`) writes none.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Agents.Changes.DelegatedProvisioning
  alias SdrAgent.Agents.Changes.GrantBundle.Delegated
  alias SdrAgent.Agents.Checks.GrantContext
  alias SdrAgent.Agents.ModelCallAllocation

  @allocation_terms [:applies_to, :attempts, :available_from, :available_until]

  @impl true
  def change(changeset, opts, context) do
    mode = Keyword.fetch!(opts, :mode)

    changeset
    |> Ash.Changeset.before_action(&plan(&1, mode))
    |> Ash.Changeset.after_action(&apply_plan(&1, &2, mode, context.actor))
  end

  defp plan(changeset, mode) do
    stored = if mode in [:create, :delegated], do: [], else: lock_allocations(changeset.data.id)

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

  defp final_state(changeset, :delegated, stored) do
    requested = changeset.context[DelegatedProvisioning.bundle_key()].allocations

    with {:ok, requests} <- normalize_all(requested, :create),
         :ok <- unique_pairs(requests) do
      plan_requests(requests, [], stored)
    end
  end

  defp final_state(changeset, mode, stored) do
    requested = Ash.Changeset.get_argument(changeset, :allocations) || []

    with {:ok, requests} <- normalize_all(requested, mode),
         :ok <- unique_pairs(requests) do
      plan_requests(requests, Enum.map(stored, &candidate/1), stored)
    end
  end

  # Plans against plain candidate maps; each request names a distinct pair,
  # so every stored row gets at most one governed write.
  defp plan_requests(requests, candidates, stored) do
    {writes, final} =
      Enum.reduce(requests, {[], candidates}, &plan_request(&1, &2, stored))

    {:ok, Enum.reverse(writes), final}
  end

  defp plan_request(request, {writes, final}, stored) do
    key = request.key
    profile_id = request[:profile_id]
    changes = Map.take(request, @allocation_terms)

    case Enum.find(stored, &same?(&1, key, profile_id)) do
      nil ->
        new = Map.merge(%{key: key, profile_id: profile_id}, changes)
        {[{:create, new} | writes], final ++ [new]}

      %ModelCallAllocation{} = allocation ->
        {[{:update, allocation, changes} | writes],
         merge_candidate(final, key, profile_id, changes)}
    end
  end

  defp merge_candidate(final, key, profile_id, changes) do
    Enum.map(final, fn candidate ->
      if same?(candidate, key, profile_id), do: Map.merge(candidate, changes), else: candidate
    end)
  end

  defp candidate(%ModelCallAllocation{} = allocation),
    do: Map.take(allocation, [:key, :profile_id | @allocation_terms])

  defp unique_pairs(requests) do
    pairs = Enum.map(requests, &{&1.key, &1[:profile_id]})

    if length(Enum.uniq(pairs)) == length(pairs),
      do: :ok,
      else: {:error, :allocations, "lists the same key and profile more than once"}
  end

  # Every requested allocation is cast and constrained with the allocation
  # resource's own attribute types before it is matched or summed, so the
  # plan and the writes use the same normalized values.
  @fields [:key, :profile_id | @allocation_terms]

  defp normalize_all(requested, mode) do
    Enum.reduce_while(requested, {:ok, []}, fn request, {:ok, acc} ->
      case normalize(request, mode) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, message} -> {:halt, {:error, :allocations, message}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize(request, mode) when is_map(request) do
    with {:ok, fields} <- known_fields(request) do
      fields
      |> cast_fields()
      |> require_fields(mode)
    end
  end

  defp normalize(_request, _mode), do: {:error, "each allocation must be a map"}

  defp cast_fields(fields) do
    Enum.reduce_while(fields, {:ok, %{}}, fn {field, value}, {:ok, acc} ->
      cast_field(field, value, acc)
    end)
  end

  defp known_fields(request) do
    Enum.reduce_while(request, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      case field_name(name) do
        nil -> {:halt, {:error, "unknown allocation field #{inspect(name)}"}}
        field -> {:cont, {:ok, Map.put(acc, field, value)}}
      end
    end)
  end

  defp field_name(name) when is_atom(name), do: if(name in @fields, do: name)

  defp field_name(name) when is_binary(name),
    do: Enum.find(@fields, &(Atom.to_string(&1) == name))

  defp field_name(_name), do: nil

  defp cast_field(field, value, acc) do
    attribute = Ash.Resource.Info.attribute(ModelCallAllocation, field)

    with {:ok, cast} <- Ash.Type.cast_input(attribute.type, value, attribute.constraints),
         {:ok, cast} <- constrain(attribute, cast) do
      {:cont, {:ok, Map.put(acc, field, cast)}}
    else
      _ -> {:halt, {:error, "allocation #{field} is invalid"}}
    end
  end

  defp constrain(_attribute, nil), do: {:ok, nil}

  defp constrain(attribute, value),
    do: Ash.Type.apply_constraints(attribute.type, value, attribute.constraints)

  defp require_fields({:ok, normalized}, mode) do
    required = if mode == :create, do: [:key, :applies_to, :attempts], else: [:key]

    case Enum.find(required, &is_nil(Map.get(normalized, &1))) do
      nil -> {:ok, normalized}
      field -> {:error, "allocation #{field} is required"}
    end
  end

  defp require_fields(error, _mode), do: error

  defp validate(changeset, final) do
    total = Ash.Changeset.get_attribute(changeset, :total_attempts)
    profiles = Ash.Changeset.get_attribute(changeset, :profile_ids) || []
    sum = final |> Enum.map(&(Map.get(&1, :attempts) || 0)) |> Enum.sum()

    cond do
      is_integer(total) and sum > total ->
        Ash.Changeset.add_error(changeset,
          field: :allocations,
          message: "allocations total %{sum}, above the grant total of %{total}",
          # Ash keeps the whole keyword as the message vars.
          sum: sum,
          total: total
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

  # An identical delegated replay (`:sdr_replayed`) wrote nothing and
  # writes no allocation. A delegated bundle is written inside its
  # registered context (`Delegated.run/2`), bound to the new grant.
  defp apply_plan(changeset, grant, :delegated, actor) do
    if Ash.Resource.get_metadata(grant, :sdr_replayed) do
      {:ok, grant}
    else
      bindings = %{
        tenant_id: grant.tenant_id,
        grant_id: grant.id,
        authorization_id: grant.delegated_authorization_id,
        authorization_sha256: grant.delegated_authorization_sha256,
        binding_sha256: changeset.context[DelegatedProvisioning.bundle_key()].binding_sha256
      }

      Delegated.run(bindings, &write_all(changeset, grant, actor, Delegated.context(&1)))
    end
  end

  defp apply_plan(changeset, grant, _mode, actor),
    do: write_all(changeset, grant, actor, GrantContext.context())

  defp write_all(changeset, grant, actor, context) do
    writes = changeset.context[:grant_bundle_writes] || []

    Enum.reduce_while(writes, {:ok, grant}, fn write, {:ok, grant} ->
      case write(write, grant, actor, context) do
        {:ok, _allocation} -> {:cont, {:ok, grant}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp write({:create, attrs}, grant, actor, context) do
    attrs = Map.merge(attrs, %{grant_id: grant.id, grant_revision: grant.revision})

    ModelCallAllocation
    |> Ash.Changeset.for_create(:create, attrs, actor: actor, context: context)
    |> Ash.create()
  end

  defp write({:update, allocation, changes}, grant, actor, context) do
    allocation
    |> Ash.Changeset.for_update(:update_terms, Map.put(changes, :grant_revision, grant.revision),
      actor: actor,
      context: context
    )
    |> Ash.update()
  end

  defp write({:release, allocation}, grant, actor, context) do
    allocation
    |> Ash.Changeset.for_update(:release, %{grant_revision: grant.revision},
      actor: actor,
      context: context
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
