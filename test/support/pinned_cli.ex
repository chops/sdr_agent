defmodule SdrAgent.Test.PinnedCLI do
  @moduledoc """
  Stand-ins for the app's pinned Claude CLI (R0-02) in hermetic tests.

  The real pinned build is never launched by tests. A test that needs an
  accepted pin binds a harmless stand-in through the test-build identity
  seam (`inject_identity!/1`; `config :sdr_agent, :claude_cli_test_seams`
  exists only in config/test.exs): the dev shell's own Elixir launcher is a
  regular executable inside `/nix/store` (local and CI runs both execute
  inside `nix develop`). The fake CLI (`fake_claude_cli.exs`) checks that it
  received exactly this path as `LLM_PROXY_SHIM_CLAUDE_BIN`.

  `stub_shim!/1` puts a recording `llm-proxy-shim` first on `PATH`, so a
  server started with the default (real) launcher resolves to it and every
  launch attempt is counted: a staged or unpinned server must leave the
  count at zero.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  alias SdrAgent.AI.ModelProvider.ClaudeCLI.PinnedExecutable

  @doc "An executable regular file inside /nix/store (flunks outside the dev shell)."
  def store_path! do
    path = System.find_executable("elixir")

    unless is_binary(path) and String.starts_with?(path, "/nix/store/"),
      do: flunk("expected the dev shell's elixir inside /nix/store, got #{inspect(path)}")

    path
  end

  @doc "A well-formed /nix/store path that does not exist."
  def missing_store_path,
    do: "/nix/store/" <> String.duplicate("0", 32) <> "-app-claude-cli-0/bin/claude-code"

  @doc """
  Binds the accepted pin to `path` (default: `store_path!/0`) for this test:
  its sha256 unless `sha256` is given, under `store` (default `/nix/store`),
  with the reviewed CLI `version` (L2 E3; default the profiles' reviewed
  `ModelProfiles.cli_version/0`; `version: nil` omits it, any other value is
  recorded as given). Restored on exit. Returns the path.
  """
  def inject_identity!(path \\ nil, opts \\ []) do
    path = path || store_path!()
    previous = Application.get_env(:sdr_agent, PinnedExecutable)

    identity =
      %{
        executable: path,
        sha256: Keyword.get_lazy(opts, :sha256, fn -> PinnedExecutable.sha256(path) end),
        store: Keyword.get(opts, :store, "/nix/store")
      }
      |> put_version(Keyword.get(opts, :version, SdrAgent.AI.ModelProfiles.cli_version()))

    Application.put_env(:sdr_agent, PinnedExecutable, identity: identity)

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:sdr_agent, PinnedExecutable, previous),
        else: Application.delete_env(:sdr_agent, PinnedExecutable)
    end)

    path
  end

  defp put_version(identity, nil), do: identity
  defp put_version(identity, version), do: Map.put(identity, :version, version)

  @doc """
  Puts a recording `llm-proxy-shim` first on `PATH` (restored on exit); each
  run appends one line to the returned counter file and prints nothing.
  """
  def stub_shim!(dir) do
    bin = Path.join(dir, "shim-bin")
    File.mkdir_p!(bin)
    counter = Path.join(dir, "shim-launches")
    shim = Path.join(bin, "llm-proxy-shim")
    File.write!(shim, "#!/bin/sh\necho launched >> '#{counter}'\nexit 0\n")
    File.chmod!(shim, 0o755)

    previous = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> previous)
    ExUnit.Callbacks.on_exit(fn -> System.put_env("PATH", previous) end)

    counter
  end

  @doc "How many times the stub shim was launched."
  def launches(counter) do
    case File.read(counter) do
      {:ok, body} -> body |> String.split("\n", trim: true) |> length()
      {:error, :enoent} -> 0
    end
  end
end
