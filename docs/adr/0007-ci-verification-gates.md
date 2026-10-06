---
status: proposed
date: 2026-10-06
supersedes: null
---

# ADR-0007: CI Verification Gates and Hermetic-Test Proof

## Status

Proposed (2026-10-06, Claude, slice S0). Becomes accepted on Codex's recorded
approving verdict on the S0 pull request (ADR-0001: agent design ADRs are
accepted on peer approval; the owner can veto).

## Context

ADR-0001 makes merges to `main` depend on green CI, and the MVP definition of
done requires format, `--warnings-as-errors` compile, ExUnit, Ash codegen
check, Credo, a secret scan, and proof that tests pass with outbound network
unavailable. Facts found while building S0:

- `bin/verify` is a factory `managed_file` whose sha256 is pinned in
  `.workflow/receipt.json`; editing it fails `bin/verify-workflow`.
- Credo was not a dependency.
- `gitleaks/gitleaks-action` v2+ is under the Gitleaks EULA, free for
  repositories owned by personal accounts (this one is), and downloads the
  gitleaks binary at run time.
- The factory scaffold commit contains four Phoenix/AshAuthentication
  generator secrets for local dev and test (`config/dev.exs`,
  `config/test.exs`) that gitleaks flags.
- On GitHub-hosted runners the runner agent runs as the same Unix user as job
  steps, so blocking that uid with iptables would also cut the runner off.
- `mix deps.get` reports published advisories against the factory pins of
  `ash`, `ash_authentication`, `ash_authentication_phoenix`, `igniter`, and
  `usage_rules` (2026-10-06).

## Options Considered

### Hermetic proof: iptables owner match vs. network namespace

iptables on the runner uid breaks the runner itself. A fresh network namespace
(`sudo unshare --net`, loopback only, then `setpriv` back to the runner uid)
isolates only the gate's processes; Postgres runs inside the namespace on
`127.0.0.1:5520`, so no service container or port mapping is involved. The Nix
daemon stays outside and may substitute store paths; it is build tooling, not
code under test.

### Script tests: edit `bin/verify` vs. ExUnit

Editing `bin/verify` breaks the factory receipt. ExUnit tests under
`test/scripts/` run the scripts as child processes and are already part of
`mix test`, so `bin/verify` covers them unchanged.

### Secret-scan allowlist: path allowlist vs. exact fingerprints

A path allowlist would hide future leaks in those files. `.gitleaksignore`
lists the four reviewed findings by exact fingerprint.

## Decision

We will run one CI job, `verify` (the required status check on `main`), on
pull requests and pushes to `main`:

1. Checkout with full history; gitleaks secret scan (action pinned by SHA,
   gitleaks 8.30.1 pinned, PR comments and artifact upload off).
2. Install Nix and build the repository's devenv shell (`nix develop
   --impure`), so CI uses the same pinned toolchain as local development.
3. Online preparation: `mix deps.get`, dependency compilation for dev and
   test; `mix hex.audit` as an **advisory** step (doctrine: dependency audits
   stay advisory until promoted).
4. Inside a loopback-only network namespace: prove outbound requests fail,
   start a throwaway Postgres 18 on `127.0.0.1:5520`, then run `bin/verify`
   (workflow receipt, format, compile `--warnings-as-errors`, `mix test`),
   `mix ash.codegen --check`, and `mix credo`.

Supporting choices:

- Add `{:credo, "== 1.7.19", only: [:dev, :test], runtime: false}` (MIT,
  Hex). Credo runs at default priority and blocks; the five generated modules
  it flagged received meaningful `@moduledoc`s rather than a disabled check.
- All third-party actions are pinned by full commit SHA.
- Branch protection on `main`: pull request required, required check
  `verify`, no required approving reviews (both agents push as the same GitHub
  user, ADR-0001), admins not enforced (owner veto), force pushes and deletion
  disallowed, linear history required.

## Justification

The namespace approach is the only one of the options that both proves no
outbound access for code under test and keeps the runner working. Keeping
`bin/verify` untouched preserves the factory receipt while still gating the
scripts.

## Consequences

### Positive

- Local `bin/verify` and CI run the same gate in the same toolchain.
- A test that needs the network fails in CI.

### Negative

- Nix shell build time on cold caches.
- gitleaks-action is not open source (EULA); replacing it with the gitleaks
  binary from nixpkgs is a drop-in alternative if the terms change.
- The dependency advisories above are not fixed by this ADR; bumping those
  pins needs its own reviewed ADR and compatibility check (ADR-0001).

### Neutral

- Credo `--strict` design suggestions are not enforced.
