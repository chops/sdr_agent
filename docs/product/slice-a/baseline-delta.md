# Slice A baseline and delta

- **Status:** proposed for slice A, pending the owner's slice choice. Input to
  gate G4 (technical fit). Grounded in `origin/main` `98fb96e`; line numbers
  are from that commit and will drift. **Revision 2:** revised for Codex's
  review of `40f76d4` (read budget, recorded entity-trigger evaluation,
  expanded G4 checks).

## Baseline: what already exists

**Today's home is `SdrAgentWeb.DashboardLive`** (`lib/sdr_agent_web/live/dashboard_live.ex`,
route `/` in `lib/sdr_agent_web/router.ex`). It already shows lead count and
stages, drafts awaiting review (count and 5 oldest), accepted and in-flight
deliveries, and the attention list. It loads only on the connected render,
records an auditor's view before serving, fails closed on any refused read,
and live-refreshes (ADR-0012). Slice A is a **redesign and extension of that
view**, not a new one.

### Reads slice A uses (all exist)

| Function | File:line | Runs as | Used today by | Notes |
|---|---|---|---|---|
| `Outreach.list_review_queue/1` | `lib/sdr_agent/outreach.ex:82` (action `Draft :review_queue`, `outreach/draft.ex:102`) | operator | Dashboard, Review | pending_review, oldest first |
| `Outreach.list_handoff_queue/1` | `lib/sdr_agent/outreach.ex:168` (composes `Sales.list_handoff_queue/1`, `sales.ex:139`; `Lead :handoff_queue`, `sales/lead.ex:116`) | operator | lead pages | interested first; returns lead, latest matched reply, current assessment |
| `Operations.list_attention/1` | `lib/sdr_agent/operations.ex:142` (`Failure :attention`, `operations/failure.ex:100`; read policy `failure.ex:168`: admin, reviewer, auditor) | operator | Dashboard, Operations | open and acknowledged, newest first |
| `Agents.list_runs/1` | `lib/sdr_agent/agents.ex:167` | operator | Operations, Run, Audit, Lead | all runs of the tenant, newest first, **unbounded** |
| `Outreach.list_records(DeliveryOperation, opts)` | `lib/sdr_agent/outreach.ex:235` (generic guarded list) | operator | Dashboard | states: pending, attempting, accepted, unknown, failed_retryable, failed_permanent, delivered, bounced, cancelled; `not_before` for deferrals (`outreach/delivery_operation.ex:54`, `:479`) |
| `Sales.list_records(Lead, opts)` | `lib/sdr_agent/sales.ex:132` | operator | Dashboard | **unbounded**, counted in memory |
| `ConsoleData.index/3`, `current_revisions/2`, `contact_name/1`, `subject_path/2` | `lib/sdr_agent_web/console_data.ex` (`current_revisions` at `:24`, `subject_path` at `:44`) | operator | many views | `index/3` takes a filter (today the dashboard loads all contacts); `current_revisions/2` does **one fetch per revision**; `subject_path/2` does **one fetch per delivery or run subject** (today applied to the whole attention list, `dashboard_live.ex:50`) |
| `Runtime.status/0` | `lib/sdr_agent/ai/model_provider/runtime.ex:133` | **no actor** | Admin only (`admin_live.ex:65`) | configured and effective provider, refusal, CLI provenance |
| `Agents.daily_model_calls/1`, `daily_model_call_limit/0` | `lib/sdr_agent/agents.ex:257`, `:246` | **system context** (tenant id, no actor) | Admin only (`admin_live.ex:72-73`) | UTC day count of reserved model invocations |
| `Compliance.daily_send_cap/0` | `lib/sdr_agent/outreach/compliance.ex:19` | config | Admin only | clamped 1..25 |
| `AuditedView.record/4` | `lib/sdr_agent_web/audited_view.ex` | auditor only | all audited views | fail closed |
| `LiveRefresh.attach/2` | `lib/sdr_agent_web/live_refresh.ex` | operator | all console views | debounce, revalidation, ignores access/auth events |

Role gating for navigation: `SdrAgentWeb.Layouts.nav_items/1`
(`lib/sdr_agent_web/components/layouts.ex:155`). Admin page: `on_mount
{LiveUserAuth, {:roles, [:admin]}}` (`admin_live.ex:37`).

## Delta: what slice A changes

### D-A-1 Display changes only
- Redesign `DashboardLive` into the home in [screen-matrix.md](screen-matrix.md):
  needs-you-now summary; replies section (`list_handoff_queue/1`, not shown on
  home today); agent activity section (`list_runs/1`, not shown on home
  today); delivery breakdown into deferred and unknown; admin-only model and
  budget card; stale banner and last-updated time; accessibility work.
- Shell: skip link, focus ring, current-page marking in `Layouts.app`.
- The auditor's recorded target list grows to every id shown (same function).
- A view-level minute timer that recomputes clock-derived values from loaded
  rows (no reads), and one reload on a UTC date change (REQ-A-17).
- **No new route, resource, action, policy, calculation, event contract or
  migration.**

**Entity-model trigger: no** (independent evaluation by Codex,
consultation `m_1791505053356568333_a2dac1dc`, review of `40f76d4`). Reason:
no new or changed resource, persisted attribute, relationship,
calculation, aggregate, policy, action, lifecycle or backend event
contract; home composes existing permitted reads and keeps the existing
role and audit invariants. Moving the admin-visible status and reserved-call
count from `/admin` to an admin-only home card does not by itself widen
who may see them. This holds only under the conditions in G4 checks 1 to 4
below, and is **not** a PASS for any other work: a new count or batch read,
a changed audit-event or target contract, status for non-admins, or a
tenant-wide unknown model-call read is **trigger: yes** and needs its own
inline delta and independent PASS before implementation.

