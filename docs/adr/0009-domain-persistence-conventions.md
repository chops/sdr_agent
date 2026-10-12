---
status: accepted
date: 2026-10-06
supersedes: null
---

# ADR-0009: Domain Persistence Conventions (IDs, Tenant Column, Clock, Append-Only, Domain Layering)

## Status

Accepted (2026-10-06) on Codex's approving verdict on the S2 pull request:
https://github.com/chops/sdr_agent/pull/5#issuecomment-6027676278
and the owner-decision delta soft-stop PASS (peer reply
b1243d3f-a7a8-450e-805e-97363b75e434, round 4). ADR-0001: agent design ADRs are
accepted on peer approval; the owner can veto. Proposed earlier the same day by
Claude in slice S2.

## Context

S2 (`notes/features/s2-entity-model.org`) defines about forty persisted
resources across seven Ash domains. ADR-0002 requires a gap-free, per-tenant,
hash-chained ledger, a single injectable UTC clock, immutable revisions and
reconstruction from Postgres alone. The accepted MVP checklist (1.3) says
"single tenant (tenant_id kept)"; ADR-0002 puts multi-tenant isolation out of
scope. The plan requires deterministic seed IDs and timestamps. Several
slices (S3, S5–S9, S11) will generate resources in parallel, so these
cross-cutting choices must be fixed once rather than per slice.

## Options Considered

### Primary keys

1. **UUIDv4** (`uuid_primary_key`, the generator default): random; poor index
   locality; no ordering.
2. **UUIDv7** (`uuid_v7_primary_key`, built into Ash 3; no new dependency):
   time-ordered, good B-tree locality, sortable by creation; still opaque.
3. **bigint sequences**: compact, but leak volume, need coordination with
   fixtures, and gaps carry no meaning.

### Tenant column

1. **Drop tenant_id** (single tenant): contradicts the accepted checklist and
   ADR-0002's per-tenant chain.
2. **tenant_id column on every tenant-owned table, no Ash multitenancy**:
   keeps the data shape and the chain partition; no isolation claim; no
   tenant plumbing through every call.
3. **Ash attribute multitenancy now**: real isolation, but every query,
   Oban job and Jido action must carry a tenant; AshAuthentication users
   need global handling; isolation is explicitly out of MVP scope.

### Immutability enforcement

1. **Ash actions only** (no update/destroy actions): stops application paths,
   not raw SQL or a future careless action.
2. **Ash actions plus Postgres triggers** rejecting `UPDATE`, `DELETE` and
   `TRUNCATE` on append-only tables (custom statements in the migration).

## Decision

1. **IDs:** every new resource uses `uuid_v7_primary_key :id`. Exceptions:
   the existing AshAuthentication `User`/`Token` keys stay as generated; the
   content-addressed payload store is keyed by `(tenant_id, sha256)`; the
   audit chain head is keyed by `tenant_id`. Seeds use fixture-declared UUIDs
   through `seed` create actions that accept `id`, authorized only for the
   seeder actor in `:dev`/`:test`.
2. **Tenant:** one `tenants` row (singleton constraint), owned by the
   lowest domain, `SdrAgent.Audit`, because the audit chain is partitioned by
   it; every FK to it therefore points downward. Every tenant-owned table has
   `tenant_id uuid NOT NULL REFERENCES tenants ON DELETE RESTRICT`, immutable
   after create and set from the actor by a shared change. Deployment-level
   tables (Tenant, ProvenanceSnapshot, AuditSigningKey) have no tenant_id; in
   the MVP their audit events append to the singleton tenant's chain. Every
   unique identity is written out with its full column list (tenant-scoped
   identities start with `tenant_id`); identities over nullable columns are
   partial indexes. Ash multitenancy is not enabled in the MVP; tenant_id is
   **not** an isolation boundary. Enabling attribute multitenancy later
   requires a new ADR.
3. **Trace correlation:** every row of every new resource and every
   AuditEvent carries non-null, non-zero `trace_id` and `span_id` (ADR-0005).
   The audit kernel opens a span when none is active, and the OTel SDK runs
   in every environment (exporter may be `none`), so no record class is
   untraced.
