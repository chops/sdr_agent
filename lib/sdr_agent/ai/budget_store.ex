defmodule SdrAgent.AI.BudgetStore do
  @moduledoc """
  Reservation boundary for model-call budgets.

  S6a provides a volatile implementation. S3 replaces it with transactional
  persistence without changing the model-provider facade.
  """

  @type reservation :: term()
  @type outcome :: :ok | {:error, term()}

  @callback reserve(run_id :: String.t(), now :: DateTime.t()) ::
              {:ok, reservation()} | {:error, {:budget_exhausted, atom()}}
  @callback settle(reservation(), outcome()) :: :ok
end
