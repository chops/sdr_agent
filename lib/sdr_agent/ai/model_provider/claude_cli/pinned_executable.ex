defmodule SdrAgent.AI.ModelProvider.ClaudeCLI.PinnedExecutable do
  @moduledoc """
  The rule for the app's own pinned Claude CLI (ADR-0004 R0 amendment,
  item 1; story R0-02).

  The app launches the Claude CLI only from its content-addressed build in
  the Nix store (`nix/app-claude-cli-package.nix`, kept alive by
  `bin/app-claude-cli-root`), by absolute path, and never resolves `claude`
  from `PATH`. `check/1` accepts a path only when it is:

    * a canonical absolute path (no `.`/`..`/empty segments, no trailing
      slash, no NUL);
    * inside `/nix/store/`;
    * free of symlinks below the store root (leaf and ancestors), so it
      cannot point back out of the store;
    * a regular file with an execute bit.

  Anything else is `{:error, reason}`: `:not_a_path`, `:not_absolute`,
  `:not_canonical`, `:not_in_nix_store`, `:symlink`, `:missing`,
  `:not_a_file` or `:not_executable`. `config/runtime.exs` refuses boot on
  it; `SdrAgent.AI.ModelProvider.ClaudeCLI` and
  `SdrAgent.AI.ModelProvider.Runtime` re-check before every launch, so a
  build collected after boot is refused rather than replaced. Only file
  metadata is read; nothing is executed.
  """

  import Bitwise

  @store "/nix/store"

  @type reason ::
          :not_a_path
          | :not_absolute
          | :not_canonical
          | :not_in_nix_store
          | :symlink
          | :missing
          | :not_a_file
          | :not_executable

  @doc """
  Checks `path` against the pinned-CLI rule. `store` is the store root; it
  is `/nix/store` except in the rule's own tests.
  """
  @spec check(term(), String.t()) :: :ok | {:error, reason()}
  def check(path, store \\ @store)

  def check(path, store) when is_binary(path) and path != "" do
    cond do
      Path.type(path) != :absolute -> {:error, :not_absolute}
      String.contains?(path, <<0>>) or Path.expand(path) != path -> {:error, :not_canonical}
      true -> inside_store(path, store)
    end
  end

  def check(_path, _store), do: {:error, :not_a_path}

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
