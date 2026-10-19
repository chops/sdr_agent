---
status: proposed
date: 2026-10-18
supersedes: null
---

# ADR-0016 Dev database summary access

## Status

Proposed. Nothing here is installed or approved for use. Codex's binding
review requirements for D-168 (`codex-d168-role-requirements.md`, eight
must-fix items) shaped this draft. The draft still needs:

- Codex review of this text, `install.sql`, `attest.sql` and the test evidence;
- owner acceptance;
- an owner-run install, followed by an installed-state attestation that matches.

Until all of those exist, every dev-database check stays owner-run.

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

Agents get one dedicated **login** role. It can do exactly one useful
thing: execute two reviewed functions in a dedicated `summary` schema.

| Function | Replaces | Output |
| --- | --- | --- |
| `summary.g3_inventory_v1()` | `g3-inventory.sql`, sections 1–5 | The same section names and counts |
| `summary.gdemo_drain_v1(phase text, start_at timestamptz, b1_attempts int, workshop_buckets text[])` | `claude-gdemo-drain.sql` (draft 3) | The same DRAIN, CONTEXT, AUTHORITY and CHECK rows and verdict |

Both functions return one fixed row type:

```
target, read_at, fn_version, section, k1..k5 text, n bigint
```

- The first row is `target`, which names the database, the UTC read time
  and the function version.
- The last row is `END`. Its k1 is `complete`, or `truncated` when any
  section reached its row limit.
- A result is complete only when its last row is `END|complete`. Anything
  else is unknown, never "nothing found". That includes an error, a
  timeout, a missing `END` row and `truncated`.
- A truncated drain result also carries `CHECK = STOP`.

Files:

- `priv/dev_summary_access/install.sql`: owner-run, one transaction, refuses
  any database other than `sdr_agent_dev`, and refuses non-superusers.
- `attest.sql`: the read-only installed-state attestation.
- `uninstall.sql`: exact rollback.
- `optional-revoke-temp.sql`: a separate owner decision, below.
- `test/dev_summary_access/adversarial.sh` and `seed.sql`: run against a
  throwaway cluster only.

### Principals

- **`sdr_summary_login`**
  - Role attributes: LOGIN, NOSUPERUSER, NOCREATEDB, NOCREATEROLE,
    NOREPLICATION, NOBYPASSRLS, NOINHERIT, CONNECTION LIMIT 2.
  - It is a member of no role, owns nothing and holds no table, column,
    sequence or large-object privilege.
  - Its only grants:
    - CONNECT on `sdr_agent_dev`;
    - USAGE on `summary`;
    - EXECUTE on the two exact function signatures.
  - Session defaults:
    - `default_transaction_read_only=on`;
    - `statement_timeout=60s`, `lock_timeout=5s`,
      `idle_in_transaction_session_timeout=60s`;
    - `search_path=pg_catalog`.
- **`sdr_summary_definer`**
  - NOLOGIN, with the same negative attributes. Nothing is a member of it.
  - It owns only the two functions.
  - It holds USAGE on `public` and `summary`, plus column-level SELECT on
    exactly the columns the two queries read:
    - `model_invocations`, `model_result_releases`, `audit_events`,
      `audit_exports`, `agent_runs` and `oban_jobs`;
    - `payloads.sha256` only;
    - the grant and allocation term columns.
  - It cannot read:
    - `payloads.content`;
    - grant names and purposes;
    - any prompt, response or bundle content.

    It cannot write anything, and it cannot create objects in `public`.
  - It does read `audit_events.payload` and `canonical_bytes`, because G3
    tests whether fixed key names are present in them. The functions return
    only fixed key names and counts from those columns.
- **The installing superuser** owns the `summary` schema. It is not the
  runtime function owner. The app's role is untouched.

### SECURITY DEFINER hardening

- Each function is `SECURITY DEFINER STABLE` and carries
  `SET search_path = pg_catalog, pg_temp`, `SET "TimeZone" = 'UTC'` and
  `SET lock_timeout = '5s'`.
- Every relation is schema-qualified as `public.x`. No helper is called
  outside `pg_catalog`.
- The bodies contain no dynamic SQL, `EXECUTE`, file, network or
  large-object call, or write.
