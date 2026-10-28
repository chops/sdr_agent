defmodule SdrAgent.Prototype.DossierParser do
  @moduledoc """
  The bounded parser of the D-237 prospect dossier `sdr-agent.prototype-dossier`
  version 1 and its importable rule (interfaces r6 IF-6, contact-source ruling
  B, rulings 4-6). Built on `SdrAgent.Prototype.BoundedJson`; it never touches
  the network and never evaluates its input.

  - `read/2` reads the file once by its full sha256 (at most 256 KiB) and
    `parse/1` decodes it (container depth at most 7, duplicate keys refused at
    any depth before any conversion) and checks the exact key sets, the closed
    enums, the text rule, the URL rule, the honest source labels, the claim
    bases and attributions, the fact rules, the contact cross rules and the
    manifest-free part of the importable rule for every flagged row.
  - `eligibility/4` applies the whole importable rule to one row against the
    spot-check manifest (`SdrAgent.Prototype.SpotcheckManifest`) and the
    retained artifacts; `select/4` refuses a selection of more than 3 rows,
    an unknown or repeated row, or any row that is not eligible, before any
    write; `eligible_rows/3` lists the eligible rows (empty: "none qualify").
  - `import_plan/3` maps one eligible row to the values the import writes:
    the account, the person contact, the three claim records, the sources
    with verified excerpts only, and the targeting notes.

  Every refusal is `{:error, {path, rule}}` with a fixed schema path with
  indices (for example `companies[0].contact.evidence.email`) and a rule
  atom; no value is ever echoed.

  RED stage (D-237 S3): the API is the contract; every function returns
  `{:error, :not_implemented}`.
  """

  @doc "Reads the dossier at `path` once, by its full sha256, and parses it."
  @spec read(Path.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def read(_path, _sha256), do: red({:error, :not_implemented})

  @doc "Parses and validates dossier bytes; see the moduledoc."
  @spec parse(binary()) :: {:ok, map()} | {:error, term()}
  def parse(_bin), do: red({:error, :not_implemented})

  @doc "`:eligible` or `{:not_importable, reason}` for `row_id`, or a refusal of the file."
  @spec eligibility(map(), map(), String.t(), Path.t()) ::
          :eligible | {:not_importable, atom()} | {:error, term()}
  def eligibility(_dossier, _manifest, _row_id, _artifacts_dir),
    do: red({:error, :not_implemented})

  @doc "The selected rows, in selection order, when every one is eligible."
  @spec select(map(), map(), [String.t()], Path.t()) :: {:ok, [map()]} | {:error, term()}
  def select(_dossier, _manifest, _row_ids, _artifacts_dir), do: red({:error, :not_implemented})

  @doc "The ids of the flagged rows that are eligible (an empty list: none qualify)."
  @spec eligible_rows(map(), map(), Path.t()) :: {:ok, [String.t()]} | {:error, term()}
  def eligible_rows(_dossier, _manifest, _artifacts_dir), do: red({:error, :not_implemented})

  @doc "The import values of one eligible row; see the moduledoc."
  @spec import_plan(map(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def import_plan(_dossier, _manifest, _row_id), do: red({:error, :not_implemented})

  # RED stub result, typed dynamic() so success clauses of callers compile
  # against the stub (Elixir 1.20 infers literal returns); nothing sets the key.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
