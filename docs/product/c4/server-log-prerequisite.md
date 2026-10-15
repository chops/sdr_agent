# C4 prerequisite 5b: PostgreSQL server log (proposal)

**Status:** PROPOSED, draft 2, 2026-10-14. Draft 1 (`86f27fe`) was
reviewed by Codex, NEEDS-REVIEW, with three must-fixes: retention,
the sink test, and activation. This draft answers them. Nothing is
configured by this document or its review.

**Owner direction (2026-10-14 11:55 MDT, standup 5b):** "i approve option
1's direction for 5b", after Codex's recommendation (consultation reply
4aff1677). Direction only. This proposal is the reviewed step that the
direction calls for.

**What it gates** (ADR-0005 C4 amendment, "PostgreSQL server log"; C4
readiness section 7): before any private settings content is saved, and
before the real-data switch is turned on, either this configuration is
accepted with its own test, or the owner accepts an explicit retention
exception for the server log. C4 code can proceed on synthetic fixtures
meanwhile, under its own gates.

## 1. The problem

The app's own logging controls (ADR-0005 C4 amendment) do not reach the
PostgreSQL server. The server can write private values to its log in
several ways:

- **Failing statements.** `log_min_error_statement` defaults to `error`,
  so the SQL text of any failing statement is logged. `log_statement=none`
  does not stop this.
- **Error detail.** `log_error_verbosity=default` includes `DETAIL`, which
  for constraint violations carries the key or the whole failing row.
- **The primary message itself.** Some errors put the input value in the
  main message (for example, an invalid value for a type). No setting
  removes that; `terse` only drops `DETAIL`, `HINT`, `QUERY` and
  `CONTEXT`.
- **Bind parameters.** Settings limit logged parameters, but they do not
  redact values written into SQL literals or into primary messages.

So no setting makes the log content-free. This proposal reduces what the
server writes, puts it in owner-only files that are pruned after 7 days of running time, and
asks the owner to accept the small residual explicitly.

## 2. Facts (read-only checks, 2026-10-14)

From Codex's recommendation and Claude's own metadata checks. No log
contents were read or copied.

- **Server:** PostgreSQL 18.6 on 127.0.0.1:5520. It is one cluster for
  this project (data in `.devenv/state/postgres`, mode 0700), not a
  cluster shared with other projects.
- **Its databases:** `sdr_agent_dev` (the owner's demo database, where
  private content will be entered), `sdr_agent_test` and its partition
  copies `sdr_agent_test<N>` (synthetic only), and `sdr_agent_calibration`
  (the calibration console). The implementation step lists the live
  databases instead of trusting this list.
- **Logging settings:** all defaults (`log_destination=stderr`,
  `logging_collector=off`, `log_error_verbosity=default`,
  `log_min_error_statement=error`, `log_statement=none`,
  `log_parameter_max_length=-1`, `log_parameter_max_length_on_error=0`,
  duration and sampling off).
- **Where the output goes today.** With the collector off, the server's
  stderr is captured by devenv's process manager:
  - `/private/tmp/devenv-ef8ad69/processes/logs/postgres.stderr.log`:
    mode 0644, in directories that are world-readable (0755). It is
    about 11 MB, written since Oct 8, with no rotation.
  - `.devenv/state/process-compose/process-compose.log`: mode 0600,
    about 15 MB. It also holds PostgreSQL messages.
  - `.devenv/processes.log`: mode 0644, about 7 MB. This is historical
    output.
  - Older `postgres.stderr.log` files from earlier devenv sessions: five
    in total under `/private/tmp/devenv-*/processes/logs/`.
- **How devenv applies settings.** In the project's locked devenv
  revision (`fe20b5cba7ab5e93ae73f956a8d3efc50e1753f4`,
  `src/modules/services/postgres.nix` lines 151 to 197, confirmed by
  Codex), the generated `postgresql.conf` is copied into `$PGDATA` on
  every start, outside the first-init branch. That does not override
  PostgreSQL's other configuration sources: `postgresql.auto.conf`, the
  command line, and role, database or session settings. The activation
  receipt (section 6) checks all of them.
