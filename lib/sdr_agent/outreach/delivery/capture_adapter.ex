defmodule SdrAgent.Outreach.Delivery.CaptureAdapter do
  @moduledoc """
  The only delivery adapter: a local capture (ADR-0001: never a delivery
  path that can reach a real recipient). "Sending" stores a `captured`
  DeliveryReceipt — the capture's own durable record of the exact message
  (its bytes are already a Payload, named by `rendered_sha256`) — in its own
  transaction, as the provider side of the hand-off would.

  Idempotent on the operation's key: the `provider_message_id` is
  `"capture-" <>` the first 32 hex digits of sha256(idempotency key), and
  the receipt is unique per operation and kind, so a repeated delivery
  returns the same id and stores nothing new. `lookup/2` answers
  reconciliation from the `captured` receipt. A message whose bytes do not
  hash to the operation's `rendered_sha256` is refused permanently.

  Test seam (`config :sdr_agent, :capture_faults, Module`, set only by
  tests): `Module.fault(:before_capture | :after_capture, operation)` may
  return `{:error, {class, reason}}` or `:crash` to simulate a provider
  failure, a timeout or a crash on either side of the capture. A fault can
  only make delivery fail; there is nothing else to reach.
  """
  @behaviour SdrAgent.Outreach.Delivery.Adapter

  alias SdrAgent.Outreach

  @impl true
  def deliver(operation, rendered, opts) do
    actor = Keyword.fetch!(opts, :actor)

    with :ok <- fault(:before_capture, operation),
         :ok <- same_bytes(operation, rendered),
         {:ok, receipt} <- capture(operation, actor),
         :ok <- fault(:after_capture, operation) do
      {:ok, %{provider_message_id: receipt.provider_message_id}}
    end
  end

  @impl true
  def lookup(operation, opts) do
    case Outreach.list_records(Outreach.DeliveryReceipt,
           filter: [delivery_operation_id: operation.id, kind: :captured],
           actor: Keyword.fetch!(opts, :actor)
         ) do
      {:ok, [receipt]} -> {:accepted, receipt.provider_message_id}
      {:ok, []} -> :not_found
    end
  end

  @doc "The deterministic capture message id of an idempotency key."
  @spec provider_message_id(String.t()) :: String.t()
  def provider_message_id(key),
    do:
      "capture-" <>
        (:sha256 |> :crypto.hash(key) |> Base.encode16(case: :lower) |> binary_part(0, 32))

  defp same_bytes(%{rendered_sha256: digest}, rendered) do
    if :crypto.hash(:sha256, rendered) == digest,
      do: :ok,
      else: {:error, {:permanent, :rendered_mismatch}}
  end

  defp capture(operation, actor) do
    Outreach.record_receipt(
      %{
        delivery_operation_id: operation.id,
        idempotency_key: operation.idempotency_key,
        kind: :captured,
        provider: :capture,
        provider_message_id: provider_message_id(operation.idempotency_key),
        rendered_sha256: operation.rendered_sha256
      },
      actor: actor
    )
  end

  defp fault(phase, operation) do
    case Application.get_env(:sdr_agent, :capture_faults) do
      nil ->
        :ok

      module ->
        case module.fault(phase, operation) do
          :crash -> raise RuntimeError, "capture fault: crash #{phase}"
          other -> other
        end
    end
  end
end
