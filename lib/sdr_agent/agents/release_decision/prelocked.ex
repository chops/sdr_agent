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
  rollback, commit or process exit ends its transaction. `verify/1` accepts
  it only in that process and transaction, while registered, when every
  binding equals the registered one, and while its database marker is set.
  A hand-built struct, a tampered copy, a leaked or stale context, or one
  used in another process is refused.

  **Savepoints (code review MF1).** A `ROLLBACK TO SAVEPOINT` keeps the
  transaction id and the process registration but releases every lock
  taken after that savepoint. So `run/2` also sets a transaction-local
  marker, `set_config('<marker>', '1', true)`, with a name unique to the
  context, and `verify/1` requires `current_setting('<marker>', true) =
  '1'`. PostgreSQL reverts a transaction-local setting when the
  subtransaction that set it is rolled back. The marker is set after every
  vouched lock is held, so a rollback that could release one of those
  locks targets a savepoint older than the marker and clears it; a rollback
  to a savepoint created after `run/2` began cannot release a lock taken
  before that savepoint, and the context stays valid. A rollback to a
  savepoint between the locks and `run/2` also clears the marker: refused,
  conservatively. The marker is not a capability against server code that
  sets it itself (a trusted in-process convention).

  This is a trusted in-process convention (like the kernel marker): it
  proves nothing against arbitrary server code, and no Boolean or
  row-shaped argument replaces it. Standalone decide (no context) always
  locks its parents before the head.

  **Demo-exception bindings (C2* S3 plan r2 §6; ADR-0005 C2* item 6).** The
  result-gate finalizer's exception branch also binds `finalizer:
  :result_gate`, the sorted `current_link_ids` it locked, the funding
  `grant_id` and `allocation_id` it locked and the attestation's
  `snapshot_generation`. The decision instant `decided_at` is never
  caller-supplied: for a `:result_gate` context `run/2` captures it itself
  (`SdrAgent.Clock.utc_now/0`), after every lock (the chain head included)
  is held; a `decided_at` binding that differs from that instant, or one
  given to any other context, is refused. Every other context binds none
  of these (nil).
  """

  alias SdrAgent.Clock
  alias SdrAgent.Repo

  @enforce_keys [:ref, :tenant_id, :model_invocation_id, :xact_id]
  defstruct [
    :ref,
    :tenant_id,
    :model_invocation_id,
    :wire_witness_link_id,
    :receipt_id,
    :xact_id,
    :marker,
    :finalizer,
    :current_link_ids,
    :grant_id,
    :allocation_id,
    :snapshot_generation,
    :decided_at
  ]

  @registry {__MODULE__, :registry}

  @type t :: %__MODULE__{}

  @doc """
  Finalizer only: establishes the context for `bindings` (`tenant_id`,
  `model_invocation_id`, optional `wire_witness_link_id` and `receipt_id`, and
  for the result-gate finalizer's exception branch the demo-exception
  bindings in the moduledoc) inside the open transaction, after every
  dependent lock is held, and runs `fun.(context)`. Returns `fun`'s result,
  `{:error, :not_in_transaction}`, or `{:error, :prelocked_context_refused}`
  for a caller-supplied `decided_at` other than the captured instant.
  """
  @spec run(map(), (t() -> result)) :: result | {:error, :not_in_transaction} when result: term()
  def run(%{tenant_id: tenant_id, model_invocation_id: invocation_id} = bindings, fun)
      when is_binary(tenant_id) and is_binary(invocation_id) and is_function(fun, 1) do
    decided_at = if Map.get(bindings, :finalizer) == :result_gate, do: Clock.utc_now()

    cond do
      not Repo.in_transaction?() ->
        {:error, :not_in_transaction}

      Map.get(bindings, :decided_at, decided_at) != decided_at ->
        {:error, :prelocked_context_refused}

      true ->
        register_and_run(bindings, decided_at, fun)
    end
  end

  defp register_and_run(bindings, decided_at, fun) do
    %{tenant_id: tenant_id, model_invocation_id: invocation_id} = bindings

    marker = "sdr_prelocked.c" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    Repo.query!("SELECT set_config($1, '1', true)", [marker])

    context = %__MODULE__{
      ref: make_ref(),
      tenant_id: tenant_id,
      model_invocation_id: invocation_id,
      wire_witness_link_id: Map.get(bindings, :wire_witness_link_id),
      receipt_id: Map.get(bindings, :receipt_id),
      xact_id: transaction_state(marker) |> elem(0),
      marker: marker,
      finalizer: Map.get(bindings, :finalizer),
      current_link_ids: Map.get(bindings, :current_link_ids),
      grant_id: Map.get(bindings, :grant_id),
      allocation_id: Map.get(bindings, :allocation_id),
      snapshot_generation: Map.get(bindings, :snapshot_generation),
      decided_at: decided_at
    }

    register(context)

    try do
      fun.(context)
    after
      unregister(context.ref)
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
         true <- transaction_state(registered.marker) == {registered.xact_id, "1"} do
      {:ok, registered}
    else
      _ -> {:error, :prelocked_context_refused}
    end
  end

  def verify(_context), do: {:error, :prelocked_context_refused}

  # The current transaction id and the context's marker, in one query (no
  # lock clause). A missing marker reads as nil or "".
  defp transaction_state(marker) do
    %{rows: [[id, value]]} =
      Repo.query!("SELECT pg_current_xact_id()::text, current_setting($1, true)", [marker])

    {id, value}
  rescue
    _aborted -> {nil, nil}
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