- **Extensions:** debug print flags are off, and the shared, session and
  local preload settings are empty. No logging-related role or database
  defaults exist (Codex's read-only check, 2026-10-14).
- **Who can change the settings.** The app connects as `postgres`, a
  SUPERUSER (devenv `initialScript`). The settings are defaults, not a
  security boundary against that role. This proposal does not change
  roles.

## 3. Proposal

### 3.1 Where to set it: the cluster, in `devenv.nix`

**Recommended:** set the logging baseline once for the whole cluster
through `services.postgres.settings` in `devenv.nix`.

Codex suggested per-database defaults (`ALTER DATABASE ... SET`) to avoid
changing a shared cluster. This cluster is not shared: it belongs to this
project only. Setting it at the cluster level has these advantages:

- every database is covered, including test partitions, the calibration
  database and any database created later;
- it survives a re-created database or data directory;
- it is reviewed in git like any other change, instead of being a manual
  step that can be forgotten;
- it needs no privileged statements against the owner's demo database.

The trade-off: the test databases also lose failing-statement detail in
the server log. App-side errors still carry the error class, and tests
read errors from the client, not the server log.

**Alternative:** per-database `ALTER DATABASE` defaults for
`sdr_agent_dev` and `sdr_agent_calibration`, applied by a reviewed
script that the owner runs. This is weaker: it does not cover re-created
databases unless the script is rerun, and it touches the demo database.

### 3.2 The baseline

```text
log_error_verbosity = terse
log_min_error_statement = panic
log_statement = none
log_parameter_max_length = 0
log_parameter_max_length_on_error = 0
log_min_duration_statement = -1
log_min_duration_sample = -1
log_transaction_sample_rate = 0
log_duration = off
debug_print_parse = off
debug_print_rewritten = off
debug_print_plan = off
```

`log_destination` and the collector are set in 3.3. No logging extension
or preload library is loaded; the invariant test checks that.

`log_min_error_statement` has no `off` value. `panic` is the documented way
to stop ordinary failing statements from being logged; a PANIC can still
log its statement.

### 3.3 One collector sink, owner-only

Turn the logging collector on, so the server writes its own log files
instead of sending everything to the process manager:

```text
log_destination = 'stderr'       # the collector captures stderr
logging_collector = on
log_directory = 'log'            # inside the data directory (0700)
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_file_mode = 0600
log_rotation_age = 1d
log_rotation_size = 50MB
log_truncate_on_rotation = off
```

- The server log lives in `.devenv/state/postgres/log/`, which only the
  owner's account can read.
- **Each file is named by its start time** and is never reused or
  appended to after a restart. That makes a file's age readable from its
  name alone.
- `log_destination` is set explicitly, because the design depends on
  having that destination and no other. The activation receipt (section
  6) checks it.

**What still reaches stderr.** Messages written before the collector
starts, and the collector's own failures, still go to stderr. Under
devenv, stderr goes to the process manager's files. The sink test
(section 4.1) measures what actually lands there.

### 3.4 Retention: a pruning step, with the stopped-server gap stated

Log files can't bound their own age, so a separate step deletes the old
ones. **The policy proposed for review:**

- **The rule:** a collector file whose name's start time is more than 7
  days old is deleted.
- **When it runs:**
  - **at every server start,** by a small reviewed script that runs as a
    devenv task before PostgreSQL starts, so before the app can connect;
  - **hourly while devenv is up,** by the same script as a devenv
    process.
- **What it deletes:** only files in `.devenv/state/postgres/log/` whose
  names match the collector's pattern exactly. Anything else in that
  folder is left alone and reported.
- **How it fails:** if the script fails or meets an unexpected file, it
  stops PostgreSQL from starting (at start) or reports the failure
  (hourly). It never deletes outside the log folder.

**The gap the owner must choose on, stated plainly:**

- **While the server is stopped,** nothing runs, so files stay at rest
  (mode 0600, owner-only) until the next start, however long that is.
- **Before the next private-content use,** the server must start, so the
  start-time pruning has already run by then.

So the maximum age is "7 days of running time, plus however long the
server is stopped". This is **not** a seven-day limit on files at rest,
and the owner's acceptance in section 5 has to say so (Q3).

**Size:** each file rotates at 50 MB. There is no total size cap; disk
use is bounded by the 7-day pruning while the server runs.

**Tests:** repeated short starts, a missed daily rotation, files with
start times on either side of the 7-day boundary, a non-matching file,
and a pruning failure that has to stop the start. All run on the isolated
test setup of section 4.

This script is a new, reviewed part of the change. It is not run on the
owner's server until the owner restarts their own `devenv up` (section
6).

### 3.5 Logs written before the change

