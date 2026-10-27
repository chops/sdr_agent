# Project Environment Facts

Lifecycle: `seed_once`; project-owned after creation.

- Project name: `sdr_agent`
- Operating system: `darwin`
- Shell: `zsh`
- Environment manager: `devenv (Nix flake via direnv)`
- Unavailable tools: `none`
- Local services and explicit ports: PostgreSQL `5520`, Phoenix `4120`
- Agent environment `agentenv-1` (ADR-0004 agent-environment amendment,
  D-224): Phoenix `4130` on loopback only; database `sdr_agent_agentenv` on
  PostgreSQL `5520`
- Project topology: `single app`
- Agent trust: Codex project doctrine and skills require this repository to be
  trusted on first open; Claude reads the checked-in bootstrap directly.

These facts are initialized from recipe answers. A later payload refresh must
not overwrite project-owned values.
