defmodule SdrAgent.Prototype.DossierImport do
  @moduledoc """
  The above-domain import coordinator of D-237 dossier rows (interfaces r6
  IF-6; supplement 1 r2 §5, Codex R9): `prepare/5`, `import/2`,
  `import_row/2` and `cap_used/1`; one transaction per row under the
  binding lock, the authoritative cap recheck, idempotent replay and
  explicit rollback.

  Both write entries, `import/2` and `import_row/2`, first re-check the
  caller, before any write: prototype runtime (`:not_prototype_runtime`),
  the live binding (`SdrAgent.Prototype.check_live/0`, `:binding_mismatch`)
  and the live operator (`SdrAgent.Prototype.operator_actor/1`, called
  fresh, must resolve the actor's own delegation to exactly the same actor;
  anything else is `:forbidden`). An empty `rows` list is no bypass: the
  caller is checked first. `import/2` reports a refusal as `{:error, %{code:,
  failed_row: nil, imported: [], replayed: []}}`, `import_row/2` as
  `{:error, code}`. Codes only.

  GREEN-2a stage (D-237 S3): the caller checks are implemented; `prepare/5`
  and the writes still return `{:error, :not_implemented}` (`cap_used/1`
  returns 0) until S1's `:store_prototype_input` scope, the Research
  `record_*` names and OperatorAction exist.
  """

  alias SdrAgent.Prototype

  @doc "The import rows of `row_ids` (at most 3), or the parser's refusal."
  @spec prepare(map(), String.t(), map(), [String.t()], Path.t()) ::
          {:ok, [map()]} | {:error, term()}
  def prepare(_dossier, _sha256, _manifest, _row_ids, _dir), do: red({:error, :not_implemented})

  @doc "Imports `rows` in order; see the moduledoc."
  @spec import([map()], SdrAgent.Actor.t()) :: {:ok, map()} | {:error, term()}
  def import(rows, actor) when is_list(rows) do
    case live(actor) do
      :ok -> import_rows(rows, actor)
      {:error, code} -> {:error, %{code: code, failed_row: nil, imported: [], replayed: []}}
    end
  end

  @doc "Imports one row in one transaction; see the moduledoc."
  @spec import_row(map(), SdrAgent.Actor.t()) :: {:ok, atom(), map()} | {:error, atom()}
  def import_row(row, actor) do
    with :ok <- live(actor), do: write_row(row, actor)
  end

  @doc "Distinct imported contacts of the binding."
  @spec cap_used(SdrAgent.Actor.t()) :: non_neg_integer()
  def cap_used(_actor), do: red(0)

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

  defp import_rows(_rows, _actor), do: red({:error, :not_implemented})
  defp write_row(_row, _actor), do: red({:error, :not_implemented})

  # RED stub result, typed dynamic() so success clauses of callers compile
  # against the stub (Elixir 1.20 infers literal returns); nothing sets the key.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
