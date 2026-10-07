defmodule SdrAgent.AI.BudgetStore.InMemory do
  @moduledoc """
  Volatile, process-isolated model-call budget store for development and tests.

  Reservations are counted before provider invocation and are intentionally
  not refunded: the guard limits attempts, including failed calls. Counters
  reset when the application restarts; persisted enforcement belongs to S3.
  """

  use Agent

  @behaviour SdrAgent.AI.BudgetStore

  @day_limit 200

  def start_link(opts \\ []) do
    Agent.start_link(fn -> empty_state() end, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def reserve_daily(%DateTime{} = now) do
    day = DateTime.to_date(now)

    Agent.get_and_update(__MODULE__, fn state ->
      day_count = Map.get(state.days, day, 0)

      if day_count >= @day_limit do
        {{:error, {:budget_exhausted, :day}}, state}
      else
        {{:ok, %{day: day}}, %{state | days: Map.put(state.days, day, day_count + 1)}}
      end
    end)
  end

  @impl true
  def settle(_reservation, _outcome), do: :ok

  @doc "Resets volatile counters. Intended for deterministic test setup."
  def reset, do: Agent.update(__MODULE__, fn _state -> empty_state() end)

  defp empty_state, do: %{days: %{}}
end
