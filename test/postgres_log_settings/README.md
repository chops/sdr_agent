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
| `selftest` | T1–T8, T9a/b, T10–T14, T15a–d, T16, T17a/b and T17-baseline, T18a–d with the R6-1 cases `d-vanish` and `d-rebind`, T19a–i, T20a–g, T21a–e, T22a–d, T23a–e, T24, T25, T26a–d, T27, T28a–c, T29a/b and the T4a-repair controls T30a–g and T30i–x, T31a–h, T32–T35, T36a–d, T37 and T38. The capability gate T35 (separate `EV_UDATA_SPECIFIC` knotes per registration token, with an exact-tuple removal oracle), the interface gate T30w (the `KERN_PROCARGS2` oldlen bound `kern.argmax + sizeof(int)` from the public XNU source, its EINVAL and truncation behaviour, with no layout decoding) and the layout gate T30m (the H-pad hypothesis on owned argv-tolerant fixtures) run first, in that order; if any fails, the suite stops before anything relies on them. T30x then checks that T30m's exception paths join every owned fixture and keep the primary failure. Each test runs under an independent outer controller. Its observed class must equal its fixed expected class, its exact per-test proof contract must be met, and an independent reconciliation (fixture trees against their declared contents, retained instances against their inventory and retention contract) must find nothing unauthorized. The outcome and the proof are decided before anything is disposed of; an unexpected result keeps all its evidence. Disposal itself is validated, and a final audit re-checks everything retained. The suite stops at the first other result (exit 3). |
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
- **Process observation (T4a repair):** events are attributed only by their registration
  token (`EV_UDATA_SPECIFIC` udata) to one sealed generation of a pid, never by pid alone.
  Image and argv come from one fenced snapshot (`proc_pidpath` and `KERN_PROCARGS2` between
  two empty event fences); nothing is attributed partially or from an earlier image. The
  pending event queue and every snapshot obligation are bounded, and a new exec never resets
  an obligation's earliest deadline. Two premises stay **unverified hypotheses**, gated by
  tests and never by a runtime fallback: the H-pad argument layout (alignment 8, T30m), and
  the kernel ordering of exec events before later reads (sampled by T30j). Unknown argument
  vectors grant nothing and are kept only as metadata (argc, lengths, sha256), which is no
  proof that no environment bytes were read; PostgreSQL children keep only their title.
  An image alone never grants an operational role: a missing, unsupported or
  unrepresentable vector gives `unknown-argv` with a violation (no signal, fork or form
  permission). Every nested stage (child census including its last read, admission
  including its final parent read, snapshot reads and path resolution, fences, lsof
  waits, expired-obligation judgement, and the final identity proof before a signal) runs
  under the shared absolute bound; a stage that returns late is not valid and starts no
  later stage, and an effect is refused while a required image observation is unresolved
  or expired.
- **Unmeasured premises (returned, not waived):** T35's ENOENT-on-zombie removal oracle is
  unverified; any other result is a non-pass, never a pid-only fallback. T30m's empty or
  short argv0 start-up is an unverified fixture premise, and A = 8 stays a hypothesis.
  The PostgreSQL logger and backend title measurement (T30h) is OPEN: T30p's fabricated
  title is not that measurement, and no discovery or campaign title proof is claimed until
  a confirmatory D measurement is authored and reviewed (if T25 needs a changed or
  unmeasured rule, the dependency is returned or an owned reviewed measurement is
  integrated earlier; the exact title and forms are never relaxed to rescue a test).
  T30g measures the shell and popen vectors only, not the devenv-tasks wrapper vector; the
  wrapper vector comes from T4a's ps display strings and stays an unmeasured premise. The
  Elixir format check run so far (`Code.format_string!` with the pinned Elixir) is partial;
  the configured `mix format` with plugins is still owed under the final gate.
- **No bytecode:** every interpreter call uses `-I -B`, and `sink_selftest.py` sets
  `sys.dont_write_bytecode` before its local import (T34 checks this in a disposable copy).
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
- **Live stack left:** when a stop, the watcher's exit or the barrier fails, or the exit
  path leaves a watcher running, the harness writes `<evidence>/LIVE-STACK-LEFT.json`. It
  lists the identities last observed in the watcher state, separately from fresh kernel
  reads (alive, gone, reused, unknown, and live children the state never recorded), plus
  the instance root, runtime and port, and every registered fixture still alive (a T4
  decoy stays alive after a failed stop or barrier, and is listed). The caller's failure
  context and the watcher's identity are passed in, and a failure context alone requires
  the record even when the state looks clean. A missing or unreadable state, a malformed
  entry, an unreadable registry, and a registry entry with a missing or unrecognized kind
  or a process entry without a process identity are recorded as unknown, never as an
  empty set. The
  record sends no signal and has no recovery authority; if writing it fails, the original
  HOLD stands.
- **Publication:** count-only. No raw log, error message or marker in context is printed,
  committed or uploaded.
- **Scope of claims:** they hold only under the reviewed launch envelope: `PGHOST=<runtime>/postgres`, an
  owned `HOME` and `TMPDIR`, and the manager API sockets locked during marker epochs. Foreign
  same-uid interference is outside the claim.
- **Residuals that keep 5b open:** the unexercised init-only collector failure, and
  forced-failure attempts whose output was truncated.

### Recovery runbook
A live stack is dispositioned by hand, after a case-specific review, never by an automatic
TERM. This is a procedure, not a script:
1. Read `LIVE-STACK-LEFT.json` and the retained evidence. Re-check every identity fresh and
   completely (pid, birth time, uid, parent, image) against the last-observed record.
2. Get a reviewed ruling for this case. Only then send one SIGTERM, to process-compose only.
3. Wait, with a bound.
4. Take a census of the whole tree by kernel identity.
5. Compare open handles and listeners with the retained evidence.
6. Prove the stack quiet. Only then disposition any retained fixture (such as the T4 decoy)
   separately, by its registered identity.
7. Release the DB slot only after the review accepts the result.

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
