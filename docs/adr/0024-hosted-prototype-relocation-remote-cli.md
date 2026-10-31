---
status: accepted
date: 2026-10-30
supersedes: null
---

# ADR-0024: Hosted prototype relocation and remote CLI transport

## Status

Accepted by Charles. Codex relayed the decision as
`m_codex_owner_source_approval_20261030T225619Z` (2026-10-30T22:56:19Z),
with the owner's exact words:

> Accept draft ADR-0024 and the ADR-0005 remote-transport amendment, and authorize source-only implementation with synthetic fixtures.

Basis:
- Entity PASS: B r4 `05a34102…` plus r4a `fee0b6d1…`
  (Codex `m_codex_sdr_offline_mac_entity_pass_b_r4a_20261030T184311Z`).
- Plan PASS: r1 `de8ac3f7…` plus r2 `df3a95a8…` (Codex review sha256
  `e70bf2cb8a532f061f3decc3c6c892f46413c084f9b7b2348ed1739f709f43e6`).

Decision D-270. The plan is recorded in
`notes/features/offline-mac-slice-b.org`.

The initial D-270 acceptance authorized **source-only implementation with
synthetic fixtures**. It did not authorize:
- real-data storage on the host (ADR-0014 Amendment 3, still proposed);
- any data transfer, deploy or relocation step;
- any model call, research, import or assign;
- any backup-secret access.

Subsequent owner authorization D-271 (2026-10-31) accepts ADR-0014 Amendment 3
and the reviewed dependency amendment, and authorizes the reviewed SDR-only
deployment sequence. See the installed Amendment 3 for the accepted backup,
data placement and restore terms. Approval does not establish backup state,
software readiness or grant additional model attempts. Existing verification,
single-authority relocation, secret-handling and no-outreach controls remain.

## Context

On 2026-10-30 the owner required that the website stay available while
the Mac is offline. Model calls must stay on the owner's subscription
Claude CLI on the Mac (D-262: no direct API; D-269 allowance). Today the
prototype's canonical DB (5542), the serve process and the CLI all run on
the Mac.

## Options Considered

1. **W1, SQL Oban node.** The Mac connects to a hosted DB as an Oban
   worker. Rejected: it gives the Mac the agent runtime's whole table
   authority, revocation needs session termination, and Lifeline is a
   threshold rather than a bound.
2. **W2, whole-run HTTP claim.** The Mac runs entire agent runs and posts
   result sets. Rejected for now: it needs a second write path into Ash
   and copies of the run inputs off the host.
3. **W3, per-call remote transport (chosen).** The hosted runtime keeps
   the workflow, and the Mac executes one charged CLI call at a time.
4. **Slice A only, a read-only mirror.** It is view-only with a manual
   refresh. It remains an optional reduced milestone and does not meet the
   full target.

## Decision

1. **Relocation.**
   - The canonical prototype DB moves once to a dedicated DB on
     ch-web-prod, through an append-only relocation event chain:
     planned → writers_stopped → fenced → restored → activated.
   - Abort is allowed before activation, and only after a
     `destination_disabled` event on any restored copy.
   - The fence is scoped to the live identity and is re-checked after
     `Kernel.lock_head` in every audit-appending action.
   - Spending authority follows the current-authority identity derived
     from the chain. The binding row is never edited, and setup is never
     re-run.
   - A return relocation is `relocation_seq + 1`.
2. **Remote transport.**
   - Under transport `:remote`, a `:claude_cli` invocation's
     RemoteModelCall is inserted in the `Agents.reserve_model_invocation`
     transaction.
   - The Mac agent claims one call in an atomic claim transaction, and
     launch admission (reserved → sent) happens inside that claim.
   - The claim is idempotent on an immutable `(worker_id, claim_nonce)`
     binding. A worker may hold one claimed call at a time.
   - The Mac returns the full stream-json transcript. The hosted side
     validates it with the existing init attestation and `finish_result`,
     then settles through the existing domain and release gate.
   - The server computes the digest; the first result is immutable; the
     receipts are append-only.
   - Deadlines: claim 120 s, result 600 s. A durable settler enforces
     them.
   - The charge is taken at reservation and never refunded.
3. **HostedOwner.**
   - An existing `:reviewer` user bound to the activation, enrolled and
     disabled by owner-run actions.
   - It has `review_read`, `assign` and Mac worker control through the
     prototype OperatorAction resolver.
   - Only it may read transcripts.
4. **Offline queueing.** An eligibility snooze runs before the START
   transition, so nothing is reserved or charged while the Mac is away.
5. **Disaster restore.** A restore after activation is read-only and
   non-spendable.
6. **Mac agent.**
   - It starts only the HTTP, crypto and SSL applications, never
     `:sdr_agent`.
   - Its executable and argv are pinned and built from an allowlist.
   - It keeps a launch-once journal of ids only.
   - Its temporary prompt files are 0600 and deleted after use.

## Justification

W3 keeps every authority decision on the host:
- grant and allocation arithmetic;
- prototype authority;
- the release gate;
- the audit chain.

The off-host credential can do only three things (claim, complete,
heartbeat), and revoking it takes effect at the next request.

## Consequences

- Model calls stay UNVERIFIED (ADR-0005 remote-transport amendment).
  Digest correlation inside the trusted-worker boundary is not provider
  evidence.
- Hosting real data needs ADR-0014 Amendment 3 and the owner's Hetzner
  Cloud backup check, both outside this acceptance.
- There are seven implementation slices:
  - S-B1 to S-B6 are owned by Claude.
  - S-B7, the Mac agent, is owned by Codex.
  - Each slice follows RED, then a Codex GO, then GREEN.
- The existing hosted synthetic service, AgentBuilder and the retained
  5542 cluster stay untouched until an approved cutover.

## Implementation limitation (2026-10-31, proposed)

**Status: proposed.** This note leaves the decision above and its acceptance (D-270) unchanged.

The S-B1 implementation refuses every `aborted` once `fenced` is recorded (Codex reviews 85b05b45 and
bbb5c558, entity PASS r3b). The approved end state is an abort that is safe across the forked copies. It needs
verified evidence that the destination was disabled, and that evidence cannot come from the source's own
history. That part is slice S-B1b: incomplete, owned by Claude, and pending its own entity/contract review and
owner approval.

Until S-B1b lands, a source fenced by a failed move stays fenced. That is fail-closed: availability is lost,
safety is not. Whether a milestone may ship with this reduced availability is the owner's decision.
