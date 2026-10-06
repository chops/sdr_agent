---
status: proposed
date: 2026-10-06
supersedes: null
---

# ADR-0010: Lifecycle State Machines as Explicit Ash Actions (No `ash_state_machine`)

## Status

Proposed (2026-10-06, Claude, slice S2). Acceptance per ADR-0001: the peer's
recorded approval on the S2 pull request; the owner can veto.

## Context

The S2 entity model has state machines on Lead, Campaign, CampaignEnrollment,
Sequence, IcpDefinition, AgentRun, ModelInvocation, ToolInvocation, Draft,
Approval, DeliveryOperation, WebhookEvent, Operation, Failure, AuditExport and
AuditSigningKey. Several guard safety invariants: a DeliveryOperation must be
claimed (`pending → attempting`) by exactly one worker, an `unknown` delivery
may leave that state only through reconciliation, and an Approval may be
revoked only while its delivery has not been attempted. Every transition must
append an AuditEvent in the same transaction (ADR-0009).

`ash_state_machine` (ash-project, Hex) offers a transitions DSL, a
`transition_state/1` change and diagrams. Adding it is a dependency change
that ADR-0001 and ADR-0008 require to be reviewed, pinned and audited.

## Options Considered

### Option 1: `ash_state_machine`

**Pros:** declarative transition table; generated diagrams; common in the
Ash ecosystem.
**Cons:** new runtime dependency to pin, audit and keep compatible with the
pinned Ash 3.34.3; we must still prove its guards are atomic under concurrent
claims and compose with the audit change; it does not remove the need for
per-transition actions with their own policies and arguments.

### Option 2: Explicit per-transition update actions (no new dependency)

Each transition is a named update action (`claim`, `mark_accepted`,
`revoke`, ...) with its own policy, arguments and audit event. A shared
validation checks the from-state atomically (the condition is part of the
SQL `UPDATE`, so a lost race returns a stale-state error rather than a double
transition). The state attribute is an atom with a `one_of` constraint and a
Postgres check constraint. Each resource declares its transition table as
data; a test asserts the declared table equals the set of transition actions
and their from/to states.

**Pros:** no dependency; per-transition policies are explicit (who may
`revoke` differs from who may `claim`); guards and audit append share one
code path; diagram can be generated from the declared table later.
**Cons:** we own a small validation and a table-consistency test.

## Decision

We will use Option 2. Lifecycle state is an atom attribute constrained by
`one_of` and a database check constraint; every transition is an explicit
update action whose from-state guard is evaluated atomically; each
resource's transition table is declared once and checked by a test.
Transitions that race (DeliveryOperation claim, reconciliation, Approval
revoke versus delivery claim) get a concurrency test in the slice that
creates them. Adopting `ash_state_machine` later needs a new ADR that
supersedes this one.

## Justification

The safety-relevant part of these machines is per-transition authorization
and atomic guarding, which both options leave to us. Option 2 delivers that
without a dependency change during an unattended build.

## Consequences

### Positive

- No new dependency or advisory surface.
- Each transition is individually authorized and audited.

### Negative

- No built-in diagram generation; the S10 or S13 docs may render one from the
  declared tables.
- Discipline needed: a transition added without updating the table fails the
  consistency test (intended).

### Neutral

- Fits ADR-0009's same-transaction audit coupling unchanged.
