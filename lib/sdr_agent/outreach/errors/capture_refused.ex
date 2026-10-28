defmodule SdrAgent.Outreach.Errors.CaptureRefused do
  @moduledoc """
  The typed, closed refusal of the D-237 capture boundary
  (`SdrAgent.Outreach.Changes.PrototypeCapture`; S4 proposal r3 sections 3.1
  and 4, accepted by Codex 6b79bfb3). It is an `:invalid`-class error, the
  `SdrAgent.Agents.Errors.ProvisionRefused` precedent, and is present in
  every build.

  - `code` is one of `codes/0`: five business refusals, decided on
    successful reads (`prototype_binding_mismatch`,
    `prototype_approval_not_delegated`, `prototype_outside_window`,
    `prototype_recipient_suppressed`, `prototype_assurance_unavailable`),
    and the call-shape refusal `prototype_capture_nested`. The two former
    `*_unchecked` codes are retired.
  - The message carries the code only, never a value.

  Stage (Codex 1fabb2d3, bounded prerequisite construction): this module
  is a declaration only. Nothing constructs it yet, and nothing calls
  `adapter_result/1`. That function is declared deny-only: every result is
  unsupported until the reviewed classification of proposal r3 section 3.2
  is approved and implemented.
  """
  use Splode.Error, fields: [:code], class: :invalid

  @codes [
    :prototype_binding_mismatch,
    :prototype_approval_not_delegated,
    :prototype_outside_window,
    :prototype_recipient_suppressed,
    :prototype_assurance_unavailable,
    :prototype_capture_nested
  ]
  @unsupported "prototype capture: unsupported record result"

  @doc "The closed set of capture refusal codes, in contract order."
  @spec codes() :: [atom()]
  def codes, do: @codes

  @impl true
  def message(%{code: code}), do: "prototype capture refused (#{code})"

  @doc """
  The capture adapter's bounded result contract (proposal r3 section 3.2),
  declared DENY-ONLY at this stage: every input yields
  `{:raise, %ArgumentError{}}` with a fixed, value-free message. Nothing
  calls it.
  """
  @spec adapter_result(term()) :: {:raise, Exception.t()}
  def adapter_result(_result), do: {:raise, ArgumentError.exception(@unsupported)}
end
