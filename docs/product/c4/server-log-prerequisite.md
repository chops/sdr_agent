# C4 prerequisite 5b: PostgreSQL server log (proposal)

**Status:** PROPOSED, draft 1, 2026-10-14. Not reviewed. Nothing is
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
server writes, puts it in one owner-only file with bounded retention, and
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
- **How devenv applies settings.** In the devenv module source checked,
  `services.postgres.settings` is written to `$PGDATA/postgresql.conf` on
  every start, not only at first creation. This has to be confirmed
  against the project's locked devenv revision (`fe20b5c`) before it is
  relied on.
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

`log_min_error_statement` has no `off` value. `panic` is the documented way
to stop ordinary failing statements from being logged; a PANIC can still
log its statement.

### 3.3 One sink, owner-only, with bounded retention

Turn the logging collector on, so the server writes its own log files
instead of sending everything to the process manager:

```text
logging_collector = on
log_directory = 'log'            # inside the data directory (0700)
log_filename = 'postgresql-%a.log'
log_file_mode = 0600
log_rotation_age = 1d
log_rotation_size = 0
log_truncate_on_rotation = on
```

With these settings:

- the server log lives in `.devenv/state/postgres/log/`, which only the
  owner's account can read;
- there is one file per weekday, and each file is truncated when the
  server rotates into it, so retention is about seven days without any
  cleanup job. **One gap:** PostgreSQL truncates only on a timed
  rotation, not at server start. If the server was stopped across a
  rotation, the reused file keeps older lines. The test measures this,
  and section 5 states it.

**What still reaches stderr.** Messages written before the collector
starts, and the collector's own failures, still go to stderr and so to
the process-manager files. The test (section 4) checks what actually
lands there.

**Not covered by this setting:** the process-manager files are written by
devenv, not PostgreSQL. Their modes and retention are reported as part of
the residual. Changing devenv's process-manager logging is out of scope
unless the owner asks for it.

### 3.4 Logs written before the change

New settings do not erase the logs already written (the files listed in
section 2). Deleting them is destructive, so it is the owner's decision
and the owner's action:

- **(a)** the owner deletes the old PostgreSQL output files once the new
  settings are verified; or
- **(b)** keep them.

Claude has not read these files and won't. What they can contain depends
on what was entered in the demo database before now.

**Recommended:** (a) if the demo database has ever held real people's
data, and (b) otherwise. The owner knows which applies.

## 4. The test

Run on an **isolated, throwaway PostgreSQL instance**: a fresh data
directory in a temporary folder, on a free local port, with the same
settings file. It never runs against the owner's server or the demo
database.

1. **Start** the instance with the proposed settings, then confirm the
   effective values with `SHOW` from a new connection.
2. **Run synthetic canaries.** Each one uses a unique random marker
   string, never a private value:
   - a unique-key violation (the key in `DETAIL`);
   - a check-constraint violation (the failing row in `DETAIL`);
   - a type error whose primary message includes the value, as a bound
     parameter (extended protocol, through Postgrex);
   - a failing statement with the marker in a SQL literal;
   - a slow statement (to confirm duration logging is off);
   - a statement run after a reconnect, and after a server restart.
3. **Search every sink** for every marker:
   - the collector's files;
   - the instance's stderr and stdout captures;
   - any process-manager file the instance writes to.
4. **Expected result:**
   - markers from `DETAIL`, statements, parameters and durations: absent
     everywhere;
   - markers in primary messages: present only in the collector's file
     (mode 0600). This is the residual in section 5.
   - Any marker found anywhere else fails the test.
5. **A short invariant in the repository.** A small ExUnit test checks,
   on the dev and test connections, that the key settings are in effect
   (`current_setting('log_min_error_statement') = 'panic'` and so on). It
   catches drift if `devenv.nix` changes. Whether CI runs it, given CI
   uses its own PostgreSQL service, is open question Q4.

The canary run itself is a script that is kept with the proposal and
rerun after any `devenv.nix` or PostgreSQL upgrade.

## 5. The residual, for the owner to accept or reject

After this change, PostgreSQL can still write a private value to its log
in two cases:

- **an error whose primary message includes the input value** (for
  example, an invalid value for a column's type); and
- **a PANIC-level failure,** which can log its statement.

In both cases the value goes only to `.devenv/state/postgres/log/`:

- **access:** files mode 0600, folder mode 0700, the owner's macOS
  account only;
- **retention:** about seven days, by weekday truncation. It can be
  longer for a file reused after the server was stopped across its
  rotation (3.3);
- **location:** this machine only, never copied, uploaded or committed.

Any startup message that still reaches the process-manager files is
covered by the test's actual findings. It would be stated here before
acceptance.

**The request:** the owner accepts this specific, bounded server-log
retention exception, with the paths, access and retention above. This
is not a blanket exception. If the test finds anything outside these
bounds, the exception does not apply and the proposal returns for
revision.

## 6. Order of work

1. Codex reviews this proposal.
2. The owner decides Q1 to Q4.
3. Claude makes the change: `devenv.nix` settings, the canary script and
   the invariant test. It goes test-first: the invariant test fails on
   the current settings. Codex reviews the change. This changes no
   dependency source or pin.
4. The canary run on the throwaway instance, with a report. Codex
   reviews the report.
5. The owner restarts their own `devenv up` so the cluster picks up the
   settings. Claude does not restart the owner's server or touch the
   demo database.
6. The owner accepts or rejects the section 5 exception. Then the gate
   closes, and private settings content can be saved.

**Estimate:** half a day of build and test after the decisions, outside
the R0 critical path. It must close before the owner enters the D-053
writing guide or other private settings, and before the real-data
switch.

## 7. Open questions for the owner

- **Q1. Where to set it.** Recommended: the cluster, in `devenv.nix`
  (3.1). Alternative: per-database defaults.
- **Q2. Old log files.** Recommended: the owner deletes them after
  verification (3.4 a) if the demo database has ever held real people's
  data. Otherwise keep them (b).
- **Q3. Retention.** Recommended: seven days (one file per weekday).
  Alternatives: one day, or longer.
- **Q4. CI.** Should CI's PostgreSQL service use the same settings, so
  the invariant test runs there too? Recommended: yes, as a small CI
  change in the same PR. Without it, the test runs locally only.

## 8. Not in scope

- Production or any deployed database. None exists yet. A deployment
  needs its own logging review.
- Database roles, the SUPERUSER login, and `pg_hba.conf`.
- devenv's process-manager logging.
- The app-side logging controls, already decided in the ADR-0005 C4
  amendment.
