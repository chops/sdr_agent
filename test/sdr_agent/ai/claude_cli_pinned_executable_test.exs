defmodule SdrAgent.AI.ClaudeCLIPinnedExecutableTest do
  @moduledoc """
  R0-02 (ADR-0004 R0 amendment, item 1): the app's Claude CLI is accepted
  only as a canonical absolute path to a regular executable file inside the
  Nix store, with no symlink below the store root. Anything else is refused
  with a typed reason; nothing is resolved from `PATH`.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.AI.ModelProvider.ClaudeCLI.PinnedExecutable
  alias SdrAgent.Test.PinnedCLI

  setup do
    suffix = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    store = Path.join(System.tmp_dir!(), "sdr-pinned-store-#{suffix}")
    bin = Path.join([store, "abc-app-claude-cli-1.0.0", "bin"])
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf!(store) end)
    %{store: store, bin: bin}
  end

  describe "against a stand-in store root" do
    test "a regular executable file below the store root is accepted", ctx do
      tool = executable!(ctx.bin, "claude-code", 0o555)
      assert PinnedExecutable.check(tool, ctx.store) == :ok
    end

    test "a symlink leaf or ancestor below the store root is refused", ctx do
      tool = executable!(ctx.bin, "claude-code", 0o555)
      leaf = Path.join(ctx.bin, "claude-link")
      File.ln_s!(tool, leaf)
      assert PinnedExecutable.check(leaf, ctx.store) == {:error, :symlink}

      linked_dir = Path.join(ctx.store, "def-linked")
      File.ln_s!(Path.dirname(ctx.bin), linked_dir)

      assert PinnedExecutable.check(Path.join([linked_dir, "bin", "claude-code"]), ctx.store) ==
               {:error, :symlink}
    end

    test "a missing, non-executable or non-regular target is refused", ctx do
      assert PinnedExecutable.check(Path.join(ctx.bin, "absent"), ctx.store) ==
               {:error, :missing}

      plain = executable!(ctx.bin, "plain", 0o644)
      assert PinnedExecutable.check(plain, ctx.store) == {:error, :not_executable}

      assert PinnedExecutable.check(ctx.bin, ctx.store) == {:error, :not_a_file}
    end
  end

  describe "against the real Nix store" do
    test "an executable inside /nix/store is accepted" do
      assert PinnedExecutable.check(PinnedCLI.store_path!()) == :ok
    end

    test "paths outside the store, relative, non-canonical or empty are refused" do
      for {path, reason} <- [
            {"/bin/sh", :not_in_nix_store},
            {"/nix/store", :not_in_nix_store},
            {"/nix/store/", :not_canonical},
            {"/nix/storefront/x/bin/claude-code", :not_in_nix_store},
            {"bin/claude-code", :not_absolute},
            {"claude-code", :not_absolute},
            {"/nix/store/../../bin/sh", :not_canonical},
            {"/nix/store//abc/bin/claude-code", :not_canonical},
            {PinnedCLI.store_path!() <> "/", :not_canonical},
            {"/nix/store/abc/bin/claude-code" <> <<0>>, :not_canonical},
            {"", :not_a_path},
            {nil, :not_a_path}
          ] do
        assert PinnedExecutable.check(path) == {:error, reason}, inspect(path)
      end
    end

    test "a store path that does not exist is refused as missing" do
      assert PinnedExecutable.check(PinnedCLI.missing_store_path()) == {:error, :missing}
    end
  end

  defp executable!(dir, name, mode) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, mode)
    path
  end
end
