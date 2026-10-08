---
status: proposed
date: 2026-10-08
supersedes: 0001 (for product-phase work, only once accepted)
---

# ADR-0014: Product-Phase Operating Charter

## Status

Proposed (2026-10-08). Drafted by Claude for gate G0 of the SDLC process in
[`docs/sdlc/`](../sdlc/README.md). It takes effect only when the owner accepts
it explicitly in chat and the G0 gate record cites that acceptance. Until
then, [ADR-0001](0001-unattended-build-operating-charter.md) governs.

## Context

ADR-0001 let Claude and Codex build the MVP unattended between owner
checkpoints. That build is finished. On 2026-10-07 the owner rejected the next
build-first plan and froze new features until the product and the operator
experience are defined. On 2026-10-08 the owner asked for a traditional
software process run by the owner, Claude and Codex together, with every
durable artifact in git.

The unattended mandate no longer fits. The owner now takes part at every gate,
and the work is about product definition and design as much as code.

## Options Considered

### Option 1: Keep ADR-0001 and add gates informally

**Pros:** no new record.
**Cons:** ADR-0001 grants unattended authority and stop conditions written for a
build, not for a collaborative product process. Gates would have no written
authority behind them.

### Option 2: A product-phase charter that supersedes ADR-0001 for this work

**Pros:** one written source for who decides what, how gates pass, and what can
never be waived.
**Cons:** another document to keep current.

## Decision

We will use Option 2, once the owner accepts it.

### Decision rights

| Decision | Who decides | Notes |
|---|---|---|
| Gate approval (G0 to G9) | Owner only | Given in chat, recorded in a committed gate record. Dates never pass a gate. |
| ADR acceptance | Owner only | Agents propose; Codex or Claude reviews. |
| Exceptions to a gate criterion | Owner only | Written, with scope and expiry. A security exception also needs a recorded, independent security review of the exception and its mitigation, with a written disposition of the finding. If that review still finds it blocking, the gate stays blocked. Constraints that cannot be waived cannot be excepted at all. |
| Real model calls | Owner only | Budget is per approval and is currently zero. |
| Publication of owner words, design-partner material or anything private | Owner only | See the publication policy in `docs/sdlc/`. |
| Running anything on the owner's machine with elevated rights, deployment, credentials | Owner only | Agents prepare commands; the owner runs them. |
| Drafting packets, reviewing, tests, docs | Claude and Codex | Author and reviewer are never the same agent. |
| Merging a reviewed PR | Claude (coordinator) | Only with green CI on that exact commit and an approving review of that exact commit. A recorded range-diff showing a context-only delta can carry a prior approving review forward to a new commit. It never replaces green CI on the new commit. |

### Non-waivable constraints

These stay in force unless the owner accepts a later ADR that amends them. No
gate decision or exception can set them aside:

1. Captured delivery only. No code path may reach a real recipient or inbox.
2. Every approval is bound to the exact recipient and draft revision shown.
3. Suppression is checked before every delivery and cannot be bypassed.
4. No secret in git, logs, chat, process arguments or environment dumps. OAuth
   tokens are never copied.
5. The real model runs only through the locked-down Claude CLI on the owner's
   own login, for personal local use, with no tools and a per-call
   attestation (ADR-0004). Distribution to other people needs a separate
   provider and terms decision.
6. The audit trail is append-only and never edited or bypassed.
7. Synthetic or owner-provided test data only. No real prospect data.

### Process rules

- Material changes after review go back to the reviewer.
- The owner settles disagreements between Claude and Codex, but that does not
  waive an unresolved security blocker.
- Drafting may run ahead of approved inputs; approval may not.
- Only explicit owner approval of G5 lifts the feature freeze. Process and
  hardening work may continue during the freeze but carry no new authority.
- Stop and ask the owner when a step would need authority this charter does
  not grant.

## Consequences

**Positive:** every gate has a written authority and a record; the
constraints that protect real people and secrets are explicit.

**Negative:** more owner time per phase than the unattended build used.

**Risks:** the owner's review time becomes the critical path. The SDLC
schedule controls (WIP limit, scope-cut trigger, workshop fallback) manage
this.