4. **Time:** all timestamps are `utc_datetime_usec` from `SdrAgent.Clock`
   (injectable; tests use a fixed clock). Resources do not call
   `DateTime.utc_now/0`; every AuditEvent records its `clock_source`.
5. **Append-only:** resources marked APPEND-ONLY in the S2 table expose only
   create and read actions, and their tables carry a trigger that rejects
   `UPDATE`, `DELETE` and `TRUNCATE`. Terminal-immutable resources
   (ModelInvocation, ToolInvocation, AuditExport) have a trigger that permits
   updates only to listed columns while the row is non-terminal. No resource
   has a destroy action in the MVP; deletion with tombstones is deferred to the
   data-classification ADR. Corrections are new rows that point backward
   (`supersedes_id` = prior row), with one root per subject and each row
   superseded at most once (partial unique indexes); the current row is the
   one with no successor.
6. **Audit coupling:** every audited action appends its AuditEvent in the same
   database transaction through one shared Ash change provided by S3; failure
   to append rolls back the domain write. Each event carries the canonical
   `record_sha256` of the row after the write. Denials of guarded actions are
   appended by the kernel after the outermost transaction ends (never inside
   it), straight to the ledger without any domain action, so they neither
   deadlock on the chain head nor recurse.
7. **Domain layering:** `Audit <- Accounts <- Operations <- Agents <- Sales <-
   Research <- Outreach`. A higher domain may hold an FK to a lower one; a
   lower domain stores a higher domain's id as a plain uuid and validates it
   in the orchestrating action. When an FK's target table arrives in a later
   slice, the earlier slice creates a plain nullable uuid column (or omits
   the column) and the later slice adds the constraint. Web, workers and Jido
   actions call public domain code interfaces with an explicit actor.