- Arguments are validated before any read.
  - Bad input raises SQLSTATE 22023 with a fixed message,
    `invalid_argument: <field>`.
  - The message never echoes the input.
- Returned labels pass a fixed allow-pattern, otherwise they become `other`:
  - statuses, providers and queues: `^[a-z0-9_]{1,32}$`;
  - event types: `^[a-z0-9_.]{1,64}$`.
- Key names come from fixed in-function lists.
- No identifier, path, hash value or content is returned.
- Every grouped section has a LIMIT, and reaching it marks the result
  `truncated`.
- PUBLIC EXECUTE is revoked on each exact signature twice: before and after
  the ownership change.
- Default privileges for the definer revoke PUBLIC EXECUTE on any future
  function.
- All of this happens inside the install transaction, so there is no window
  where PUBLIC can execute either function.
- A STABLE function runs all of its queries on the calling statement's
  snapshot, so each call is one consistent observation.

### Shared defaults are not changed

`install.sql` changes nothing about PUBLIC, the `public` schema, or any
existing role, table or function. `attest.sql` instead reports the effective
PUBLIC-derived privileges as inventory:

- CONNECT and TEMP on each database;
- USAGE on `public`;
- the default backend-signal functions;
- other SECURITY DEFINER functions executable by PUBLIC.

Any database-wide change is a separate owner approval. The only one drafted
is `optional-revoke-temp.sql`. It defaults to read-only inventory mode,
prints which login roles would lose TEMP, and applies only with
`-v mode=apply`. The undo command is in the file.

## Boundaries

### Trust boundary (stated plainly)

The dev cluster accepts `trust` authentication on 127.0.0.1 and ::1, so any
local process can connect as any role, including `postgres`. On this
cluster, the login role is therefore a **procedural** boundary:

- agents agree to connect only as `sdr_summary_login` and to call only the
  reviewed functions;
- PostgreSQL then enforces what that role can do.

PostgreSQL does not stop an agent that breaks the agreement. To make the
boundary technical, the owner would change `pg_hba.conf` to `scram-sha-256`
for every role, including the app's, and set the login's password out of
band. That is an owner decision with app-configuration impact, and it is not
part of this ADR.

### Privilege boundary (what PostgreSQL enforces for the login)

The login cannot:

- SELECT any `public` relation, which was tested on all 56;
- write anything, even after it turns off its own read-only default;
- run DDL in `public`, `summary` or a new schema;
- replace, alter, drop or re-grant the functions;
- SET ROLE or SET SESSION AUTHORIZATION to the definer or a superuser;
- grant itself roles or alter itself;
- read server files, list directories or import large objects;
- COPY to or from files or programs.

Temporary objects can't change results:

- relations are qualified;
- `pg_temp` is never searched for functions or operators;
- the functions pin `search_path`.

The test shadows tables and views and defines a temp `~` operator and a
`count` function. Results are unchanged. With the pinned `search_path`
removed, the shadow probes still pass, so the attestation's shape check is
what catches that regression.

### Residual risks (accepted, recorded, not hidden)

1. **TEMP.** The login can create temp objects in its own session through
   the PUBLIC TEMP default. A per-role REVOKE can't cancel a PUBLIC grant,
   so this stays until the owner applies `optional-revoke-temp.sql`. The app
   connects as a superuser and is unaffected by that revoke.
2. **CONNECT elsewhere.** The login can connect to other databases on the
   cluster, such as `postgres`, through PUBLIC CONNECT. There it sees
   catalog metadata only. Removing this needs a `pg_hba.conf` line limiting
   the role to `sdr_agent_dev`, which is an owner option.
3. **Large objects.** PostgreSQL has no privilege for creating large
   objects, so once the login turns off its read-only default it can store
   data that way. It still reads nothing. `attest.sql` section J fails if
   either role owns any large object.
4. **Settings the login can change.** It can raise its own timeouts and
   turn off `default_transaction_read_only`. Timeouts and the connection
   limit bound accidents, not a hostile caller. Writes stay denied by
   privilege, not by the read-only default.
5. **Function source is readable.** `pg_proc.prosrc` is world-readable.
   The source is the reviewed file and contains no secrets.
