---
name: project-factory
description: Create a new workflow-managed Elixir project from explicit answers. Load when scaffolding a greenfield project or preparing a factory recipe.
---

# Project Factory

First resolve the factory checkout from this installed skill's physical path.
For Claude the link is `~/.claude/skills/project-factory`; for Codex it is
`~/.agents/skills/project-factory`. Resolve the applicable link with
`cd <skill-link> && pwd -P`, then ascend `../../..` to the factory root. Do not
assume a repository name or fixed checkout path. Invoke every command as
`nix develop <factory-root> --command <factory-root>/bin/factory ...` while
leaving the caller's current directory unchanged.

1. Run `factory wizard --questions`, ask `project_kind` first, then ask
   every returned question whose optional `project_kinds` includes that answer
   (plus every question without `project_kinds`) and whose optional
   `predicate` holds for the answers so far. Do not infer optional decisions
   or decline reasons.
2. Ask every `repository.*` question explicitly. You may propose the owner
   from `gh api user -q .login` and the name from the project directory, but
   the user must confirm or replace each; never choose visibility or license.
3. Put the answers in the returned field structure and run
   `bin/factory wizard --answers <answers.json> --output <recipe.json>`.
4. Run `bin/factory plan --recipe <recipe.json>` and show the resolved plan,
   final target, and repository facts: `<owner>/<name>`, visibility, default
   branch, license, and that a GitHub repository will be created and pushed.
5. Ask for explicit confirmation before creation. That one confirmation also
   covers the outward-facing GitHub step in 8; say so when asking.
6. After confirmation, apply into the caller's existing current directory:
   `factory apply --recipe <recipe.json> --in-place --target "$PWD"`.
7. Run the generated project's own gate from that directory. Stop on failure.
8. Only after a green gate, publish with the recipe's repository facts:
   - `git init -b <default_branch>` unless `git rev-parse --show-toplevel`
     already prints this project directory.
   - Enumerate candidates with `git ls-files --others --exclude-standard`,
     drop the `preexisting_unowned` paths listed in `.workflow/receipt.json`
     (for example `.claude/settings.local.json`), and stage each remaining
     path by name with `git add -- <path>...`; never `git add .` or `-A`.
   - `git commit -m "Initial scaffold from project-factory"`.
   - `gh repo create <owner>/<name> --<visibility> --source . --push`.
   When retrying after `gh repo create` fails, reuse the existing clean initial
   scaffold commit and retry only repository creation and push. Do not create a
   second commit. Stop if the worktree is dirty or the existing commit does not
   represent the generated scaffold.
   GitHub credentials come from the user's `gh` keyring login, not sops.
   If `gh` is not logged in or creation fails, report it and stop; the local
   project and commit remain valid.

The alternative absent-target flow remains available as
`factory apply --recipe <recipe.json> --parent <directory>`.

Do not choose optional decisions for the user, derive destinations, reorder
generator actions, or edit generated files. User answers flow through the
question engine; selection, derivation, and ordering belong to the planner and
applier.
