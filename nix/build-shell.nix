# Plain release-build shell for the hosted deployment, used by
# scripts/deploy.sh through `nix develop --impure --expr` on the NixOS host:
# it works non-interactively where the devenv shell cannot. Kept out of
# flake.nix, a workflow-managed file pinned by .workflow/receipt.json. The
# caller passes this flake's locked nixpkgs, so the toolchain matches
# devenv.nix (OTP 29, Elixir 1.20). gcc/make build NIFs (bcrypt_elixir);
# patchelf patches the downloaded tailwind binary. The assets need no
# Node.js (no package.json; esbuild resolves packages from the Mix deps).
#
# Hex and rebar3 are the pinned package set's too (Codex I2), so the build
# never runs `mix local.hex`/`mix local.rebar`: bp.hex's setup hook puts Hex
# on ERL_LIBS, and MIX_REBAR3 names bp.rebar3's binary for Mix. deploy.sh
# checks both are /nix/store paths and records every tool's identity.
{ pkgs }:
let
  bp = pkgs.beam.packages.erlang_29;
in
pkgs.mkShell {
  packages = [
    bp.elixir_1_20
    bp.hex
    bp.rebar3
    pkgs.git
    pkgs.gnumake
    pkgs.gcc
    pkgs.patchelf
  ];

  MIX_REBAR3 = "${bp.rebar3}/bin/rebar3";
}
