defmodule SdrAgent.Outreach.Delivery.Adapter do
  @moduledoc """
  The delivery adapter behaviour (spec §17 anti-corruption layer for the
  email provider). Exactly one implementation exists:
  `SdrAgent.Outreach.Delivery.CaptureAdapter`, a local capture that never
  reaches a recipient (ADR-0001; checklist 3.4) — a test asserts no other
  module implements this behaviour and no environment configures one.

    * `deliver/3` hands over the exact rendered message for a claimed
      operation, keyed by its idempotency key: a repeated key must return the
      same `provider_message_id` and never deliver twice. Outcomes:
      `{:ok, %{provider_message_id: id}}`, `{:error, {:retryable, reason}}`,
      `{:error, {:permanent, reason}}`, `{:error, {:unknown, reason}}`.
    * `lookup/2` answers reconciliation: what, if anything, the provider
      accepted for the operation's key — `{:accepted, provider_message_id}`
      or `:not_found`.
  """

  @type outcome ::
          {:ok, %{provider_message_id: String.t()}}
          | {:error, {:retryable | :permanent | :unknown, atom() | String.t()}}

  @callback deliver(operation :: struct(), rendered :: binary(), opts :: keyword()) :: outcome()
  @callback lookup(operation :: struct(), opts :: keyword()) ::
              {:accepted, String.t()} | :not_found
end
