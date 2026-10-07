---
status: accepted
date: 2026-10-07
supersedes: null
---

# ADR-0012: Live Console Refresh from Commit-Time Audit Notifications

## Status

Accepted (2026-10-07) on Codex's design ruling on the S13a pull request
("ADR-0012 DESIGN APPROVED independently"):
https://github.com/chops/sdr_agent/pull/19#issuecomment-6043274640
(ADR-0001: agent design ADRs are accepted on peer approval; the owner can
veto). Proposed earlier the same day by Claude in slice S13a. The ruling
keeps the failure coupling and lost-notification limits below explicit, and
required the payload bound below before the implementation is approved. No
dependency is added.

## Context

For the demo, the console has to show the agent working: a lead's runs,
evidence and draft appear, the review queue fills, a draft's approval and
delivery update. The S10 LiveViews load data only on navigation. Live views
need a signal that domain state has changed, with these constraints:

- **Commit, not attempt.** A view that re-reads on a signal sent before
  commit can read stale rows, or announce work that is then rolled back.
  Writes commit through several paths: Ash-managed transactions,
  `Repo.transaction`, `SdrAgent.Audit.transaction/1`,
  `SdrAgent.Audit.Kernel.in_transaction/1` and worker transactions. Ecto
  has no after-commit hook that covers all of them.
- **One choke point already exists.** Every audited write appends an
  AuditEvent through `SdrAgent.Audit.Kernel` inside its transaction
  (ADR-0002, ADR-0009).
- **Web rules.** LiveViews re-read through public domain APIs with
  `actor: scope.user` and treat socket state as stale. An auditor's view is
  recorded (AuditAccess) before it is served, and recording an access also
  appends an AuditEvent.
- **Approval binding.** A reviewer approves the revision id and hash
  rendered on the page. If a refresh swapped the revision silently, the
  reviewer could approve content they had not read.

## Options Considered

### Option 1: Broadcast from domain code after each public API call

**Pros:** no database feature involved.
**Cons:** many entry points (agent turns, workers, hand-off, reviewers).
Calls inside an enclosing transaction would broadcast before commit, and a
broadcast could be missed when a new path is added.

### Option 2: Process-dictionary after-commit queue flushed by our transaction wrappers

**Pros:** in-process.
**Cons:** it must hook every transaction boundary (Ash, Ecto and ours) and
clear itself on every rollback path. It is fragile and leaks when a path is
missed.

### Option 3: `pg_notify` in the audit append and a supervised LISTEN relay

**Pros:** Postgres delivers `NOTIFY` only when the enclosing transaction
commits, and drops it on rollback, which gives exact commit semantics for
every write path. The hook sits at the single append point. Notifications
cross nodes.
**Cons:** one extra statement per append, and a dedicated listener
connection. Notifications sent while the relay is disconnected are lost.

### Option 4: Polling

**Pros:** trivial.
**Cons:** load and latency. Every poll by an auditor records an access.

## Decision

We will use Option 3:

- `SdrAgent.Audit.Kernel` calls `SdrAgent.LiveEvents.notify/1` after it
  advances the chain head. This runs `SELECT pg_notify('sdr_audit_events',
  json)` in the same transaction. The payload is bounded by construction to
  at most 512 bytes, whatever the event holds: tenant id and sequence, plus
  event type, category, subject resource, subject id and agent run id only
  when each is short (per-field byte caps) and plain (`[A-Za-z0-9_.:-]`, so
  JSON never escapes it). Any other value is sent as `null` — dropped, never
  truncated — so an oversized or multibyte event type or resource still
  commits and still triggers a (coarse) refresh. It never holds content.
- `SdrAgent.LiveEvents.Relay` is supervised after PubSub. It keeps a
  `Postgrex.Notifications` connection (async connect, auto-reconnect) and
  re-broadcasts each notification on the tenant topic
  `audit_events:<tenant_id>` with `Phoenix.PubSub.broadcast_from/4`.
- `SdrAgentWeb.LiveRefresh.attach/2` subscribes a connected view to its
  scope's tenant topic. On a relevant event the view re-runs its normal
  load function: a full re-read through the domain APIs with the operator
  as actor, so an auditor's refresh is recorded like any other view. Events
  in the `access` and `auth` categories are ignored. They change no domain
  data, and reacting to them would loop on the auditor's own access
  records. Bursts are coalesced to one reload per 250 ms window (0 in
  tests).
- The draft page never swaps the displayed revision. When the current
  revision has changed, it keeps the displayed revision and its
  approve/reject binding, and shows a notice that offers the latest
  revision. The domain still refuses a verdict on the old revision as stale.
- Live refresh is wired on the Dashboard, Leads detail, Review queue, Draft,
  Runs & operations and Run views.

## Justification

Only Option 3 gives commit-exact signals on every write path without
touching each one. It does so at the existing audit choke point, adds no
dependency, and leaves the ledger unchanged.

## Consequences

### Positive

- The demo shows agent, reviewer and delivery progress live.
- A rolled-back write never triggers a refresh.
- New audited write paths are covered with no further change.

### Negative

- One extra statement per audit append, and one extra database connection.
- Best effort only. A notification sent while the relay is disconnected is
  lost, and the view updates on its next navigation. The ledger is
  unaffected.
- Sandboxed tests never commit, so view tests deliver the relay's broadcast
  themselves. Commit-time delivery is proven separately on real connections
  (`test/sdr_agent/live_events_test.exs`).

### Neutral

- Failure coupling (explicit, accepted): if `pg_notify` fails (for example,
  the server's notification queue is full because a listener stalls inside
  a long transaction), the append fails and its transaction rolls back, as
  any failed statement would. The payload bound removes the size failure;
  `test/sdr_agent/live_events_test.exs` commits an oversized event.
