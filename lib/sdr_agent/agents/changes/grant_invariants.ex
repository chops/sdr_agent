defmodule SdrAgent.Agents.Changes.GrantInvariants do
  @moduledoc """
  Grant and allocation invariants (C9), checked in a `before_action` with
  the grant row locked (`FOR UPDATE`), so concurrent edits serialise:

    * the grant is `active`;
    * every allocation's `profile_id` (when set) is one of the grant's
      `profile_ids`;
    * the allocations' `attempts` sum to at most the grant's
      `total_attempts`.

  Option `on:` is `:grant` (a grant terms change; checks the new terms
  against the stored allocations) or `:allocation` (an allocation create or
  change; checks it against its grant and sibling allocations).
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Agents.ModelCallAllocation
  alias SdrAgent.Agents.ModelCallGrant

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case Keyword.get(opts, :on, :grant) do
        :grant -> check_grant(changeset)
        :allocation -> check_allocation(changeset)
      end
    end)
  end

  defp check_grant(changeset) do
    grant = changeset.data
    total = Ash.Changeset.get_attribute(changeset, :total_attempts)
    profiles = Ash.Changeset.get_attribute(changeset, :profile_ids)
    allocations = allocations(grant.id, nil)

    changeset
    |> check_sum(Enum.sum(Enum.map(allocations, & &1.attempts)), total)
    |> check_profiles(allocations, profiles)
  end

  defp check_allocation(changeset) do
    grant_id = Ash.Changeset.get_attribute(changeset, :grant_id)

    case lock_grant(grant_id) do
      {:ok, %ModelCallGrant{status: :active} = grant} ->
        own = %{
          attempts: Ash.Changeset.get_attribute(changeset, :attempts),
          profile_id: Ash.Changeset.get_attribute(changeset, :profile_id)
        }

        siblings = allocations(grant.id, changeset.data.id)

        changeset
        |> check_sum(Enum.sum(Enum.map([own | siblings], & &1.attempts)), grant.total_attempts)
        |> check_profiles([own], grant.profile_ids)

      {:ok, %ModelCallGrant{}} ->
        Ash.Changeset.add_error(changeset, field: :grant_id, message: "grant is not active")

      _ ->
        Ash.Changeset.add_error(changeset, field: :grant_id, message: "grant not found")
    end
  end

  defp check_sum(changeset, sum, total) when sum > total do
    Ash.Changeset.add_error(changeset,
      field: :attempts,
      message: "allocations total %{sum}, above the grant total of %{total}",
      vars: [sum: sum, total: total]
    )
  end

  defp check_sum(changeset, _sum, _total), do: changeset

  defp check_profiles(changeset, allocations, profiles) do
    if Enum.all?(allocations, &(is_nil(&1.profile_id) or &1.profile_id in profiles)) do
      changeset
    else
      Ash.Changeset.add_error(changeset,
        field: :profile_id,
        message: "must be one of the grant's profiles"
      )
    end
  end

  defp lock_grant(nil), do: {:error, :missing}

  defp lock_grant(id) do
    ModelCallGrant
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock("FOR UPDATE")
    |> Ash.read_one(authorize?: false)
  end

  defp allocations(grant_id, except_id) do
    ModelCallAllocation
    |> Ash.Query.filter(grant_id == ^grant_id)
    |> then(fn query ->
      if except_id, do: Ash.Query.filter(query, id != ^except_id), else: query
    end)
    |> Ash.read!(authorize?: false)
  end
end
