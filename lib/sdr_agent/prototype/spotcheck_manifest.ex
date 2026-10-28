defmodule SdrAgent.Prototype.SpotcheckManifest do
  @moduledoc """
  The bounded parser of the D-237 spot-check manifest
  `sdr-agent.prototype-spotcheck` version 1 (interfaces r6 IF-6), bound to one
  parsed dossier. Built on `SdrAgent.Prototype.BoundedJson`; no network, no
  evaluation.

  - `read/3` reads the manifest once by its full sha256 (at most 64 KiB) and
    `parse/3` decodes it (container depth at most 3) and checks it against
    the parsed dossier and the dossier's sha256: the exact key sets and
    enums, `dossier_sha256`, the checker pattern, RFC 3339 times with an
    offset, and each result's identity `(row_id, item)`. The whole manifest
    is refused on an unknown row or item, a `source_id` or `final_url` that
    is not exactly that claim's or fact's source, a duplicate
    `(row_id, item)` whatever its status, or a relation on the wrong item.
  - It returns `%{sha256:, checker:, results: %{{row_id, item} => result}}`.
  - `artifact/2` reads one retained source copy named by a claim's
    `artifact` (`{file, sha256}`) from the artifacts directory: the
    directory 0700, the file a regular 0600 file by `lstat`, at most 1 MiB,
    UTF-8 text, and its sha256 equal to the recorded one.

  Refusals are `{:error, {path, rule}}`, value-free.

  RED stage (D-237 S3): the API is the contract; every function returns
  `{:error, :not_implemented}`.
  """

  @doc "Reads the manifest at `path` once, by its full sha256, and parses it against `dossier`."
  @spec read(Path.t(), String.t(), {map(), String.t()}) :: {:ok, map()} | {:error, term()}
  def read(_path, _sha256, _dossier), do: red({:error, :not_implemented})

  @doc "Parses manifest bytes against the parsed `dossier` and its sha256 hex."
  @spec parse(binary(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def parse(_bin, _dossier, _dossier_sha256), do: red({:error, :not_implemented})

  @doc "Reads one retained artifact (`%{\"file\" => …, \"sha256\" => …}`) from `dir`."
  @spec artifact(Path.t(), map()) :: {:ok, binary()} | {:error, term()}
  def artifact(_dir, _ref), do: red({:error, :not_implemented})

  # RED stub result, typed dynamic() so success clauses of callers compile
  # against the stub (Elixir 1.20 infers literal returns); nothing sets the key.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
