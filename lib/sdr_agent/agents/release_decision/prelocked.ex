defmodule SdrAgent.Agents.ReleaseDecision.Prelocked do
  @moduledoc """
  The private, transaction-scoped prelocked decision context (R0-07 round 5,
  contract (d); PASS at dc8cae7, clarification 4).

  The owning finalizer (R0-07 slice C, and run recovery) takes every
  dependent lock before the chain head — run, Operation, invocation, the
  current primary link, the selected gate cause — and then decides the
  release inside `run/2`. `SdrAgent.Agents.decide_result_release/2` given
  that context (`prelocked:`) reads its parents **without** a lock clause,
  so the finalization requests no row lock after the head.

  A context binds `tenant_id`, `model_invocation_id`, the optional
  `wire_witness_link_id` and `receipt_id` (the selected gate cause's
  Failure id), and the PostgreSQL transaction id it was established in. It
  is registered in the calling process only for the duration of `run/2`:
  the registration is removed when `run/2` returns or raises, and a
  rollback, commit or process exit ends its transaction, so no reference
  outlives the locks it vouches for. `verify/1` accepts it only in that
  process and transaction, while registered, and when every binding equals
  the registered one. A hand-built struct, a tampered copy, a leaked or
  stale context, or one used in another process is refused.

  This is a trusted in-process convention (like the kernel marker): it
  proves nothing against arbitrary server code, and no Boolean or
  row-shaped argument replaces it. Standalone decide (no context) always
  locks its parents before the head.
  """

  alias SdrAgent.Repo

  @enforce_keys [:ref, :tenant_id, :model_invocation_id, :xact_id]
  defstruct [
    :ref,
    :tenant_id,
    :model_invocation_id,
    :wire_witness_link_id,
    :receipt_id,
    :xact_id
  ]

  @registry {__MODULE__, :registry}

  @type t :: %__MODULE__{}

  @doc """
  Finalizer only: establishes the context for `bindings` (`tenant_id`,
  `model_invocation_id`, optional `wire_witness_link_id` and `receipt_id`)
  inside the open transaction, after every dependent lock is held, and runs
  `fun.(context)`. Returns `fun`'s result, or `{:error, :not_in_transaction}`.
  """
  @spec run(map(), (t() -> result)) :: result | {:error, :not_in_transaction} when result: term()
  def run(%{tenant_id: tenant_id, model_invocation_id: invocation_id} = bindings, fun)
      when is_binary(tenant_id) and is_binary(invocation_id) and is_function(fun, 1) do
    if Repo.in_transaction?() do
      context = %__MODULE__{
        ref: make_ref(),
        tenant_id: tenant_id,
        model_invocation_id: invocation_id,
        wire_witness_link_id: Map.get(bindings, :wire_witness_link_id),
        receipt_id: Map.get(bindings, :receipt_id),
        xact_id: xact_id()
      }

      register(context)

      try do
        fun.(context)
      after
        unregister(context.ref)
      end
    else
      {:error, :not_in_transaction}
    end
  end

  @doc """
  The registered context `context` stands for, when it is used in its own
  process and transaction, while registered, with every binding unchanged:
  `{:ok, registered}`, otherwise `{:error, :prelocked_context_refused}`.
  """
  @spec verify(term()) :: {:ok, t()} | {:error, :prelocked_context_refused}
  def verify(%__MODULE__{ref: ref} = context) when is_reference(ref) do
    with %__MODULE__{} = registered <- Map.get(registry(), ref),
         true <- registered == context,
         true <- Repo.in_transaction?(),
         true <- xact_id() == registered.xact_id do
      {:ok, registered}
    else
      _ -> {:error, :prelocked_context_refused}
    end
  end

  def verify(_context), do: {:error, :prelocked_context_refused}

  defp xact_id do
    %{rows: [[id]]} = Repo.query!("SELECT pg_current_xact_id()::text", [])
    id
  end

  defp registry, do: Process.get(@registry, %{})

  defp register(context), do: Process.put(@registry, Map.put(registry(), context.ref, context))

  defp unregister(ref) do
    case Map.delete(registry(), ref) do
      empty when empty == %{} -> Process.delete(@registry)
      rest -> Process.put(@registry, rest)
    end
  end
end
