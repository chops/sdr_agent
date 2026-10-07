defmodule SdrAgent.Demo.SigningKey do
  @moduledoc """
  Registers the pinned audit-anchor **public** key for the local demo
  (`bin/demo seed`, S13c), so anchoring works after `bin/demo reset`.
  Without a registered active key the AnchorWorker retries with
  `{:error, :no_active_signing_key}`.

  It reads only `docs/audit/anchor-signing-key.pub` (public key and key id;
  ADR-0005) and registers it through `SdrAgent.Audit.register_signing_key/2`
  — the audited kernel path `mix sdr.audit.register_key` uses. No private
  key material is read. Idempotent: an already registered key is left as it
  is and nothing is written.
  """

  alias SdrAgent.Actor
  alias SdrAgent.Audit
  alias SdrAgent.Audit.AuditSigningKey
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Audit.TrustedKey

  @pinned "docs/audit/anchor-signing-key.pub"

  @doc "Registers the pinned public key unless it is already registered."
  @spec ensure() :: {:ok, :registered | :already_registered} | {:error, term()}
  def ensure do
    with {:ok, pinned} <- TrustedKey.load(@pinned),
         {:ok, tenant_id} <- Kernel.singleton_tenant_id() do
      if registered?(pinned.key_id) do
        {:ok, :already_registered}
      else
        register(pinned, tenant_id)
      end
    end
  end

  @doc "Whether the pinned key is registered and active."
  @spec registered?() :: boolean()
  def registered? do
    case TrustedKey.load(@pinned) do
      {:ok, pinned} -> registered?(pinned.key_id)
      _ -> false
    end
  end

  @doc "The registered signing keys (public data only)."
  @spec keys() :: [struct()]
  def keys do
    AuditSigningKey
    |> Ash.Query.for_read(:read, %{}, Kernel.opts())
    |> Ash.read!()
  end

  defp registered?(key_id), do: Enum.any?(keys(), &(&1.key_id == key_id and &1.status == :active))

  defp register(pinned, tenant_id) do
    case Audit.register_signing_key(%{key_id: pinned.key_id, public_key: pinned.public_key},
           actor: Actor.system(:kernel, tenant_id)
         ) do
      {:ok, _key} -> {:ok, :registered}
      {:error, error} -> {:error, error}
    end
  end
end
