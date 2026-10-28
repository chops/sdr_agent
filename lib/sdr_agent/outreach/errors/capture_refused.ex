defmodule SdrAgent.Outreach.Errors.CaptureRefused do
  @moduledoc """
  The typed, closed refusal of the D-237 capture boundary
  (`SdrAgent.Outreach.Changes.PrototypeCapture`; S4 proposal r3 sections
  3.1, 3.2 and 4, Codex 6b79bfb3 and 6a092753). It is an `:invalid`-class
  error, the `SdrAgent.Agents.Errors.ProvisionRefused` precedent, and is
  present in every build. Only PrototypeCapture constructs it.

  - `code` is one of `codes/0`: five business refusals, decided on
    successful reads (`prototype_binding_mismatch`,
    `prototype_approval_not_delegated`, `prototype_outside_window`,
    `prototype_recipient_suppressed`, `prototype_assurance_unavailable`),
    and the call-shape refusal `prototype_capture_nested`. The two former
    `*_unchecked` codes are retired.
  - The message carries the code only, never a value.
  - `adapter_result/1` is the capture adapter's bounded, total result
    contract. Only the compile-gated prototype clause of
    `SdrAgent.Outreach.Delivery.CaptureAdapter` calls it, and only in
    prototype runtime.
  """
  use Splode.Error, fields: [:code], class: :invalid

  alias SdrAgent.Outreach.DeliveryReceipt

  @business [
    :prototype_binding_mismatch,
    :prototype_approval_not_delegated,
    :prototype_outside_window,
    :prototype_recipient_suppressed,
    :prototype_assurance_unavailable
  ]
  @codes @business ++ [:prototype_capture_nested]
  @classes [Ash.Error.Invalid, Ash.Error.Forbidden, Ash.Error.Framework, Ash.Error.Unknown]
  @unsupported "prototype capture: unsupported record result"

  @doc "The closed set of capture refusal codes, in contract order."
  @spec codes() :: [atom()]
  def codes, do: @codes

  @impl true
  def message(%{code: code}), do: "prototype capture refused (#{code})"

  @doc """
  The capture adapter's bounded, total result contract over
  `SdrAgent.Outreach.record_receipt/2`'s result (proposal r3 section 3.2).
  It matches struct names and the closed code set only; it never decodes
  error text.

  - `{:ok, %DeliveryReceipt{}}` is success: `{:ok, receipt}`.
  - Exactly one business refusal, singleton in an `Ash.Error.Invalid`, is
    a permanent delivery outcome: `{:outcome, {:permanent, code}}`.
  - Any other value of the four Ash error classes is re-raised unchanged:
    `{:raise, error}`. That includes the nested call-shape code, an unknown
    code, several or mixed errors, an empty container and a nested
    container; none of them is a business outcome.
  - Any other term is unsupported: `{:raise, %ArgumentError{}}` with a
    fixed, value-free message. This covers rollback containers, raw
    database errors, a bare refusal outside a class, atoms, binaries and
    maps.
  """
  @spec adapter_result(term()) ::
          {:ok, struct()} | {:outcome, {:permanent, atom()}} | {:raise, Exception.t()}
  def adapter_result({:ok, %DeliveryReceipt{} = receipt}), do: {:ok, receipt}

  def adapter_result({:error, %Ash.Error.Invalid{errors: [%__MODULE__{code: code}]}})
      when code in @business,
      do: {:outcome, {:permanent, code}}

  def adapter_result({:error, %class{} = error}) when class in @classes, do: {:raise, error}
  def adapter_result(_other), do: {:raise, ArgumentError.exception(@unsupported)}
end
