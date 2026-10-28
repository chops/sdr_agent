# Compiled only with the D-237 prototype authority (config/dev.exs and
# config/test.exs); the production build does not contain this module.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.Seed do
    @moduledoc """
    Writes the D-237 GTM seed (interfaces r6 IF-7; supplement 1 r2 §3-§4,
    Codex R5-R7) as the acting prototype operator, in one transaction, from
    the validated `SdrAgent.Prototype.SeedDir.read/2` result; returns ids and
    digests only.

    `run/2` owns its one transaction (seed design D3), so a call inside an
    already-open transaction (a Repo or `SdrAgent.Audit.transaction/1`
    caller) is refused with `{:error, :seed_failed}` first, before any query:
    before the runtime, actor and live checks below, and before any read or
    write. That caller's transaction stays usable. The sole callers (setup
    phase 3 after the phase-2 commit, and the seed task) call it at top
    level.

    Then `run/2` re-checks the caller, before any write: prototype runtime
    (`:not_prototype_runtime`), the live binding (`SdrAgent.Prototype.check_live/0`,
    `:binding_mismatch`) and the live operator
    (`SdrAgent.Prototype.operator_actor/1`, called fresh, must resolve the
    actor's own delegation to exactly the same actor; anything else is
    `:forbidden`). Codes only.

    GREEN-2a stage (D-237 S3): the caller check is implemented; the write
    itself still returns `{:error, :not_implemented}` until S1's
    `:store_prototype_input` scope and OperatorAction exist.
    """

    alias SdrAgent.Prototype
    alias SdrAgent.Repo

    @doc """
    Writes or replays the seed; see the moduledoc. Inside an already-open
    transaction it is `{:error, :seed_failed}` before any query.
    """
    @spec run(map(), SdrAgent.Actor.t()) :: {:ok, map()} | {:error, atom()}
    def run(seed, actor) do
      with :ok <- not_nested(),
           :ok <- live(actor),
           do: write(seed, actor)
    end

    # Seed design D3: the seed owns its one transaction, so an open caller
    # transaction (a nested Repo or Audit transaction is not a savepoint) is
    # refused before any query, and that transaction stays usable.
    defp not_nested, do: if(Repo.in_transaction?(), do: {:error, :seed_failed}, else: :ok)

    # The fresh real resolver must return exactly this actor (type, delegation
    # id and tenant), after the live binding check; nothing is taken from the
    # map or its type alone.
    defp live(%SdrAgent.Actor{type: :prototype_operator, id: id, tenant_id: tenant_id} = actor)
         when is_binary(id) and is_binary(tenant_id) do
      with :prototype <- Prototype.runtime(),
           :ok <- Prototype.check_live(),
           {:ok, ^actor} <- Prototype.operator_actor(id) do
        :ok
      else
        :ordinary -> {:error, :not_prototype_runtime}
        {:error, :binding_mismatch} -> {:error, :binding_mismatch}
        {:error, :not_prototype_runtime} -> {:error, :not_prototype_runtime}
        _ -> {:error, :forbidden}
      end
    end

    defp live(_actor) do
      if Prototype.runtime() == :prototype,
        do: {:error, :forbidden},
        else: {:error, :not_prototype_runtime}
    end

    defp write(_seed, _actor), do: red({:error, :not_implemented})

    # RED stub result, typed dynamic() so success clauses of callers compile
    # against the stub (Elixir 1.20 infers literal returns); nothing sets the key.
    defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
  end
end
