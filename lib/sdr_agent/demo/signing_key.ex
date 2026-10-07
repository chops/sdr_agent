defmodule SdrAgent.Demo.SigningKey do
  @moduledoc """
  Registers the pinned audit-anchor **public** key for the local demo
  (`bin/demo seed`, S13c), so anchoring works after `bin/demo reset`.
  Without a registered active key the AnchorWorker retries with
  `{:error, :no_active_signing_key}`.

  It reads only `docs/audit/anchor-signing-key.pub` (public key, key id and
  lifecycle; ADR-0005) and registers it through
  `SdrAgent.Audit.register_signing_key/2` — the audited kernel path
  `mix sdr.audit.register_key` uses. No private key material is read.

  It fails closed and never rewrites trust data:

    * only where demo seeding is allowed (`seeding_allowed?`, dev/test;
      `{:error, :demo_not_allowed}`), checked before anything is read or
      written;
    * only an **active** pin is registered (`{:error, {:pin_not_active,
      status}}` for a rotated or revoked file) — a reset database never turns
      a retired key into a trust root;
    * the registry must hold exactly the pin: a row with the pin's key id
      but other public bytes is `{:error, :pinned_key_mismatch}`, an inactive
      row for it `{:error, {:pinned_key_inactive, status}}` (immutable
      lifecycle: never reactivated or re-registered), and another key already
      active `{:error, :another_key_active}`.

  Idempotent for the single-writer demo path: the exact active pin already
  registered is `{:ok, :already_registered}` and writes nothing. (Two
  concurrent calls are not reconciled: the key's unique identities refuse
  the second registration, which then returns that error.)
  """

  alias SdrAgent.Actor
  alias SdrAgent.Audit
  alias SdrAgent.Audit.AuditSigningKey
  alias SdrAgent.Audit.Checks.SeedingAllowed
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Audit.TrustedKey

  @pinned "docs/audit/anchor-signing-key.pub"

  @doc "Registers the active pinned public key unless exactly it is registered. See the moduledoc."
  @spec ensure() :: {:ok, :registered | :already_registered} | {:error, term()}
  def ensure do
    with :ok <- allowed(),
         {:ok, pinned} <- active_pin(),
         {:ok, tenant_id} <- Kernel.singleton_tenant_id() do
      case state(pinned) do
        :registered -> {:ok, :already_registered}
        :absent -> register(pinned, tenant_id)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  The registry's state for the pin: `:registered` (exactly the active pin),
  `:absent`, or `{:error, reason}` (an inactive or unreadable pin, a
  mismatched or inactive row, another active key). Read-only.
  """
  @spec status() :: :registered | :absent | {:error, term()}
  def status do
    with {:ok, pinned} <- active_pin(), do: state(pinned)
  end

  @doc "Whether exactly the active pinned key is registered and active."
  @spec registered?() :: boolean()
  def registered?, do: status() == :registered

  @doc "The registered signing keys (public data only)."
  @spec keys() :: [struct()]
  def keys do
    AuditSigningKey
    |> Ash.Query.for_read(:read, %{}, Kernel.opts())
    |> Ash.read!()
  end

  defp allowed do
    if SeedingAllowed.allowed?(), do: :ok, else: {:error, :demo_not_allowed}
  end

  defp active_pin do
    case TrustedKey.load(@pinned) do
      {:ok, %{status: :active} = pinned} -> {:ok, pinned}
      {:ok, %{status: status}} -> {:error, {:pin_not_active, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp state(pinned) do
    keys = keys()

    case Enum.find(keys, &(&1.key_id == pinned.key_id)) do
      %{public_key: bytes} when bytes != pinned.public_key ->
        {:error, :pinned_key_mismatch}

      %{status: :active} ->
        :registered

      %{status: status} ->
        {:error, {:pinned_key_inactive, status}}

      nil ->
        if Enum.any?(keys, &(&1.status == :active)),
          do: {:error, :another_key_active},
          else: :absent
    end
  end

  defp register(pinned, tenant_id) do
    case Audit.register_signing_key(%{key_id: pinned.key_id, public_key: pinned.public_key},
           actor: Actor.system(:kernel, tenant_id)
         ) do
      {:ok, _key} -> {:ok, :registered}
      {:error, error} -> {:error, error}
    end
  end
end
