defmodule SdrAgent.Test.PinnedCLI do
  @moduledoc """
  A stand-in for the app's pinned Claude CLI path (R0-02) in hermetic tests.

  The real pinned build is never launched by tests. What the tests need is a
  path that passes the pinned-executable rule (a regular executable file
  inside `/nix/store`): the dev shell's own Elixir launcher is one, because
  local and CI runs both execute inside `nix develop`. The fake CLI
  (`fake_claude_cli.exs`) checks that it received exactly this path as
  `LLM_PROXY_SHIM_CLAUDE_BIN`.
  """

  import ExUnit.Assertions, only: [flunk: 1]

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
end
