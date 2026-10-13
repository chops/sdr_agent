---
status: proposed
date: 2026-10-12
supersedes: null
---

# ADR-0015 Home inbox projection and command boundary

## Status

Proposed amended text for C1, following the owner-accepted Home framing
(D-084) and [the C1 contract](../product/c1/readiness.md). On 2026-10-12 the
owner accepted the architectural choice with **exact totals** for Home's
count tiles. This replaces the prior prohibition on total-count queries;
it does not uncap list rows or accept runtime code. Amendment 1 below needs
independent full-text review and the owner's acceptance of the amended
wording. Scoped C1 G5 remains required before implementation.

Initial entity/full-contract reviews passed at 354c590/202349d. The
exact-total entity/action delta passed independent Claude review in
`m_1791862258000010202_eafd672b` (2026-10-13 03:30:58 UTC), including
auditor-only post-read audit placement. No runtime implementation is
included here; frontmatter stays proposed until amended-text acceptance.

## Context

Home is the founder's exception and approval inbox. Different domains
produce work requiring a human, while approval, suppression, recovery and
audit rules remain owned by those domains. A UI row must be bounded,
authorized and fresh, without creating a second lifecycle that disagrees
with the source or copying sensitive model/body content into a task store.

The first sources are drafts pending review and live Failures. Later
channels, referral/reply work and CRM previews need the same row and command
contract, but not automatic registration or a generic action dispatcher.

## Options considered

### Persist a separate Task resource

Pros: a single indexed queue and independently addressable task lifecycle.
Cons: source/task synchronization, invalidation and authorization become
new correctness responsibilities; resolved causes can leave stale tasks;
stored summaries can duplicate personal data. This is unnecessary for the
bounded initial sources.

### Compose and mutate separately in each LiveView

Pros: little new application structure and reuse of existing screens.
Cons: each consumer repeats ordering, error/empty semantics, freshness and
capability logic; a cached UI button can be mistaken for authority. Source
reads can become unbounded and cross-domain protections drift.

### Use a shared stateless projection and fixed command gateway

Pros: one bounded, typed contract for Home and consumers; source-owned
lifecycle and policy stay authoritative; no mirrored Task state or process.
Cons: each producer needs a bounded reader and an atomic freshness/action
adapter; paging across sources and partial-read states need explicit tests.

## Proposed decision

We will use the shared stateless projection and fixed command gateway.
There is no persisted Task, new Ash domain or organizing GenServer. Item
identity is stable for the source condition; membership and resolution come
from committed source state. Initial coverage is explicit, not a claim that
every future founder task is already represented.

The facade accepts only reviewed producer and action identifiers, resolves
the actor from authenticated scope, and delegates to source-owned APIs.
Domain adapters bound their queries and protect freshness comparison and
mutation in the same transaction using the existing source lock order.
They call guarded domain actions, never raw Repo writes. A token is a
concurrency check, not authorization. Approval preserves the exact displayed
revision id, content hash and recipient binding. Unknown cleanup/outcomes
never acquire blind retry permission.

List projections select metadata only, with fixed caps, stable continuation
and truthful partial/error states. Full content and audit evidence remain
behind the source's read policy and audited detail flow. Each later producer
requires independent entity/action and security review; it is not a plugin.

### Amendment 1: exact authorized section totals

Owner direction (verbatim, routed in
`m_1791861397000025639_2dad34b9`):

> 1. accept ADR-0015 as proposed 2. accept with exact totals 3. nothing to reject or change at this time

Clarification:

> the home count tiles should show exact totals

The initial count metrics are pending email Drafts, open/acknowledged
Failures, and committed local captures this week. The latter is a
count-only Outreach read, not another inbox task producer. Each metric has
one domain-owned, source-policy-authorized aggregate query; it returns a
scalar, not source rows, bodies or counted ids. Pending counts use the same
membership and fixed filters as the source list, **without its pagination
cursor or row limit**. Drafts are counted as drafts, Failures as conditions,
not distinct people or grouped leads. Historical captures count one logical
capture DeliveryOperation with committed `accepted_at`, not attempts or
files; the server's Monday-to-Monday America/Denver week is expressed as a
half-open UTC interval and labeled in the result.

Exact totals were chosen over page-derived/`50+` numbers, estimates and
persisted counters. The 50-row page cap and 51-candidate-per-producer
lookahead remain. No total is inferred from visible rows, truncated at 50,
computed by loading all rows, or substituted with a stale cached number.

A typed total is ready with a nonnegative integer, or unavailable with no
number. Authorization, withholding, source/list/count error or timeout makes
the affected section unavailable; zero is shown only after a successful
authorized exact count. Healthy sibling sources remain usable. Count
observations are timestamped, not an atomic global snapshot or authority
for a command. Empty/all-clear claims retain the complete-read rules of the
contract; a history count never becomes pending-work membership.

An exact COUNT can scan many index entries: **fixed scan cardinality or
constant work is not promised**. Each metric returns at most one aggregate
result and has a hard 2500 ms end-to-end deadline, including pool wait and
authorization work; its database statement timeout is at most 2000 ms and
the remaining deadline. Settings may lower, never disable or raise these
ceilings. Timeout cancels/rolls back query work rather than leaving an
orphan or retry loop. Source indexes/query plans and large synthetic
cardinality/held-lock tests are required; missing the bound produces
unavailable, not an approximate count.

Admin/reviewer metadata counts follow the ordinary list-read convention:
no per-count AuditAccess or introduced chain-head lock for successful
authorized reads; existing guarded denial auditing is not suppressed.
An auditor's Home view gets at
most one coalesced metadata-view AuditAccess per refresh, preserving the
bounded shown-row references and identifying aggregate scope/metric/window,
never enumerating unseen members or claiming body access. Every COUNT runs
outside head/domain row locks; read connections are released before the
separate short audit append transaction. That append has its own 2500 ms
ceiling; if it fails, the auditor view/numbers are withheld, not zero.
The aggregate target-ref shape must fit existing `record_access/5`
constraints or return for explicit review before code. Future count metrics
need independent review, just as future task producers do.

## Consequences

Positive: the inbox does not own or drift from domain lifecycles, does not
add a sensitive-data mirror, and gives B1/H1 and later consumers one testable
contract. Existing approval, capture-only, suppression, model-release and
operator-recovery protections remain in force.

Negative: no globally materialized task snapshot; exact count queries add
database work and can time out independently, so Home must show unavailable
numbers and partial state. They are time/result-size bounded, not promised
to scan a fixed number of rows. Source queries can fail independently.
Compare-and-mutate adapters and global keyset paging are correctness work,
not UI convenience. An unavailable guard disables an action rather than
inventing an implementation.

Neutral: adding persistence, dynamic producers or independent task lifecycle
later is a new architecture decision. No dependency or app-model permission
is added by this ADR. Runtime diagrams change when the approved C1 code
lands, not when this proposal is written.
