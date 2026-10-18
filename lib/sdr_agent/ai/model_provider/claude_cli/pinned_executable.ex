defmodule SdrAgent.AI.ModelProvider.ClaudeCLI.PinnedExecutable do
  @moduledoc """
  The identity of the app's own pinned Claude CLI (ADR-0004 R0 amendment,
  item 1; story R0-02).

  The app launches the Claude CLI only from its content-addressed build in
  the Nix store (`nix/app-claude-cli-package.nix`, kept alive by
  `bin/app-claude-cli-root`), by absolute path, and never resolves `claude`
  from `PATH`. A path is not accepted because it merely looks like a store
  executable: it must be the reviewed artifact recorded in
  `nix/app-claude-cli.identity` (compiled in): for this machine's Nix
  platform, exactly `<store path>/bin/claude-code`, whose sha256 matches
  the record. A platform without a record is refused.

    * `verify/1` — the boot check (`config/runtime.exs`): `check/1` plus
      the file's sha256 (the file is read once, at boot).
    * `check/1` — the cheap check before every resolution and launch: the
      exact recorded path, still a regular executable file with no symlink
      below the store root. A build collected after boot is refused, never
      replaced.
    * `shape/2` — the path rule alone: canonical and absolute, inside the
      store, no symlink below it, a regular file with an execute bit.

  Refusal reasons: `:not_a_path`, `:not_absolute`, `:not_canonical`,
  `:not_in_nix_store`, `:symlink`, `:missing`, `:not_a_file`,
  `:not_executable`, `:unsupported_platform`, `:not_the_pinned_path`,
  `:hash_mismatch`. Only file metadata and (in `verify/1`) content are
  read; nothing is executed.

  **Test seam.** Only in a build compiled with `config :sdr_agent,
  :claude_cli_test_seams, true` (config/test.exs) does `config :sdr_agent,
  #{inspect(__MODULE__)}, identity: %{executable:, sha256:, store:}` replace
  the recorded identity, so tests can bind a harmless stand-in. Development
  and production builds contain no override.
  """

  import Bitwise

  @store "/nix/store"
  @record Path.expand("../../../../../nix/app-claude-cli.identity", __DIR__)
  @external_resource @record
  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)

  @identities @record
              |> File.read!()
              |> String.split("\n", trim: true)
              |> Enum.reject(&String.starts_with?(&1, "#"))
              |> Map.new(fn line ->
                [system, store_path, sha256, version] =
                  case String.split(line) do
                    [_, _, _, _] = fields -> fields
                    _other -> raise("invalid app Claude CLI identity line: #{line}")
                  end

                unless String.starts_with?(store_path, @store <> "/") and
                         Regex.match?(~r/\A[0-9a-f]{64}\z/, sha256) and
                         Regex.match?(~r/\A\d+\.\d+\.\d+\z/, version),
                       do: raise("invalid app Claude CLI identity line: #{line}")

                {system,
                 %{
                   store: @store,
                   executable: Path.join(store_path, "bin/claude-code"),
                   sha256: sha256,
                   version: version
                 }}
              end)

  @type reason ::
          :not_a_path
          | :not_absolute
          | :not_canonical
          | :not_in_nix_store
          | :symlink
          | :missing
          | :not_a_file
          | :not_executable
          | :unsupported_platform
          | :not_the_pinned_path
          | :hash_mismatch

  @doc "The reviewed identities compiled from `nix/app-claude-cli.identity`, by Nix system."
  def recorded, do: @identities

  @doc """
  This machine's Nix system name (`aarch64-darwin`, `x86_64-linux`, …), or
  nil when it is not one the record format knows.
  """
  def platform do
    arch = :erlang.system_info(:system_architecture) |> to_string()

    cpu =
      cond do
        String.starts_with?(arch, ["aarch64", "arm64"]) -> "aarch64"
        String.starts_with?(arch, ["x86_64", "amd64"]) -> "x86_64"
        true -> nil
      end

    os =
      cond do
        String.contains?(arch, "darwin") -> "darwin"
        String.contains?(arch, "linux") -> "linux"
        true -> nil
      end

    if cpu && os, do: "#{cpu}-#{os}"
  end

  if @test_seams do
    @doc """
    The identity the app accepts on this machine, or nil (unsupported
    platform). This test build honours an injected `:identity`.
    """
    def identity do
      case :sdr_agent |> Application.get_env(__MODULE__, []) |> Keyword.get(:identity) do
        nil -> Map.get(@identities, platform())
        identity -> identity
      end
    end
  else
    @doc "The identity the app accepts on this machine, or nil (unsupported platform)."
    def identity, do: Map.get(@identities, platform())
  end

  @doc """
  L2 E3: whether this machine's identity records the reviewed CLI version
  (`SdrAgent.AI.ModelProfiles.cli_version/0`). Metadata only, read on every
  call: a missing, malformed or other version is false. It is reviewed
  artifact evidence, never an observed version.
  """
  @spec version_bound?() :: boolean()
  def version_bound? do
    case identity() do
      %{version: version} when is_binary(version) ->
        version == SdrAgent.AI.ModelProfiles.cli_version()

      _missing ->
        false
    end
  end

  @doc "The boot check: `check/1` plus the file's sha256 against the identity."
  @spec verify(term()) :: :ok | {:error, reason()}
  def verify(path) do
    with :ok <- check(path) do
      if sha256(path) == identity().sha256, do: :ok, else: {:error, :hash_mismatch}
    end
  end

  @doc "The per-launch check: exactly the identity's path, still a sound store file."
  @spec check(term()) :: :ok | {:error, reason()}
  def check(path) do
    case identity() do
      nil ->
        with :ok <- shape(path), do: {:error, :unsupported_platform}

      %{executable: executable, store: store} ->
        with :ok <- shape(path, store), do: pinned_path(path, executable)
    end
  end

  defp pinned_path(path, path), do: :ok
  defp pinned_path(_path, _executable), do: {:error, :not_the_pinned_path}

  @doc """
  The path rule alone. `store` is the store root; it is `/nix/store` except
  for an injected test identity.
  """
  @spec shape(term(), String.t()) :: :ok | {:error, reason()}
  def shape(path, store \\ @store)

  def shape(path, store) when is_binary(path) and path != "" do
    cond do
      Path.type(path) != :absolute -> {:error, :not_absolute}
      String.contains?(path, <<0>>) or Path.expand(path) != path -> {:error, :not_canonical}
      true -> inside_store(path, store)
    end
  end

  def shape(_path, _store), do: {:error, :not_a_path}

  @doc "The lowercase hex sha256 of the file at `path` (streamed)."
  def sha256(path) do
    path
    |> File.stream!(1_048_576)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp inside_store(path, store) do
    case Path.relative_to(path, store, force: false) do
      ^path -> {:error, :not_in_nix_store}
      "." -> {:error, :not_in_nix_store}
      relative -> walk(store, Path.split(relative))
    end
  end

  # Every component below the store root is lstat-ed: directories on the
  # way, then a regular executable leaf; a symlink anywhere is refused.
  defp walk(dir, [leaf]), do: leaf(Path.join(dir, leaf))

  defp walk(dir, [name | rest]) do
    next = Path.join(dir, name)

    case File.lstat(next) do
      {:ok, %File.Stat{type: :directory}} -> walk(next, rest)
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink}
      {:ok, _other} -> {:error, :not_a_file}
      {:error, _reason} -> {:error, :missing}
    end
  end

  defp leaf(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} when (mode &&& 0o111) != 0 -> :ok
      {:ok, %File.Stat{type: :regular}} -> {:error, :not_executable}
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink}
      {:ok, _other} -> {:error, :not_a_file}
      {:error, _reason} -> {:error, :missing}
    end
  end
end
