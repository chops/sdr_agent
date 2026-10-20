---
status: accepted
date: 2026-10-18
supersedes: null
---

# ADR-0016 Dev database summary access

## Status

Accepted by the owner on 2026-10-19 (D-173), with these four risk choices,
recorded as D-173 states them:

1. revoke TEMP from PUBLIC;
2. revoke the large-object functions from PUBLIC;
3. pg_hba allow and reject rules for the summary login, which the owner
   edits;
4. the trust-auth procedural boundary is accepted for this dev machine, with
   no switch to scram now.

Choices 1 and 2 are shared changes: Codex reviews their effect on the other
roles ([Shared hardening](#shared-hardening-d-173-choices-1-and-2)) before
the owner applies them. The owner installs the role and applies the
reviewed SQL, pg_hba and ACL changes for these choices. Trust auth remains a
procedural residual accepted by the owner, not authenticated isolation.

**Agent boundary (D-173, D-179).** Agents may use only the dedicated role's
reviewed aggregate interfaces, and only once both of these hold:

- the owner has installed them, following
  [OWNER-STEPS.md](../../priv/dev_summary_access/OWNER-STEPS.md);
- the installed-state acceptance check, `accept.sh`, has printed
  `ACCEPTANCE PASS` on that install, and the owner has reported it.
  Running the attestation alone is not enough.

Every other agent access to the owner's dev database or app stays
forbidden: raw or base-table SQL, arbitrary queries, writes, and dev-app or
browser use. Until acceptance passes, every dev-database check stays
owner-run.

Accepting this ADR installs nothing. Three Codex reviews shaped revisions
1–3: its D-168 review requirements (`codex-d168-role-requirements.md`), its
review of the first draft (`codex-d168-7b5e172-review.md`, MF1–MF4), and its
r3 PASS at `7bff0cc`. The D-173 owner path was added after acceptance: the
revokes, the pg_hba rules, the acceptance check and the owner steps. It
needs Codex review before the owner applies it.

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
- `attest.sql`: the read-only attestation of the summary roles, with a
  machine-checked verdict. It is part of acceptance, not acceptance on its
  own.
- `revoke-public-temp-lo.sql`: the D-173 TEMP and large-object revokes from
  PUBLIC. It has three modes: inventory, apply and restore. It replaces
  revision 3's `optional-revoke-temp.sql`.
- `pg_hba-summary.conf`: the exact pg_hba rules for D-173 choice 3.
- `accept.sql` and `accept.sh`: the installed-state acceptance check.
- `OWNER-STEPS.md`: the owner's exact order of steps, including rollback.
- `uninstall.sql`: exact rollback of `install.sql`. It validates everything
  before it drops anything.
- `test/dev_summary_access/`: run against a throwaway cluster only, or
  hermetically.
  - `adversarial.sh`, `seed.sql` and `canaries.sql`: the adversarial test,
    including the full owner path (section 9).
  - `guard.sh`, `guard-test.sh` and `lifecycle-test.sh`: the throwaway
    guard and its hermetic tests.
  - `accept-test.sh`: a hermetic test that `accept.sh` fails closed.
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

### Shared hardening (D-173 choices 1 and 2)

`install.sql` still changes nothing about PUBLIC, the `public` schema, or
any existing role, table or function. `attest.sql` adds no revoke. The
shared changes are one separate owner step, `revoke-public-temp-lo.sql`,
applied after install (OWNER-STEPS.md step 3). It acts on `sdr_agent_dev`
only, in one transaction:

- `REVOKE TEMP ON DATABASE sdr_agent_dev FROM PUBLIC`;
- `REVOKE EXECUTE ... FROM PUBLIC` on the 17 server-side large-object
  functions below.

A per-role REVOKE cannot cancel a PUBLIC grant, so only a PUBLIC revoke
closes either route for the login.

**The large-object set** was read from the catalog, not from memory. The
source was a fresh PostgreSQL 18.6 throwaway cluster with initdb defaults,
built from the same Nix store package as the dev cluster
(`/nix/store/zndqgdxn4p28iyax8raza3pfn7lkjw64-postgresql-18.6`):

```sql
SELECT p.oid::regprocedure::text AS signature, l.lanname, p.prosrc,
       has_function_privilege('public', p.oid, 'EXECUTE') AS public_execute,
       coalesce(p.proacl::text, '(default)') AS proacl
FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_language l ON l.oid = p.prolang
WHERE p.pronamespace = 'pg_catalog'::regnamespace
  AND (p.proname LIKE 'lo\_%' OR p.proname IN ('loread', 'lowrite')
       OR p.prosrc LIKE 'be\_lo%' OR p.prosrc LIKE '%lo\_%'
       OR p.prosrc LIKE '%largeobject%')
ORDER BY 1;
```

It returned 23 rows. Every row is `internal`.

| Group | Functions | PUBLIC EXECUTE by default |
| --- | --- | --- |
| Revoked: 17 `be_lo*` | `lo_close(integer)`, `lo_creat(integer)`, `lo_create(oid)`, `lo_from_bytea(oid,bytea)`, `lo_get(oid)`, `lo_get(oid,bigint,integer)`, `lo_lseek(integer,integer,integer)`, `lo_lseek64(integer,bigint,integer)`, `lo_open(oid,integer)`, `lo_put(oid,bigint,bytea)`, `lo_tell(integer)`, `lo_tell64(integer)`, `lo_truncate(integer,integer)`, `lo_truncate64(integer,bigint)`, `lo_unlink(oid)`, `loread(integer,integer)`, `lowrite(integer,bytea)` | yes, default ACL |
| Already superuser-only: 3 `be_lo*` | `lo_export(oid,text)`, `lo_import(text)`, `lo_import(text,oid)` | no (`{postgres=X/postgres}`); untouched |
| Not large-object access: 3 | `has_largeobject_privilege(name,oid,text)`, `has_largeobject_privilege(oid,oid,text)`, `has_largeobject_privilege(oid,text)` | yes; kept, because they only answer a privilege question |

- The script pins the 17 by signature.
- Its apply mode refuses unless the internal `be_lo*` functions PUBLIC can
  execute are exactly those 17. A server with a different set needs a new
  review.
- `accept.sql` fails closed on any `be_lo*` function outside the 17 and the
  3.

Revocation takes effect at once, also in sessions that already exist. On
the throwaway cluster, a session that had created a temporary table could
not create another after the revoke, and a later `lo_create` in it was
denied. Existing temporary tables last until their session ends.

**Effect on other roles**, for Codex review. The script's inventory mode
prints the same for the live cluster before apply, and OWNER-STEPS.md step
3a stops on any role not listed here.

| Role | TEMP on `sdr_agent_dev` | The 17 functions on `sdr_agent_dev` |
| --- | --- | --- |
| `sdr_summary_login` | lost | lost |
| `sdr_summary_definer` (NOLOGIN; the two functions use neither) | lost | lost |
| `postgres`: superuser, the app's role (`config/dev.exs`) and the installer | kept (superuser) | kept (superuser) |
| the initdb bootstrap superuser, the OS user on the devenv cluster, which also owns `sdr_agent_dev` | kept | kept |
| any other non-superuser login holding only PUBLIC's defaults | lost | lost |
| a non-superuser with an explicit TEMP grant | kept | lost |

The adversarial test checks this table on synthetic roles: `adv_plain`,
`adv_tempgrant`, `postgres`, the login and the definer.

Not affected:

- **Other databases.** `sdr_agent_test`, the `sdr_agent_test*` demo
  databases, `postgres` and `template1` keep their defaults. Database ACLs
  and `pg_proc` are per database, and databases created later from
  `template1` do not inherit the revokes. The test shows a role that lost
  both privileges on `sdr_agent_dev` keeps both in `postgres`.
- **The app.** It connects as `postgres`, a superuser. A search of `lib`,
  `priv` and `config` found no use of temporary tables or large objects.

Also worth knowing:

- Client-side libpq large-object calls, such as psql `\lo_import`, call the
  same server functions through the fast-path protocol. That path checks
  EXECUTE, so it is denied too. The test proves it for the login.
- A `pg_dump` of `sdr_agent_dev` carries the revokes, because pg_dump
  records changed privileges on `pg_catalog` objects. A restore therefore
  reproduces them.
- Large objects that a non-superuser already owns become unusable to that
  owner through these functions. The inventory counts them; 0 are
  expected.

Rollback: after `uninstall.sql`, `-v mode=restore` re-grants exactly the
revoked PUBLIC entries. It is refused while either summary role exists. The
effective privileges then equal the PostgreSQL defaults. The stored ACLs
stay explicit rather than NULL; the test compares effective
(grantor, grantee, privilege, grantability) tuples.

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

Before the D-173 owner path, it **can** also do these four things:

- create temporary objects in its own session. The TEMP revoke closes this.
- create and write large objects. The large-object revoke closes this.
- connect to the cluster's other databases. The pg_hba reject rules close
  this.
- change its own session settings, and persist role-level setting defaults
  on itself. This one stays. The attestation detects a persisted change,
  and acceptance checks the login's live session settings.

None of these lets it read application data. They are why "cannot write
anything" was wrong in the first draft. After the owner path, the harness
proves each of the first three denied (section 9).

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

PostgreSQL does not stop an agent that breaks the agreement. The owner
accepted this procedural boundary for this developer-machine cluster, with
no switch to scram now (D-173 choice 4). It is a procedural residual, not
authenticated isolation. The pg_hba rules confine where the login can
connect, not who can use it.

### Owner decisions (D-173)

Revision 3 listed four open choices. D-173 decided them:

1. **TEMP writes: revoked.** `revoke-public-temp-lo.sql` revokes TEMP on
   `sdr_agent_dev` from PUBLIC. A per-role REVOKE cannot cancel a PUBLIC
   grant. Acceptance checks 5 and 6.
2. **Large-object writes: revoked.** No privilege governs creating a large
   object, so the only closure is EXECUTE. The same script revokes PUBLIC
   EXECUTE on the 17 functions. Acceptance checks 7–10. The attestation's
   checks M, J30 and J31 still refuse any large object either role owns or
   can access.
3. **Other databases: pg_hba rules.**
   - pg_hba is first-match. The cluster's initdb `trust` rules for `local`,
     127.0.0.1 and ::1 match every database, so an allow line alone is not
     a deny boundary.
   - `pg_hba-summary.conf` has an allow line for the login on
     `sdr_agent_dev` over 127.0.0.1. It then rejects the login for every
     other database, and for replication, over 127.0.0.1, ::1 and the Unix
     socket. The devenv cluster has a Unix socket in its runtime directory.
     All seven lines go above every other rule.
   - Acceptance checks 12–14 read the rules and their load time. Checks
     15–16 confirm the rejection live, without reading data.
   - The attestation still covers only this database's catalogs plus the
     shared ones. The login can no longer reach the others.
4. **Procedural connection boundary: accepted.** Trust auth stays on this
   developer-machine cluster, with no scram switch now. See
   [Trust boundary](#trust-boundary).

D-173 records the rejected alternatives:

- reject the ADR;
- accept TEMP and large-object writes, with the attestation as detector;
- revoke CONNECT, or an inventory only;
- switch every role to scram.

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
  covers:
  - install, uninstall, the revoke script and `accept.sql` when run in the
    wrong database or by a non-superuser;
  - the revoke script without a valid mode;
  - a repeated apply;
  - a restore while the summary roles exist.
- `accept.sh` prints `ACCEPTANCE STOP` last and exits 3 on any failure.
  That includes a missing psql, an interrupted run, and output it cannot
  account for.
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

The owner follows [OWNER-STEPS.md](../../priv/dev_summary_access/OWNER-STEPS.md)
in its order: backup and verify point, install, the revokes (inventory,
then apply), the pg_hba edit and reload, `accept.sh`, the labels-only
report and, when needed, rollback. Agents do none of these. In summary:

1. Review the exact files at the reviewed commit. They must be unchanged
   since Codex's PASS.
2. Run the steps through the pg_hba reload. Each must end with its stated
   marker.
3. Run `accept.sh 5520`. Acceptance requires all of:
   - exit 0;
   - every line a fixed `ACCEPT` label line;
   - 18 `ok` lines;
   - the last line `ACCEPTANCE PASS`.

   On anything else, it prints `ACCEPTANCE STOP` last and exits 3. Do not
   activate agent use. The checks, in order:

   **Check 1: `attest.sql`.** It requires psql exit 0, the line
   `ATTEST PASS: 36 of 36 checks hold`, no row marked `FAILED`, and the
   last line `END-OF-SUMMARY-ATTEST`. Only the verdict and the fixed names
   of any failed checks are printed; the inventory stays with the owner. On
   its own, attest prints `ATTEST REFUSED`, rolls back and exits 3 on any
   failure.

   The 36 attest checks are machine-checked, fixed sets:
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

   **Checks 2–14: `accept.sql`** (read-only):
   - 2: the server is PostgreSQL 18.6, the version the functiondef hashes
     were recorded on;
   - 3: both summary roles are present;
   - 4: both functions' `pg_get_functiondef` SHA-256 equal the reviewed
     values below;
   - 5–6: PUBLIC holds no TEMP on `sdr_agent_dev`, and neither summary role
     can create temporary objects there by any route;
   - 7–10: all 17 reviewed large-object functions are present, no `be_lo*`
     function lies outside the reviewed lists, and none is executable by
     PUBLIC or by either summary role, by any route;
   - 11: `lo_compat_privileges` is off;
   - 12–14: no pg_hba rule has an error; rules 1–7 of the loaded
     `hba_file` are exactly the reviewed rules, in order; and the file was
     loaded after its last change.

   **Checks 15–17: live.**
   - 15–16: pg_hba rejects the login for `postgres` and `template1`.
   - 17: the login connects to `sdr_agent_dev` with its read-only default,
     `search_path = pg_catalog`, its timeouts and no superuser attribute.

   These read settings only. There is no table read, no function call and
   no write probe on the owner's data.
4. The functiondef hashes depend on the server's formatting. These values
   are for PostgreSQL 18.6. Check 4 compares them, and attest pins the
   prosrc values:

   | Function | prosrc SHA-256 (pinned in attest) | functiondef SHA-256 (PostgreSQL 18.6) |
   | --- | --- | --- |
   | `summary.g3_inventory_v1()` | `6357e1d4bd6bbd2038a0f07ff5f1ca8601ba1f864a24c28db8623859a527ea65` | `eae28c02a08eeb532c49d0c0a05b783b4856a1cbbec8c3dfa7706f8b312b829f` |
   | `summary.gdemo_drain_v1(text,timestamp with time zone,integer,text[])` | `b6cc57a9dbe7154ee9f400821670e10035ae9bb7a63fb969389d9a5c4d6142b8` | `ea809c263d976e99d5ed7dfa0bfca796b89493704c87f0143c2783c792c2775e` |

5. The owner reports the `accept.sh` output, labels only. Agents may start
   calling only after `ACCEPTANCE PASS` is reported. Running the
   attestation alone is not acceptance (D-173).
6. Re-run `accept.sh`, not attest alone:
   - after any CREATE OR REPLACE, ALTER, GRANT or REVOKE touching these
     roles, the schema or the functions;
   - after any change to PUBLIC's privileges on `sdr_agent_dev`, or to
     `pg_hba.conf`;
   - after a PostgreSQL upgrade. A new version also needs new functiondef
     values, and check 2 STOPs until they are reviewed.

   On STOP, agents stop calling.
7. Each new function or version, such as `_v2`, needs its own review,
   install and acceptance record.

## Credentials

There is no password today: the cluster uses `trust`. If the owner moves
to password authentication, they set one with `\password sdr_summary_login`
and keep it in owner-managed private configuration. It never goes in the
repo, chat, command arguments, logs or environment dumps.

## Owner-only (unchanged by this ADR)

- Writes, grants and raw reads.
- Installing, replacing or removing the functions.
- The TEMP and large-object revokes and their restore.
- The `pg_hba.conf` edit and reload, and any authentication change.
- Running acceptance and reporting it (OWNER-STEPS.md).
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
  - before each owner-path step in section 9: the uninstall, the install,
    the apply, the pg_hba edits and the rollback.

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

- `accept-test.sh` drives the real `accept.sh` through a stub `psql` in
  28 cases. Each failing input must end with `ACCEPTANCE STOP` and exit 3,
  with only fixed label lines. The inputs cover:
  - a missing or non-canonical port (zero psql calls);
  - attest exiting 3, missing its END marker, passing a different number
    of checks, or holding a FAILED row next to a PASS line (reported by
    name, never by value);
  - `accept.sql` exiting 3, missing `ACCEPT-SQL PASS`, holding a STOP row,
    having 12 `ok` rows, or printing nothing;
  - the login reaching `postgres`, or being refused for a reason other than
    pg_hba;
  - wrong login session settings;
  - a missing psql;
  - SIGTERM mid-run.

  A positive control shows hostile `PGHOST`/`PGPORT=5520`/`PGSERVICE`/
  `PSQLRC` values never reach psql, and every call names the endpoint
  explicitly. Mutating `accept.sh` (dropping the port bound, the FAILED-row
  check, the 13-ok count, the pg_hba-message check or the signal trap)
  fails the test.

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
- **Owner path (section 9), from the uninstalled prior state.**
  - Acceptance STOPs on install alone, on the revokes without pg_hba, and
    on pg_hba edited but not reloaded.
  - The inventory changes nothing and predicts each role's effect exactly.
  - After apply, the login and the definer are denied TEMP and all 17
    functions (42501). That includes psql's client-side `\lo_import`.
  - `adv_plain` loses both in `sdr_agent_dev` but keeps both in `postgres`.
    `adv_tempgrant` keeps TEMP and loses the 17. `postgres` keeps both.
  - The summary results are unchanged. A second apply is refused.
  - After the pg_hba reload, `accept.sh` passes, and the login is rejected
    for `postgres`.
  - Each tampered variant STOPs on its named check, then passes once
    reverted:
    - an extra table grant;
    - an extra SECURITY DEFINER function;
    - TEMP or a large-object function granted back to PUBLIC;
    - a direct TEMP or `lo_create` grant to the login;
    - `lo_compat_privileges` on;
    - login CREATEDB or INHERIT, or definer LOGIN;
    - a changed `search_path` or read-only default;
    - a replaced function body;
    - a missing reject line, a broader rule first, or an invalid pg_hba
      line;
    - a pg_hba change after the reload.
  - The rollback (uninstall, restore, pg_hba revert) returns the prior
    state exactly: roles, the effective database and `be_lo*` ACL tuples,
    the probed roles' reach, the schema, default ACLs, large objects, and
    pg_hba rules and bytes. Acceptance then STOPs.
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
- the acceptance of the real install;
- the effect inventory of the real cluster's roles (OWNER-STEPS.md step 3a
  stops on any role the table above does not list);
- the `local` (Unix socket) reject rules live. The throwaway cluster has no
  socket, so checks 12–13 verify those rules from the loaded file only.

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

- After the owner completes OWNER-STEPS.md once and reports
  `ACCEPTANCE PASS`, agents can run the G3 and G-DEMO checks without the
  owner at the keyboard.
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
  their own owner approval. D-173 approved exactly two narrow PUBLIC
  revokes, TEMP and the 17 large-object functions, with the effect list
  above. Nothing else is revoked.
