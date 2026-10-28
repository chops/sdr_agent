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

  `prepare/5` is pure: `DossierParser.select/4` (which validates EVERY
  flagged row, selected or not, and refuses the whole input on any), then
  `DossierParser.import_plan/4` per selected row, composed and never
  re-implemented. Rows keep the selection order, each row's original index
  in the dossier, and the exact dossier and manifest digests; a parser
  refusal is returned unchanged. No database, network, evaluation or write;
  only the parser's own bounded artifact reads.

  Stage (D-237 S3): the caller checks and `prepare/5` are implemented; the
  writes still return `{:error, :not_implemented}` (`cap_used/1` returns 0,
  never a measured cap) until their own RED and prerequisites.
  """

  alias SdrAgent.Prototype
  alias SdrAgent.Prototype.DossierParser

  @doc "The import rows of `row_ids` (at most 3), or the parser's refusal."
  @spec prepare(map(), String.t(), map(), [String.t()], Path.t()) ::
          {:ok, [map()]} | {:error, term()}
  def prepare(dossier, dossier_sha256, manifest, row_ids, artifacts_dir) do
    with {:ok, rows} <- DossierParser.select(dossier, manifest, row_ids, artifacts_dir) do
      collect(rows, &prepared(&1, dossier, dossier_sha256, manifest, artifacts_dir))
    end
  end

  defp prepared(row, dossier, dossier_sha256, manifest, artifacts_dir) do
    row_id = row["row_id"]

    with {:ok, plan} <- DossierParser.import_plan(dossier, manifest, row_id, artifacts_dir) do
      {:ok,
       %{
         row_id: row_id,
         row_index: Enum.find_index(dossier["companies"], &(&1["row_id"] == row_id)),
         dossier_sha256: dossier_sha256,
         spotcheck_sha256: manifest.sha256,
         plan: plan
       }}
    end
  end

  # {:ok, values} in input order, or the first error unchanged.
  defp collect(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

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
