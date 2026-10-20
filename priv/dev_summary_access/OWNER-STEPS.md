# D-168 summary access: owner steps (ADR-0016, D-173)

**Owner only. Agents do none of these steps.** No agent runs any command
below, connects as `postgres`, edits `pg_hba.conf`, or connects as
`sdr_summary_login` before step 5 prints `ACCEPTANCE PASS` and the owner
reports it (step 6). After that, agents may use only the dedicated role's
reviewed aggregate functions; every other agent access to the dev database
or app stays forbidden (D-173, D-179).

**Every command goes through `owner-run.sh`, started by one clean launch**
(step 0.2, the `owner_run` function). The launch clears the environment
before any shell starts, so no `PATH`, `BASH_ENV`, `ENV`, exported shell
function or shell-option variable from your shell reaches bash. The script
is not executable, and it refuses any other way of starting it. Inside, it
fixes the rest of the execution context:

- the pinned PostgreSQL 18.6 binaries, each checked;
- no inherited `PG*`, `PSQL*` or `GIT_*` variable reaches any child,
  including `PGHOSTADDR`, `PGSERVICE`, `PGOPTIONS` and `PGPASSFILE`;
- every connection is explicit: `127.0.0.1` with `hostaddr`, the port, the
  database, user `postgres`, and timeouts;
- the data directory is an explicit `--pgdata` argument, checked against
  the server's own `data_directory` and `hba_file`;
- every command needs `--commit`, the full reviewed SHA. It refuses unless
  the checkout is exactly that commit, with the package and ADR-0016
  unmodified.

Each command ends with `OWNER-RUN <command> OK` (exit 0) or
`OWNER-RUN REFUSED: <reason>` (exit 3). Stop at the first command that
does not end `OK`, and report its step number and that line.

## 0. Setup and preflight

Run these once, in this order. `devenv up` must be running for the dev
cluster. No devenv shell is needed.

1. Use a checkout at exactly the commit Codex passed. A detached worktree
   leaves your own checkout where it is:

   ```sh
   git -C ~/src/SDR_agent fetch origin
   git -C ~/src/SDR_agent worktree add --detach ~/src/SDR_agent-d173 <REVIEWED-SHA>
   ```
2. Set three names and the launch function. Each value is a single word
   with no spaces, so they work in zsh and bash. `R` must be absolute:

   ```sh
   C=<REVIEWED-SHA>
   R=/Users/charles/src/SDR_agent-d173/priv/dev_summary_access/owner-run.sh
   D=/Users/charles/src/SDR_agent/.devenv/state/postgres
   owner_run() { /usr/bin/env -i PATH=/usr/bin:/bin HOME=/var/empty /bin/bash --noprofile --norc "$R" "$@"; }
   mkdir -m 700 ~/sdr-agent-owner-backups   # once; if it exists, it must be mode 700
   ```

   `owner_run` is the only launch. Every command below uses it, rechecks
   and rollback included. Never run `$R` directly, or with another `bash`
   or `env`.

   `D` is the dev cluster's data directory. The repository's devenv
   configuration sets `PGDATA` to `<checkout>/.devenv/state/postgres`.
   `devenv.nix` does not set `services.postgres.hbaConf`, so devenv never
   rewrites `pg_hba.conf`. It does rewrite `postgresql.conf` at every
   start, but that file sets no `hba_file`. Preflight confirms all of this
   against the running server.
3. Preflight:

   ```sh
   owner_run preflight --commit $C --port 5520 --pgdata $D
   ```

   It confirms the commit, the 18.6 binaries, the 18.6 server, and that
   `data_directory` is `$D` and `hba_file` is `$D/pg_hba.conf`. It also
   reports the TCP listen address and whether a Unix socket is configured.

## 1. Backup and verify point

```sh
owner_run backup --commit $C --port 5520 --pgdata $D --backup-parent ~/sdr-agent-owner-backups
```

- The command creates a new private directory, mode 700 (never reused).
  Into it go `pg_dump` of `sdr_agent_dev`, `pg_dumpall --globals-only`, a
  copy of `pg_hba.conf` and the archive's table of contents.
- It checks every producer's exit status. The dump must hold table data for
  every `public` table, and the globals file must be complete.
- It then writes a `MANIFEST` and a `BACKUP-COMPLETE` marker.
- Only then does it print `BACKUP-VERIFIED` and `BACKUP-DIR <path>`.
- On any failure, it prints `BACKUP-INCOMPLETE <path>`. That directory is
  never accepted by a later step.
- Earlier backups are never touched.

Copy the printed path by hand, without sourcing anything:

```sh
B=<the BACKUP-DIR path>
```

The backup holds real data. It never goes in the repo, chat or a log.

## 2. Install

```sh
owner_run install --commit $C --port 5520 --backup $B
```

The output includes `END-OF-SUMMARY-INSTALL`. It runs in one transaction,
so a failure changes nothing.

## 3. TEMP and large-object revokes (D-173 choices 1 and 2)

a. Inventory (read-only):

```sh
owner_run revoke-inventory --commit $C --port 5520
```

The `before` row must read `t | 17 | 17 | 17`. The `effect` rows must match
the reviewed list:

| Role | would_lose_temp | lo_functions_lost |
| --- | --- | --- |
| `sdr_summary_login` | `t` | `17` |
| `sdr_summary_definer` | `t` | `17` |
| every superuser (`postgres`, and the initdb user) | `f` | `0` |

If any other role appears, stop. It is a role the reviewed effect list
did not cover.

b. Apply (one transaction; a `REFUSED` line means nothing was changed):

