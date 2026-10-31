defmodule SdrAgent.Audit.Guard do
  @moduledoc """
  The audit kernel's guard around domain code interfaces (S2 "Denial audit
  contract").

  `run/3` executes a domain call. When the call is refused with
  `Ash.Error.Forbidden` and either the action is a *guarded action* or the
  actor is an auditor (AUR), exactly one `authz.denied` event is appended —
  *after* the outermost transaction has finished (commit or rollback), never
  from inside it, so the denial neither deadlocks on the chain-head lock nor
  rolls back with the refused write. The append goes straight to the kernel
  (no domain action, no policy evaluation), so it cannot recurse.

  A result carrying the relocation fence's refusal
  (`SdrAgent.Audit.RelocationFenced`) is returned as the plain
  `{:error, :relocation_fenced}` and is never a denial.

  An auditor's mutation attempt is refused here before the action runs (so
  even an invalid attempt is denied and audited); the per-resource auditor
  guard policies refuse it again if the action is reached another way.

  Guarded calls may run inside a transaction only when it was opened with
  `SdrAgent.Audit.transaction/1`, which flushes queued denials when it ends;
  inside any other transaction they raise `ArgumentError` up front.

  `refuse/2` is a closed refusal decided before any changeset (a domain
  precheck): through `run/3`, so audited exactly once, only for a
  well-formed actor whose tenant has an initialized audit chain; any other
  input is refused with no append, so no audit destination comes from
  unvalidated input.
  """

  require Ash.Query

  alias SdrAgent.Audit.AuditChainHead
  alias SdrAgent.Audit.AuditEvent
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Repo

  @queue {__MODULE__, :queue}
  # Read-like actions an auditor may call (S2 "Auditor (AUR) contract").
  @auditor_exempt [:read_content, :verify_chain, :create_export]

  @doc """
  Runs `fun` for `meta` (`%{resource:, action:, guarded?:, subject_id:}`) on
  behalf of `actor`, auditing a qualifying denial.
  """
  def run(meta, actor, fun) do
    if Repo.in_transaction?() and is_nil(Process.get(@queue)) do
      raise ArgumentError,
            "guarded action #{inspect(meta.resource)}.#{meta.action} called inside a " <>
              "transaction not opened by SdrAgent.Audit.transaction/1"
    end

    # ADR-0024 decision 1: a relocation-fenced append surfaces as the plain
    # `{:error, :relocation_fenced}` (never a denial).
    result =
      if auditor?(actor) and meta.action not in @auditor_exempt,
        do: {:error, Ash.Error.Forbidden.exception([])},
        else: SdrAgent.Audit.RelocationFenced.normalize(fun.())

    with {:error, %Ash.Error.Forbidden{}} <- result,
         true <- audit_denial?(meta, actor) do
      deny(meta, actor)
    end

    result
  end

  @doc """
  Refuses a call for `meta` before it runs: `{:error, Ash.Error.Forbidden}`.
  For a well-formed `SdrAgent.Actor` (a known type, a nil or non-empty
  UTF-8 id of at most 128 bytes with no NUL) or `SdrAgent.Accounts.User` (a canonical
  UUID id, a role an audit event can record) whose canonical tenant UUID
  has an initialized audit chain, the refusal goes through `run/3` (one
  `authz.denied` when `meta` is guarded or the actor is an auditor);
  missing, non-actor, malformed or unknown-tenant input appends nothing. A failed
  chain read raises; it is never treated as a destination.
  """
  def refuse(meta, actor) do
    forbidden = fn -> {:error, Ash.Error.Forbidden.exception([])} end
    if destination?(actor), do: run(meta, actor, forbidden), else: forbidden.()
  end

  # A destination needs a kernel-safe actor envelope first (Codex e976f58a
  # R1): only values an audit event can record, never coerced, and only then
  # a canonical tenant UUID with an initialized chain head. A malformed
  # envelope is the plain refusal: it never reaches the kernel.
  defp destination?(%SdrAgent.Actor{type: type, id: id, tenant_id: tenant_id}) do
    type in SdrAgent.Actor.types() and actor_id?(id) and chain_initialized?(tenant_id)
  end

  defp destination?(%SdrAgent.Accounts.User{id: id, role: role, tenant_id: tenant_id}) do
    uuid?(id) and role in auditable_roles() and chain_initialized?(tenant_id)
  end

  defp destination?(_actor), do: false

  # The kernel records a system actor id as `to_string(id || type)`: nil, or
  # a non-empty valid UTF-8 string of at most 128 bytes with no NUL
  # (PostgreSQL text and jsonb cannot store U+0000; Codex 67ff29f5 R1a).
  defp actor_id?(nil), do: true

  defp actor_id?(id) when is_binary(id),
    do: byte_size(id) in 1..128 and String.valid?(id) and not String.contains?(id, <<0>>)

  defp actor_id?(_id), do: false

  # The roles an audit event can record (`AuditEvent.actor_role`).
  defp auditable_roles,
    do: Ash.Resource.Info.attribute(AuditEvent, :actor_role).constraints[:one_of]

  # A canonical UUID string only (a raw 16-byte binary also casts).
  defp uuid?(id) when is_binary(id) and byte_size(id) == 36, do: Ecto.UUID.cast(id) == {:ok, id}
  defp uuid?(_id), do: false

  defp chain_initialized?(tenant_id) do
    uuid?(tenant_id) and
      AuditChainHead
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
      |> Ash.Query.filter(tenant_id == ^tenant_id)
      |> Ash.exists?()
  end

  @doc "Transaction that defers denial appends until it has finished."
  def transaction(fun) do
    if Process.get(@queue) do
      Repo.transaction(fun)
    else
      Process.put(@queue, [])

      try do
        Repo.transaction(fun)
      after
        @queue |> Process.delete() |> Enum.reverse() |> Enum.each(&append!/1)
      end
    end
  end

  defp audit_denial?(meta, actor), do: Map.get(meta, :guarded?, false) or auditor?(actor)

  defp auditor?(%SdrAgent.Actor{}), do: false
  defp auditor?(%{role: :auditor}), do: true
  defp auditor?(_actor), do: false

  defp deny(meta, actor) do
    case Process.get(@queue) do
      nil -> append!({meta, actor})
      queue -> Process.put(@queue, [{meta, actor} | queue])
    end
  end

  defp append!({meta, actor}) do
    {:ok, _event} = Kernel.append_denial(meta, actor)
    :ok
  end
end
