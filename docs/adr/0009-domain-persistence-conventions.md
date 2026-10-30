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

**Status: ACCEPTED.** The owner accepted this amendment on 2026-10-14
(America/Denver, about 14:28 MDT), in the private Claude session chat,
answering "yes" to "Accept the ADR-0009 C3 amendment (shared identity
keys)?". Codex passed its text in the C3-01 round-4 entity review (PASS at
1737063). No code depends on it yet; C3-02 implements it. Source: C3 readiness packet
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

#### C3-02 amendment (2026-10-19): application transactions, key-set additions and company identity

**Status: ACCEPTED.** The owner accepted this amendment on 2026-10-19
(D-176), through a pre-acceptance conditional on Codex's exact-text PASS of
the draft `claude-c302-adr0009-amendment-draft.md` (sha256
`149b3c7f0cb115d73d07600b3e71467b08b348e0d6654bfa798736ea3056c371`); Codex's
review `c1847c86` gave that PASS. Apart from this status paragraph, the text
below is exactly the text that PASS covered. The owner decided on 2026-10-19
(D-174, Q-O3) that this is a new amendment, not a clarification of the C3
amendment. No code depends on it yet; C3-02 implements it. Source: C3-02
module plan (`claude-c302-plan-r8.md`, sections 2.2-2.7).

The C3 amendment's items 2-3 speak of "the transaction", and its item 1
gives one domain normalization. Implementing them showed three gaps. Under
the Ecto SQL sandbox an application transaction is a savepoint, so the
backend can still hold keys of an earlier, released one. Three writers
change an identity value in place and so must serialize on both the old
and the new value. And stripping exactly one leading `www.` is not
idempotent (`www.www.acme.test` strips to `www.acme.test`, which strips
again to `acme.test`), so "normalize first" does not by itself make every
path agree on a company's identity. This amendment adds:

1. **Application and physical transaction lifetime.** In items 2-3,
   "transaction" means the outermost *application* transaction: the
   outermost `SdrAgent.Repo` transaction a process opens (including those
   Ash opens for an action, `Audit.transaction/1` and raw
   `Repo.transaction/2`). In production it is the physical transaction;
   under the Ecto SQL sandbox it is a savepoint, and advisory locks of an
   earlier, released application transaction may still be held by the same
   backend. Physically held keys are read from `pg_locks`, the authority
   for ownership. Each application transaction gets a fresh scope token at
   its root; its single pass records the complete deduplicated id set
   (possibly empty), bound to that token and the backend, in a
   transaction-local setting written after the last lock, so a rollback
   that releases the keys also reverts the record. A later request is
   allowed only when the whole recorded set is physically held and the
   request is inside it; otherwise `LateAcquisition` (outside the set) or a
   refusal (inconsistent). A failed acquisition ends the right to pass in
   that application transaction. A recorded pass reverted by a rollback may
   be followed by a fresh pass; detection relies on the convention that
   `IdentityKeys` is the only writer of the setting. Keys left by an
   earlier application transaction on the same backend neither count as
   this transaction's pass nor block it. The same code runs in every
   environment; lock-order and race proofs use independent physical
   connections.
2. **Key-set additions to item 4.** Lead `:seed` keys its account's
   canonical domain. Account `:update` keys the old and the new canonical
   domain. Contact `:change_email` keys the old email, the new email and
   the new email's domain. Each of these writers re-checks the keyed value
   on the locked row and refuses a stale one with a typed conflict,
   requesting no further key.
3. **Normalization by purpose (item 1).**
   - Key and index canonicalization is `strip`, exactly as written in item
     1 (`sdr_canonical_domain`: one trailing dot and one leading `www.`
     removed). A domain key id hashes the stripped key input exactly once.
   - Company identity additionally requires the stripped value `c` to be a
     valid fixed point (`company(c) == {:ok, c}`: a valid host of at least
     two labels with no leading `www.` and no trailing dot, unchanged by
     a second normalization). It therefore refuses repeated `www.`. That
     refusal at account and admission input, and the additive migration
     stopping with counts only when an existing account's indexed value is
     not such a fixed point, are the owner's separate decision D-174 Q-O6
     (accepted), recorded here by reference only.
   - Key inputs keep their purpose's existing validity. Suppression values
     and contact emails are not restricted by the company rule; they stay
     keyable as today.

Changing the transaction lifetime, a key set or a normalization purpose
needs a further reviewed amendment and a green concurrency suite
(independent connections, both commit orders, waits shown on advisory
locks).

#### D-237 amendment (2026-10-29): registered seed-run activation authority

