defmodule SdrAgent.AI.ClaudeCLIPinnedExecutableTest do
  @moduledoc """
  R0-02 (ADR-0004 R0 amendment, item 1): the app's Claude CLI is accepted
  only as the reviewed artifact recorded in `nix/app-claude-cli.identity`:
  for this platform, exactly the recorded store path's `bin/claude-code`,
  whose sha256 matches (boot), and which is still a regular executable with
  no symlink below the store root (every launch). Being some executable in
  `/nix/store` is not enough: the dev shell's Elixir, another Claude build
  and an artifact with the same name and version but other content are all
  refused. Nothing is resolved from `PATH`; nothing is executed.
  """
  # Mutates the application env (the test-build identity seam).
  use ExUnit.Case, async: false

  alias SdrAgent.AI.ModelProvider.ClaudeCLI.PinnedExecutable
  alias SdrAgent.Test.PinnedCLI

  setup do
    suffix = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    store = Path.join(System.tmp_dir!(), "sdr-pinned-store-#{suffix}")
    bin = Path.join([store, "abc-app-claude-cli-2.1.294", "bin"])
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf!(store) end)
    %{store: store, bin: bin}
  end

  describe "the reviewed identity record" do
    test "records aarch64-darwin, under /nix/store, at the packaged version" do
      [_, version] = Regex.run(~r/version = "([^"]+)";/, File.read!("nix/app-claude-cli.nix"))
      recorded = PinnedExecutable.recorded()

      assert Map.has_key?(recorded, "aarch64-darwin")

      for {system, identity} <- recorded do
        assert system in ~w(aarch64-darwin x86_64-darwin aarch64-linux x86_64-linux)
        assert identity.store == "/nix/store"

        assert identity.executable =~
                 ~r"\A/nix/store/[0-9a-z]{32}-app-claude-cli-#{Regex.escape(version)}/bin/claude-code\z"

        assert identity.sha256 =~ ~r/\A[0-9a-f]{64}\z/
      end
    end

    test "the platform is a Nix system name derived from the BEAM's architecture" do
      arch = to_string(:erlang.system_info(:system_architecture))
      platform = PinnedExecutable.platform()

      assert platform in [nil | ~w(aarch64-darwin x86_64-darwin aarch64-linux x86_64-linux)]
      if arch =~ ~r/\Aaarch64-apple-darwin/, do: assert(platform == "aarch64-darwin")
    end

    test "without an injected identity the dev shell's Elixir is refused" do
      Application.delete_env(:sdr_agent, PinnedExecutable)

      expected =
        if Map.has_key?(PinnedExecutable.recorded(), PinnedExecutable.platform()),
          do: {:error, :not_the_pinned_path},
          else: {:error, :unsupported_platform}

      assert PinnedExecutable.check(PinnedCLI.store_path!()) == expected
      assert PinnedExecutable.verify(PinnedCLI.store_path!()) == expected
    end

    test "only config/test.exs compiles the test seams in" do
      for file <- Path.wildcard("config/*.exs"), file != "config/test.exs" do
        refute File.read!(file) =~ "claude_cli_test_seams", file
      end

      assert File.read!("config/test.exs") =~ "config :sdr_agent, :claude_cli_test_seams, true"
    end
  end

  describe "binding to an identity (test-build seam)" do
    test "the exact recorded artifact passes check and verify", ctx do
      tool = executable!(ctx.bin, "claude-code", "pinned build A")
      PinnedCLI.inject_identity!(tool, store: ctx.store)

      assert PinnedExecutable.check(tool) == :ok
      assert PinnedExecutable.verify(tool) == :ok
    end

    test "another Claude build (same content, other store path) is refused", ctx do
      tool = executable!(ctx.bin, "claude-code", "pinned build A")
      other_bin = Path.join([ctx.store, "def-claude-code-2.1.294", "bin"])
      File.mkdir_p!(other_bin)
      other = executable!(other_bin, "claude-code", "pinned build A")
      PinnedCLI.inject_identity!(tool, store: ctx.store)

      assert PinnedExecutable.check(other) == {:error, :not_the_pinned_path}
      assert PinnedExecutable.verify(other) == {:error, :not_the_pinned_path}
    end

    test "an artifact with the same name and version but other content fails verify", ctx do
      tool = executable!(ctx.bin, "claude-code", "pinned build A")
      PinnedCLI.inject_identity!(tool, store: ctx.store)
      File.chmod!(tool, 0o755)
      File.write!(tool, "#!/bin/sh\n# a different build at the recorded path\n")

      # The per-launch check is cheap by design; the content is bound at boot.
      assert PinnedExecutable.check(tool) == :ok
      assert PinnedExecutable.verify(tool) == {:error, :hash_mismatch}
    end

    test "the dev shell's Elixir, or another store executable, is not the pin" do
      PinnedCLI.inject_identity!(PinnedCLI.missing_store_path(),
        sha256: String.duplicate("0", 64)
      )

      elixir = PinnedCLI.store_path!()
      elixirc = Path.join(Path.dirname(elixir), "elixirc")

      for path <- [elixir, elixirc] do
        assert PinnedExecutable.shape(path) == :ok, path
        assert PinnedExecutable.check(path) == {:error, :not_the_pinned_path}, path
        assert PinnedExecutable.verify(path) == {:error, :not_the_pinned_path}, path
      end

      assert PinnedExecutable.check(PinnedCLI.missing_store_path()) == {:error, :missing}
    end

    test "a recorded path that went missing or became a symlink is refused at launch", ctx do
      tool = executable!(ctx.bin, "claude-code", "pinned build A")
      PinnedCLI.inject_identity!(tool, store: ctx.store)

      File.rm!(tool)
      assert PinnedExecutable.check(tool) == {:error, :missing}

      decoy = executable!(ctx.store, "decoy", "pinned build A")
      File.ln_s!(decoy, tool)
      assert PinnedExecutable.check(tool) == {:error, :symlink}
    end
  end

  describe "the path rule (shape) against a stand-in store root" do
    test "a regular executable file below the store root is accepted", ctx do
      tool = executable!(ctx.bin, "claude-code", "x", 0o555)
      assert PinnedExecutable.shape(tool, ctx.store) == :ok
    end

    test "a symlink leaf or ancestor below the store root is refused", ctx do
      tool = executable!(ctx.bin, "claude-code", "x", 0o555)
      leaf = Path.join(ctx.bin, "claude-link")
      File.ln_s!(tool, leaf)
      assert PinnedExecutable.shape(leaf, ctx.store) == {:error, :symlink}

      linked_dir = Path.join(ctx.store, "def-linked")
      File.ln_s!(Path.dirname(ctx.bin), linked_dir)

      assert PinnedExecutable.shape(Path.join([linked_dir, "bin", "claude-code"]), ctx.store) ==
               {:error, :symlink}
    end

    test "a missing, non-executable or non-regular target is refused", ctx do
      assert PinnedExecutable.shape(Path.join(ctx.bin, "absent"), ctx.store) ==
               {:error, :missing}

      plain = executable!(ctx.bin, "plain", "x", 0o644)
      assert PinnedExecutable.shape(plain, ctx.store) == {:error, :not_executable}

      assert PinnedExecutable.shape(ctx.bin, ctx.store) == {:error, :not_a_file}
    end
  end

  describe "the path rule (shape) against the real Nix store" do
    test "an executable inside /nix/store has the right shape" do
      assert PinnedExecutable.shape(PinnedCLI.store_path!()) == :ok
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
        assert PinnedExecutable.shape(path) == {:error, reason}, inspect(path)
      end
    end

    test "a store path that does not exist is refused as missing" do
      assert PinnedExecutable.shape(PinnedCLI.missing_store_path()) == {:error, :missing}
    end
  end

  defp executable!(dir, name, body, mode \\ 0o555) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n# #{body}\nexit 0\n")
    File.chmod!(path, mode)
    path
  end
end
