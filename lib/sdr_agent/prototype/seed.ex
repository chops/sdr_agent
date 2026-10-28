defmodule SdrAgent.Prototype.Seed do
  @moduledoc """
  Writes the D-237 GTM seed (interfaces r6 IF-7; supplement 1 r2 §3-§4,
  Codex R5-R7) as the acting prototype operator, in one transaction, from
  the validated `SdrAgent.Prototype.SeedDir.read/2` result; returns ids and
  digests only.

  `run/2` first re-checks the caller, before any write: prototype runtime
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

  @doc "Writes or replays the seed; see the moduledoc."
  @spec run(map(), SdrAgent.Actor.t()) :: {:ok, map()} | {:error, atom()}
  def run(seed, actor) do
    with :ok <- live(actor), do: write(seed, actor)
  end

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
