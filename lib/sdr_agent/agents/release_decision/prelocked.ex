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
  Failure id), the optional `finalizer` (D-237 IF-4: `:prototype_gate` only
  for the prototype gate's own context, `SdrAgent.Prototype.Release`; nil
  otherwise; any other value is refused), and the PostgreSQL transaction id
  it was established in. It
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
  """

  alias SdrAgent.Repo

  @enforce_keys [:ref, :tenant_id, :model_invocation_id, :xact_id]
  defstruct [
    :ref,
    :tenant_id,
    :model_invocation_id,
    :wire_witness_link_id,
    :receipt_id,
    :finalizer,
    :xact_id,
    :marker
  ]

  @registry {__MODULE__, :registry}
  # D-237 IF-4: the only finalizer binding a context may carry (nil for an
  # ordinary context).
  @finalizers [nil, :prototype_gate]

  @type t :: %__MODULE__{}

  @doc """
  Finalizer only: establishes the context for `bindings` (`tenant_id`,
  `model_invocation_id`, optional `wire_witness_link_id`, `receipt_id` and
  `finalizer`) inside the open transaction, after every dependent lock is
  held, and runs `fun.(context)`. Returns `fun`'s result,
  `{:error, :invalid_finalizer}` for a `finalizer` other than nil or
  `:prototype_gate` (D-237 IF-4: only the prototype gate's own context
  may decide `released_unverified`; `fun` does not run), or
  `{:error, :not_in_transaction}`.
  """
  @spec run(map(), (t() -> result)) ::
          result | {:error, :invalid_finalizer | :not_in_transaction}
        when result: term()
  def run(%{tenant_id: tenant_id, model_invocation_id: invocation_id} = bindings, fun)
      when is_binary(tenant_id) and is_binary(invocation_id) and is_function(fun, 1) do
    finalizer = Map.get(bindings, :finalizer)

    cond do
      finalizer not in @finalizers -> {:error, :invalid_finalizer}
      Repo.in_transaction?() -> establish(bindings, finalizer, fun)
      true -> {:error, :not_in_transaction}
    end
  end

  defp establish(bindings, finalizer, fun) do
    %{tenant_id: tenant_id, model_invocation_id: invocation_id} = bindings

    marker = "sdr_prelocked.c" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    Repo.query!("SELECT set_config($1, '1', true)", [marker])

    context = %__MODULE__{
      ref: make_ref(),
      tenant_id: tenant_id,
      model_invocation_id: invocation_id,
      wire_witness_link_id: Map.get(bindings, :wire_witness_link_id),
      receipt_id: Map.get(bindings, :receipt_id),
      finalizer: finalizer,
      xact_id: transaction_state(marker) |> elem(0),
      marker: marker
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
