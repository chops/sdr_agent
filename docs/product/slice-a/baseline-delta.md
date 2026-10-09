# Slice A baseline and delta

- **Status:** proposed for slice A, pending the owner's slice choice. Input to
  gate G4 (technical fit). Grounded in `origin/main` `98fb96e`; line numbers
  are from that commit and will drift.

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
| `ConsoleData.index/2`, `current_revisions/2`, `contact_name/1`, `subject_path/2` | `lib/sdr_agent_web/console_data.ex` (`subject_path` at `:44`) | operator | many views | contacts are loaded whole (**unbounded**) |
| `Runtime.status/0` | `lib/sdr_agent/ai/model_provider/runtime.ex:133` | **no actor** | Admin only (`admin_live.ex:65`) | configured and effective provider, refusal, CLI provenance |
| `Agents.daily_model_calls/1`, `daily_model_call_limit/0` | `lib/sdr_agent/agents.ex:257`, `:246` | **system context** (tenant id, no actor) | Admin only (`admin_live.ex:72-73`) | UTC day count of reserved model invocations |
| `Compliance.daily_send_cap/0` | `lib/sdr_agent/outreach/compliance.ex:19` | config | Admin only | clamped 1..25 |
| `AuditedView.record/4` | `lib/sdr_agent_web/audited_view.ex` | auditor only | all audited views | fail closed |
| `LiveRefresh.attach/2` | `lib/sdr_agent_web/live_refresh.ex` | operator | all console views | debounce, revalidation, ignores access/auth events |

Role gating for navigation: `SdrAgentWeb.Layouts.nav_items/1`
(`lib/sdr_agent_web/components/layouts.ex:155`). Admin page: `on_mount
{LiveUserAuth, {:roles, [:admin]}}` (`admin_live.ex:37`).

## Delta: what slice A changes

### D-A-1 Display changes only (no entity trigger)
- Redesign `DashboardLive` into the home in [screen-matrix.md](screen-matrix.md):
  needs-you-now summary; replies section (`list_handoff_queue/1`, not shown on
  home today); agent activity section (`list_runs/1`, not shown on home
  today); delivery breakdown into deferred and unknown; admin-only model and
  budget card; stale banner and last-updated time; accessibility work.
- Shell: skip link, focus ring, current-page marking in `Layouts.app`.
- The auditor's recorded target list grows to every id shown (same function).
- **No new route, resource, action, policy, calculation or migration.**

**Admin-only model card:** calling `Runtime.status/0` and
`Agents.daily_model_calls/1` from home for an admin shows the admin the same
information `/admin` already shows them. It does not widen exposure, but it
is a second caller of two reads that do not take an actor. **G4 must confirm
the role check happens before these calls** (the home must not call them at
all for a reviewer or auditor).

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

1. Every read passes `actor: scope.user`, except the two admin-only reads,
   which are called only after an admin role check (D-A-1).
2. No payload content is read on home; no newly exposed field for any role.
3. Auditor: one recorded view per load and refresh, ids complete, fail closed.
4. Refresh fails closed and revalidates the operator (existing `LiveRefresh`).
5. LiveView tests: each role's visible cards; empty, error (refused read),
   stale (disconnect), unknown delivery; no write controls present; nav
   filtering.
6. Load-time measurement at REQ-A-15 scale with synthetic data.
7. Entity-trigger evaluation recorded: "no entity delta" holds only if
   D-A-2, D-A-3 and D-A-4 stay excluded.

## Frozen while slice A is built

- Every domain resource, action, policy, migration and integration.
- Approval binding, suppression, idempotency, the audit trail.
- Real model calls (budget zero), HubSpot, live research, alerts.
- All routes other than the redesigned `/` and the shared layout.
