defmodule SdrAgent.Agents.DemoException.Attestation do
  @moduledoc """
  What a `SdrAgent.Agents.DemoException.Source` reports about the calling
  process's active operation snapshot (ADR-0005 C2* amendment item 2; S3
  plan r2 §4.1).

  Only a Source implementation builds it, from the process's active
  registration. A caller-built value is never authority: the decision and
  use checks re-validate it through `c:SdrAgent.Agents.DemoException.Source.live_binding?/2`.

    * `generation` and `observed_at`: the snapshot's per-VM generation and
      observation instant.
    * `environment_id`: the attested agent environment.
    * `level`: `:none`, `:provisioning` or `:spend_ready`. Spend-ready and
      `agentenv-1` are necessary for a demo exception, never sufficient.
    * `environment_binding_sha256`: lowercase hex-64 of the environment
      binding.
    * `tenant_id`: the binding's tenant.
    * `authorization`: nil, or `%{id, entry_sha256, grant_id}`, where
      `entry_sha256` is the compiled authorization REGISTRY ENTRY digest,
      never the authorization file's digest.
  """

  @enforce_keys [
    :generation,
    :observed_at,
    :environment_id,
    :level,
    :environment_binding_sha256,
    :tenant_id
  ]
  defstruct [
    :generation,
    :observed_at,
    :environment_id,
    :level,
    :environment_binding_sha256,
    :tenant_id,
    authorization: nil
  ]

  @type level :: :none | :provisioning | :spend_ready

  @type t :: %__MODULE__{
          generation: non_neg_integer(),
          observed_at: DateTime.t(),
          environment_id: String.t(),
          level: level(),
          environment_binding_sha256: String.t(),
          tenant_id: Ecto.UUID.t(),
          authorization:
            nil | %{id: String.t(), entry_sha256: String.t(), grant_id: Ecto.UUID.t()}
        }
end
