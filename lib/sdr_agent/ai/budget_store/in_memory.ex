defmodule SdrAgent.AI.BudgetStore.InMemory do
  @moduledoc """
  Volatile, process-isolated model-call budget store for development and tests.

  Reservations are counted before provider invocation and are intentionally
  not refunded: the guard limits attempts, including failed calls. Counters
  reset when the application restarts; persisted enforcement belongs to S3.
  """

  use Agent

  @behaviour SdrAgent.AI.BudgetStore

  @run_limit 20
  @day_limit 200

  def start_link(opts \\ []) do
    Agent.start_link(fn -> empty_state() end, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def reserve(run_id, %DateTime{} = now) when is_binary(run_id) do
    day = DateTime.to_date(now)

    Agent.get_and_update(__MODULE__, fn state ->
      run_count = Map.get(state.runs, run_id, 0)
      day_count = Map.get(state.days, day, 0)

      cond do
        run_count >= @run_limit ->
          {{:error, {:budget_exhausted, :run}}, state}

        day_count >= @day_limit ->
          {{:error, {:budget_exhausted, :day}}, state}

        true ->
          reservation = %{run_id: run_id, day: day}

          next = %{
            runs: Map.put(state.runs, run_id, run_count + 1),
            days: Map.put(state.days, day, day_count + 1)
          }

          {{:ok, reservation}, next}
      end
    end)
  end

  @impl true
  def settle(_reservation, _outcome), do: :ok

  @doc "Resets volatile counters. Intended for deterministic test setup."
  def reset, do: Agent.update(__MODULE__, fn _state -> empty_state() end)

  defp empty_state, do: %{runs: %{}, days: %{}}
end
