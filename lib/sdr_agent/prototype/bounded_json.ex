defmodule SdrAgent.Prototype.BoundedJson do
  @moduledoc """
  The general parser rules of the D-237 private inputs (interfaces r6 IF-6
  "General parser rules", must-fix R3): the dossier, the spot-check
  manifest, the four seed files and the budget worksheet. Owned by S1, used
  by S1 and S3. It never evaluates code and never touches the network.

  1. **Bytes.** `read_file/3` checks a regular, non-symlink file of at most
     `max_bytes` by `lstat`, then reads it through ONE handle: before any
     byte is read, the opened object (fstat on the handle) must be that
     same regular file (device, inode, type and mode) within the bound,
     else `:changed` (or `:too_large`); the read stops at `max_bytes` plus
     one sentinel byte; the handle is closed on every path; the full sha256
     of that one snapshot must equal the argument (the path is never
     reread). Refusals are `{"(file)", rule}` with `:unreadable`,
     `:not_regular`, `:too_large`, `:changed` or `:digest_mismatch`.
     `read_private/4` is the private-evidence variant (a lexical relative
     path under a checked 0700 root, a 0600 leaf, the directory chain
     rechecked before any byte); see its doc. `decode/2` refuses invalid
     UTF-8.
  2. **Syntax vs content.** JSON whitespace between tokens is ignored; text
     rules apply only to decoded string values.
  3. **Decode.** `Jason.decode(bin, objects: :ordered_objects)`, then one
     recursive walk that refuses a repeated key at any depth and counts the
     depth (the root container is 1; each nested object or array adds 1;
     scalars do not count), before any conversion to maps. Keys compare
     after JSON unescaping, with no normalization.
  4. **Depth bounds** are the caller's `max_depth:` (the per-file minimum).
  5. **Shape.** `exact_keys/3` checks an exact key set.
  6. **Text.** `check_text/2` applies the dossier text rule: valid UTF-8; no
     C0 control except LF and TAB, and those only with `multiline: true`;
     no U+007F, C1 (U+0080..U+009F) or bidi control (U+202A..U+202E,
     U+2066..U+2069); a length in characters (`String.length/1`) within
     `min:`..`max:`; no normalization before the check.
  7. **Errors** are `{:error, {path, rule}}`: a fixed schema path with
     indices (`format_path/1`, for example `companies[3].contact.email`;
     `(root)` for the root and `(file)` for `read_file/3`) and a rule atom.
     An unknown key is reported as the parent path with `:unknown_key`,
     never naming the key. No value is ever echoed.
     `decode/2` runs before any schema check, so it names only the object
     keys in the caller's `known_keys:` (default `[]`, the file's fixed
     schema vocabulary, a trusted literal; it validates nothing and permits
     nothing): a duplicate-key or depth error is reported at its
     container's path cut at the first key outside `known_keys:`, which is
     that key's parent (as for an unknown key), and never resumed below
     the cut. Array indices are kept up to the cut. Jason's error text is
     never returned.

  **Limits (disclosed).** The open is an ordinary blocking open: a FIFO
  substituted for the checked file between the `lstat` and the open can
  block it before the fstat refuses it. There is no nonblocking or timeout
  cancellation, and this is no general guarantee against an arbitrarily
  hostile same-uid filesystem.

  Test builds only (`:prototype_test_seams`, fixed at compile time):
  `read_file/3` calls a one-argument hook from the calling process's
  dictionary under `{SdrAgent.Prototype.BoundedJson, name}` at
  `:after_precheck` (path), `:after_open` (handle), `:after_identity`
  (handle) and `:after_read` (the bytes read, before they are checked).
  A hook's return value is ignored: it can observe or act on the
  filesystem, never skip a check or supply a result. Every other build
  has no hook.
  """

  alias Jason.OrderedObject

  @test_seams Application.compile_env(:sdr_agent, :prototype_test_seams, false)

  @type path :: [String.t() | non_neg_integer()]
  @type error :: {:error, {String.t(), atom()}}

  @doc "Reads `path` once (regular file by lstat, at most `max_bytes`) and checks its sha256 hex."
  @spec read_file(Path.t(), String.t(), pos_integer()) :: {:ok, binary()} | error()
  def read_file(path, sha256_hex, max_bytes)
      when is_binary(path) and is_binary(sha256_hex) and is_integer(max_bytes) and max_bytes > 0 do
    with {:ok, checked} <- precheck(path, max_bytes) do
      hook(:after_precheck, path)
      open_and_read(path, checked, sha256_hex, max_bytes)
    end
  end

  # By lstat: a regular file (never a symlink) within the bound.
  defp precheck(path, max_bytes) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > max_bytes ->
        file_failure(:too_large)

      {:ok, %File.Stat{type: :regular} = checked} ->
        {:ok, checked}

      {:ok, %File.Stat{}} ->
        file_failure(:not_regular)

      {:error, _reason} ->
        file_failure(:unreadable)
    end
  end

  # The one handle: closed on every path after a successful open.
  defp open_and_read(path, checked, sha256_hex, max_bytes) do
    case :file.open(path, [:read, :raw, :binary]) do
      {:ok, handle} ->
        try do
          hook(:after_open, handle)
          read_checked(handle, checked, sha256_hex, max_bytes)
        after
          :file.close(handle)
        end

      {:error, _reason} ->
        file_failure(:unreadable)
    end
  end

  defp read_checked(handle, checked, sha256_hex, max_bytes) do
    with :ok <- same_object(handle, checked, max_bytes),
         {:ok, snapshot} <- read_after_identity(handle, max_bytes) do
      check_snapshot(snapshot, sha256_hex, max_bytes)
    end
  end

  # fstat on the handle, before any byte is read: the opened object must be
  # the checked one (device, inode, type and mode), and still within the
  # bound. A different object is `:changed` whatever its size.
  defp same_object(handle, checked, max_bytes) do
    case :file.read_file_info(handle, time: :posix) do
      {:ok, info} -> compare(File.Stat.from_record(info), checked, max_bytes)
      {:error, _reason} -> file_failure(:unreadable)
    end
  end

  defp compare(opened, checked, max_bytes) do
    cond do
      identity(opened) != identity(checked) -> file_failure(:changed)
      opened.size > max_bytes -> file_failure(:too_large)
      true -> :ok
    end
  end

  defp identity(%File.Stat{} = stat),
    do: {stat.type, stat.major_device, stat.minor_device, stat.inode, stat.mode}

  defp read_after_identity(handle, max_bytes) do
    hook(:after_identity, handle)
    read_bounded(handle, max_bytes + 1, <<>>)
  end

  # At most `remaining` bytes (the bound plus one sentinel byte) in total.
  defp read_bounded(handle, remaining, acc) when remaining > 0 do
    case :file.read(handle, remaining) do
      {:ok, <<_, _::binary>> = chunk} ->
        read_bounded(handle, remaining - byte_size(chunk), <<acc::binary, chunk::binary>>)

      {:ok, <<>>} ->
        {:ok, acc}

      :eof ->
        {:ok, acc}

      {:error, _reason} ->
        file_failure(:unreadable)
    end
  end

  defp read_bounded(_handle, _remaining, acc), do: {:ok, acc}

  # The digest is of exactly this one snapshot; the path is never reread.
  defp check_snapshot(snapshot, sha256_hex, max_bytes) do
    hook(:after_read, snapshot)

    cond do
      byte_size(snapshot) > max_bytes -> file_failure(:too_large)
      hex(:crypto.hash(:sha256, snapshot)) == String.downcase(sha256_hex) -> {:ok, snapshot}
      true -> file_failure(:digest_mismatch)
    end
  end

  defp file_failure(rule), do: failure("(file)", rule)

  # Test builds only: a process-local observation/action hook. Its return
  # value is ignored; every other build compiles no lookup at all.
  if @test_seams do
    defp hook(name, arg) do
      case Process.get({__MODULE__, name}) do
        fun when is_function(fun, 1) ->
          _ignored = fun.(arg)
          :ok

        _absent ->
          :ok
      end
    end
  else
    defp hook(_name, _arg), do: :ok
  end

  @doc """
  Reads the private evidence file at the relative `path` under `root`
  (Codex a6850b13 D4, S1's IF-2 worksheet evidence), in one pass:

  - `path` matches `^[A-Za-z0-9._/-]{1,200}$`, is relative and has no
    empty, `.` or `..` segment (`:invalid_path`), checked on the raw
    string before any path operation; it is walked lexically and never
    resolved;
  - `root` is absolute and, by `lstat`, a real directory (not a symlink)
    of mode 0700 (`:root_mode`); the caller supplies a trusted canonical
    root, whose own ancestors are outside this boundary;
  - each intermediate directory of `path`, by `lstat`, is a real directory
    (`:not_directory`; absent: `:unreadable`) that neither group nor other
    can write (`:dir_mode`), so 0755 is accepted;
  - the leaf, by `lstat`, is a regular file (`:not_regular`; absent:
    `:unreadable`) of mode 0600 (`:file_mode`) within `max_bytes`
    (`:too_large`);
  - then ONE raw handle: before any byte is read, the opened object (fstat)
    must be that checked leaf by type, device and inode (`:changed`), still
    0600 (`:file_mode`) and within the bound (`:too_large`); and the root
    and every intermediate directory must still be the checked objects
    (`:changed`), the root still 0700 (`:root_mode`) and no directory
    writable by group or other (`:dir_mode`); the read stops at
    `max_bytes` plus one sentinel byte; the sha256 of exactly those bytes
    must equal `sha256_hex` (`:digest_mismatch`); the handle is closed on
    every path.

  Refusals are `{"(file)", rule}`, value-free. Nothing is chmod-ed,
  repaired or adopted. Test builds call the same hooks as `read_file/3`.

  Residuals, explicit: the open blocks on a FIFO substituted after the
  checks; after the final check a same-uid process can still change a mode
  or an entry (no atomic guarantee); the root's own ancestors are not
  checked. No uid is verified: `File.Stat` carries a uid, but there is no
  trusted current euid here, and the IF-2 contract asks for none. The
  leaf's link count is not checked: no hard-link exclusion, path-unique
  provenance or immutability is claimed. This read-only, hash-pinned
  contract is not the SafeLog writer's.
  """
  @spec read_private(Path.t(), String.t(), String.t(), pos_integer()) :: {:ok, binary()} | error()
  def read_private(root, path, sha256_hex, max_bytes)
      when is_binary(root) and is_binary(path) and is_binary(sha256_hex) and
             is_integer(max_bytes) and max_bytes > 0 do
    with {:ok, segments} <- lexical(path),
         {:ok, chain} <- private_chain(root, segments),
         full = Path.join([root | segments]),
         {:ok, leaf} <- private_leaf(full, max_bytes) do
      hook(:after_precheck, full)
      open_private(full, chain, leaf, sha256_hex, max_bytes)
    end
  end

  # On the raw string, before any Path operation could normalize it away.
  defp lexical(path) do
    segments = String.split(path, "/")

    if byte_size(path) in 1..200 and path_chars?(path) and
         Enum.all?(segments, &(&1 not in ["", ".", ".."])),
       do: {:ok, segments},
       else: file_failure(:invalid_path)
  end

  defp path_chars?(path), do: path |> :binary.bin_to_list() |> Enum.all?(&path_char?/1)

  defp path_char?(c),
    do: c in ?A..?Z or c in ?a..?z or c in ?0..?9 or c in [?., ?_, ?/, ?-]

  # The root and every intermediate directory, by lstat, in order:
  # `[{path, :root | :dir, stat}]`.
  defp private_chain(root, segments) do
    with {:ok, root_stat} <- private_root(root) do
      segments
      |> Enum.drop(-1)
      |> Enum.reduce_while({:ok, root, [{root, :root, root_stat}]}, &chain_link/2)
      |> case do
        {:ok, _dir, chain} -> {:ok, Enum.reverse(chain)}
        error -> error
      end
    end
  end

  defp chain_link(segment, {:ok, dir, chain}) do
    next = Path.join(dir, segment)

    case private_dir(next) do
      {:ok, stat} -> {:cont, {:ok, next, [{next, :dir, stat} | chain]}}
      error -> {:halt, error}
    end
  end

  defp private_root(root) do
    with :absolute <- Path.type(root),
         {:ok, %File.Stat{type: :directory} = stat} <- File.lstat(root),
         0o700 <- mode_bits(stat) do
      {:ok, stat}
    else
      _other -> file_failure(:root_mode)
    end
  end

  defp private_dir(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        if others_write?(stat), do: file_failure(:dir_mode), else: {:ok, stat}

      {:ok, %File.Stat{}} ->
        file_failure(:not_directory)

      {:error, _reason} ->
        file_failure(:unreadable)
    end
  end

  defp private_leaf(path, max_bytes) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular} = stat} -> private_bounds(stat, max_bytes)
      {:ok, %File.Stat{}} -> file_failure(:not_regular)
      {:error, _reason} -> file_failure(:unreadable)
    end
  end

  defp private_bounds(stat, max_bytes) do
    cond do
      mode_bits(stat) != 0o600 -> file_failure(:file_mode)
      stat.size > max_bytes -> file_failure(:too_large)
      true -> {:ok, stat}
    end
  end

  # The one handle: closed on every path after a successful open.
  defp open_private(path, chain, leaf, sha256_hex, max_bytes) do
    case :file.open(path, [:read, :raw, :binary]) do
      {:ok, handle} ->
        try do
          hook(:after_open, handle)
          read_private_checked(handle, chain, leaf, sha256_hex, max_bytes)
        after
          :file.close(handle)
        end

      {:error, _reason} ->
        file_failure(:unreadable)
    end
  end

  # Before any byte: the opened leaf, then the whole directory chain.
  defp read_private_checked(handle, chain, leaf, sha256_hex, max_bytes) do
    with :ok <- same_private_leaf(handle, leaf, max_bytes),
         :ok <- Enum.find_value(chain, :ok, &changed_link/1),
         {:ok, snapshot} <- read_after_identity(handle, max_bytes) do
      check_snapshot(snapshot, sha256_hex, max_bytes)
    end
  end

  defp same_private_leaf(handle, leaf, max_bytes) do
    case :file.read_file_info(handle, time: :posix) do
      {:ok, info} -> compare_private(File.Stat.from_record(info), leaf, max_bytes)
      {:error, _reason} -> file_failure(:unreadable)
    end
  end

  defp compare_private(opened, leaf, max_bytes) do
    cond do
      object(opened) != object(leaf) -> file_failure(:changed)
      mode_bits(opened) != 0o600 -> file_failure(:file_mode)
      opened.size > max_bytes -> file_failure(:too_large)
      true -> :ok
    end
  end

  # nil while the directory is still the checked object meeting its
  # requirement (for Enum.find_value/3); otherwise the refusal.
  defp changed_link({path, kind, checked}) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory} = now} ->
        cond do
          object(now) != object(checked) -> file_failure(:changed)
          kind == :root and mode_bits(now) != 0o700 -> file_failure(:root_mode)
          kind == :dir and others_write?(now) -> file_failure(:dir_mode)
          true -> nil
        end

      _other ->
        file_failure(:changed)
    end
  end

  defp object(%File.Stat{} = stat),
    do: {stat.type, stat.major_device, stat.minor_device, stat.inode}

  defp mode_bits(%File.Stat{mode: mode}), do: Bitwise.band(mode, 0o777)
  defp others_write?(%File.Stat{mode: mode}), do: Bitwise.band(mode, 0o022) != 0

  @doc """
  Decodes `bin` under rules 1-4 and 7 (`max_bytes:`, `max_depth:`,
  `known_keys:`); returns plain maps and lists.
  """
  @spec decode(binary(), keyword()) :: {:ok, term()} | error()
  def decode(bin, opts) when is_binary(bin) and is_list(opts) do
    max_bytes = Keyword.fetch!(opts, :max_bytes)
    limits = %{max_depth: Keyword.fetch!(opts, :max_depth), known: known_keys(opts)}

    cond do
      byte_size(bin) > max_bytes -> failure("(root)", :too_large)
      not String.valid?(bin) -> failure("(root)", :invalid_utf8)
      true -> decode_valid(bin, limits)
    end
  end

  defp known_keys(opts), do: opts |> Keyword.get(:known_keys, []) |> MapSet.new()

  defp decode_valid(bin, limits) do
    case Jason.decode(bin, objects: :ordered_objects) do
      {:ok, value} ->
        with :ok <- walk(value, {[], :open}, 1, limits), do: {:ok, plain(value)}

      {:error, _jason_error} ->
        failure("(root)", :invalid_json)
    end
  end

  # The walk, before any map is built: refuses a container deeper than the
  # bound and an object with a repeated key. `at` is the reported path:
  # trusted segments and indices, reversed, cut for good at the parent of
  # the first key outside `known_keys:`.
  defp walk(value, at, depth, limits) when is_list(value) or is_struct(value, OrderedObject) do
    cond do
      depth > limits.max_depth -> failure(at_path(at), :too_deep)
      duplicate_key?(value) -> failure(at_path(at), :duplicate_key)
      true -> walk_children(value, at, depth, limits)
    end
  end

  defp walk(_scalar, _at, _depth, _limits), do: :ok

  defp walk_children(container, at, depth, limits) do
    container
    |> children()
    |> Enum.reduce_while(:ok, fn {segment, child}, :ok ->
      case walk(child, descend(at, segment, limits.known), depth + 1, limits) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp duplicate_key?(%OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))
    length(Enum.uniq(keys)) != length(keys)
  end

  defp duplicate_key?(list) when is_list(list), do: false

  defp children(%OrderedObject{values: pairs}), do: pairs
  defp children(list) when is_list(list), do: Enum.with_index(list, &{&2, &1})

  defp descend({_segments, :cut} = at, _segment, _known), do: at

  defp descend({segments, :open}, index, _known) when is_integer(index),
    do: {[index | segments], :open}

  defp descend({segments, :open}, key, known) do
    if MapSet.member?(known, key), do: {[key | segments], :open}, else: {segments, :cut}
  end

  defp at_path({segments, _state}), do: segments |> Enum.reverse() |> format_path()

  # Keys are unique by now.
  defp plain(%OrderedObject{values: pairs}), do: Map.new(pairs, fn {k, v} -> {k, plain(v)} end)
  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(scalar), do: scalar

  @doc "`:ok` when `map` has exactly `keys`; otherwise `{:error, {path, :unknown_key | :missing_key}}`."
  @spec exact_keys(map(), [String.t()], path()) :: :ok | error()
  def exact_keys(map, keys, path) when is_map(map) and is_list(keys) and is_list(path) do
    present = Map.keys(map)

    cond do
      present -- keys != [] -> failure(format_path(path), :unknown_key)
      keys -- present != [] -> failure(format_path(path), :missing_key)
      true -> :ok
    end
  end

  @doc "Applies the dossier text rule to one decoded string (`min:`, `max:`, `multiline:`)."
  @spec check_text(term(), keyword()) :: :ok | {:error, atom()}
  def check_text(value, opts) when is_binary(value) do
    multiline? = Keyword.get(opts, :multiline, false)

    cond do
      not String.valid?(value) -> {:error, :invalid_utf8}
      control?(value, multiline?) -> {:error, :control_character}
      String.length(value) < Keyword.fetch!(opts, :min) -> {:error, :too_short}
      String.length(value) > Keyword.fetch!(opts, :max) -> {:error, :too_long}
      true -> :ok
    end
  end

  def check_text(_value, _opts), do: {:error, :not_a_string}

  defp control?(value, multiline?),
    do: value |> String.to_charlist() |> Enum.any?(&forbidden?(&1, multiline?))

  defp forbidden?(c, true) when c in [0x0A, 0x09], do: false
  defp forbidden?(c, _multiline?) when c < 0x20, do: true
  defp forbidden?(0x7F, _multiline?), do: true
  defp forbidden?(c, _multiline?) when c in 0x80..0x9F, do: true
  defp forbidden?(c, _multiline?) when c in 0x202A..0x202E, do: true
  defp forbidden?(c, _multiline?) when c in 0x2066..0x2069, do: true
  defp forbidden?(_c, _multiline?), do: false

  @doc "Formats a schema path, for example `companies[3].contact` from its segments and indices."
  @spec format_path(path()) :: String.t()
  def format_path([]), do: "(root)"

  def format_path(segments) when is_list(segments) do
    Enum.reduce(segments, "", fn
      index, acc when is_integer(index) -> acc <> "[#{index}]"
      key, "" -> key
      key, acc -> acc <> "." <> key
    end)
  end

  defp failure(path, rule), do: {:error, {path, rule}}
  defp hex(bin), do: Base.encode16(bin, case: :lower)
end