**Admin-only model card:** calling `Runtime.status/0` and
`Agents.daily_model_calls/1` from home for an admin shows the admin the same
information `/admin` already shows them. It does not widen exposure, but it
is a second caller of two reads that do not take an actor. The role check
must run **before** these calls, against the freshly revalidated user on
every load and reload, so the home never calls them for a reviewer or an
auditor, or after a demotion. `/admin` is read-only: it has no settings,
approve or retry controls, and the provider and budget are launch
configuration the owner changes outside the app.

### Read budget (REQ-A-15)

| Read | Count | Bound |
|---|---|---|
| `Sales.list_records(Lead)` | 1 | rows unbounded, counted in memory (D-A-2) |
| `Outreach.list_review_queue/1` | 1 | rows unbounded; 5 shown |
| `Outreach.list_records(DeliveryOperation)` | 1 | rows unbounded, bucketed in memory (D-A-2) |
| `Operations.list_attention/1` | 1 | rows unbounded; 5 shown |
| `Outreach.list_handoff_queue/1` | 3 internal | leads, matched replies, current assessments; 5 shown |
| `Agents.list_runs/1` | 1 | rows unbounded; 5 shown, counts in memory |
| `ConsoleData.index(scope, Contact, id: [in: shown recipient ids])` | 1 | at most 5 rows |
| `ConsoleData.current_revisions/2` on the 5 shown drafts | at most 5 | one fetch each |
| Subject paths for the 5 shown problems | at most 5 | 0 when the subject is a delivery or run already loaded (draft id or lead id read from the loaded row); `ConsoleData.subject_path/2` only otherwise |
| Admin card: `Runtime.status/0`, `Agents.daily_model_calls/1` | 2 | admin only, after the role check |
| `AuditedView.record/4` | 1 write | auditor only |

Worst case per load: 9 list reads, 2 status reads, 10 per-item fetches and
1 audit write, independent of how many rows exist. The row counts of the
unbounded lists are what REQ-A-15's target measures.

### D-A-2 Aggregate counts (entity-review trigger candidate; not in slice A)
Today's home loads every lead, delivery operation and contact, and counts in
memory; slice A adds every run. At workshop scale this is acceptable
(REQ-A-15). Bounded count reads would be new public read contracts on
`Lead`, `DeliveryOperation`, `AgentRun` (and `Contact`), so they trigger
entity discovery and an independent review. **Recommendation:** measure at
workshop scale in G4; add only if REQ-A-15 fails.

### D-A-3 Tenant-wide unknown model calls (trigger; excluded)
There is no tenant-wide read of `ModelInvocation`; `Agents.list_model_invocations/2`
(`agents.ex:297`) is per run. Showing "model calls with unknown outcome" on
home needs a new read action and policy: an entity delta. **Excluded from
slice A**; unknown model calls stay visible per run on `/runs/:id`.
Owner question OQ-3.

### D-A-4 Provider and budget for reviewers and auditors (trigger; excluded)
Showing this to non-admins means exposing admin-only information and calling
an actor-less status function and a system-context count for them. That
needs an actor-scoped read with a policy, and a threat note. **Excluded**;
owner question OQ-2.

### D-A-5 Why a delivery was deferred (excluded)
The reason (quiet hours or daily cap) is on the `Decision` named by
`last_decision_id`; reading it per delivery is one extra read each (N+1),
or a new joined read. **Excluded**: slice A shows "deferred until <time>".

## G4 checks for slice A (proposed)

1. **Same data, roles and contracts:** every read passes `actor: scope.user`
   except the two admin-only reads; no new or newly exposed field for any
   role; no payload content read on home.
2. **Admin guard before the actorless calls:** allow and deny tests prove
   `Runtime.status/0` and `Agents.daily_model_calls/1` are invoked for an
   admin and **never** for a reviewer, an auditor, or an admin demoted
   before a reload. CSS hiding is not evidence.
3. **Fresh user on every re-read:** each load and reload runs as the
   revalidated user (existing `LiveRefresh`); a disabled operator is signed
   out without a read; the role-restricted card disappears after demotion.
4. **Audit:** for an auditor, exactly one `record_view` per load and per
   event-driven reload, before rendering, with REQ-A-12's references; empty
   home records `"none"`; no access from the minute tick; no reload loop;
   nothing served when the record fails.
5. **Error paths:** a refused or failing read, including a raise from the
   status function or the count, withholds the page or the card with an
   operator-safe message; no value from an earlier load and no raw internals
   remain.
6. **Delivery buckets and clock:** the REQ-A-7 table and REQ-A-17 cases as
   unit tests on the bucketing and window functions (future and due
   `not_before`, nil, mixed deadlines, `failed_retryable` deferral, bounced,
   cancelled, expiry without an event, UTC rollover reload once).
7. **LiveView tests:** each role's visible cards; empty, error, refused on
   refresh, stale, unknown delivery and its recovery link, failure without a
   subject page; no write controls present; nav filtering.
8. **Load:** measure REQ-A-15 with its worst-case fixtures (including 200
   attention failures, 100 hand-off leads with replies and 50 drafts
   pending), and count the per-item fetches against the read budget.
9. **Accessibility:** REQ-A-14 checks 1 to 6, with measured contrast pairs.
10. **Entity trigger:** the recorded "trigger: no" above still holds; D-A-2,
    D-A-3 and D-A-4 stay excluded.

## Frozen while slice A is built

- Every domain resource, action, policy, migration and integration.
- Approval binding, suppression, idempotency, the audit trail.
- Real model calls (budget zero), HubSpot, live research, alerts.
- All routes other than the redesigned `/` and the shared layout.
