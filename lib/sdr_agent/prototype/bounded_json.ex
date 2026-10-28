defmodule SdrAgent.Prototype.BoundedJson do
  @moduledoc """
  The general parser rules of the D-237 private inputs (interfaces r6 IF-6
  "General parser rules", must-fix R3): the dossier, the spot-check
  manifest, the four seed files and the budget worksheet. Owned by S1, used
  by S1 and S3. It never evaluates code and never touches the network.

  1. **Bytes.** `read_file/3` checks a regular, non-symlink file of at most
     `max_bytes` by `lstat`, then reads it through ONE handle: before any
     byte is read, the opened object (fstat on the handle) must be that
     same regular file (device and inode) within the bound, else
     `:changed` (or `:too_large`); the read stops at `max_bytes` plus one
     sentinel byte; the handle is closed on every path; the full sha256 of
     that one snapshot must equal the argument (the path is never reread).
     Refusals are `{"(file)", rule}` with `:unreadable`, `:not_regular`,
     `:too_large`, `:changed` or `:digest_mismatch`. `decode/2` refuses
     invalid UTF-8.
  2. **Syntax vs content.** JSON whitespace between tokens is ignored; text
     rules apply only to decoded string values.
  3. **Decode.** `Jason.decode(bin, objects: :ordered_objects)`, then one
     recursive walk that refuses a repeated key at any depth and counts the
     depth (the root container is 1; each nested object or array adds 1;
     scalars do not count), before any conversion to maps.
  4. **Depth bounds** are the caller's `max_depth:` (the per-file minimum).
  5. **Shape.** `exact_keys/3` checks an exact key set.
  6. **Text.** `check_text/2` applies the dossier text rule: valid UTF-8; no
     C0 control except LF and TAB, and those only with `multiline: true`;
     no U+007F, C1 (U+0080..U+009F) or bidi control (U+202A..U+202E,
     U+2066..U+2069); a length in characters within `min:`..`max:`; no
     normalization before the check.
  7. **Errors** are `{:error, {path, rule}}`: a fixed schema path with
     indices (`format_path/1`, for example `companies[3].contact.email`)
     and a rule atom. An unknown key is reported as the parent path with
     `:unknown_key`, never naming the key. No value is ever echoed.
     `decode/2` runs before any schema check, so it names only the object
     keys in the caller's `known_keys:` (default `[]`, the file's fixed
     schema vocabulary): a duplicate-key or depth error is reported at its
     container's path cut at the first key outside `known_keys:`, which is
     that key's parent (as for an unknown key). Array indices are kept up
     to the cut. Jason's error text is never returned.

  Test builds only (`:prototype_test_seams`, fixed at compile time):
  `read_file/3` calls a one-argument hook from the calling process's
  dictionary under `{SdrAgent.Prototype.BoundedJson, name}` at
  `:after_precheck` (path), `:after_open` (handle), `:after_identity`
  (handle) and `:after_read` (the bytes read, before they are checked).
  Every other build has no hook.

  RED stage (D-237 S1): the API is the contract; every function returns
  `{:error, :not_implemented}`.
  """

  @type path :: [String.t() | non_neg_integer()]
  @type error :: {:error, {String.t(), atom()}}

  @doc "Reads `path` once (regular file by lstat, at most `max_bytes`) and checks its sha256 hex."
  @spec read_file(Path.t(), String.t(), pos_integer()) :: {:ok, binary()} | error()
  def read_file(_path, _sha256_hex, _max_bytes), do: red({:error, :not_implemented})

  @doc """
  Decodes `bin` under rules 1-4 and 7 (`max_bytes:`, `max_depth:`,
  `known_keys:`); returns plain maps and lists.
  """
  @spec decode(binary(), keyword()) :: {:ok, term()} | error()
  def decode(_bin, _opts), do: red({:error, :not_implemented})

  @doc "`:ok` when `map` has exactly `keys`; otherwise `{:error, {path, :unknown_key | :missing_key}}`."
  @spec exact_keys(map(), [String.t()], path()) :: :ok | error()
  def exact_keys(_map, _keys, _path), do: red({:error, :not_implemented})

  @doc "Applies the dossier text rule to one decoded string (`min:`, `max:`, `multiline:`)."
  @spec check_text(term(), keyword()) :: :ok | {:error, atom()}
  def check_text(_value, _opts), do: red({:error, :not_implemented})

  @doc "Formats a schema path, for example `companies[3].contact` from its segments and indices."
  @spec format_path(path()) :: String.t() | {:error, :not_implemented}
  def format_path(_path), do: red({:error, :not_implemented})

  # RED stub result, typed dynamic() so success clauses of callers compile
  # against the stub (Elixir 1.20 infers literal returns); nothing sets the key.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
