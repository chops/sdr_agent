{
  description = "Elixir/Phoenix/Ash development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/e8be7818e19ada32105a8af937a6a473b38167ca";
    devenv.url = "github:cachix/devenv/v2.2.1";
  };

  nixConfig = {
    extra-trusted-public-keys = "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=";
    extra-substituters = "https://devenv.cachix.org";
  };

  outputs = inputs@{ nixpkgs, devenv, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forEachSystem = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forEachSystem (system:
        let
          # The app's own pinned Claude CLI (ADR-0004 R0 amendment, item 1).
          # Its unfree licence is allowed for this one package only; every
          # other package keeps the default (unfree refused).
          appCliPkgs = import nixpkgs {
            inherit system;
            config.allowUnfreePredicate = pkg: nixpkgs.lib.getName pkg == "app-claude-cli";
          };
        in
        {
          devenv-up = inputs.self.devShells.${system}.default.config.procfileScript;
          app-claude-cli = appCliPkgs.callPackage ./nix/app-claude-cli.nix { };
        });

      devShells = forEachSystem (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = devenv.lib.mkShell {
            inherit inputs pkgs;
            modules = [ ./devenv.nix ];
          };
        });
    };
}
