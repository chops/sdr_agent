defmodule SdrAgent.Agents.DemoException.Source do
  @moduledoc """
  The read-only consumer seam through which the C2* demo exception sees the
  agent environment (ADR-0005 C2* amendment item 2; S3 plan r2 §4.1, R2-R4).

  Four callbacks, none of which observes files, takes a lock or writes:

    * `attestation/0`: the calling process's ACTIVE registered snapshot, or
      `:none` when none is registered. Process-local; no file I/O, lock or
      database.
    * `live_binding?/2`: a plain database read (no lock clause, no file I/O),
      callable under the chain head. It re-validates the attestation against
      the process's active registration; any difference, lookup failure, or
      database name or oid mismatch is `false`. The tenant is compared
      separately.
    * `authorization/1`: a pure lookup in the compiled authorization registry.
    * `delegated_grant?/2`: pure over a loaded grant row: whether it carries
      the delegated provenance of that authorization.

  The shipped source is `SdrAgent.Agents.DemoException.Unattested`, hard-coded
  in `SdrAgent.Agents.DemoException.source/0`; no configuration selects
  another in dev or prod.
  """

  alias SdrAgent.Agents.DemoException.Attestation
  alias SdrAgent.Agents.DemoException.Authorization

  @callback attestation() :: {:ok, Attestation.t()} | :none
  @callback live_binding?(attestation :: Attestation.t(), tenant_id :: Ecto.UUID.t()) ::
              boolean()
  @callback authorization(id :: String.t()) :: {:ok, Authorization.t()} | :error
  @callback delegated_grant?(grant :: struct(), authorization :: Authorization.t()) ::
              boolean()
end