**Status: ACCEPTED.** The owner accepted this exact r2 text in D-268(1),
recorded in commit `9ed3eb6494c5b21dfc7f972f4409c22eec2e22e8`. The reviewed
draft's SHA256 is `5c81c61dc616ddf80ed6ceb71b896cdcc935805f42ff565b4444497eff9e7e17`;
Claude's independent exact-text PASS is `4cc8f4e1987733224db60efbda84b4508e0c87f6d7db5d5b55fe652714b9aeb1`.
Apart from this status paragraph the inserted text is unchanged. Acceptance
is not a source, policy or runtime execution grant.

##### Context and alternatives

The local prototype operator must activate only the ICP, sequence and
campaign created by its own first seed run. A tenant match, a free context
map, a provenance digest alone, or a newly written profile paired with an
old draft does not establish that relationship. Row-version `xmin` is not
authority: subtransactions and 32-bit versus extended transaction identity
make it unsuitable here.

Two creation-evidence mechanisms were considered. W takes the audit chain
head first and uses its sequence as a watermark. That adds lock-order
inversions against existing revision and unique-key writers. C uses a
fresh seed-run correlation id on the existing creation events and adds no
early head lock. C is selected; existing audit appends keep their current
locks and ordering. No new persisted seed-run entity is introduced.

##### Decision

We will authorize this narrow seed activation through a registered,
transaction-bound `SeedScope`, following the existing trusted-process
conventions of Prelocked and ProvisionScope without changing either.

1. The scope is created only for the freshly resolved live prototype
   operator, inside its existing transaction, with one active scope per
   calling process. Tenant and delegation are derived from that actor.
   It binds a fresh reference, the complete registered state, the
   provenance digest, a fresh random UUID run id, the top-level
   `pg_current_xact_id()` and transaction-local markers.
2. Its ordered members are offering-profile revision 1, ICP, sequence,
   sequence step and campaign. Each is re-read by tenant/id through the
   existing kernel-context read path. Each must have exactly one matching
   authoritative creation event: resource/type/subject/action, tenant,
   delegation actor and this run's correlation id. Sales members must also
   carry the exact seed provenance digest; the profile must carry the
   validated provenance note. Stored step/campaign relationships must
   match the other bound members. Old drafts or caller-supplied structs
   cannot substitute for those reads.
3. The existing AppendEvent `context_links` copies `sdr_seed_run_id` onto
   `AuditEvent.correlation_id` only for the five seed action definitions.
   SettingsRevision is invoked twice, so both profile and guide creation
   events receive it. Seed still writes both revisions; the guide is not
   a sixth activation member. No column, migration, other action or
   operator read permission is added. A forged context key without a live
   registered scope supplies no activation authority.
4. The opening marker and a separate marker after each vouched member
   must remain set in the same top-level transaction. A rollback that
   undoes a vouched fact reverts its marker. The complete scope must equal
   the entry registered under its reference in this same process.
   Unregistered, incomplete, copied, tampered, cross-process, released or
   transaction-invalid scopes refuse. Registration is removed when the
   scope callback returns or exits in any way (return, raise, throw or
   exit); transaction completion and marker rollback do not extend its
   authority. The full transaction id alone
   is not an application-savepoint lifetime proof.
5. The new policy allowance applies only to `:activate` on IcpDefinition,
   Sequence and Campaign when that changeset's stored id, tenant and
   resource kind equal the corresponding member of the complete scope,
   and the live actor still resolves exactly. Ordinary runtime and the
   production build refuse this allowance. Existing admin/seeder policy
   lines, lifecycle transitions, row locks, step requirements and related
   active checks remain. There is no broad operator activation, update,
   retire, pause or resume permission.
6. Seed owns the single enclosing Audit transaction. The helper does not
   roll earlier writes back on its own: any member-write, bind or
   activation refusal must make Seed roll back the whole seed. Seed
   activates ICP, then sequence, then campaign. An exact historical seed
   replay performs no activation or write; complete-but-inactive history
   refuses rather than reactivating. Partial, ambiguous or differing
   history cannot supply a new scope.

##### Consequences and trust limit

Creation evidence uses the existing append-only audit event and
transaction-local marker mechanisms, without a new early chain-head lock.
This does not claim that all existing application lock orders are
deadlock-free. No public domain API accepts a caller-built scope; only
the internal Seed path supplies the run context and activation scope.

Like the referenced registered scopes, this is a trusted in-process
convention, not a capability secure against arbitrary privileged server
code. A run id is a correlation nonce, not a secret authorization token.
Refs, markers and captured state are not logged. No direct API, outreach,
model-budget, suppression, approval-binding or idempotency rule changes.

Before positive policy authority, focused checks must prove exact member
and kind binding, old/foreign/forged/rolled-back/released scope refusals,
ordinary/prod refusal and unchanged ordinary activation. Seed's own
checks must prove full rollback and replay-without-activation. Neither
this ADR nor an entity PASS substitutes for that implementation evidence.

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
