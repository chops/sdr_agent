---
status: accepted
date: 2026-10-08
supersedes: 0001 (for product-phase work)
---

# ADR-0014: Product-Phase Operating Charter

## Status

Accepted (2026-10-08, by the owner, in chat at about 14:00 America/Denver;
recorded in [`docs/sdlc/gates/G0.md`](../sdlc/gates/G0.md)). Drafted by Claude
and reviewed by Codex for gate G0 of the SDLC process in
[`docs/sdlc/`](../sdlc/README.md). It supersedes
[ADR-0001](0001-unattended-build-operating-charter.md) for product-phase work.

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

We use Option 2.

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

## Amendment 1 (proposed 2026-10-10): delegated authority

**Status: PROPOSED.** Not in force until the owner explicitly accepts it in
chat and an acceptance note, in the style of a gate record, is added below.
Until then every decision in the table above stays as written, and the
real-model budget stays zero. Decision ID: proposed D-028.

The owner asked for this during the prep-docs walkthrough on 2026-10-09 to
keep the project moving without routing low-risk work through the owner.
Claude and Codex recommended it jointly; the owner reviewed the
recommendation and asked for it to be drafted.

### (a) Docs-only pull requests

- **May be delegated:** pull requests that change only documentation (the
  journal, the decision log, walkthrough notes, the prep-docs hub), that are
  factual, and that contain no private material.
- **Rule:** the coordinator may merge such a pull request on an independent
  approving review of the exact commit and green CI on that exact commit,
  without waiting for the owner.
- **Limits:** these documents may record owner decisions that already exist,
  each with a source locator. They never create or imply an approval.
- **Stays owner-only:** gate records, policy and ADR changes, and new
  publication consent for private or previously unconsented material.

### (b) Agent CLI version bumps

- **May be delegated:** version bumps of the command-line tools the agents
  themselves use (Claude Code, Codex, agy).
- **Rule:** the agents prepare and peer-review the bump in their own
  nix-darwin worktree, with pinned artifacts, a build and tests, and a
  rollback path. Replacing a running agent session uses the resume skills with
  a checkpoint and a safe handoff.
- **Out of scope:** the application's pinned model runtime, the proxy,
  authentication and permissions.
- **Stays owner-only:** `sudo darwin-rebuild switch` and any other activation
  with elevated rights.

### (c) Standing proof budget for the application's model runtime

- **May be delegated:** up to 2 synthetic real-model proof invocations per
  named, independently reviewed candidate CLI version for the application's
  runtime; at most 2 per UTC day and 6 in total. The budget expires
  2026-11-05 at 23:59 America/Denver.
- **Rule:** one designated runner checks and updates a shared budget ledger
  before each call. The ledger's path is defined in the application-runtime
  pinning work. Failed and unknown attempts count against the budget. Any
  drift or unknown outcome stops the work. There is no automatic top-up.
- **Reporting:** after each use the owner receives a sanitized report:
  purpose, candidate, attempts including wire retries, outcome, and an
  evidence locator.
- **Limits:** the budget pays for proof only. Promoting the application's
  runtime, changing the wire-witness allowlist, and any activation or restart
  still need owner approval. Tools-off operation, per-call attestation, proxy
  routing, privacy rules and the existing hard caps remain mandatory.

### Revocation

The owner may revoke or narrow any of these delegations at any time in chat.
Revocation takes effect immediately and is recorded in the decision log.
