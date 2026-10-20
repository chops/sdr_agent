# D-168 summary access: owner steps (ADR-0016, D-173)

**Owner only. Agents do none of these steps.** No agent runs any command
below, connects as `postgres`, edits `pg_hba.conf`, or connects as
`sdr_summary_login` before step 5 prints `ACCEPTANCE PASS` and the owner
reports it (step 6). After that, agents may use only the dedicated role's
reviewed aggregate functions; every other agent access to the dev database
or app stays forbidden (D-173, D-179).

Run every step in the owner checkout (`~/src/SDR_agent`), at the reviewed
commit, inside its devenv shell, with `devenv up` running. Stop at the
first step that does not end exactly as stated, and report its step number
and marker. The commands use `/bin/cat` because `cat` may be aliased.

## 0. Preconditions

1. `git rev-parse HEAD` is the commit Codex passed, and
   `git status --short priv/dev_summary_access` prints nothing.
2. `echo "$PGDATA"` prints `/Users/charles/src/SDR_agent/.devenv/state/postgres`.
   This is derived from the repository's devenv configuration (devenv sets
   `PGDATA` to `<checkout>/.devenv/state/postgres`). Item 3 confirms it.
3. `psql -X -At -h 127.0.0.1 -p 5520 -U postgres -d postgres -c 'SHOW hba_file'`
   prints `$PGDATA/pg_hba.conf`, spelled out. `devenv.nix` does not set
   `services.postgres.hbaConf`. So devenv never rewrites `pg_hba.conf`, and
   the edit in step 4 survives restarts. devenv does rewrite
   `postgresql.conf` at every start, but that file sets no `hba_file`. If the
   printed path differs, stop.
4. `psql -X -At -h 127.0.0.1 -p 5520 -U postgres -d postgres -c 'SHOW server_version'`
   prints `18.6`.

## 1. Backup and verify point

The backup holds real data. Keep it private (mode 700/600). It never goes
in the repo, chat or a log.

```sh
B=~/sdr-agent-owner-backups/d173-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p -m 700 "$B"
pg_dump -h 127.0.0.1 -p 5520 -U postgres -Fc -f "$B/sdr_agent_dev.dump" sdr_agent_dev
pg_dumpall -h 127.0.0.1 -p 5520 -U postgres --globals-only -f "$B/globals.sql"
cp -p "$PGDATA/pg_hba.conf" "$B/pg_hba.conf.before"
chmod 600 "$B"/*
pg_restore --list "$B/sdr_agent_dev.dump" > /dev/null && test -s "$B/globals.sql" \
  && cmp -s "$PGDATA/pg_hba.conf" "$B/pg_hba.conf.before" && echo BACKUP-VERIFIED
```

The step must print `BACKUP-VERIFIED`. Keep `$B` set for steps 4 and 8.

## 2. Install

```sh
psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 5520 -U postgres -d sdr_agent_dev \
  -f priv/dev_summary_access/install.sql
```

The command must exit 0 and print `END-OF-SUMMARY-INSTALL` last. It runs in
one transaction: a failure changes nothing.

## 3. TEMP and large-object revokes (D-173 choices 1 and 2)

a. Inventory (read-only):

```sh
psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 5520 -U postgres -d sdr_agent_dev \
  -v mode=inventory -f priv/dev_summary_access/revoke-public-temp-lo.sql
```

The last line must be `END-OF-REVOKE-PUBLIC-TEMP-LO-INVENTORY (nothing changed)`.
The `before` row must read `t | 17 | 17 | 17`. The `effect` rows must match
the reviewed list:

| Role | would_lose_temp | lo_functions_lost |
| --- | --- | --- |
| `sdr_summary_login` | `t` | `17` |
| `sdr_summary_definer` | `t` | `17` |
| every superuser (`postgres`, and the initdb user) | `f` | `0` |

If any other role appears, stop. It is a role the reviewed effect list
did not cover.

b. Apply (one transaction):

```sh
psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 5520 -U postgres -d sdr_agent_dev \
  -v mode=apply -f priv/dev_summary_access/revoke-public-temp-lo.sql
```

The command must exit 0 and print `END-OF-REVOKE-PUBLIC-TEMP-LO-APPLIED`
last. If it prints a `REFUSED` line instead, nothing was changed.

## 4. pg_hba rules and reload (D-173 choice 3)

a. Put the seven rule lines of `priv/dev_summary_access/pg_hba-summary.conf`
   above every existing rule:

