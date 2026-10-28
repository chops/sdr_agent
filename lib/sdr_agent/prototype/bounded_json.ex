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
     `decode/2` refuses invalid UTF-8.
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