New settings do not erase the logs already written (the files listed in
section 2). Deleting them is destructive, so it is the owner's decision
and the owner's action:

- **(a)** the owner deletes the old PostgreSQL output files once the new
  settings are verified; or
- **(b)** keep them.

Claude has not read these files and won't. What they can contain depends
on what was entered in the demo database before now.

**Recommended:** (a) if the demo database has ever held real people's
data, and (b) otherwise. The owner knows which applies. The activation
receipt records the choice.

### 3.6 Copying

The logging settings say nothing about backups, exports or copies of the
data or log folders. **"Never copied, uploaded or committed" is an
operating rule**: the owner and the agents keep the log folder out of
backups, uploads and git. It is stated here as an obligation, not as
something the settings achieve. `.devenv/` is already git-ignored.

## 4. The tests

All tests use only synthetic values. None runs against the owner's
server or the demo database, and none reads an existing log file.

### 4.1 The sink test: through devenv's own launcher

A bare PostgreSQL instance would write no process-manager files, so it
could pass without testing the files that motivated this prerequisite.
The sink test therefore uses the same launch path as the project:

1. **Set up a throwaway devenv project** in a temporary folder:
   - it uses the project's locked devenv revision (`fe20b5c`) and the
     same PostgreSQL package;
   - it uses the same `services.postgres` settings and pruning task as
     the change;
   - it listens on a free local port, never 5520.
2. **Start it with `devenv up`,** so devenv's process manager captures
   stdout and stderr exactly as it does for the project.
3. **Trace every sink it creates.** Before and after the run, list every
   file under the throwaway's `.devenv/`, its `/private/tmp/devenv-*`
   runtime folder, and the collector folder. For each file, record its
   path, owner, mode and the modes of the folders above it.
4. **Run the canaries** (section 4.2), then a restart, then the canaries
   again.
5. **Force a collector start failure** (an unwritable log folder) and
   record where the server's messages go and whether the server starts.
6. **Search every traced file** for every marker.

**Pass criteria:**

- no marker in any process-manager file;
- markers only where section 5 allows them;
- every traced path, mode and owner listed in the report.

**Fail closed:** if a marker appears in a process-manager file, or a
sink can't be traced, the test fails. 5b stays open and the section 5
exception cannot be offered. The proposal then comes back with that
finding: for example, tightening the process-manager files, or an
explicit owner choice about them. Any failure path the test can't
exercise is listed as an unverified residual, not counted as passing.

### 4.2 The canaries

Each uses a unique random marker string, never a private value:

- a unique-key violation (the key in `DETAIL`);
- a check-constraint violation (the failing row in `DETAIL`);
- a type error whose primary message includes the value, as a bound
  parameter (extended protocol, through Postgrex);
- a failing statement with the marker in a SQL literal;
- a slow statement (to confirm duration logging is off);
- a connection-level failure with the marker in the client-supplied
  application name. This is a primary message at a severity other than
  ERROR.

**Expected:**

- markers from `DETAIL`, statements, parameters and durations: absent
  everywhere;
- markers in primary messages: present only in collector files (mode
  0600). This is the residual in section 5.

### 4.3 The invariant test in the repository

A small ExUnit test checks the key settings on the test connections
(`current_setting('log_min_error_statement') = 'panic'` and so on,
including `log_destination`, `logging_collector` and
`shared_preload_libraries`, `session_preload_libraries` and
`local_preload_libraries` all empty). It catches drift if `devenv.nix`
changes. It runs only against the test cluster, never the demo database.

**CI** doesn't use devenv or a service container:
`.github/scripts/hermetic-verify.sh` runs its own `initdb`/`pg_ctl`
cluster inside the network namespace. Whether CI gets the same settings,
so that the invariant runs there too, is Q4. If yes, the change applies
them in that script and keeps it hermetic.

The sink test and the canaries are kept as a script with the proposal,
and rerun after any `devenv.nix`, devenv or PostgreSQL upgrade.

## 5. The residual, for the owner to accept or reject

After this change, PostgreSQL can still write a private value to its log
whenever a value appears in an **unredacted primary server message at any
logged severity**. Some examples:

- an error whose primary message includes the input value;
- a PANIC that logs its statement;
- a connection or authentication message that names a client-supplied
  value.

Settings cannot remove these. They go only to the collector files,
subject to the sink test confirming it:

- **location:** `.devenv/state/postgres/log/`, on this machine only;
- **access:** files mode 0600, folder mode 0700, the owner's macOS
  account only;
