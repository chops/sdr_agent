# Home inbox read and command runtime

Hand-maintained: 2026-10-17. Source: [inbox-runtime.mmd](inbox-runtime.mmd).
Implements accepted ADR-0015: C1-02 reads and C1-03 slice A's three fixed
draft commands. There is no new Ash domain/resource, persistent task,
supervisor child or screen. The retry writer and H1 UI remain excluded;
refresh and these commands never invoke a model or send external email.

Cursor signing and freshness use one validated configuration secret per
authenticated request; the facade does not call or require the web Endpoint
process. Missing/invalid signing configuration fails closed. The Draft
aggregate is the single exact, field-authorized metadata-only call site in
the reviewed R0 aggregate inventory; output-field aggregates stay forbidden.

```mermaid
flowchart TB
    Caller[Authenticated backend consumer<br/>no H1 screen]
    Inbox[Stateless Inbox.refresh<br/>fresh active session, fixed options + cursor]
    Accounts[Accounts.current_operator<br/>signed + stored + unrevoked token]
    Drafts[Outreach list adapter<br/>51 candidates, selected bounded context<br/>source suppression + release guards]
    Failures[Operations list adapter<br/>51 candidates, global keyset]
    Counts[Three source-owned authorized aggregates<br/>Drafts, Failures, committed local captures<br/>Denver Monday half-open window]
    Budget[ReadDeadline short worker<br/>2500ms including pool + authorization<br/>SET LOCAL statement_timeout <=2000ms<br/>cancel / rollback, no retry]
    Merge[Merge and return <=50 metadata rows<br/>last returned key cursor<br/>independent exact totals or unavailable]
    AA[Auditor only: one coalesced AuditAccess<br/>after all reads finish + release connections<br/>2500ms append ceiling; failure withholds view]
    Command[Inbox.command<br/>current session + closed typed request]
    Adapter[Outreach.inbox_command<br/>independent session and shape validation]
    Locks[Audit.transaction<br/>enrollment SHARE, draft UPDATE,<br/>campaign SHARE, contact SHARE]
    Fresh[Revalidate session + current role after waits<br/>id-bound authorized source context<br/>synthetic, release and v1 freshness checks]
    Write[Existing guarded approve / edit / reject<br/>source actions append after dependent locks<br/>capture outbox only, never external send]
    Held[Retry has no writer in slice A<br/>one typed Failure read; stays blocked]
    DB[(PostgreSQL<br/>existing source policies and indexes)]

    Caller --> Inbox
    Inbox --> Accounts
    Accounts --> DB
    Inbox --> Drafts
    Inbox --> Failures
    Inbox --> Counts
    Drafts --> DB
    Failures --> DB
    Counts --> Budget
    Budget --> DB
    Drafts --> Merge
    Failures --> Merge
    Counts --> Merge
    Merge -- admin / reviewer: no audit append --> Caller
    Merge -- auditor --> AA
    AA --> DB
    AA --> Caller
    Caller --> Command
    Command --> Accounts
    Command -- three draft commands --> Adapter
    Adapter --> Locks --> Fresh --> Write
    Locks --> DB
    Fresh --> DB
    Write --> DB
    Write -- after commit: applied, refresh source --> Caller
    Fresh -- "refusal: rollback; guarded denial audited after txn" --> Caller
    Command -- retry request --> Held
    Held -- read only --> DB
    Held -- typed refusal --> Caller
```

Capabilities are advisory. Edit uses the atomic C1-03 adapter; retry remains
blocked pending slice B's reviewed recovery adapter. The source adapter
protects comparison and mutation together, and revalidates the real stored
session after lock waits; it never takes a generic audit-head lock. The
pure Command validator and Binding codec own no policies or processes.
Known source repeats return stale, not an unproven successful replay.
Source errors and lost replies never claim rollback or trigger auto-retry.

Reviewer Home conservatively withholds gen-2 Claude drafts
because the existing release metadata policy excludes that role (#152);
its pending-Draft total is unavailable, not a reduced ready count. Source
draft-page policy is unchanged. Bodies, parsed outputs, stderr and Payloads
are never read for this projection. Exact aggregates can scan many index
entries; they are time/result bounded, not fixed-scan-work bounded.

Forward obligation #153: C5-04 must make the synthetic-only list and count
guards consume its real-data switch together, preserving SQL/Elixir parity.
Until then, one withheld/corrupt Draft context withholds the whole Draft
producer, not only that row. Lists have bounded candidates but use existing
queue/query timeout defaults; sequential reads have no whole-page deadline.
