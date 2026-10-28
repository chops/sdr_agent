defmodule SdrAgent.Prototype.DossierImport do
  @moduledoc """
  The above-domain import coordinator of D-237 dossier rows (interfaces r6
  IF-6; supplement 1 r2 §5, Codex R9): `prepare/5`, `import/2`,
  `import_row/2` and `cap_used/1`; one transaction per row under the
  binding lock, the authoritative cap recheck, idempotent replay and
  explicit rollback.

  RED stage (D-237 S3): the API is the contract; every function returns
  `{:error, :not_implemented}` (`cap_used/1` returns 0).
  """

  @doc "The import rows of `row_ids` (at most 3), or the parser's refusal."
  @spec prepare(map(), String.t(), map(), [String.t()], Path.t()) ::
          {:ok, [map()]} | {:error, term()}
  def prepare(_dossier, _sha256, _manifest, _row_ids, _dir), do: red({:error, :not_implemented})

  @doc "Imports `rows` in order."
  @spec import([map()], SdrAgent.Actor.t()) :: {:ok, map()} | {:error, term()}
  def import(_rows, _actor), do: red({:error, :not_implemented})

  @doc "Imports one row in one transaction."
  @spec import_row(map(), SdrAgent.Actor.t()) :: {:ok, atom(), map()} | {:error, atom()}
  def import_row(_row, _actor), do: red({:error, :not_implemented})

  @doc "Distinct imported contacts of the binding."
  @spec cap_used(SdrAgent.Actor.t()) :: non_neg_integer()
  def cap_used(_actor), do: red(0)

  # RED stub result, typed dynamic() so success clauses of callers compile
  # against the stub (Elixir 1.20 infers literal returns); nothing sets the key.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