- **retention:** deleted 7 days after the file's start time, while the
  server runs. **While the server is stopped, files stay at rest until
  the next start, with no time limit** (section 3.4);
- **copying:** never copied, uploaded or committed, as an operating rule
  (section 3.6).

**Extensions:** no logging extension or preload library is in use today
(Codex's metadata check, 2026-10-14). The invariant and the activation
receipt check that this is still so. Adding one would reopen 5b.

**What the sink test may add:** whatever the sink test finds in
process-manager files (section 4.1) is written here before acceptance.
If it finds any marker there, this exception does not cover it.

**The request:** the owner accepts this specific server-log retention
exception, with the paths, access, retention and at-rest gap above. This
is not a blanket exception. If the sink test or the activation receipt
finds anything outside these bounds, the exception does not apply.

## 6. Order of work, and what closes 5b

1. Codex reviews this proposal.
2. The owner decides Q1 to Q5.
3. Claude builds the change test-first (the invariant test fails on the
   current settings). It includes:
   - the `devenv.nix` settings;
   - the pruning script, task and process;
   - the sink-test and canary script;
   - the invariant test;
   - the CI script change, if Q4 is yes;
   - a read-only receipt script.

   Codex reviews it. No dependency source or pin changes.
4. Claude runs the sink test and canaries on the throwaway setup and
   writes a report. Codex reviews the report.
5. The owner restarts their own `devenv up`, then runs the receipt
   script. Claude does not restart the owner's server or connect to the
   demo database.
6. **The activation receipt.** It is read-only and prints metadata only:
   no log contents, no app data, no writes. It checks:
   - **the target:** the cluster and port (127.0.0.1:5520), and that
     the connected databases are the app's, the calibration console's
     and any other database that can hold private content;
   - **effective settings,** on fresh connections to each of those
     databases: every baseline and collector setting, with its source
     (`pg_settings.source` and `sourcefile`), and no `pending_restart`;
   - **overrides:** none in `postgresql.auto.conf`, on the command line,
     or as role or database defaults (`pg_db_role_setting`). If the app
     sets any of these settings on its own connections, that counts too.
     The app's pools have reconnected since the restart;
   - **sinks:** `pg_current_logfile()` is in the collector folder; the
     folder and file paths and modes; the pruning task ran;
   - **old copies:** the owner's choice from section 3.5 is recorded.

   **Any mismatch, or anything that can't be read or verified, leaves 5b
   open.** Nothing is reset or fixed automatically; a fix is a new,
   reviewed step.
7. The owner accepts or rejects the section 5 exception, with the
   receipt in hand. **5b closes only when the receipt passes and the
   owner accepts.** Only then can private settings content be saved, or
   the real-data switch turned on.

The settings are defaults, not a security boundary: the app's SUPERUSER
login could change them for its own session. This proposal does not
change roles (section 8).

**Estimate:** about a day of build and test after the decisions, outside
the R0 critical path. It must close before the owner enters the D-053
writing guide or other private settings, and before the real-data
switch.

## 7. Open questions for the owner

- **Q1. Where to set it.** Recommended: the cluster, in `devenv.nix`
  (3.1). Alternative: per-database defaults.
- **Q2. Old log files.** Recommended: the owner deletes them after
  verification (3.5 a) if the demo database has ever held real people's
  data. Otherwise keep them (b).
- **Q3. Retention.** Recommended: 7 days while the server runs, pruned at
  every start and hourly, with files kept at rest while it is stopped
  (3.4). Alternatives: a shorter window, or the owner also deletes the
  folder by hand before any long stop.
- **Q4. CI.** Should CI's own throwaway cluster
  (`.github/scripts/hermetic-verify.sh`) use the same settings, so the
  invariant runs there too? Recommended: yes, in the same PR, keeping
  CI hermetic.
- **Q5. Process-manager files.** If the sink test finds markers in
  devenv's process-manager files, should the next revision tighten those
  files, or come back to the owner for an explicit choice? Recommended:
  tighten them, as a separate reviewed step.

## 8. Not in scope

- Production or any deployed database. None exists yet. A deployment
  needs its own logging review.
- Database roles, the SUPERUSER login, and `pg_hba.conf`.
- Changing devenv's process-manager logging in this change (see Q5).
- The app-side logging controls, already decided in the ADR-0005 C4
  amendment.
