defmodule SdrAgent.Agents.Changes.GrantBundle.Delegated do
  @moduledoc """
  The registered delegated-bundle context (C2* S2; plan
  `claude-c2star-s2-provisioning-plan-r1.md` §2 AC4 and §5; Codex Q3): the
  only authority under which a delegated grant's allocations are created.
  Modelled on `SdrAgent.Agents.ReleaseDecision.Prelocked`.

  `run(bindings, fun)` establishes a context for `bindings` (`tenant_id`,
  `grant_id`, `authorization_id`, `authorization_sha256`, `binding_sha256`)
  inside the open transaction and runs `fun.(context)`. It registers the
  context in the calling process for the duration of `run/2` (removed when
  `run/2` returns or raises) and sets a transaction-local marker,
  `set_config('<marker>', '1', true)`, with a name unique to the context,
  so a rollback to a savepoint taken before it clears it.

  `verify/1` accepts a context only in its own process and transaction,
  while it is registered, with every field equal to the registered one and
  its marker set: a hand-built struct, a tampered copy, a context used after
  `run/2` returned, or one used from another process is refused.

  `context/1` only packages a context for an allocation changeset
  (`context:`), as `SdrAgent.Agents.Checks.GrantContext.context/0` does for
  the owner-form bundle; it attests nothing. Whether the context authorizes
  a write is decided by `SdrAgent.Agents.Checks.DelegatedBundleContext`,
  which verifies it and compares it with the actual persisted parent grant.

  This is a trusted in-process convention: it proves nothing against
  arbitrary server code that calls `run/2` itself.
  """

  alias SdrAgent.Repo

  @enforce_keys [
    :ref,
    :tenant_id,
    :grant_id,
    :authorization_id,
    :authorization_sha256,
    :binding_sha256,
    :xact_id,
    :marker
  ]
  defstruct @enforce_keys

  @registry {__MODULE__, :registry}
  @context_key :sdr_agent_delegated_bundle

  @type t :: %__MODULE__{}

  @doc """
  Establishes the context for `bindings` in the open transaction and runs
  `fun.(context)`. Returns `fun`'s result, or `{:error, :not_in_transaction}`.
  """
  @spec run(map(), (t() -> result)) :: result | {:error, :not_in_transaction}
        when result: term()
  def run(
        %{
          tenant_id: tenant_id,
          grant_id: grant_id,
          authorization_id: authorization_id,
          authorization_sha256: authorization_sha256,
          binding_sha256: binding_sha256
        },
        fun
      )
      when is_binary(tenant_id) and is_binary(grant_id) and is_binary(authorization_id) and
             is_binary(authorization_sha256) and is_binary(binding_sha256) and
             is_function(fun, 1) do
    if Repo.in_transaction?() do
      marker = "sdr_delegated.c" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      Repo.query!("SELECT set_config($1, '1', true)", [marker])

      context = %__MODULE__{
        ref: make_ref(),
        tenant_id: tenant_id,
        grant_id: grant_id,
        authorization_id: authorization_id,
        authorization_sha256: authorization_sha256,
        binding_sha256: binding_sha256,
        xact_id: transaction_state(marker) |> elem(0),
        marker: marker
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

  @doc "The allocation changeset context carrying `context` (no attestation)."
  @spec context(t()) :: map()
  def context(context), do: %{@context_key => context}

  @doc "The delegated-bundle context an allocation changeset carries, if any."
  @spec carried(map()) :: term()
  def carried(changeset_context) when is_map(changeset_context),
    do: Map.get(changeset_context, @context_key)

  def carried(_changeset_context), do: nil

  @doc """
  `{:ok, registered}` when `context` is a registered context used in its own
  process and transaction, unchanged, with its marker set; otherwise
  `{:error, :delegated_context_refused}`.
  """
  @spec verify(term()) :: {:ok, t()} | {:error, :delegated_context_refused}
  def verify(%__MODULE__{ref: ref} = context) when is_reference(ref) do
    with %__MODULE__{} = registered <- Map.get(registry(), ref),
         true <- registered == context,
         true <- Repo.in_transaction?(),
         true <- transaction_state(registered.marker) == {registered.xact_id, "1"} do
      {:ok, registered}
    else
      _other -> {:error, :delegated_context_refused}
    end
  end

  def verify(_context), do: {:error, :delegated_context_refused}

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
