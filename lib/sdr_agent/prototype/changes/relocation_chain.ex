defmodule SdrAgent.Prototype.Changes.RelocationChain do
  @moduledoc """
  The chain rules of `SdrAgent.Prototype.Relocation :create` (ADR-0024
  decision 1; plan R2). A `before_action` hook, after authorization and
  inside the action's transaction: it takes the actor's tenant chain-head
  lock (`SdrAgent.Audit.Kernel.lock_head/1`), reads the binding (which must
  belong to the actor's tenant) and its relocation chain as plain kernel
  reads, and requires `relocation_seq` to be
  `SdrAgent.Prototype.CurrentAuthority.next_seq/1`, `from_identity` to be
  the chain's current authority and `to_identity` to differ from it. A
  failed rule is an `Ash.Error.Changes.InvalidAttribute` (the action is
  `Ash.Error.Invalid` and writes nothing); a returned read error is added
  as itself.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias Ash.Error.Changes.InvalidAttribute
  alias SdrAgent.Audit.Kernel, as: AuditKernel
  alias SdrAgent.Operations.PrototypeDatabaseBinding
  alias SdrAgent.Prototype.CurrentAuthority
  alias SdrAgent.Prototype.Relocation

  @impl true
  def change(changeset, _opts, context) do
    tenant_id = context.actor && context.actor.tenant_id
    Ash.Changeset.before_action(changeset, &check(&1, tenant_id))
  end

  defp check(changeset, tenant_id) do
    with :ok <- lock(tenant_id),
         {:ok, binding} <- binding(Ash.Changeset.get_attribute(changeset, :binding_id), tenant_id),
         {:ok, chain} <- Relocation.chain(binding.id, tenant_id),
         :ok <- seq(Ash.Changeset.get_attribute(changeset, :relocation_seq), chain),
         :ok <- identities(changeset, chain, binding) do
      changeset
    else
      {:invalid, field, message} ->
        Ash.Changeset.add_error(
          changeset,
          InvalidAttribute.exception(field: field, message: message)
        )

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  defp lock(tenant_id) when is_binary(tenant_id) do
    case AuditKernel.lock_head(tenant_id) do
      {:ok, _head} -> :ok
      {:error, %{} = error} -> {:error, error}
      {:error, _reason} -> {:invalid, :binding_id, "has no audit chain"}
    end
  end

  defp lock(_tenant_id), do: {:invalid, :binding_id, "has no tenant"}

  defp binding(binding_id, tenant_id) do
    PrototypeDatabaseBinding
    |> Ash.Query.for_read(:read, %{}, AuditKernel.opts(tenant_id))
    |> Ash.Query.filter(id == ^binding_id and tenant_id == ^tenant_id)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:invalid, :binding_id, "is not this tenant's binding"}
      {:ok, binding} -> {:ok, binding}
      {:error, error} -> {:error, error}
    end
  end

  defp seq(seq, chain) do
    if seq == CurrentAuthority.next_seq(chain),
      do: :ok,
      else: {:invalid, :relocation_seq, "is not the chain's next relocation_seq"}
  end

  defp identities(changeset, chain, binding) do
    original = CurrentAuthority.normalize(binding)
    from = CurrentAuthority.normalize(Ash.Changeset.get_attribute(changeset, :from_identity))
    to = CurrentAuthority.normalize(Ash.Changeset.get_attribute(changeset, :to_identity))

    case CurrentAuthority.identity(chain, original) do
      {:ok, ^from} when to != from -> :ok
      {:ok, ^from} -> {:invalid, :to_identity, "is the source identity"}
      {:ok, _other} -> {:invalid, :from_identity, "is not the current authority"}
      {:error, :chain_invalid} -> {:invalid, :binding_id, "has an invalid relocation chain"}
    end
  end
end