```sh
{ grep -vE '^[[:space:]]*(#|$)' priv/dev_summary_access/pg_hba-summary.conf; /bin/cat "$B/pg_hba.conf.before"; } \
  > "$PGDATA/pg_hba.conf.new" \
  && /bin/cat "$PGDATA/pg_hba.conf.new" > "$PGDATA/pg_hba.conf" && rm "$PGDATA/pg_hba.conf.new"
```

b. Reload. The command must print `t`:

```sh
psql -X -At -h 127.0.0.1 -p 5520 -U postgres -d postgres -c 'SELECT pg_reload_conf()'
```

c. Check that the file loads cleanly. The command must print `0`:

```sh
psql -X -At -h 127.0.0.1 -p 5520 -U postgres -d postgres \
  -c 'SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL'
```

The allow line keeps `trust`. That is the owner-accepted procedural residual
(D-173 choice 4). These rules confine where the login can connect. They are
not authenticated isolation: any local process can still connect as any
role.

## 5. Acceptance (must pass before any agent connects)

```sh
priv/dev_summary_access/accept.sh 5520
```

The script must exit 0. Every line starts with `ACCEPT`, 18 lines end in
`|ok`, and the last line is `ACCEPTANCE PASS`. It runs `attest.sql`, then
`accept.sql`, then the live pg_hba checks. Running `attest.sql` alone is not
acceptance (D-173).

On `ACCEPTANCE STOP`, agents do not connect. The `STOP` lines name the
failing checks. Fix the cause with Codex review, or roll back (step 8).

## 6. Report back (labels only)

Paste only these into the standup answer or chat:

- `BACKUP-VERIFIED`;
- the three END markers from steps 2, 3a and 3b;
- `effect rows as reviewed: yes` (or `no`, with the step number);
- the `t` and `0` from steps 4b and 4c;
- the complete `accept.sh` output, which is fixed labels, counts and fixed
  values only.

Never paste the backup, the `attest.sql` inventory, role passwords, or any
table data. Agents start calling the two functions only after this report
shows `ACCEPTANCE PASS`.

## 7. Afterwards

Re-run `accept.sh 5520` (not `attest.sql` alone), and report its output, in
any of these cases:

- after any change touching these roles, the `summary` schema or its
  functions;
- after any change to PUBLIC's privileges on `sdr_agent_dev`, or to
  `pg_hba.conf`;
- after a PostgreSQL upgrade.

On `ACCEPTANCE STOP`, agents stop calling.

## 8. Uninstall and rollback (this order)

1. Tell agents to stop calling.
2. End any login sessions:

   ```sh
   psql -X -At -h 127.0.0.1 -p 5520 -U postgres -d sdr_agent_dev \
     -c "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE usename = 'sdr_summary_login'"
   ```
3. Uninstall. The last line must be `END-OF-SUMMARY-UNINSTALL`. It refuses,
   changing nothing, if anything unreviewed depends on either role.

   ```sh
   psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 5520 -U postgres -d sdr_agent_dev \
     -f priv/dev_summary_access/uninstall.sql
   ```
4. Restore PUBLIC's TEMP and large-object defaults. The last line must be
   `END-OF-REVOKE-PUBLIC-TEMP-LO-RESTORED`. It refuses while either summary
   role exists.

   ```sh
   psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 5520 -U postgres -d sdr_agent_dev \
     -v mode=restore -f priv/dev_summary_access/revoke-public-temp-lo.sql
   ```
5. Revert `pg_hba.conf` and reload. If the file was edited for another
   reason since step 4, delete only the seven lines instead of restoring the
   copy.

   ```sh
   /bin/cat "$B/pg_hba.conf.before" > "$PGDATA/pg_hba.conf"
   psql -X -At -h 127.0.0.1 -p 5520 -U postgres -d postgres -c 'SELECT pg_reload_conf()'
   ```

   Then the following must print `0`:

   ```sh
   psql -X -At -h 127.0.0.1 -p 5520 -U postgres -d postgres \
     -c "SELECT count(*) FROM pg_hba_file_rules WHERE 'sdr_summary_login' = ANY (user_name)"
   ```
6. Report the three END markers and the `0`.

After a rollback, `accept.sh` prints `ACCEPTANCE STOP`, as expected. The
step 1 backup is a last-resort recovery point, not part of rollback.
Restoring it discards every change made since step 1, so only the owner
decides that.
