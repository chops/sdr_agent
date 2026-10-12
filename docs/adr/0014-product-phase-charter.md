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

## Amendment 2 (2026-10-12): real companies and people for the owner's demo (constraint 7)

**Status: ACCEPTED** by the owner on 2026-10-12 (see Acceptance below).
Constraint 7 now reads as amended here. The app's synthetic-data guard
changes only through contract C5 (story C5-04); until that merges the guard
stays as it is. Decisions:
walkthrough rows F1 to F1d (D-032 to D-034, D-038 to D-047) and 22 (D-101).
Independent of the still-open Amendment 1 (PR #37).

### Why

The owner decided that the agent must find and work real companies and real
people for the Nov 6 demo ("i want the SDR agent finding real people for the
demo. otherwise this product is useless."), approved the data flow in build
plan §9a, and accepted its limitations. Constraint 7 as written forbids
that.

### Constraint 7, as amended

> 7. Synthetic or owner-provided test data in tests, CI, fixtures and every
> public artifact. Real companies and people may be processed only by the
> owner's own local instance, for the owner's personal demo use, with the
> real-data switch on, under the rules of Amendment 2. No real person's data
> in git, GitHub, public artifacts, chat transcripts shared outside the
> owner's machine, or telemetry content.

Constraints 1 to 6 are unchanged. In particular delivery stays captured
only (1): real data never means a real message is sent.

### Rules

1. **Switch, off by default.** Real data is accepted only when the app's
   real-data switch is on. It is refused at boot in `test`, never set in CI,
   and off unless the owner turns it on for the local instance. With it off,
   the existing reserved-domain guard applies unchanged.
2. **Guard policy (contract C5, story C5-04).** With the switch on, the guard
   allows non-reserved domains for accounts, contacts and research sources;
   everything else the guard protects stays as it is unless C5's reviewed
   contract changes it. With the switch off, already persisted real leads
   are not processed (no research, drafting or model calls), not only new
   ones refused at ingestion. Allow and deny tests cover both modes, and
   tests show personal content cannot reach logs, trace attributes, events
   or public evidence through any path, not only GenAI content capture.
3. **Approved flow (build plan §9a).**
   - Search queries go to Brave and Exa; company web pages are fetched
     directly.
   - Full fetched content is stored as local audit payloads, where the
     provider's terms permit it. If a provider permits only bounded
     snippets, local storage is bounded too, not only the model input
     (build plan §9a).
   - Research text and prospect fields go to Anthropic through the Claude CLI
     on the owner's subscription.
   - Raw model traffic is kept in the private local witness store.
   - The owner's attended LinkedIn flow and the owner's own contact-finding
     algorithm are sources once their B2 contracts are reviewed.
   - Paid enrichment providers are out (F1c).
4. **Telemetry.** OpenTelemetry content capture is off whenever the switch is
   on.
5. **Public surfaces.** Issues, pull requests, docs, fixtures, screenshots and
   evidence that leave the owner's machine stay synthetic. The owner masks or
   stops recording when real names or addresses would appear (walkthrough F1c).
   Screenshots of real people's data are not taken by the agents.
6. **Minimal fields.** Collect the standard CRM fields needed to qualify and
   reach a person (F1c); no sensitive categories. Contact details published
   on a source are kept as candidates with their citation and never
   auto-promoted (F4, F3b).

### Retention and deletion (simple rules, D-046)

- App-held copies stay in the owner's local database and private witness
  store (and any private local artifact the owner explicitly approves).
  The processing transfers in rule 3 do leave the machine: query terms go to
  Brave and Exa, and research text and prospect fields go to Anthropic.
  Provider-side retention follows each provider's terms and the owner's
  account settings, and a local wipe does not erase it. Agents make no
  additional copies.
- Someone who asks not to be contacted is suppressed at once. Outreach to
  them stops, and suppression is never lifted by the agent.
- There is no deletion feature in the MVP. The audit trail, payloads and
  witness are append-only, so a person's data cannot be erased record by
  record. This is the accepted limitation in item 7.
- Review point: by 2026-12-06 (30 days after the workshop) the owner decides
  whether to keep the local real-data database or wipe it. Wiping means
  dropping the database and the witness store, done by the owner. This is
  the owner's decision point, not authority for agents to delete anything,
  and it does not erase provider-side copies or backups. Any
  backups of the owner's machine are the owner's to manage.
- Before any decision to productize: an erasable personal-data store, legal
  review and redaction are required first. All three are deferred today
  (F1c).

### Accepted limitations (owner decisions)

7. Real personal data persists in the append-only audit trail, payloads and
   witness blobs and cannot be erased in the MVP. There is no legal review
   now. Provider-terms compliance rests on the owner's understanding (D-101).
   This is a personal, non-commercial demo.

### Acceptance (to fill)

- Owner words: "i accept PR #125"; 2026-10-12 (America/Denver), in the
  private Claude session chat.
- Independent review: Codex APPROVE of exact head 8a401f1 (after CHANGES
  REQUESTED on a552e15 was addressed); reply 01a130fa.
