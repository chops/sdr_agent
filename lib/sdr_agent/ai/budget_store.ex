defmodule SdrAgent.AI.BudgetStore do
  @moduledoc """
  Temporary reservation boundary for the cross-run daily model-call budget.

  S3 persists per-run reservations and invocation lifecycle. This seam remains
  only for the 200-per-UTC-day limit until that aggregate is persisted.
  """

  @type reservation :: term()
  @type outcome :: :ok | {:error, term()}

  @callback reserve_daily(now :: DateTime.t()) ::
              {:ok, reservation()} | {:error, {:budget_exhausted, atom()}}
  @callback settle(reservation(), outcome()) :: :ok
end
