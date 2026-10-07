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

  An auditor's mutation attempt is refused here before the action runs (so
  even an invalid attempt is denied and audited); the per-resource auditor
  guard policies refuse it again if the action is reached another way.

  Guarded calls may run inside a transaction only when it was opened with
  `SdrAgent.Audit.transaction/1`, which flushes queued denials when it ends;
  inside any other transaction they raise `ArgumentError` up front.
  """

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

    result =
      if auditor?(actor) and meta.action not in @auditor_exempt,
        do: {:error, Ash.Error.Forbidden.exception([])},
        else: fun.()

    with {:error, %Ash.Error.Forbidden{}} <- result,
         true <- audit_denial?(meta, actor) do
      deny(meta, actor)
    end

    result
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