6. **Aggregates are not anonymity.** Counts over small populations reveal
   facts about those populations. The outputs are limited to the two
   reviewed scripts' categories, and no adaptive filter arguments exist.

### Operational boundary

- Each call runs under the 60 s statement timeout and the 5 s lock timeout.
- At most 2 concurrent login sessions are allowed.
- Callers add their own deadline and call no more than the procedure needs.
- A drain result of zero is a snapshot. It does not prove that no writer is
  in flight, and it gives no authority to release leases, create grants,
  enable models or spend. The drain protocol and its owner gates are
  unchanged.

### Failure boundary

- Install is one transaction. A failed or repeated install leaves no
  partial state: the test shows that a second install refuses with 42710
  and leaves the function hashes unchanged.
- Bad arguments fail before any read.
- A caller sees only `complete`, `truncated`, or an error. All but
  `complete` are inconclusive.

## Installation and attestation (owner)

1. Review the exact `install.sql` at the reviewed commit, which must be
   unchanged since Codex's PASS.
2. Run it as the owner superuser against `sdr_agent_dev`. The last line
   must be `END-OF-SUMMARY-INSTALL`.
3. Run `attest.sql` and keep its output. Every `(must be …)` row must hold.
   The `G summary functions` prosrc and functiondef sha256 values must equal
   the values recorded for the reviewed commit; the adversarial log prints
   them from the same file. Agents may start calling only after this
   attestation is recorded.
4. Re-attest after any CREATE OR REPLACE, ALTER, GRANT or REVOKE touching
   these roles, the schema or the functions, and after any PostgreSQL major
   upgrade.
5. Each new function or version, such as `_v2`, needs its own review,
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
- The optional TEMP revoke.
- The app, the owner checkout, and every release, grant or spend decision.

## Verification

`test/dev_summary_access/adversarial.sh` runs on a throwaway cluster. It
uses its own initdb, a non-default port, the app schema restored without
data, and synthetic rows. It connects as the real `sdr_summary_login`
login, not only as `SET ROLE` from a superuser. It checks:

- **Exact output.** The function output equals the reviewed psql scripts
  for G3 and for drain pre and post, undrained and drained, plus a
  wrong-term post. The only difference is label sanitization.
- **Verdicts.** GO and STOP verdicts are correct.
- **Row bound.** A section at its row limit gives `END=truncated`.
- **Denials and shadowing.** Every denial and shadowing case listed above.
- **Argument rejections.** 21 cases, with no echo of the input.
- **Timeouts.** The statement timeout and the function lock timeout both
  trip.
- **Connection limit.** It is enforced.
- **The definer's own reach.** `payloads.content`, grant names, `SELECT *`
  and writes are all denied, and it cannot log in.
- **Leakage.** No seeded secret, raw label or path appears in any login
  output or error.
- **Attestation.** It holds before and after.

The script exits 0 only if every check passes. Three install mutants each
turn it red:

- widening the label sanitizer;
- unpinning `search_path`;
- granting the login `payloads`.

The run log records the results.

Not proven here:

- behaviour on the real `sdr_agent_dev` data;
- the attestation of the real install;
- that the dev cluster has no pre-existing PUBLIC SECURITY DEFINER
  functions. The test schema copy has none; `attest.sql` section H shows it
  on the real database.

## Consequences

- Agents can run the G3 and G-DEMO checks without the owner at the
  keyboard, after the owner installs and attests once.
- Every new question needs a new reviewed function version. There is no
  ad-hoc SQL, by design.
- The trust-auth caveat means this lowers the owner's toil but is not a
  hard security control until authentication changes.

## Alternatives considered

- **Keep all checks owner-run.** This is the D-168 rejected option. It is
  safe, but each check costs owner time.
- **A read-only login with column grants and no definer.** Rejected per
  Codex: the login could then run arbitrary SQL over every granted column,
  including content-bearing JSON, instead of fixed aggregates.
- **Views instead of functions.** Rejected: views need SELECT and would
  silently widen the EXECUTE-only interface.
- **Blanket revokes of PUBLIC and `public`-schema privileges.** Rejected.
  They are database-wide, can affect the app and other roles, and need
  their own owner approval (`optional-revoke-temp.sql` covers TEMP only).
