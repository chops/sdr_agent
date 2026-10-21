# PostgreSQL server-log settings (5b)

This directory holds the checks for the 5b server-log baseline (D-178, #156): where the
PostgreSQL server writes its log, and what it may write there.

- `expected-contract.conf`: the approved `postgresql.conf` lines, in devenv's spelling.
- `devenv-render-test.sh`: the CI check that the locked devenv module renders exactly those
  lines.
- The **sink test** (below): the disposable, owner-run campaign behind the 5b sink report.

## Sink test

The sink test starts throwaway devenv projects through the project's locked launcher. It
sends synthetic canaries, then checks where every marker could land, using count-only
searches of every file the launch path can write. The design is reviewed plan r2 as amended
by r3, r4, r5, r6 and R6-1 (handoff `claude-5b-sink-plan-r*.md`), repaired per
`claude-5b-harness-repair-plan.md`, its amendment, the binding A1/A2, and the ba40b5b
dispositions with their binding Q1–Q4. Those documents, not this README, are normative.

| File | Role |
|---|---|
| `sink-test.sh` | Orchestrator. Modes: `--dry-plan`, `selftest`, `discovery`, `campaign`. |
| `sink_watch.py` | Process watcher and evidence tools: manifest, runtime claim, provenance, kqueue/libproc identity, verified signalling, listener proof, API-socket lockout, inventory, snapshots, counting, epoch classification. |
| `sink_selftest.py` | Fixture registry, fixture programs and the synthetic self-tests. |
| `sink_canaries.exs` | Entry point for the Postgrex client. The logic is `SdrAgent.Test.PostgresLogSinkCanaries` in `test/support`. |

### Running it

These are owner actions, each run under a fresh DB-slot claim. None of them runs in CI (see below).

```sh
bash test/postgres_log_settings/sink-test.sh --dry-plan          # starts nothing
bash test/postgres_log_settings/sink-test.sh selftest  --scratch DIR --evidence DIR
bash test/postgres_log_settings/sink-test.sh discovery --scratch DIR --evidence DIR \
     --selftest-summary <selftest evidence>/selftest/selftest-summary.json
bash test/postgres_log_settings/sink-test.sh campaign  --scratch DIR --evidence DIR \
     --selftest-summary ... --discovery-summary <discovery evidence>/discovery-summary.json
```

- `DIR` must be a physical, 0700 directory that you own.
- The worktree must be clean.
- The summaries must be for the same head.

| Mode | What it does |
|---|---|
| `--dry-plan` | Prints the plan constants and the shape of each instance manifest. Builds nothing, starts nothing, creates nothing, reads no runtime or log path. |
| `selftest` | T1–T8, T9a/b, T10–T14, T15a–d, T16, T17a/b and T17-baseline, T18a–d with the R6-1 cases `d-vanish` and `d-rebind`, T19a–i, T20a–f, T21a–e, T22a–d, T23a–e, T24, T25, T26a–d and T27. Each test runs under an independent outer controller. Its observed class must equal its fixed expected class, its exact per-test proof contract must be met, and an independent reconciliation (fixture trees against their declared contents, retained instances against their inventory and retention contract) must find nothing unauthorized. Fixtures are disposed of only after validation, and a final audit re-checks everything retained. The suite stops at the first other result (exit 3). |
| `discovery` | One B-configured instance, two epochs, no markers. It records real exit statuses, socket outcomes and the inventory, and checks the API-socket lockout (EACCES) on the real sockets. |
| `campaign` | In this order: positive controls P (E1, E2), audit controls A, then the candidate B (E1, E2, and the forced collector-start failure S5). Every epoch needs a complete classification; an INCOMPLETE one stops the run before any later instance. Then the cross-instance search over SNAP-0, SNAP-pre and SNAP-post of every required epoch, and the count-only report. S5 must show the forced failure was exercised, otherwise the result is NOT-EXERCISED (exit 4, roots retained). |

Exit status: 0 pass; 2 refusal (nothing was started); 3 HOLD (uncertainty; everything is
retained); 4 FAIL.

Every wait on a background job has a monotonic deadline. A job still running at its deadline
is HOLD, and the script never signals it. Self-tests and the long observation commands run
under an independent observer process with its own receipts. Any recorded watcher violation
freezes signals at once. The exit path sends at most one stop, and only after a known FAIL
(exit 4) with a current, clean, unfrozen watcher status; after any HOLD or unknown status
the instance is left for disposition.

### Guarantees and boundaries
- **Never touched:** port 5520 or 4120, the owner's checkout, any existing `/tmp/devenv-*`,
  any owner log, and any owner, shared-app, runtime or database state.
- **Dev shell (deviation D-5):** the client runs through `nix develop` in the candidate
  worktree. Entering that shell runs devenv's `enterShell` and `files:cleanup` tasks in the
  candidate worktree's **own** `.devenv` (build and dependency caches). That is the only
  `.devenv` outside the throwaway roots that the harness causes to be written.
- **Image checks (deviation D-7):** the package-bin-directory image check is supplementary.
  The "no API client" fact H rests on the verified command and source closure plus the
  watcher's image observations and the exact `/bin/sh` forms, never on the directory check
  alone.
- **Database access:** the client connects only over the claimed unix socket, to databases on
  the manifest's allowlist, and proves the server's identity before any mutation. A read-only
  pre-connect socket/lock guard is supplementary only; it replaces none of the identity,
  system-identifier, settings or listener checks.
- **Audit limitation (Q3):** inside the throwaway copies, the contents of PostgreSQL storage
  directories and the copy's `.git` are accepted by their reviewed inventory class. A stray
  object placed there is not distinguishable; the harness does not claim universal stray
  detection.
- **On failure:** nothing is deleted. Evidence (dir 0700, files 0600) and instance roots are
  retained and reported. Disposal is a separately reviewed step.
- **Publication:** count-only. No raw log, error message or marker in context is printed,
  committed or uploaded.
- **Scope of claims:** they hold only under the reviewed launch envelope: `PGHOST=<runtime>/postgres`, an
  owned `HOME` and `TMPDIR`, and the manager API sockets locked during marker epochs. Foreign
  same-uid interference is outside the claim.
- **Residuals that keep 5b open:** the unexercised init-only collector failure, and
  forced-failure attempts whose output was truncated.

### Not in CI
CI's render check already builds the locked `devenv-up`, process-compose included. Keeping
this campaign out of CI is a scope, cost and platform choice: it is a long-running stateful
service campaign, the claim is about the owner's macOS launch path, and its evidence is
private.

### Rerun triggers
Rerun on any change to:
- `flake.lock`, `flake.nix`, `devenv.nix` or `priv/postgres/log_settings.json`;
- `expected-contract.conf`;
- the PostgreSQL, process-compose or devenv-tasks store paths, or any normalized generated
  launch artifact;
- these harness files;
- a rebase that changes any of them.

No result transfers to another launcher or head.
