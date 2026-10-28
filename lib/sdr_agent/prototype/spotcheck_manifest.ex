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

  Refusals are `{:error, {path, rule}}`, value-free; every artifact refusal
  is `{:error, {"artifact", :artifact_invalid}}`.

  GREEN-1 stage (D-237 S3; Codex a322d6d9): `artifact/2` is implemented.
  `read/3` and `parse/3` still return `{:error, :not_implemented}`: they wait
  for S1's `SdrAgent.Prototype.BoundedJson` and their own review.
  """

  import Bitwise

  @artifact_max_bytes 1_048_576
  @artifact_file ~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/
  @hex64 ~r/\A[0-9a-f]{64}\z/

  @doc "Reads the manifest at `path` once, by its full sha256, and parses it against `dossier`."
  @spec read(Path.t(), String.t(), {map(), String.t()}) :: {:ok, map()} | {:error, term()}
  def read(_path, _sha256, _dossier), do: red({:error, :not_implemented})

  @doc "Parses manifest bytes against the parsed `dossier` and its sha256 hex."
  @spec parse(binary(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def parse(_bin, _dossier, _dossier_sha256), do: red({:error, :not_implemented})

  @doc "Reads one retained artifact (`%{\"file\" => …, \"sha256\" => …}`) from `dir`."
  @spec artifact(Path.t(), term()) :: {:ok, binary()} | {:error, {String.t(), :artifact_invalid}}
  def artifact(dir, %{"file" => file, "sha256" => sha256})
      when is_binary(dir) and is_binary(file) and is_binary(sha256) do
    path = Path.join(dir, file)

    # The basename grammar is checked here, whatever the caller parsed: no
    # separator, traversal, absolute or dot-leading name reaches the disk.
    with true <- Regex.match?(@artifact_file, file) and Regex.match?(@hex64, sha256),
         {:ok, %File.Stat{type: :directory, mode: dir_mode}} <- File.lstat(dir),
         true <- (dir_mode &&& 0o777) == 0o700,
         {:ok, %File.Stat{type: :regular} = before} <- File.lstat(path),
         true <- (before.mode &&& 0o777) == 0o600 and before.size <= @artifact_max_bytes,
         {:ok, bytes} <- File.read(path),
         {:ok, %File.Stat{type: :regular} = after_read} <- File.lstat(path),
         true <- same_file?(before, after_read) and byte_size(bytes) == before.size,
         true <- String.valid?(bytes),
         true <- Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == sha256 do
      {:ok, bytes}
    else
      _invalid -> {:error, {"artifact", :artifact_invalid}}
    end
  end

  def artifact(_dir, _ref), do: {:error, {"artifact", :artifact_invalid}}

  # The file read is the file checked: the same inode, size and mtime.
  defp same_file?(a, b), do: a.inode == b.inode and a.size == b.size and a.mtime == b.mtime

  # RED stub result, typed dynamic() so success clauses of callers compile
  # against the stub (Elixir 1.20 infers literal returns); nothing sets the key.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
