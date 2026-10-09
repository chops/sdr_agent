# Slice A screen, action and state matrix

- **Status:** proposed for slice A, pending the owner's slice choice. Method
  step 4 (P2 draft); finalised in P3 after the prototype walkthrough.
- **Requirements:** [requirements.md](requirements.md). **Data sources:**
  [baseline-delta.md](baseline-delta.md). **Prototype:** [prototype.html](prototype.html).

## Screens

### SCR-A-1 Navigation shell

| Field | Content |
|---|---|
| Job | Get to the right place in one step, and always know where you are. |
| Information and provenance | Signed-in name and role (`current_scope.user`); navigation items filtered by role (`SdrAgentWeb.Layouts.nav_items/1`). |
| Actions | ACT-A-1 to ACT-A-6 (navigation), ACT-A-12 (skip to content), ACT-A-13 (sign out, existing). |
| Actor and preconditions | Any active signed-in operator (`LiveUserAuth :operator`). Audit and Admin items only for the roles allowed today. |
| States | Normal. Stale: connection banner (shared with home). Signed out or disabled: redirected to sign-in (existing). |
| Audit | No new audit records. |
| Requirements | REQ-A-1, REQ-A-14 |
| Example | A reviewer tabs once to "Skip to content", then through Home, Leads, Review queue, Runs & operations; no Audit or Admin item exists for them. |

### SCR-A-2 Home

| Field | Content |
|---|---|
| Job | Answer "what needs me now, and what is the agent doing?", then hand off to the existing screen where the founder acts. |
| Information and provenance | Needs-you-now counts (review queue, hand-off queue, attention failures); drafts awaiting review (`Outreach.list_review_queue/1` + current revisions and contacts via `ConsoleData`); replies to handle (`Outreach.list_handoff_queue/1`); problems (`Operations.list_attention/1`); agent activity (`Agents.list_runs/1`); captured sends by state (`Outreach.list_records(DeliveryOperation)`); model and budget, admin only (`Runtime.status/0`, `Agents.daily_model_calls/1`, `Agents.daily_model_call_limit/0`, `Compliance.daily_send_cap/0`); pipeline (`Sales.list_records(Lead)`). All reads run as the signed-in operator except the admin-only model and budget reads, which are system-level today (see D-A-4). |
| Actions | ACT-A-7 to ACT-A-11 (navigation to existing safe screens). **No writes** (REQ-A-13). |
| Actor and preconditions | admin: everything. reviewer: everything except the model and budget card. auditor: everything except the model and budget card, and only after the audited view is recorded. |
| States | **Loading:** skeleton until connected. **Error:** whole page withheld, operator-safe message, nothing stale left on screen. **Empty:** per section ("Nothing waiting", "No replies to handle", "No open problems", "No runs yet", "No captured sends yet"). **Stale:** banner while disconnected, last-updated time. **Blocked:** a role-restricted card is absent, not greyed. **Unknown:** "Outcome unknown" delivery count, never merged into sent or failed. |
| Async and recovery | Live refresh per ADR-0012: debounced reload on committed audit events, revalidating the operator each time. Recovery actions are on `/operations` and the subject screens, not here. |
| Audit | For auditors: one `record_view` access per load and per refresh, naming every record id shown; failure to record means nothing is served (`AuditedView.record/4`). No payload content is read on home. |
| Requirements | REQ-A-2 to REQ-A-16 |
| Example | The founder (admin) opens the app at 08:05: "2 drafts to review · 1 reply to handle · 1 problem". The model card says "Fake model". Captured sends show "3 deferred until 08:00" now released, and "1 outcome unknown". They click the reply and land on the lead page. |

## Actions

All slice A actions are navigation. Every destination already exists and
enforces its own policies.

| ID | Action | Where | Who | Destination | Requirement |
|---|---|---|---|---|---|
| ACT-A-1 | Open Home | Shell | all roles | `/` | REQ-A-1 |
| ACT-A-2 | Open Leads | Shell | all roles | `/leads` | REQ-A-1 |
| ACT-A-3 | Open Review queue | Shell, summary | all roles | `/review` | REQ-A-1, REQ-A-2, REQ-A-3 |
| ACT-A-4 | Open Runs & operations | Shell, problems, sends | all roles | `/operations` | REQ-A-1, REQ-A-5, REQ-A-7 |
| ACT-A-5 | Open Audit | Shell | admin, auditor | `/audit` | REQ-A-1 |
| ACT-A-6 | Open Admin | Shell, model card | admin | `/admin` | REQ-A-1, REQ-A-8 |
| ACT-A-7 | Open a draft | Drafts list | all roles | `/drafts/:id` | REQ-A-3 |
| ACT-A-8 | Open a replied lead | Replies list | all roles | `/leads/:id` | REQ-A-4 |
| ACT-A-9 | Open a failure's subject | Problems list | all roles | subject path (`ConsoleData.subject_path/2`) | REQ-A-5 |
| ACT-A-10 | Open a run | Agent activity | all roles | `/runs/:id` | REQ-A-6 |
| ACT-A-11 | Jump to a home section from a summary count | Summary | all roles | in-page anchor | REQ-A-2 |
| ACT-A-12 | Skip to content | Shell | all roles | in-page anchor | REQ-A-1, REQ-A-14 |
| ACT-A-13 | Sign out | Shell | all roles | existing sign-out route | REQ-A-1 |

## Coverage check

- Every REQ-A-1 to REQ-A-16 appears in SCR-A-1 or SCR-A-2.
- Every action maps to a requirement and to an existing destination.
- No action calls a domain write (REQ-A-13).
