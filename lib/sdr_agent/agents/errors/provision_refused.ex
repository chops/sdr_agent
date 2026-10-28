defmodule SdrAgent.Agents.Errors.ProvisionRefused do
  @moduledoc """
  A closed refusal of the D-237 prototype grant's provisioning
  (`SdrAgent.Agents.ModelCallGrant :provision_prototype`; interfaces r6
  IF-2, closure note r2). Raised as a changeset error (class `:invalid`) by
  the action itself, so a raw call is refused with no write;
  `SdrAgent.Agents.provision_prototype_grant/2` returns the plain
  `{:error, reason}`.

  `reason` is one of `:forged_metadata` (a caller supplied a server-derived
  argument), `:binding_mismatch`, `:grant_exists`, `:worksheet_invalid`,
  `:budget_unbounded` or `:budget_below_ceiling`. The message carries the
  reason only, never an input value.
  """
  use Splode.Error, fields: [:reason], class: :invalid

  def message(error), do: "prototype grant provisioning refused (#{error.reason})"
end
