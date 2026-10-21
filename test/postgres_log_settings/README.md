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
by r3, r4, r5, r6 and R6-1 (handoff `claude-5b-sink-plan-r*.md`). That plan, not this README,
is normative.

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
| `selftest` | T1–T18, including T15a–d, T17a/b and T18a–d with the R6-1 cases `d-vanish` and `d-rebind`. Each test must give its expected verdict, and anything it retains must be in the fixture registry. |
| `discovery` | One B-configured instance, two epochs, no markers. It records real exit statuses, socket outcomes and the inventory, and checks the API-socket lockout (EACCES) on the real sockets. |
| `campaign` | In this order: positive controls P (E1, E2), audit controls A, then the candidate B (E1, E2, and the forced collector-start failure E3). Then the cross-instance search and the count-only report. |

Exit status: 0 pass; 2 refusal (nothing was started); 3 HOLD (uncertainty; everything is
retained); 4 FAIL.

### Guarantees and boundaries
- **Never touched:** port 5520 or 4120, the owner's checkout, any existing `/tmp/devenv-*`,
  any `.devenv/state` other than the throwaway roots it creates, and any owner log.
- **Database access:** the client connects only over the claimed unix socket, to databases on
  the manifest's allowlist, and proves the server's identity before any mutation.
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
