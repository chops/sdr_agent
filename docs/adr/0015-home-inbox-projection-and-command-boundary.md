---
status: proposed
date: 2026-10-12
supersedes: null
---

# ADR-0015 Home inbox projection and command boundary

## Status

Proposed for C1, following the owner-accepted Home framing (D-084) and
[the C1 contract](../product/c1/readiness.md). Entity review passed on the
initial model at 354c590; full contract review, owner acceptance and scoped
C1 G5 remain required. No runtime implementation is included here.

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

## Consequences

Positive: the inbox does not own or drift from domain lifecycles, does not
add a sensitive-data mirror, and gives B1/H1 and later consumers one testable
contract. Existing approval, capture-only, suppression, model-release and
operator-recovery protections remain in force.

Negative: no globally materialized task snapshot or total-count scan; source
queries can fail independently and Home must show that partial state.
Compare-and-mutate adapters and global keyset paging are correctness work,
not UI convenience. An unavailable guard disables an action rather than
inventing an implementation.

Neutral: adding persistence, dynamic producers or independent task lifecycle
later is a new architecture decision. No dependency or app-model permission
is added by this ADR. Runtime diagrams change when the approved C1 code
lands, not when this proposal is written.
