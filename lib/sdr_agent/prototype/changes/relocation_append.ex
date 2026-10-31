defmodule SdrAgent.Prototype.Changes.RelocationAppend do
  @moduledoc """
  The order and identity rules of `SdrAgent.Prototype.RelocationEvent
  :append` (ADR-0024 decision 1; plan R2). A `before_action` hook, after
  authorization and inside the action's transaction: it takes the actor's
  tenant chain-head lock (`SdrAgent.Audit.Kernel.lock_head/1`; the `fenced`
  append is thereby serialized against every spending writer), reads the
  relocation (whose binding must belong to the actor's tenant) and its
  recorded events as plain kernel reads, checks the order rules of
  `allowed?/2`, reads the live database identity and requires it to be the
  relocation's `from_identity` for a source kind or its `to_identity` for
  a destination kind (`destination_kinds/0`). It then sets `identity` to
  that live identity and `recorded_by`. A failed rule is an
  `Ash.Error.Changes.InvalidAttribute` (`Ash.Error.Invalid`, no row); a
  returned read error is added as itself.

  The live identity is `SdrAgent.Prototype.Authority.live_identity/0`; in a
  build without the prototype authority it is unavailable (and the action's
  policy never passes there).
  """
  use Ash.Resource.Change

  require Ash.Query

  alias Ash.Error.Changes.InvalidAttribute
  alias SdrAgent.Audit.Kernel, as: AuditKernel
  alias SdrAgent.Prototype.CurrentAuthority
  alias SdrAgent.Prototype.Relocation
  alias SdrAgent.Prototype.RelocationEvent

  @destination_kinds [:restored, :activated, :destination_disabled]
  @recorded_by "kernel:relocation"

  @doc "The kinds written at the relocation's destination (`to_identity`)."
  @spec destination_kinds() :: [atom()]
  def destination_kinds, do: @destination_kinds

  @doc """
  Whether `kind` may follow the relocation's recorded kinds: planned
  first; writers_stopped, fenced, restored and activated each after its
  predecessor; one of each kind; destination_disabled after restored;
  aborted after planned and before activated, after destination_disabled
  when restored exists (never on an empty event chain); nothing after
  aborted or activated; no activated after destination_disabled.
  """
  @spec allowed?(atom(), [atom()]) :: boolean()
  def allowed?(kind, recorded) do
    cond do
      kind in recorded -> false
      :aborted in recorded or :activated in recorded -> false
      true -> follows?(kind, recorded)
    end
  end

  defp follows?(:planned, recorded), do: recorded == []
  defp follows?(:writers_stopped, recorded), do: :planned in recorded
  defp follows?(:fenced, recorded), do: :writers_stopped in recorded
  defp follows?(:restored, recorded), do: :fenced in recorded

  defp follows?(:activated, recorded),
    do: :restored in recorded and :destination_disabled not in recorded

  defp follows?(:destination_disabled, recorded), do: :restored in recorded

  defp follows?(:aborted, recorded),
    do:
      :planned in recorded and
        (:restored not in recorded or :destination_disabled in recorded)

  defp follows?(_kind, _recorded), do: false

  @impl true
  def change(changeset, _opts, context) do
    tenant_id = context.actor && context.actor.tenant_id
    Ash.Changeset.before_action(changeset, &check(&1, tenant_id))
  end

  defp check(changeset, tenant_id) do
    kind = Ash.Changeset.get_attribute(changeset, :kind)

    with :ok <- lock(tenant_id),
         {:ok, relocation} <-
           relocation(Ash.Changeset.get_attribute(changeset, :relocation_id), tenant_id),
         {:ok, recorded} <- recorded(relocation.id, tenant_id),
         :ok <- order(kind, recorded),
         {:ok, live} <- live_identity(),
         :ok <- side(kind, relocation, live) do
      changeset
      |> Ash.Changeset.force_change_attribute(:identity, live)
      |> Ash.Changeset.force_change_attribute(:recorded_by, @recorded_by)
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
      {:error, _reason} -> {:invalid, :relocation_id, "has no audit chain"}
    end
  end

  defp lock(_tenant_id), do: {:invalid, :relocation_id, "has no tenant"}

  defp relocation(relocation_id, tenant_id) do
    Relocation
    |> Ash.Query.for_read(:read, %{}, AuditKernel.opts(tenant_id))
    |> Ash.Query.filter(id == ^relocation_id and binding.tenant_id == ^tenant_id)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:invalid, :relocation_id, "is not this tenant's relocation"}
      {:ok, relocation} -> {:ok, relocation}
      {:error, error} -> {:error, error}
    end
  end

  defp recorded(relocation_id, tenant_id) do
    RelocationEvent
    |> Ash.Query.for_read(:read, %{}, AuditKernel.opts(tenant_id))
    |> Ash.Query.filter(relocation_id == ^relocation_id)
    |> Ash.read()
    |> case do
      {:ok, events} -> {:ok, Enum.map(events, & &1.kind)}
      {:error, error} -> {:error, error}
    end
  end

  defp order(kind, recorded) do
    if allowed?(kind, recorded),
      do: :ok,
      else: {:invalid, :kind, "is out of order for this relocation"}
  end

  defp side(kind, relocation, live) do
    expected =
      if kind in @destination_kinds,
        do: relocation.to_identity,
        else: relocation.from_identity

    if CurrentAuthority.normalize(expected) == CurrentAuthority.normalize(live),
      do: :ok,
      else: {:invalid, :kind, "is not written at this relocation's identity for the kind"}
  end

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    defp live_identity do
      case SdrAgent.Prototype.Authority.live_identity() do
        {:ok, live} -> {:ok, CurrentAuthority.normalize(live)}
        {:error, _unavailable} -> {:invalid, :kind, "has no live database identity"}
      end
    end
  else
    defp live_identity, do: {:invalid, :kind, "has no live database identity"}
  end
end
