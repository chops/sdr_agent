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

  D-237 prototype runtime only. This clause compiles only with
  `:prototype_authority_compiled`, and the production build has none. The
  capture's result passes the bounded contract
  `SdrAgent.Outreach.Errors.CaptureRefused.adapter_result/1` (S4 proposal r3
  section 3.2):
  - a typed business refusal becomes the supported permanent outcome
    `{:error, {:permanent, code}}`;
  - any other error is raised unchanged, so the worker boundary sanitizes
    it and the existing crash recovery owns what follows;
  - an unsupported result shape raises a fixed, value-free
    `ArgumentError`.

  Ordinary runtime outcomes are unchanged.
  """
  @behaviour SdrAgent.Outreach.Delivery.Adapter

  alias SdrAgent.AgentEnv.OperationSnapshot
  alias SdrAgent.Outreach

  # C2* operation snapshot entry `:capture_deliver` (ADR-0005 C2* item 2):
  # under Delivery.attempt/2 it inherits; a direct top-level call owns.
  @impl true
  def deliver(operation, rendered, opts) do
    OperationSnapshot.enter(:capture_deliver, fn ->
      actor = Keyword.fetch!(opts, :actor)

      with :ok <- fault(:before_capture, operation),
           :ok <- same_bytes(operation, rendered),
           {:ok, receipt} <- capture(operation, actor),
           :ok <- fault(:after_capture, operation) do
        {:ok, %{provider_message_id: receipt.provider_message_id}}
      end
    end)
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
    %{
      delivery_operation_id: operation.id,
      idempotency_key: operation.idempotency_key,
      kind: :captured,
      provider: :capture,
      provider_message_id: provider_message_id(operation.idempotency_key),
      rendered_sha256: operation.rendered_sha256
    }
    |> Outreach.record_receipt(actor: actor)
    |> captured()
  end

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    alias SdrAgent.Outreach.Errors.CaptureRefused

    # D-237 (see the moduledoc): prototype runtime only.
    defp captured(result) do
      if SdrAgent.Prototype.runtime() == :prototype do
        case CaptureRefused.adapter_result(result) do
          {:ok, receipt} -> {:ok, receipt}
          {:outcome, outcome} -> {:error, outcome}
          {:raise, exception} -> raise exception
        end
      else
        result
      end
    end
  else
    defp captured(result), do: result
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
