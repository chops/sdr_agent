defmodule SdrAgent.Agents.DemoException.Unattested do
  @moduledoc """
  The shipped `SdrAgent.Agents.DemoException.Source` (S3 plan r2 §4.1): no
  agent environment is ever attested. `attestation/0` is `:none`,
  `live_binding?/2` and `delegated_grant?/2` are `false`, and
  `authorization/1` is `:error`, so no output is ever eligible for, or
  usable under, the demo exception. The real source replaces it only in a
  later, separately reviewed slice.
  """

  @behaviour SdrAgent.Agents.DemoException.Source

  @impl true
  def attestation, do: :none

  @impl true
  def live_binding?(_attestation, _tenant_id), do: false

  @impl true
  def authorization(_id), do: :error

  @impl true
  def delegated_grant?(_grant, _authorization), do: false
end
