---
status: proposed
date: 2026-10-06
supersedes: null
---

# ADR-0009: Domain Persistence Conventions (IDs, Tenant Column, Clock, Append-Only, Domain Layering)

## Status

Proposed (2026-10-06, Claude, slice S2). Acceptance per ADR-0001: the peer's
recorded approval on the S2 pull request; the owner can veto.

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
