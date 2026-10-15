defmodule SdrAgent.Agents.Preparations.TransitionLock do
  @moduledoc """
  The `:lock_for_transition` reads of `ModelProfileSetting` and
  `ModelProfileSwitch` (C2-02a): each locks its one row `FOR UPDATE`, in an
  open transaction only, and records the locked row as evidence of the
  `:transition` phase (`SdrAgent.Agents.Checks.ProfileSwitchContext`).

  Lock order is setting → switch: the switch read is refused unless the
  setting was already locked under the same phase. The status of the
  switch is not checked here, so a replay or conflict on a finished or
  blocked switch reaches its decision; the pending check belongs to the
  write guard.

  Option `row:` — `:setting` or `:switch`.
  """
  use Ash.Resource.Preparation

  alias SdrAgent.Agents.Checks.ProfileSwitchContext
  alias SdrAgent.Repo

  @impl true
  def prepare(query, opts, _context) do
    row = Keyword.fetch!(opts, :row)

    query
    |> Ash.Query.lock(:for_update)
    |> Ash.Query.before_action(&check_order(&1, row))
    |> Ash.Query.after_action(fn query, records -> record(query, records, row) end)
  end

  defp check_order(query, row) do
    cond do
      not Repo.in_transaction?() ->
        Ash.Query.add_error(query, field: :switch_id, message: "must run in a transaction")

      row == :switch and not setting_locked?(query) ->
        Ash.Query.add_error(query, field: :switch_id, message: "the setting must be locked first")

      true ->
        query
    end
  end

  defp setting_locked?(query) do
    match?({:ok, %{evidence: %{setting: %{}}}}, ProfileSwitchContext.fetch(query.context))
  end

  defp record(query, [record], row) do
    with :ok <- ProfileSwitchContext.put_evidence(query.context, row, record),
         do: {:ok, [record]}
  end

  defp record(_query, records, _row), do: {:ok, records}
end
