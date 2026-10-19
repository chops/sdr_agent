---
status: proposed
date: 2026-10-18
supersedes: null
---

# ADR-0016 Dev database summary access

## Status

Proposed. Nothing here is installed, accepted or approved for use. Codex's
D-168 review requirements (`codex-d168-role-requirements.md`, eight
must-fix items) and its review of the first draft
(`codex-d168-7b5e172-review.md`, MF1–MF4) shaped this revision. Before
any agent may call the interface, all of these must exist:

1. Codex review of this text, the SQL, the harness and the test evidence.
2. Owner acceptance of this ADR.
3. An explicit owner decision on every item under
   [Open owner choices](#open-owner-choices). Drafting direction is not
   such a decision, and none is inferred from D-168.
4. An owner-run install, followed by an installed-state attestation that
   passes (see [Installed-state acceptance](#installed-state-acceptance-owner)).

Until all four exist, every dev-database check stays owner-run.

## Context

D-168 (owner, 2026-10-18) amends the rule that agents never connect to the
owner's dev database, `sdr_agent_dev` on 127.0.0.1:5520. Agents may run
**read-only summary checks**: reviewed aggregate interfaces only, with
counts, field names and fixed categories. Writes, grants, raw reads, the app
and the owner checkout stay owner-only.

Two owner-run psql scripts motivate the first interface:

- **The G3 metadata inventory** (L2 contract, OQ-E3-4).
- **The G-DEMO drain check** (pre and post phases).

Running each one needs the owner at the keyboard. The results are counts
that an agent could read without seeing any content.

## Decision

### Interface

Agents get one dedicated **login** role. Its only useful capability is to
execute two reviewed functions in a dedicated `summary` schema.

| Function | Replaces | Output |
| --- | --- | --- |
| `summary.g3_inventory_v1()` | `g3-inventory.sql`, sections 1–5 | The same section names and counts |
| `summary.gdemo_drain_v1(phase text, start_at timestamptz, b1_attempts int, workshop_buckets text[])` | `claude-gdemo-drain.sql` (draft 3) | The same DRAIN, CONTEXT, AUTHORITY and CHECK rows and verdict |

`gdemo_drain_v1` implements **only** the reviewed draft-3 G-DEMO contract:
exactly two allocations, `b1` and `workshop`.

- It is not the drain for any later G-DEMO attempt or procedure. Any other
  grant shape is unexpected authority and gives `CHECK = STOP`. That
  includes the proposed rehearsal or third-allocation shape, and the
  harness tests that case.
- If a procedure adopts a new shape, it needs a new function version (for
  example `_v2`) with its own review, install and attestation record.
- Code review of v1 implies no authority for any attempt.

Both functions return one fixed row type:

```
target, read_at, fn_version, section, k1..k5 text, n bigint
```

- The first row is `target`, which names the database, the UTC read time
  and the function version.
- The last row is `END`. Its k1 is `complete`; `truncated` when any
  section reached its row limit; or (drain only) `incomplete` when a live
  grant or allocation has malformed terms.
- A result is complete only when its last row is `END|complete`. Anything
  else is unknown, never "nothing found". That includes an error, a
  timeout, a missing `END` row, `truncated` and `incomplete`.
- A truncated or incomplete drain result also carries `CHECK = STOP`.

### Closed output vocabulary

Every returned label is a fixed string in the function body or a member of
a reviewed vocabulary declared in the body. These are the app's own
enumerations at this version:

| Category | Reviewed values |
| --- | --- |
| providers | `claude_cli`, `codex_app_server`, `fake` |
| invocation statuses | `reserved`, `sent`, `completed`, `failed`, `unknown` |
| profiles | `claude_cli_opus`, `claude_cli_sonnet`, `fake` |
| release dispositions | `released`, `withheld`, `calibration` |
| export statuses | `building`, `completed`, `failed` |
| run statuses | `queued`, `running`, `succeeded`, `failed`, `budget_exhausted`, `cancelled` |
| Oban queues | `default`, `research`, `delivery`, `reconciliation`, `followup`, `integration`, `agent` |
| Oban job states | `available`, `scheduled`, `executing`, `retryable`, `completed`, `discarded`, `cancelled` |
| allocation keys | `b1`–`b5`, `proof`, `rehearsal`, `daily_use`, `workshop` |
| allocation buckets | `b1`–`b5`, `proof` |
| event types | the 27 `model.*` event types the app emits |

- Any other stored value is **counted under `other`** and never returned.
  This keeps the agreed aggregate semantics: unknown values are grouped,
  not dropped.
- `applies_to` is canonicalized against the bucket set. It must be
  one-dimensional, have 1–6 members, have no NULL or repeated member, and
  use only known buckets. A valid array is returned sorted, as at most 23
  bytes, such as `{b1,b2,b5}`. Anything else is returned as `malformed`
  and never matches a reviewed authority term. A malformed live allocation
  or grant `profile_ids` makes the drain result `incomplete` with
  `CHECK = STOP`.
- Generations, attempts and counts are integers.
- With labels closed, a row's size is bounded. The row count is also
  bounded: each section has a LIMIT, and reaching it marks the result
  `truncated`.

The harness checks this on every result row it receives. It also seeds
canaries that the first draft's regular expressions would have returned:

- lowercase and dotted values, such as `model.seedsecret` and the queue
  `privateclient`;
- unknown statuses and profiles;
- malformed arrays: unknown, NULL, repeated, 1000-member, two-dimensional,
  empty, and a 5000-byte member.

None of them appears in any output.

Files:

- `priv/dev_summary_access/install.sql`: owner-run, one transaction.
  Refuses (psql exit 3) any database other than `sdr_agent_dev`, and any
  non-superuser.
- `attest.sql`: the read-only installed-state attestation, with a
  machine-checked verdict.
- `uninstall.sql`: exact rollback. It validates everything before it drops
  anything.
- `optional-revoke-temp.sql`: one of the options under Open owner choices.
- `test/dev_summary_access/`: run against a throwaway cluster only.
  - `adversarial.sh`, `seed.sql` and `canaries.sql`: the adversarial test.
  - `guard.sh`, `guard-test.sh` and `lifecycle-test.sh`: the throwaway
    guard and its hermetic tests.
  - `throwaway-cluster.sh` and `migrate_throwaway.exs`: the disposable
    cluster and its schema.

### Principals

- **`sdr_summary_login`**
  - Role attributes: LOGIN, NOSUPERUSER, NOCREATEDB, NOCREATEROLE,
    NOREPLICATION, NOBYPASSRLS, NOINHERIT, CONNECTION LIMIT 2.
  - It is a member of no role and owns nothing at install time. It holds
    no table, column, sequence or large-object privilege by any route.
  - Its only grants:
    - CONNECT on `sdr_agent_dev`;
    - USAGE on `summary`;
    - EXECUTE on the two exact function signatures.
  - Session defaults:
    - `default_transaction_read_only=on`;
    - `statement_timeout=60s`, `lock_timeout=5s`,
      `idle_in_transaction_session_timeout=60s`;
    - `search_path=pg_catalog`.

    These are not an authorization boundary. The login can change them
    for its own sessions, and it can persist new values on its own role
    with `ALTER ROLE sdr_summary_login SET ...`. The attestation refuses
    any persisted change.
- **`sdr_summary_definer`**
  - NOLOGIN, with the same negative attributes. Nothing is a member of it,
    and it is a member of nothing.
  - It owns only the two functions and its own default-privilege entry.
  - It holds USAGE on `public` and `summary`, plus SELECT on exactly 42
    columns. The attestation pins that list. The columns cover:
    - `model_invocations`, `model_result_releases`, `audit_events`,
      `audit_exports`, `agent_runs` and `oban_jobs`;
    - `payloads.sha256` only;
    - the grant and allocation term columns.
  - **It can read content.** Its grants include
    `audit_events.payload`, `audit_events.canonical_bytes` and
    `audit_exports.bundle_path`. G3 needs them to test whether fixed key
    names are present and to count recorded paths. Only the fixed function
    outputs bound what leaves those columns, not the column ACL: the
    functions return only fixed key names and counts from them.
  - It cannot read `payloads.content`, grant names, grant purposes or any
    column outside the reviewed list.
  - It holds no INSERT, UPDATE, DELETE, TRUNCATE, sequence or CREATE
    privilege.
- **The installing superuser** owns the `summary` schema. It is not the
  runtime function owner. The app's role is untouched.

### SECURITY DEFINER hardening

- Each function is `SECURITY DEFINER STABLE PARALLEL UNSAFE`. Each carries
  `SET search_path = pg_catalog, pg_temp`, `SET "TimeZone" = 'UTC'` and
  `SET lock_timeout = '5s'`.
- Every relation is schema-qualified as `public.x`. No helper is called
  outside `pg_catalog`. Operators resolve in `pg_catalog`, and `pg_temp` is
  never searched for operators or functions.
- The bodies contain none of the following: dynamic SQL, `EXECUTE`, file
  calls, network calls, large-object calls or writes.
- Arguments are validated before any read.
  - Bad input raises SQLSTATE 22023 with a fixed message,
    `invalid_argument: <field>`.
  - The message never echoes the input.
- No identifier, path, hash value or stored text is returned. Labels come
  from the closed vocabulary above.
- PUBLIC EXECUTE is revoked on each exact signature twice: once before the
  ownership change and once after.
- `ALTER DEFAULT PRIVILEGES FOR ROLE sdr_summary_definer` revokes PUBLIC
  EXECUTE on any future function the definer owns.
  - The first draft also had a per-schema default revoke. It was removed
    because a per-schema default cannot cancel the global PUBLIC EXECUTE
    default, so the line did nothing.
- All of this happens inside the install transaction, so PUBLIC can never
  execute either function, even briefly.
- A STABLE function runs all of its queries on the calling statement's
  snapshot, so each call is one consistent observation.

### Shared defaults are not changed

`install.sql` changes nothing about PUBLIC, the `public` schema, or any
existing role, table or function. `attest.sql` adds no revoke. It reports
the PUBLIC-derived privileges as inventory and refuses only on unreviewed
routes. Any database-wide change is a separate owner approval: see Open
owner choices.

## Boundaries

### Privilege boundary (what PostgreSQL enforces for the login)

The login cannot:

- read any application table: SELECT is denied on all 56 `public`
  relations, and table, column and sequence privileges are 0 by any route;
- insert, update, delete or truncate application data, or advance an app
  sequence, even after it turns off its own read-only default;
- run DDL in `public`, `summary` or a new schema;
- replace, alter, drop or re-grant the summary functions;
- SET ROLE or SET SESSION AUTHORIZATION to the definer or a superuser;
- grant itself a role, or give itself CREATEDB, CREATEROLE, a higher
  connection limit or any other role attribute;
- read server files, list directories or import server-side large objects;
- COPY to or from server files or programs.

It **can**:

- create temporary objects in its own session (Open choice 1);
- create and write large objects (Open choice 2);
- connect to the cluster's other databases (Open choice 3);
- change its own session settings, and persist role-level setting
  defaults on itself. The attestation detects a persisted change.

None of these lets it read application data. They are why "cannot write
anything" was wrong in the first draft.

Temporary objects can't change results:

- relations are qualified;
- `pg_temp` is never searched for functions or operators;
- the functions pin `search_path`.

The test shadows the tables and a view, defines temp `~` and `=`
operators and a temp `count` function, and changes TimeZone and
DateStyle. Results are unchanged. With the pinned `search_path` removed,
the shadow probes still pass, so the attestation's shape check is what
catches that regression.

### Trust boundary

The dev cluster accepts `trust` authentication on 127.0.0.1 and ::1, so any
local process can connect as any role, including `postgres`. The login
role is therefore a **procedural** boundary on this cluster:

- agents agree to connect only as `sdr_summary_login` and to call only the
  reviewed functions;
- PostgreSQL then enforces what that role can do.

PostgreSQL does not stop an agent that breaks the agreement. Whether that
is acceptable is Open choice 4.

### Open owner choices

None of these is accepted. D-168 did not decide them, and they diverge
from the earlier role requirements. Each needs one of two things before
installation or agent use:

- an explicit, recorded owner decision naming it; or
- technical closure through separately authorized hardening.

1. **TEMP writes.** The login can create temporary tables, views and
   functions in its own session, through the PUBLIC TEMP default on
   `sdr_agent_dev`. A per-role REVOKE cannot cancel a PUBLIC grant.
   - Options:
     - (a) accept it;
     - (b) run `optional-revoke-temp.sql`: inventory mode first, then
       `-v mode=apply` after reviewing which login roles lose TEMP. That
       revokes TEMP from PUBLIC database-wide, and is a shared-default
       change.
   - Prerequisite: a recorded decision. For (b), the attestation's C
     inventory must show `can_temp = f` for the login on `sdr_agent_dev`.
2. **Large-object writes.** PostgreSQL has no privilege that governs
   creating large objects. Once the login turns off its read-only default,
   it can store data with `lo_create` and `lowrite`. It cannot read large
   objects it does not own.
   - Options:
     - (a) accept it, with the attestation as the detector. Checks M, J30
       and J31 refuse while either role owns or can access any large
       object. The owner sets a re-attestation cadence.
     - (b) close it with separately authorized hardening: revoke EXECUTE on
       the large-object creation functions from PUBLIC. That is a
       shared-default change, so its effect on the app and other roles
       must be inventoried first.
   - Prerequisite: a recorded decision.
3. **Other databases.** The login can CONNECT to `postgres`, `template1`
   and any other database whose PUBLIC CONNECT default allows it. The
   attestation reads this database's catalogs plus the shared ones. Those
   prove that neither role owns anything or holds an explicit grant in
   any other database. They do **not** cover another database's PUBLIC
   grants or SECURITY DEFINER functions. "Catalog metadata only" is
   unproven there.
   - Options:
     - (a) preferred: owner `pg_hba.conf` rules that deny the login every
       other database. An allow line for `sdr_agent_dev` alone is not a
       deny boundary: pg_hba is first-match, and the cluster's broader
       `host all all ... trust` rule would still match other databases.
       The rules need an allow line for `sdr_summary_login` on
       `sdr_agent_dev`, followed by a `reject` line for
       `sdr_summary_login` on `all`. Both must come before any broader
       rule that could match the login, for every address it can use
       (127.0.0.1 and ::1). An owner-run connection test then confirms
       the denial, without reading data;
     - (b) REVOKE CONNECT from PUBLIC on the other databases, a shared
       change;
     - (c) an owner-run inventory of each other connectable database,
       equivalent to checks 12, 13, 25, 26 and 28 there, with a narrowly
       stated acceptance.
   - Prerequisite: (a) or (b) in place, or (c) recorded. No agent probe
     of another database.
4. **Procedural connection boundary.** Under trust authentication the
   role restricts only a cooperating agent.
   - Options:
     - (a) `scram-sha-256` for every role, including the app's, with the
       login's password set out of band. This has app-configuration
       impact.
     - (b) accept the procedural boundary explicitly, for this
       developer-machine cluster only.
   - Prerequisite: a recorded decision.

Known properties, not choices:

- `pg_proc.prosrc` is world-readable. The source is the reviewed file and
  contains no secrets.
- Aggregates are not anonymity. Counts over small populations reveal facts
  about those populations. Outputs are limited to the two reviewed
  scripts' categories, and no adaptive filter argument exists.

### Operational boundary

- Each call runs under the 60 s statement timeout and the 5 s lock timeout.
- At most 2 concurrent login sessions are allowed.
- Callers add their own deadline and call no more than the procedure needs.
- A drain result of zero is a snapshot. It does not prove that no writer
  is in flight, and it gives no authority to release leases, create
  grants, enable models or spend. The drain protocol and its owner gates
  are unchanged.

### Failure boundary

- Install is one transaction. A repeated install refuses with exit 3 and
  42710, and leaves the function hashes unchanged.
- Every refusal exits nonzero (psql exit 3) and prints no END marker. That
  covers install, uninstall and the optional TEMP revoke when run in the
  wrong database or by a non-superuser, and the optional revoke without a
  mode.
- Uninstall validates the complete dependency set before any DROP:
  - pg_shdepend for both roles, in every database, large objects and
    default ACLs included;
  - the occupants of schema `summary`;
  - role memberships.

  Anything install.sql did not create refuses the whole transaction, so
  `DROP OWNED` never removes something unreviewed.
- Bad arguments fail before any read.
- A caller sees only `complete`, `truncated`, `incomplete`, or an error.
  All but `complete` are inconclusive.

## Installed-state acceptance (owner)

1. Review the exact `install.sql` and `attest.sql` at the reviewed commit.
   Both must be unchanged since Codex's PASS.
2. Record a decision on each Open owner choice.
3. Run `install.sql` as the owner superuser against `sdr_agent_dev`. psql
   must exit 0, and the last line must be `END-OF-SUMMARY-INSTALL`.
4. Run `attest.sql` and keep its full output. Acceptance requires all of:
   - psql exit 0;
   - the line `ATTEST PASS: 36 of 36 checks hold`;
   - no row marked `FAILED`;
   - the last line `END-OF-SUMMARY-ATTEST`.

   On any failure it prints `ATTEST REFUSED`, rolls back and exits 3.
   Do not activate agent use.

   The checks are machine-checked, fixed sets:
   - role attributes, connection limits and the exact session defaults;
   - no per-database role settings;
   - no membership in either direction;
   - the exact 51 dependency records of both roles in every database;
   - the definer's exact 42 SELECT columns;
   - no other table, column, sequence or large-object privilege, by any
     route;
   - no callable SECURITY DEFINER function except the two, and no callable
     untrusted-language function outside `pg_catalog` that is not in
     citext, by direct, inherited, owned or PUBLIC route, for **both**
     principals;
   - the server-file and admin built-ins denied;
   - the summary schema's owner, ACL and occupants;
   - each function's owner, flags, settings, result type, ACL and pinned
     prosrc SHA-256;
   - the exact default ACLs naming either role;
   - the exact 53 ACL entries naming either role or on the summary
     objects, as full (grantor, grantee, privilege, grantability) tuples.
     An object owner's own entry is modeled as `OWNER` and its implicit
     rights are not revoked. So a `WITH GRANT OPTION` widening of an
     allowed grant, or a delegation by either role, is refused;
   - the extension set: `plpgsql` and `citext`.
5. Compare the `G summary functions` `functiondef_sha256` values with the
   reviewed values below. That hash depends on the server's formatting.
   These values are for PostgreSQL 18.6:

   | Function | prosrc SHA-256 (pinned in attest) | functiondef SHA-256 (PostgreSQL 18.6) |
   | --- | --- | --- |
   | `summary.g3_inventory_v1()` | `6357e1d4bd6bbd2038a0f07ff5f1ca8601ba1f864a24c28db8623859a527ea65` | `eae28c02a08eeb532c49d0c0a05b783b4856a1cbbec8c3dfa7706f8b312b829f` |
   | `summary.gdemo_drain_v1(text,timestamp with time zone,integer,text[])` | `b6cc57a9dbe7154ee9f400821670e10035ae9bb7a63fb969389d9a5c4d6142b8` | `ea809c263d976e99d5ed7dfa0bfca796b89493704c87f0143c2783c792c2775e` |

6. Agents may start calling only after steps 2–5 are recorded.
7. Re-attest:
   - after any CREATE OR REPLACE, ALTER, GRANT or REVOKE touching these
     roles, the schema or the functions;
   - after a PostgreSQL major upgrade;
   - on the cadence set under Open choice 2.
8. Each new function or version, such as `_v2`, needs its own review,
   install and attestation record.

## Credentials

There is no password today: the cluster uses `trust`. If the owner moves
to password authentication, they set one with `\password sdr_summary_login`
and keep it in owner-managed private configuration. It never goes in the
repo, chat, command arguments, logs or environment dumps.

## Owner-only (unchanged by this ADR)

- Writes, grants and raw reads.
- Installing, replacing or removing the functions.
- `pg_hba.conf` and authentication changes.
- Every Open owner choice, including the optional TEMP revoke.
- The app, the owner checkout, and every release, grant or spend decision.

## Verification

Everything runs on a throwaway cluster. Nothing here connects to 5520 or
to the app.

### The throwaway guard (`guard.sh`)

- `throwaway-cluster.sh init` creates the cluster under a private temporary
  root (mode 700) with initdb:
  - trust on 127.0.0.1 only, no Unix socket, a free port in 49152–65535;
  - a manifest recording the physical PGDATA, the port and the
    `pg_controldata` system identifier.
- Every other lifecycle action (`start`, `stop`, `destroy`, `schema`,
  `env`) first runs `guard_offline` on the root. That works for a stopped
  or a running cluster, and runs before any pg_ctl action, connection or
  removal. It requires:
  - the private temporary root and its creation marker;
  - a regular, private, five-line manifest with the exact version and
    root;
  - a canonical allowed port;
  - PGDATA exactly the physical, non-symlink `ROOT/pgdata`, mode 700;
  - the control file's system identifier.

  Then:
  - `start` requires the stopped state: no pid file, no listener (a
    failing `lsof` refuses), and the configured endpoint exactly the
    manifest's, with no `postgresql.auto.conf` override or include. It
    launches with that endpoint on the command line, then checks the
    running and server identity.
  - `stop` checks the running identity (pid file, live PID, sole
    listener) and the server identity before signalling.
  - `destroy` does the same if the cluster is running, then re-validates
    the same root, stopped, immediately before `rm`.
  - `schema` exits nonzero unless three things hold: the migration command
    succeeds, it prints `MIGRATED N migrations, all up` for every
    repository migration, and `schema_migrations` equals the repository's
    set with the nine interface tables present. Only then does it print
    `SCHEMA-READY`.
- Before its first connection, `adversarial.sh` refuses (exit 2, no psql
  call) unless all of these hold:
  - every `PG*`/`PSQL*` variable can be unset. The scrub does not use
    `compgen`, which Nix's non-interactive bash lacks.
  - the port is canonical decimal in that range, and never 5520 or 4120 in
    any spelling;
  - the root and PGDATA are physical paths, with no symlink, `.` or `..`
    segment, under `/private/tmp/` or `/private/var/folders/`;
  - the manifest agrees with the inputs;
  - `pg_controldata` reports the manifest's system identifier;
  - `postmaster.pid` names that PGDATA, port and 127.0.0.1;
  - the postmaster PID is the only TCP listener on the port.
- It then compares `system_identifier`, `data_directory` and `port` from
  the server. It re-checks them at each stage boundary:
  - before the initial uninstall and install;
  - before the grant-option mutations;
  - before the clean uninstall;
  - before seeding;
  - before the canaries;
  - before the optional TEMP apply.

  It does not re-check before each individual statement. Between checks,
  every connection still names the same explicit endpoint, so drift would
  need another server to bind that exact port in the interval. No
  zero-width check-to-use window is claimed. Every connection passes all
  libpq parameters explicitly.
- `guard-test.sh` stubs `psql`, `pg_controldata` and `lsof` on PATH, and
  drives the real harness entry point through 51 cases:
  - 5520 and 4120 in every spelling (`05520`, `005520`, `+5520`,
    `' 5520'`, `5520.0`, `0x15a0`, ...);
  - `/tmp` symlinks, `../` and `./` traversal, and symlinked roots and
    PGDATA pointing at non-temporary directories;
  - manifest drift;
  - mismatched control-file, `postmaster.pid`, listener and server
    identities.

  Every refused input makes zero psql calls. A server-identity mismatch
  makes exactly one read-only identity query. A positive control with
  hostile `PGSERVICE`/`PGHOST`/`PGPORT=5520`/`PSQLRC` values shows that
  none reaches psql. The test passes under bash 5.3, Nix's non-interactive
  bash 5.3 and macOS bash 3.2.
- `lifecycle-test.sh` stubs `pg_ctl`, `psql`, `pg_controldata`, `lsof`,
  `nix` and `rm` on PATH, and drives the real `throwaway-cluster.sh`
  through 131 cases. Each of these refuses every action with zero `pg_ctl`
  start/stop, `rm`, `nix` and `psql` calls:
  - a manifest whose PGDATA is another cluster's physical data directory;
  - a symlinked root, manifest or PGDATA;
  - 5520, `05520`, `+5520`, 4120 and other bad ports;
  - a changed system identifier;
  - a non-temporary root;
  - manifest version, line, mode, marker or root drift;
  - PID, listener and pid-file mismatches;
  - endpoint configuration drift;
  - a failing `lsof`.

  A server-identity mismatch stops after one identity query. For `start`,
  the server it just launched cannot be checked before launch. Positive
  controls show that start (stopped), stop (running), destroy (stopped and
  running), schema and env act on exactly the validated target. The schema
  cases refuse each of these, with no `SCHEMA-READY`, even though the
  later relation count would succeed:
  - a migration that exits 1;
  - a missing or short success marker;
  - a partial or extra `schema_migrations`;
  - a missing interface table.

### The adversarial test (`adversarial.sh`)

The app schema comes from the repository's own migrations
(`throwaway-cluster.sh schema`, 25 migrations, 56 `public` relations),
with synthetic rows. This is author evidence about the repository's
schema. It is not proof that it equals the real dev schema: installed-state
attestation and the owner decisions still come before any agent use. The test connects as the real `sdr_summary_login`
login, not only through `SET ROLE` from a superuser. It checks:

- **Exact output.** Function output equals the reviewed psql scripts for
  G3 and for drain pre and post, undrained and drained, plus a wrong-term
  post. The only difference is vocabulary mapping. A three-allocation
  G-DEMO shape gives `STOP`.
- **Pinned references.** A FULL verdict requires `ADV_REF_DIR` with the
  reference scripts at their pinned SHA-256 (`602e9429…f250`,
  `908c2829…c41e`, recorded in full in the script). Without them the run
  is marked REDUCED and exits 3.
- **Attestation mutations.** Each of these makes attest refuse (exit 3,
  named check FAILED); after the revert, attest passes again:
  - a direct-only SECURITY DEFINER grant to the login (shown to be a real
    route);
  - `SELECT(content)` on `payloads` for the definer;
  - table SELECT on `payloads` for the login, and a PUBLIC column grant
    on `payloads.content`;
  - a PUBLIC SECURITY DEFINER function;
  - a SECURITY DEFINER function reached through a membership;
  - a PUBLIC internal-language server-file wrapper;
  - an outgoing definer membership;
  - definer sequence USAGE;
  - the login persisting its own `statement_timeout`;
  - a raised connection limit;
  - a per-database setting;
  - a widened default ACL;
  - a changed function `search_path`;
  - a replaced function body;
  - an extra EXECUTE grant;
  - a login-owned large object;
  - an object in `summary`;
  - a grant to the login in another database;
  - grant options, each refused as soon as the option exists, before any
    delegation:
    - EXECUTE WITH GRANT OPTION to the login, shown to permit real
      delegation to PUBLIC, which is refused too;
    - a WITH GRANT OPTION widening of the allowed definer column grant
      `agent_runs.status`, shown to permit a real delegated read by the
      login;
    - schema USAGE and database CONNECT with grant option;
    - a default ACL with a grant option.

    Each is then restored with `REVOKE GRANT OPTION ... CASCADE`, which
    removes the delegated grants and keeps the ordinary ones, and a clean
    attest passes.
- **Uninstall drift.** Each of these refuses atomically, leaving roles,
  functions and large objects intact:
  - a login large object;
  - a table in `summary`;
  - an extra definer column grant;
  - an EXECUTE grant option held by the login;
  - a definer membership.

  Then a clean uninstall and a reinstall reproduce the same hashes.
- **Refusals.** Every refusal path exits 3 with no END marker.
- **Vocabulary.** The canaries collapse into `other` or `malformed`.
  Malformed live terms give `END=incomplete` and `CHECK=STOP`. 150 unknown
  queues give one `other` row. 150 generations reach the row limit, which
  gives `truncated` and `STOP`.
- **Closed outputs.** Every k field of every result row is a reviewed
  label, an integer or a canonical bucket set, and at most 64 characters.
  No canary or secret appears in any login output or error.
- **Denials and shadowing.** Every case listed under Boundaries, plus the
  definer's denials. A positive probe confirms that the definer can read
  `audit_events.payload`.
- **Arguments, timeouts and connection limit.** 21 argument rejections,
  with no echo of the input. The statement timeout and the function lock
  timeout both trip. The connection limit is enforced.

Mutation check of the harness itself: restoring the first draft's
event-type regex fails it through four independent checks:

- the attest prosrc pin;
- the canary grouping rows;
- the leak check;
- the closed-vocabulary check.

The first draft's three install mutants are now covered inside the
harness:

- sanitizer widening: the mutation check above;
- an unpinned `search_path`: the changed-`search_path` mutation;
- a `payloads` grant to the login: the table SELECT mutation.

Not proven here:

- behaviour on the real `sdr_agent_dev` data;
- the attestation of the real install;
- what the real cluster's other databases expose (Open choice 3).

### Evidence and process record

- While drafting revision 1 (`7b5e172`), the drafting helper disclosed that
  it had read the dev database's **schema only** (no rows) on port 5520,
  to build the throwaway test schema.
  - That access predates this ADR and is outside it.
  - It authorizes no agent dev-database connection of any kind.
- From revision 2, the throwaway schema is built from the repository's
  migrations instead, and no harness, guard or helper step connects to
  5520.
- Author run logs are evidence from the author, not an independent run.

## Consequences

- After the owner decides the Open choices, installs and attests once,
  agents can run the G3 and G-DEMO checks without the owner at the
  keyboard.
- Every new question needs a new reviewed function version. There is no
  ad-hoc SQL, by design.
- A vocabulary change in the app needs a new function version. Until then,
  new values are counted as `other`.
- Under trust authentication this lowers the owner's toil but is not a
  hard security control.

## Alternatives considered

- **Keep all checks owner-run.** This is the D-168 rejected option. It is
  safe, but each check costs owner time.
- **A read-only login with column grants and no definer.** Rejected per
  Codex: the login could then run arbitrary SQL over every granted column,
  including content-bearing JSON, instead of fixed aggregates.
- **Views instead of functions.** Rejected: views need SELECT and would
  silently widen the EXECUTE-only interface.
- **Regex-sanitized labels.** Rejected in revision 2 (MF2). A character
  class is not a category vocabulary, so `model.seedsecret` or a queue
  named `privateclient` would pass it.
- **Blanket revokes of PUBLIC and `public`-schema privileges.** Rejected.
  They are database-wide, can affect the app and other roles, and need
  their own owner approval.
