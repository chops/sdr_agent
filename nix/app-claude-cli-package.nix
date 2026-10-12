# Entry point for the app's pinned Claude CLI (ADR-0004 R0 amendment item 1,
# story R0-02), built with `nix build -f nix/app-claude-cli-package.nix`
# (bin/app-claude-cli-root does this and keeps the GC roots).
#
# flake.nix is a project-factory managed file (its hash is recorded in
# .workflow/receipt.json), so the package is not a flake output. It uses the
# exact nixpkgs the flake is locked to: the root `nixpkgs` input of
# flake.lock, fetched by its locked rev and narHash.
#
# The CLI's unfree licence is allowed for this one package only
# (pname app-claude-cli); every other package keeps the default.
{ system ? builtins.currentSystem }:

let
  lock = builtins.fromJSON (builtins.readFile ../flake.lock);
  nixpkgs = builtins.fetchTree lock.nodes.${lock.nodes.root.inputs.nixpkgs}.locked;
  pkgs = import nixpkgs {
    inherit system;
    config.allowUnfreePredicate = pkg: pkgs.lib.getName pkg == "app-claude-cli";
  };
in
pkgs.callPackage ./app-claude-cli.nix { }
