# Home inbox read runtime

Hand-authored: 2026-10-14. Source: [inbox-runtime.mmd](inbox-runtime.mmd).
Implements accepted ADR-0015 and the C1-02 read-only slice. There is no new
Ash domain/resource, persistent task, supervisor child or screen. C1-03
commands and H1 UI are excluded; no calls or spend occur on refresh.

Cursor signing and freshness use one validated configuration secret per
authenticated request; the facade does not call or require the web Endpoint
process. Missing/invalid signing configuration fails closed. The Draft
aggregate is the single exact, field-authorized metadata-only call site in
the reviewed R0 aggregate inventory; output-field aggregates stay forbidden.

```mermaid
flowchart TB
    Caller[Authenticated consumer]
    Inbox[Stateless Inbox.refresh]
    Accounts[Fresh signed + stored + unrevoked session]
    Drafts[Outreach: <=51 Draft candidates<br/>bounded selected context + suppression/release guards]
    Failures[Operations: <=51 Failure candidates]
    Counts[Three authorized scalar counts<br/>2500ms end-to-end each, <=2000ms statements<br/>short worker + local settings + cancel/rollback]
    Merge[<=50 merged metadata items + last returned key<br/>exact totals or unavailable; truthful partial state]
    AA[Auditor only: coalesced post-read audit<br/>2500ms; failure withholds view]
    DB[(PostgreSQL + existing source policies)]
    Caller --> Inbox
    Inbox --> Accounts --> DB
    Inbox --> Drafts --> DB
    Inbox --> Failures --> DB
    Inbox --> Counts --> DB
    Drafts --> Merge
    Failures --> Merge
    Counts --> Merge
    Merge -- ordinary human --> Caller
    Merge -- auditor, after read connections released --> AA
    AA --> DB
    AA --> Caller
```

Capabilities are advisory. Edit/retry are blocked pending reviewed atomic
C1-03 adapters. Reviewer Home conservatively withholds gen-2 Claude drafts
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
