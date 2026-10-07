defmodule SdrAgent.Agents.Changes.BudgetCounter do
  @moduledoc """
  Race-free budget counter update on `AgentRun.budget` (S2 AgentRun:
  "budget counters only increase; reservation is a conditional UPDATE
  (reserved < max) before each call").

  Ash cannot update embedded attributes with SQL expressions, so the
  counter actions are non-atomic (`require_atomic? false`) and serialise
  with a row lock instead (the alternative S2 names for this case): inside
  the action transaction the run row is re-read `FOR UPDATE`, the guard
  (run is `running`, counter below its limit) is evaluated on the locked
  row, and the new budget is computed from it. A concurrent reservation
  waits for the lock and then sees the incremented counter, so the maximum
  can never be exceeded; a refused reservation is an `Ash.Error.Invalid`.

  Options:

    * `:increment` — keyword of `counter: amount | {:arg, name}`
    * `:limit` — `{counter, max_field}`: refuse when `counter >= max_field`
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Audit.Kernel

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      locked = lock(changeset)
      budget = locked.budget

      cond do
        locked.status != :running ->
          Ash.Changeset.add_error(changeset, field: :status, message: "run is not running")

        exhausted?(budget, opts[:limit]) ->
          Ash.Changeset.add_error(changeset, field: :budget, message: "budget exhausted")

        true ->
          Ash.Changeset.force_change_attribute(
            changeset,
            :budget,
            increment(budget, changeset, opts)
          )
      end
    end)
  end

  defp lock(changeset) do
    %{id: id, tenant_id: tenant_id} = changeset.data

    changeset.resource
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!()
  end

  defp increment(budget, changeset, opts) do
    Enum.reduce(opts[:increment], budget, fn {counter, amount}, acc ->
      Map.put(acc, counter, Map.fetch!(acc, counter) + amount(changeset, amount))
    end)
  end

  defp amount(changeset, {:arg, name}), do: Ash.Changeset.get_argument(changeset, name) || 0
  defp amount(_changeset, amount), do: amount

  defp exhausted?(_budget, nil), do: false

  defp exhausted?(budget, {counter, max}),
    do: Map.fetch!(budget, counter) >= Map.fetch!(budget, max)
end
