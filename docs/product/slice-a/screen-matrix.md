# Slice A screen, action and state matrix

- **Status:** proposed for slice A, pending the owner's slice choice. Method
  step 4 (P2 draft); finalised in P3 after the prototype walkthrough.
  **Revision 2:** revised for Codex's review of `40f76d4`.
- **Requirements:** [requirements.md](requirements.md). **Data sources:**
  [baseline-delta.md](baseline-delta.md). **Prototype:** [prototype.html](prototype.html).

## Screens

### SCR-A-1 Navigation shell

| Field | Content |
|---|---|
| Job | Get to the right place in one step, and always know where you are. |
| Information and provenance | Signed-in name and role (`current_scope.user`); navigation items filtered by role (`SdrAgentWeb.Layouts.nav_items/1`). |
| Actions | ACT-A-1 to ACT-A-6 (navigation), ACT-A-12 (skip to content), ACT-A-13 (sign out: the existing authentication action, not a domain write). |
| Actor and preconditions | Any active signed-in operator (`LiveUserAuth :operator`). Audit and Admin items only for the roles allowed today. |
| States | Normal. Stale: connection banner (shared with home). Signed out or disabled: redirected to sign-in (existing). |
| Audit | No new audit records. |
| Requirements | REQ-A-1, REQ-A-13, REQ-A-14 |
| Example | A reviewer tabs once to "Skip to content", then through Home, Leads, Review queue, Runs & operations; no Audit or Admin item exists for them. |

### SCR-A-2 Home

| Field | Content |
|---|---|
| Job | Answer "what needs me now, and what is the agent doing?", then hand off to the existing screen where the founder acts. |
| Information and provenance | Needs-you-now counts (review queue, hand-off queue, attention failures); drafts awaiting review, 5 shown (`Outreach.list_review_queue/1`, current revisions via `ConsoleData.current_revisions/2`, recipients via `ConsoleData.index/3` filtered to the shown drafts); replies to handle, 5 shown (`Outreach.list_handoff_queue/1`); problems, 5 shown (`Operations.list_attention/1`, subject paths from loaded rows, `ConsoleData.subject_path/2` only as fallback); agent activity (`Agents.list_runs/1`); captured sends in nine disjoint buckets (`Outreach.list_records(DeliveryOperation)`, REQ-A-7); model and budget, admin only (`Runtime.status/0`, `Agents.daily_model_calls/1`, `Agents.daily_model_call_limit/0`, `Compliance.daily_send_cap/0`, called only after the admin check); pipeline (`Sales.list_records(Lead)`). All reads run as the signed-in operator except the two admin-only reads, which take no actor (D-A-1). |
| Actions | ACT-A-7 to ACT-A-11, ACT-A-14 to ACT-A-16 (navigation to existing screens). **No writes** (REQ-A-13). |
| Actor and preconditions | admin: everything. reviewer: everything except the model and budget card. auditor: everything except the model and budget card, and only after the audited view is recorded. |
| States | **Loading:** skeleton until connected. **Error** and **refused on refresh:** whole page withheld, operator-safe message, nothing from an earlier load left on screen, "Try again" and a link to Runs & operations. **Empty:** per section ("Nothing waiting", "No replies to handle", "No open problems", "No runs yet", "No captured sends yet"), capture-only label still shown. **Stale:** banner while disconnected. **Blocked:** a role-restricted card is absent, not greyed. **Unknown:** "Outcome unknown" delivery bucket with its recovery link, never merged into captured or failed. **Due:** a deferral past its time is Queued or Retry due, not captured. |
| Freshness | "Data as of" the last load; "times checked at" the last minute tick, which recomputes delivery buckets and the 24-hour run window from loaded rows with no reads. One normal reload when the UTC date changes (REQ-A-17). |
| Async and recovery | Live refresh per ADR-0012: debounced reload on committed audit events, revalidating the operator each time. Recovery actions are on `/operations` and the subject screens; home only links to them (REQ-A-18). |
| Audit | For auditors: exactly one `record_view` access per load and per event-driven reload, recorded before rendering, `target_resource` "Dashboard", `target_ref` and `purpose` as in REQ-A-12; failure to record means nothing is served (`AuditedView.record/4`). The minute tick records nothing. No payload content is read on home. |
| Requirements | REQ-A-2 to REQ-A-18 |
| Example | The founder (admin) opens the app at 07:58 MDT: "7 drafts to review · 4 replies to handle · 2 problems". The model card says "Configured: fake model. In effect: fake model." Captured sends show "Deferred: next due 08:00, last 09:30" with 4, "Queued" 1 and "Outcome unknown" 1 with a link to reconcile it on Runs & operations. At 08:05, with no new event, the minute tick moves the three 08:00 deferrals out of Deferred: Queued becomes 3 and Retry due 1, and Deferred shows "next due 09:30"; "Data as of 07:58" is unchanged and Captured stays 4. They click the interested reply and land on the lead page. |

## Actions

All slice A actions are navigation, plus the existing sign-out. Every
destination already exists and enforces its own policies.

| ID | Action | Where | Who | Destination | Requirement |
|---|---|---|---|---|---|
| ACT-A-1 | Open Home | Shell | all roles | `/` | REQ-A-1 |
| ACT-A-2 | Open Leads | Shell | all roles | `/leads` | REQ-A-1 |
| ACT-A-3 | Open Review queue | Shell, summary, "See all" | all roles | `/review` | REQ-A-1, REQ-A-2, REQ-A-3 |
| ACT-A-4 | Open Runs & operations | Shell, problems footer | all roles | `/operations` | REQ-A-1, REQ-A-5 |
| ACT-A-5 | Open Audit | Shell | admin, auditor | `/audit` | REQ-A-1 |
| ACT-A-6 | Open Admin (read-only status) | Shell, model card | admin | `/admin` | REQ-A-1, REQ-A-8 |
| ACT-A-7 | Open a draft | Drafts list | all roles | `/drafts/:id` | REQ-A-3 |
| ACT-A-8 | Open a replied lead | Replies list | all roles | `/leads/:id` | REQ-A-4 |
| ACT-A-9 | Open a failure's subject | Problems list | all roles | subject path | REQ-A-5 |
| ACT-A-10 | Open a run | Agent activity | all roles | `/runs/:id` | REQ-A-6 |
| ACT-A-11 | Jump to a home section from a summary count | Summary | all roles | in-page anchor | REQ-A-2 |
| ACT-A-12 | Skip to content | Shell | all roles | in-page anchor | REQ-A-1, REQ-A-14 |
| ACT-A-13 | Sign out (existing authentication action) | Shell | all roles | existing sign-out route | REQ-A-13 |
| ACT-A-14 | Reconcile unknown outcomes (opens recovery) | Captured sends, when unknown > 0 | all roles | `/operations` | REQ-A-7, REQ-A-18 |
| ACT-A-15 | Open recovery for a failure with no subject page | Problems list | all roles | `/operations` | REQ-A-5, REQ-A-18 |
| ACT-A-16 | Try again, or open Runs & operations, from the withheld state | Withheld message | all roles | `/` reload, `/operations` | REQ-A-10, REQ-A-18 |

## Coverage check

- Every REQ-A-1 to REQ-A-18 appears in SCR-A-1 or SCR-A-2.
- Every action maps to a requirement and to an existing destination.
- No action calls a domain write (REQ-A-13). ACT-A-14 and ACT-A-15 only
  navigate; reconciliation itself stays on `/operations`.
- `check-prototype.mjs` proves every prototype link opens a known page,
  including subjects with apostrophes and markup-shaped text.
