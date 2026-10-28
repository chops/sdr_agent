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
    `artifact` (`{file, sha256}`) from the artifacts directory: a basename
    of the fixed grammar; the directory a real 0700 directory and the file
    a regular 0600 file of at most 1 MiB by `lstat`; then ONE handle whose
    opened object (fstat) must be that same file (device and inode) under
    the same root before any byte is read; a read bounded to 1 MiB plus one
    sentinel byte; UTF-8 text; its sha256 equal to the recorded one. The
    handle is closed on every path. Known limitation (availability only): a
    FIFO substituted after the precheck can block the open, since the raw
    open has no no-follow or non-blocking flag; no content is read and the
    call never succeeds.

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
  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)

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
         {:ok, %File.Stat{type: :directory} = root} <- File.lstat(dir),
         true <- (root.mode &&& 0o777) == 0o700,
         {:ok, %File.Stat{type: :regular} = checked} <- File.lstat(path),
         true <- allowed?(checked),
         :ok <- seam(:after_precheck, path),
         {:ok, bytes} <- read_checked(dir, root, path, checked),
         true <- String.valid?(bytes),
         true <- Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == sha256 do
      {:ok, bytes}
    else
      _invalid -> {:error, {"artifact", :artifact_invalid}}
    end
  end

  def artifact(_dir, _ref), do: {:error, {"artifact", :artifact_invalid}}

  # ONE handle (Codex GREEN-1 R1): before any content is read, the opened
  # object itself (fstat on the handle) must be the regular 0600 file of at
  # most 1 MiB that the precheck saw (same device and inode), and the root
  # must still be the checked directory, still 0700 (Codex GREEN-1b). A
  # file or root substituted or widened after the precheck is therefore
  # never read. The read is bounded to the limit plus one sentinel byte, so
  # growth after the identity check is refused without an unbounded read.
  # The handle is closed on every path. Nothing is chmod-ed or repaired.
  defp read_checked(dir, root, path, checked) do
    case :file.open(path, [:read, :raw, :binary]) do
      {:ok, handle} ->
        try do
          with {:ok, info} <- :file.read_file_info(handle, time: :posix),
               opened = File.Stat.from_record(info),
               true <-
                 opened.type == :regular and allowed?(opened) and same_object?(opened, checked),
               {:ok, %File.Stat{type: :directory} = root_now} <- File.lstat(dir),
               true <- same_object?(root_now, root) and (root_now.mode &&& 0o777) == 0o700,
               :ok <- seam(:after_open, handle),
               {:ok, bytes} <- read_at_most(handle, @artifact_max_bytes + 1, []),
               :ok <- seam(:after_read, bytes),
               true <- byte_size(bytes) <= @artifact_max_bytes do
            {:ok, bytes}
          else
            _ -> :error
          end
        after
          :file.close(handle)
        end

      {:error, _reason} ->
        :error
    end
  end

  defp allowed?(%File.Stat{mode: mode, size: size}),
    do: (mode &&& 0o777) == 0o600 and size <= @artifact_max_bytes

  defp same_object?(a, b),
    do:
      a.inode == b.inode and a.major_device == b.major_device and a.minor_device == b.minor_device

  # At most `left` bytes in total, however the reads are split.
  defp read_at_most(_handle, 0, acc), do: {:ok, :erlang.iolist_to_binary(acc)}

  defp read_at_most(handle, left, acc) do
    case :file.read(handle, left) do
      {:ok, data} -> read_at_most(handle, left - byte_size(data), [acc, data])
      :eof -> {:ok, :erlang.iolist_to_binary(acc)}
      {:error, _} = error -> error
    end
  end

  # Test-seam builds only (`:claude_cli_test_seams`, fixed at compile time):
  # a test may act or observe at a named boundary of `artifact/2` through a
  # one-argument function in its own process dictionary under
  # `{SdrAgent.Prototype.SpotcheckManifest, name}`. Every other build
  # compiles `seam/2` to `:ok`.
  if @test_seams do
    defp seam(name, arg) do
      case Process.get({__MODULE__, name}) do
        hook when is_function(hook, 1) -> hook.(arg)
        _none -> nil
      end

      :ok
    end
  else
    defp seam(_name, _arg), do: :ok
  end

  # RED stub result, typed dynamic() so success clauses of callers compile
  # against the stub (Elixir 1.20 infers literal returns); nothing sets the key.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