8. **Roles and actors:** human roles are `admin`, `reviewer` and `auditor`
   (the read-only auditor role was added by owner decision on 2026-10-06,
   extending ADR-0001's admin and reviewer roles). System actors are
   `%SdrAgent.Actor{}` structs, never users. An `auditor` user may only read
   (including the read-like generic actions for payload content and chain
   verification) and create AuditExports; the AuditAccess records its views
   produce are appended by the audit kernel. It cannot change its own
   password; an admin sets it. Every resource carries, after any
   AshAuthentication bypass, a guard policy over non-read actions that
   authorizes the exempt actions, forbids the auditor role, and ends with
   `authorize_if always()` so it never blocks other actors (in Ash every
   applicable policy must pass). Every auditor view is audited and fails
   closed.
9. **Synthetic-data guard:** in the MVP, account domains, contact emails and
   sender addresses must be under reserved names (`.test`, `.example`,
   `.invalid`, `example.com/.net/.org`), validated in every environment.

#### S3 implementation amendment (2026-10-06): upserts use `INSERT ... ON CONFLICT`

All AshPostgres upserts in this project MUST compile to `INSERT ... ON CONFLICT`,
never `MERGE`: `config :ash_postgres, upsert_with_merge?: false` is a durable
correctness constraint, not a tuning knob. On PostgreSQL 17+ AshPostgres would
otherwise emit `MERGE`, which raises unique violations when concurrent
transactions insert the same key. The insert-if-absent paths depend on
`ON CONFLICT` semantics: `Payload` (content-addressed dedupe),
`ProvenanceSnapshot`, and `Decision` idempotency (replay fingerprint
`replay_sha256`; identical replays return the existing row, conflicting key
reuse fails with `IdempotencyConflict`). Evidence: with `MERGE` re-enabled the
concurrency tests in `test/sdr_agent/audit/concurrency_test.exs` failed on every
run; with `ON CONFLICT` they pass. Removing or flipping this setting, or
upgrading AshPostgres in a way that changes upsert compilation, requires a
reviewed amendment to this ADR and a green concurrency suite. Reviewed by Codex
on PR #7 (https://github.com/chops/sdr_agent/pull/7#issuecomment-6029500570).

#### C3 amendment (2026-10-12): shared identity keys and their order

**Status: PROPOSED, pending Codex review and owner acceptance.** Not in force
until accepted; no code depends on it yet. Source: C3 readiness packet
(`docs/product/c3/readiness.md`, sections 5-7), Codex C3-01 entity review
round 1 (NEEDS-REVIEW at 5987410).

Lead admission, suppression and the webhook paths write the same identities
(a person's email, a company domain, the one open lead per company). Row
locks alone cannot serialize them, because the rows may not exist yet and
unique-index waits after the chain head can deadlock. One namespace and one
order cover every writer:

1. **Namespace.** `SdrAgent.Audit.IdentityKeys` is the only way to take a
   transaction advisory lock in this project. Kinds: `email`, `domain`,
   `admission-ref`, `reply-message`. A value is normalized per kind first
   (email trimmed and lowercased; domain canonical as `sdr_canonical_domain`: exactly one trailing dot and one leading `www.` stripped, malformed hosts rejected first).
   Lock id = the first 8 bytes of
   `sha256("sdr-identity-key/1\0" <> kind <> "\0" <> tenant_id <> "\0" <> value)`
   read as a signed 64-bit integer. It is computed in Elixir and sent as an
   integer parameter (`pg_advisory_xact_lock($1::bigint)`), so no personal
   value is ever a query parameter or log entry. The existing webhook
   Message-ID key (`hashtextextended`) moves into this namespace.
2. **One pass, sorted.** A transaction takes all its keys in a single call:
   lock ids deduplicated, then acquired in ascending signed order. A later
   call in the same transaction may ask only for keys it already holds;
   asking for a new one raises `IdentityKeys.LateAcquisition`. Held keys are
   read from `pg_locks` for the backend (the authority); a transaction-local
   marker (`set_config('sdr.identity_pass', …, true)`) records that a pass
   was made, even an empty one, and is reverted together with the keys by a
   rollback to a savepoint. The pass is an outer-transaction contract: the
   transaction's entry point (including seed, bootstrap and batch
   transactions) takes the whole set; nested actions only find keys held.
   No key is held while a model call waits.
3. **Before shared row locks.** The pass comes before any row lock in the
   identity lock domain: users, campaigns, agent runs, agent definitions,
   accounts, contacts, leads and their qualifications, enrollments, drafts,
   deliveries, approvals, and the chain head. A transaction may first lock
   only rows no key holder ever waits for (today: the WebhookEvent it is
   processing).
4. **Who takes keys.** Admission and referral handover (source ref, company
   domain, email, email domain); every Suppression create (its value);
   webhook reply, unsubscribe, bounce and complaint paths (one pass with the
   Message-ID key where used); Account create/seed/update (new canonical
   domain); Contact create/seed/change_email (new email); Lead `:reopen` and
   Qualification `:override` (the lead's company domain). An action nested in
   a transaction that already holds its key finds it held.
5. **Collisions.** Two values with the same lock id only serialize unrelated
   work. Correctness never depends on distinct ids.
6. **Unchanged.** Every existing row-lock order (Outreach leads → enrollments
   → drafts → deliveries → approvals, approval binding, grant admission) and
   the rule that every row lock precedes the first append stay as they are;
   keys are a prefix, not a reordering.

7. **Cutover.** The namespace and every writer in item 4 ship in one
   release with their migration; no deployment mixes the old webhook key and
   this namespace.

Changing a kind, the id derivation, the order or the lock domain needs a
further reviewed amendment and a green concurrency suite (independent
connections, both commit orders, waits shown on advisory locks).

## Justification

UUIDv7 costs nothing (built into the pinned Ash) and gives ordered, local
inserts for large append-only tables. The plain tenant column honours the
accepted checklist and the per-tenant chain without pretending to isolate
tenants. Triggers make "append-only" a database property an auditor can
inspect, not only an application promise. A fixed layering keeps parallel
slices from creating FK cycles.

## Consequences

### Positive

- One convention for every slice; reviewers check conformance, not taste.
- Raw-SQL edits of evidence tables fail loudly; hash checks catch the rest.
- Deterministic seeds without weakening production create paths.

### Negative

- Every audited write takes the chain-head row lock (serialised writes).
- Triggers live in custom migration SQL that Ash codegen does not manage;
  S3 must add a test that every APPEND-ONLY table has its trigger.
- tenant_id without enforcement can mislead a future reader; documented here.

### Neutral

- Existing AshAuthentication keys stay UUIDv4.
