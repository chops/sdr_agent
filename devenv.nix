{ pkgs, config, ... }:

let
  beamPackages = pkgs.beam.packages.erlang_29;
  toolchainTag = "elixir-1.20.4-otp-29.0.5";
in {
  # Elixir/Erlang toolchain
  languages.elixir = {
    enable = true;
    package = beamPackages.elixir_1_20;
  };

  # PostgreSQL as a per-project service
  # Data stored in .devenv/state/postgres, isolated from other projects
  services.postgres = {
    enable = true;
    package = pkgs.postgresql_18;
    initialDatabases = [{ name = "sdr_agent_dev"; } { name = "sdr_agent_test"; }];
    # Listen only on localhost for security
    listen_addresses = "127.0.0.1";
    # REQUIRED: Set the explicit PostgreSQL port from the project recipe.
    # Check local availability with: lsof -nP -iTCP:PORT -sTCP:LISTEN
    # Must also update port in config/dev.exs and config/test.exs
    port = 5520;
    # Create postgres superuser for Phoenix/Ecto default config compatibility
    initialScript = "CREATE USER postgres SUPERUSER;";
  };

  # Additional packages
  packages = with pkgs; [
    # Exact Hex/Rebar versions from the pinned Erlang package set
    beamPackages.hex
    beamPackages.rebar3
    # File watching for Phoenix live reload
    (if stdenv.isDarwin then fswatch else inotify-tools)
    # Useful for debugging
    git
    # Required by Claude hooks in .claude/hooks/*.sh
    jq
  ];

  # Environment variables
  env = {
    # Isolate Mix/Hex artifacts to this project
    # Prevents version conflicts between projects.
    # NOTE: devenv does NOT shell-expand env values — use config.devenv.state
    # (absolute path, resolved at Nix eval time), not the literal "$DEVENV_STATE".
    MIX_HOME = "${config.devenv.state}/mix/${toolchainTag}";
    MIX_BUILD_ROOT = "${config.devenv.state}/build/${toolchainTag}";
    MIX_DEPS_PATH = "${config.devenv.state}/deps/${toolchainTag}";
    HEX_HOME = "${config.devenv.state}/hex";

    # Enable IEx shell history across sessions
    ERL_AFLAGS = "-kernel shell_history enabled";
  };

  # Run on shell entry
  enterShell = ''
    echo ""
    echo "Elixir $(elixir --version | tail -1)"
    echo "Hex $(mix hex.info | head -1)"
    echo "$(rebar3 version)"
    echo "PostgreSQL ${pkgs.postgresql_18.version}"
    echo ""
    echo "Run 'devenv up' to start PostgreSQL"
  '';

  # Pre-commit hooks (optional, uncomment if desired)
  # pre-commit.hooks = {
  #   mix-format.enable = true;
  # };
}
