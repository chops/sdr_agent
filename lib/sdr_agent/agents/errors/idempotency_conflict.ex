defmodule SdrAgent.Agents.Errors.IdempotencyConflict do
  @moduledoc """
  A Decision was recorded with an idempotency key that already belongs to a
  *different* decision (its replay fingerprint differs). Identical replays
  return the existing row; a conflicting reuse fails with this error (class
  `:invalid`) and writes nothing.
  """
  use Splode.Error, fields: [:idempotency_key, :existing_id], class: :invalid

  def message(error) do
    "idempotency key #{inspect(error.idempotency_key)} already records a different decision " <>
      "(#{error.existing_id})"
  end
end