```sh
owner_run revoke-apply --commit $C --port 5520 --backup $B
```

## 4. pg_hba rules, applied and effectively loaded (D-173 choice 3)

```sh
owner_run hba-apply --commit $C --port 5520 --pgdata $D --backup $B
```

It refuses, changing nothing, unless `pg_hba.conf` is byte for byte the
backup's copy and is a regular file you own. Then:

1. It writes the seven rules of `pg_hba-summary.conf` above the copy's
   content into a fresh private file in the same directory. It checks the
   bytes and keeps the live file's mode.
2. It re-checks the live file, then renames the staged file onto it
   atomically.
3. It has the server read the file back (`accept.sql` checks 12 and 13). If
   that fails, it puts the backup copy back the same way, and nothing is
   reloaded.
4. Otherwise it waits until the server clock is past the file's
   modification second, and reloads.
5. It waits until `pg_conf_load_time()` shows a reload at least one second
   after that modification. A `t` from `pg_reload_conf()` only means the
   signal was sent.

It must print `HBA-APPLIED-AND-LOADED`. A refusal names its stage. Its
reason starts `before any change` when the live file is untouched. It says
`the backup copy was put back` after a successful revert. It starts
`PUT-BACK FAILED`, or says `the NEW pg_hba.conf is in place`, when the new
file is on disk without a confirmed reload. In those last two cases, stop
and report the line; do not retry or repair it without review.

If a later step says the reload state is uncertain (acceptance check 14),
run
`owner_run hba-reload --commit $C --port 5520 --pgdata $D`.

The allow line keeps `trust`. That is the owner-accepted procedural residual
(D-173 choice 4). These rules confine where the login can connect. They are
not authenticated isolation: any local process can still connect as any
role.

## 5. Acceptance (must pass before any agent connects)

```sh
owner_run accept --commit $C --port 5520
```

The output must have 20 lines ending in `|ok`, and the last two lines must
be `ACCEPTANCE PASS` and `OWNER-RUN accept OK`. It runs these, in order:

- `attest.sql`;
- `accept.sql`, including the strict reload check and the TCP listen
  address;
- live checks, each a pg_hba rejection, never a mere refused connection:
  - the login is rejected for `postgres` and `template1` over 127.0.0.1;
  - the login connects to `sdr_agent_dev` over 127.0.0.1 with its reviewed
    settings;
  - the login is rejected for every database over every Unix socket the
    server reports.

Running `attest.sql` alone is not acceptance (D-173). On
`ACCEPTANCE STOP`, agents do not connect. The `STOP` lines name the
failing checks. Fix the cause with Codex review, or roll back (step 8).

## 6. Report back (labels only)

Paste only these into the standup answer or chat:

- each step's last line (`OWNER-RUN <command> OK`);
- `BACKUP-VERIFIED`, `END-OF-SUMMARY-INSTALL`,
  `END-OF-REVOKE-PUBLIC-TEMP-LO-APPLIED` and `HBA-APPLIED-AND-LOADED`;
- `effect rows as reviewed: yes` (or `no`, with the step number);
- the complete `ACCEPT ...` and `ACCEPTANCE ...` lines from step 5. These
  are fixed labels, counts and fixed values only.

Never paste the backup, the backup path, the inventory rows, the attest
inventory or any table data. Agents start calling the two functions only
after this report shows `ACCEPTANCE PASS`.

Acceptance authorizes only the two reviewed functions. `gdemo_drain_v1`
implements the old two-allocation G-DEMO contract and returns STOP for the
current three-allocation rehearsal shape. Installing and accepting it does
not approve it as the current attempt's drain. That needs its own reviewed
version and protocol.

## 7. Afterwards

Re-run `owner_run accept --commit $C --port 5520`, not `attest.sql` alone, and
report its output, in any of these cases:

- after any change touching these roles, the `summary` schema or its
  functions;
- after any change to PUBLIC's privileges on `sdr_agent_dev`, to
  `pg_hba.conf`, or to the listen address or socket settings;
- after a PostgreSQL upgrade.

On `ACCEPTANCE STOP`, agents stop calling.

## 8. Uninstall and rollback (this order)

1. Tell agents to stop calling.
2. End any login sessions:

   ```sh
   owner_run end-login-sessions --commit $C --port 5520
   ```
3. Uninstall. It refuses, changing nothing, if anything unreviewed depends
   on either role. Its output includes `END-OF-SUMMARY-UNINSTALL`.

   ```sh
   owner_run uninstall --commit $C --port 5520
   ```
4. Restore PUBLIC's TEMP and large-object defaults. It refuses while either
   summary role exists.

   ```sh
   owner_run revoke-restore --commit $C --port 5520
   ```
5. Restore `pg_hba.conf` from the backup copy:

   ```sh
   owner_run hba-restore --commit $C --port 5520 --pgdata $D --backup $B
   ```

   If the live file is not exactly the applied content, it refuses and
   changes nothing. That means the file was edited after step 4, and it
   needs reviewed manual handling: delete only the seven lines by hand, then
   run `owner_run hba-reload --commit $C --port 5520 --pgdata $D`. If the live file is exactly the applied
   content, it puts the copy back with the same staged atomic write. It checks that no rule names the
   login, then reloads and waits until the reload is effective. It must
   print `HBA-RESTORED-AND-LOADED`.
6. Report each step's last line.

After a rollback, `owner_run accept` prints `ACCEPTANCE STOP`, as expected. The
step 1 backup is a last-resort recovery point, not part of rollback.
Restoring it discards every change made since step 1, so only the owner
decides that.
