# Project Environment Facts

Lifecycle: `seed_once`; project-owned after creation.

- Project name: `sdr_agent`
- Operating system: `darwin`
- Shell: `zsh`
- Environment manager: `devenv (Nix flake via direnv)`
- Unavailable tools: `none`
- Local services and explicit ports: PostgreSQL `5520`, Phoenix `4120`
- Project topology: `single app`
- Agent trust: Codex project doctrine and skills require this repository to be
  trusted on first open; Claude reads the checked-in bootstrap directly.

These facts are initialized from recipe answers. A later payload refresh must
not overwrite project-owned values.
