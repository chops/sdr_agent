defmodule SdrAgent.HostedArtifactTest do
  @moduledoc """
  The inactive hosted_prototype release artifact (plan r1, Codex scoped PASS
  m_codex_hosted_artifact_go_20261031): the release support files and the
  build-only script.

  The script builds and checks a release on the build host and reports where
  it is. It never installs, switches, migrates, seeds, provisions or
  restarts anything. Activation belongs to the separately reviewed runbook.
  `SdrAgent.Release` offers `migrate/0` only, so the artifact cannot
  auto-provision.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @script Path.join(@root, "scripts/build-hosted-artifact.sh")

  defp read(rel), do: File.read(Path.join(@root, rel))

  defp executable?(rel) do
    case File.stat(Path.join(@root, rel)) do
      {:ok, %File.Stat{mode: mode, type: :regular}} -> Bitwise.band(mode, 0o111) == 0o111
      _absent -> false
    end
  end

  describe "release support files" do
    test "the release runs without Erlang distribution" do
      assert {:ok, env} = read("rel/env.sh.eex"), "rel/env.sh.eex is absent"
      assert env =~ ~r/^export RELEASE_DISTRIBUTION=none$/m
    end

    test "bin/server starts the endpoint; bin/migrate runs only Release.migrate" do
      assert {:ok, server} = read("rel/overlays/bin/server"), "bin/server is absent"
      assert server =~ "PHX_SERVER=true exec ./sdr_agent start"
      assert executable?("rel/overlays/bin/server"), "bin/server is not executable"

      assert {:ok, migrate} = read("rel/overlays/bin/migrate"), "bin/migrate is absent"
      assert migrate =~ "exec ./sdr_agent eval SdrAgent.Release.migrate"
      assert executable?("rel/overlays/bin/migrate"), "bin/migrate is not executable"
    end

    test "the build shell pins the devenv toolchain (OTP 29, Elixir 1.20) and Nix Hex/rebar3" do
      assert {:ok, shell} = read("nix/build-shell.nix"), "nix/build-shell.nix is absent"
      assert shell =~ "pkgs.beam.packages.erlang_29"
      assert shell =~ "bp.elixir_1_20"
      assert shell =~ "bp.hex"
      assert shell =~ ~s(MIX_REBAR3 = "${bp.rebar3}/bin/rebar3")
    end
  end

  describe "SdrAgent.Release" do
    test "exports migrate/0 and nothing that seeds, provisions or activates" do
      module = Module.concat([SdrAgent, Release])
      assert Code.ensure_loaded?(module), "SdrAgent.Release is absent"

      exported =
        :functions
        |> module.__info__()
        |> Enum.reject(fn {name, _arity} -> String.starts_with?(Atom.to_string(name), "__") end)
        |> Enum.sort()

      assert exported == [migrate: 0]
    end
  end

  describe "scripts/build-hosted-artifact.sh" do
    setup do
      assert {:ok, text} = File.read(@script), "the build script is absent"
      %{text: text}
    end

    test "parses (bash -n) and is executable", %{text: _text} do
      assert {_out, 0} = System.cmd("bash", ["-n", @script], stderr_to_stdout: true)
      assert executable?("scripts/build-hosted-artifact.sh")
    end

    test "builds the hosted_prototype release from a clean pushed commit", %{text: text} do
      assert text =~ "export MIX_ENV=hosted_prototype"
      assert text =~ "git archive"
      assert text =~ "mix deps.get --only hosted_prototype --check-locked"
      assert text =~ "mix release --overwrite"
      assert text =~ "nix/build-shell.nix"
      assert text =~ "sha256sum"
    end

    test "never installs, switches, migrates, seeds, provisions or restarts", %{text: text} do
      code =
        text
        |> String.split("\n")
        |> Enum.reject(&String.match?(&1, ~r/^\s*#/))
        |> Enum.join("\n")

      for forbidden <- [
            "/opt/sdr_agent",
            "systemctl",
            "switch-to-configuration",
            "nixos-rebuild",
            "Release.migrate",
            "bin/migrate",
            " eval ",
            "seed",
            "provision",
            "sdr.prototype",
            "ecto.migrate",
            "/run/secrets"
          ] do
        refute String.contains?(code, forbidden), "the build script uses #{inspect(forbidden)}"
      end
    end
  end
end
