# Slice A requirements: operator shell and home (read-only triage starter)

- **Status:** proposed for slice A, **pending the owner's slice choice**
  (first-slice question in the P1 review). Nothing here is approved. Drafted
  2026-10-08 for gate G2 of the slice-scoped path (D-020 in
  `docs/sdlc/decisions.md`).
- **Built on:** [brief](../brief.md) (OUT, NG, AS), [story map](../story-map.md)
  (J, F), [first slice](../first-slice.md), and the code at `origin/main`
  `98fb96e`. Grounding for every data source: [baseline-delta.md](baseline-delta.md).
- **Screens and actions:** [screen-matrix.md](screen-matrix.md).
  **Clickable prototype:** [prototype.html](prototype.html).

## What slice A is, and is not

Slice A redesigns the existing dashboard (`/`, `SdrAgentWeb.DashboardLive`)
into a home screen that answers "what needs me now?", inside an improved
navigation shell. It reads through public functions that already exist, as
the signed-in operator. **Its only actions are navigation.**

It does **not** deliver OUT-1 (a list of companies turned into approved
drafts): that needs an intake path and the rest of the journey. Its success
on its own is narrow: the founder opens the app, sees what needs attention,
and reaches the existing safe screen for it in one click.

Roles in the app today: `admin`, `reviewer`, `auditor` (`SdrAgent.Accounts.User`).
The solo founder signs in as `admin`.

## Requirements

Each requirement lists what it traces to. "Existing" means the data comes
from a function that already exists; "display change" means only the page
changes.

### REQ-A-1 Navigation shell
The shell shows the existing navigation items, filtered by role exactly as
today (`Layouts.nav_items/1`): Home, Leads, Review queue, Runs & operations,
Audit (admin, auditor), Admin (admin). It adds a skip-to-content link,
a visible focus ring, and marks the current page. No new routes.
*Traces:* OUT-5, J-9. *Source:* existing.

- **Given** a signed-in reviewer, **when** the shell renders, **then** it
  shows Home, Leads, Review queue and Runs & operations, and does not show
  Audit or Admin.
- **Given** keyboard-only use, **when** the founder presses Tab on any page,
  **then** the first stop is "Skip to content" and every nav item is
  reachable with a visible focus ring.

### REQ-A-2 "Needs you now" summary
The top of home shows three counts, each linking to where the founder acts:
drafts awaiting review, replies to handle, and open problems.
*Traces:* OUT-3, OUT-5, J-6, J-8. *Source:* existing
(`Outreach.list_review_queue/1`, `Outreach.list_handoff_queue/1`,
`Operations.list_attention/1`).

- **Given** 3 drafts pending review, 2 replied leads and 1 open failure,
  **when** home loads, **then** it shows 3, 2 and 1, and each count links to
  `/review`, the replies list below, and the problems list below.
- **Given** all three are zero, **then** the summary says "Nothing needs you
  right now" instead of three zeros.

### REQ-A-3 Drafts awaiting review
Up to 5 drafts, oldest first: subject of the current revision, recipient
name, age. Each opens `/drafts/:id`, where review, edit and approve already
live. A "See all" link opens `/review`.
*Traces:* OUT-3, J-6. *Source:* existing (as today on the dashboard).

- **Given** 7 drafts pending, **when** home loads, **then** it lists the 5
  oldest and "See all 7" links to `/review`.
- **Given** the founder clicks a draft, **then** `/drafts/:id` opens and no
  approval happens on home.

### REQ-A-4 Replies to handle
Up to 5 replied leads from the hand-off queue, interested first: company or
lead, the reply's assessment classification as recorded (interested,
objection, referral, not now, unsubscribe, out of office, irrelevant,
unknown) or "not assessed yet", and when it arrived. Each opens `/leads/:id`.
*Traces:* OUT-6 (entry point only), J-8, F-10. *Source:* existing read, new on
home (display change).

- **Given** a reply assessed "interested" and an older one not yet assessed,
  **then** the interested one is listed first.
- **Given** a reply whose assessment is missing, **then** it shows "not
  assessed yet", never a guessed label; a recorded `unknown` classification
  shows "unclear: needs a look" (F-10).

### REQ-A-5 Problems
Open and acknowledged failures, newest first: severity, class, message, when,
and a link to the subject. Acknowledge and resolve stay on
`/operations`.
*Traces:* OUT-5, F-4, F-5, F-9. *Source:* existing (as today).

- **Given** an open critical failure, **then** it is listed with a critical
  marker that is not colour-only (text "Critical").
- **Given** the founder wants to resolve it, **then** the only control on home
  is a link to `/operations` or the subject.

### REQ-A-6 Agent activity
How many runs are queued or running, the 5 latest runs with status, and how
many runs ended `failed` or `budget_exhausted` in the last 24 hours, each
with its reason. Each run opens `/runs/:id`.
*Traces:* OUT-5, F-4, F-5. *Source:* existing (`Agents.list_runs/1`), new on
home.

- **Given** a run that ended `budget_exhausted` with reason `daily_budget`,
  **then** home shows it as "Stopped: daily model budget reached" and links
  to the run. There is no retry or budget control on home.

### REQ-A-7 Captured sends, honestly labelled
Counts by delivery state: accepted or delivered; in flight (pending,
attempting, failed but retryable); **deferred** (pending with a future
`not_before`), shown with "until <time>"; **unknown**; failed permanently.
The card says "Local capture only: nothing is sent to a real inbox."
*Traces:* OUT-3, OUT-5, J-7, F-8, F-9. *Source:* existing
(`Outreach.list_records(DeliveryOperation)`), display change.

- **Given** a delivery in state `unknown`, **then** it is counted under
  "Outcome unknown", never under sent or failed, with a link to
  `/operations`.
- **Given** a delivery deferred by quiet hours until 08:00, **then** it shows
  "Deferred until 08:00". The reason (quiet hours or daily cap) is not shown
  in slice A (see baseline-delta D-A-5).

### REQ-A-8 Model and budget (admin only)
For `admin`: the effective model provider (fake or real Claude CLI), any
refusal reason, model calls used today against the daily limit (UTC day),
and the daily send cap. Reviewers and auditors do not see this card, as
today (the data lives on the admin-only `/admin` page).
*Traces:* OUT-5, OUT-7, F-4. *Source:* existing (`Runtime.status/0`,
`Agents.daily_model_calls/1`, `Agents.daily_model_call_limit/0`,
`Compliance.daily_send_cap/0`), shown on home for admin only.

- **Given** the fake provider is configured, **then** the card says "Fake
  model (no AI calls leave this machine)".
- **Given** the real provider is configured and refusing calls, **then** the
  card shows the operator-safe refusal message and links to `/admin`.
- **Given** a reviewer, **then** the card is absent.

### REQ-A-9 Pipeline by stage
Lead counts by stage group, as on today's dashboard.
*Traces:* J-9. *Source:* existing.

### REQ-A-10 States
Home has designed states:

- **Loading:** a skeleton on the first (disconnected) render; nothing is read
  until the live connection is up (as today).
- **Error:** if any read is refused or fails, the whole home is withheld with
  an operator-safe message, and nothing previously shown stays on screen
  (fail closed, as today).
- **Empty:** each section has its own empty message.
- **Stale:** when the live connection drops, a banner says "Connection lost:
  numbers may be out of date" until it reconnects; the page shows the time it
  was last updated.
- **Unknown:** unknown delivery outcomes are a named count (REQ-A-7), never
  folded into success or failure.

*Traces:* OUT-5, F-9, F-13.

- **Given** the domain refuses one read for the signed-in operator, **then**
  no section is shown and the withheld message appears.
- **Given** the socket disconnects, **then** the stale banner appears within
  2 seconds and disappears on reconnect after a fresh reload.

### REQ-A-11 Live refresh
Home reloads through `SdrAgentWeb.LiveRefresh` (ADR-0012): a committed audit
event triggers one debounced re-read of everything, as the freshly
revalidated user. Access and auth events are ignored. A demoted or disabled
operator is redirected or signed out on the next reload.
*Traces:* OUT-5. *Source:* existing.

### REQ-A-12 Auditor views are recorded
For an `auditor`, every home load and refresh records one audited view naming
every record shown (drafts, replies, failures, runs and deliveries listed),
before anything is served. If the record cannot be written, nothing is
shown.
*Traces:* OUT-3, NG audit constraints. *Source:* existing
(`SdrAgentWeb.AuditedView.record/4`), with a longer list of records.

- **Given** an auditor opens home, **then** exactly one `record_view` access
  is appended, naming the ids shown.

### REQ-A-13 Read-only
Home and the shell offer **navigation only**. Excluded from slice A, and
from home in general unless a later slice adds them through its own gates:

- approve, reject or edit a draft;
- acknowledge or resolve a failure;
- retry a run or a webhook; cancel an operation;
- resolve an unknown delivery;
- raise any budget, switch the model provider, change settings;
- assign a lead, import or create anything.

*Traces:* OUT-3, constraints (approval binding, owner-only budget).

- **Given** any role, **when** home renders, **then** it contains no form,
  `phx-click` or button that calls a domain write.

### REQ-A-14 Accessibility
Text and controls meet WCAG 2.2 AA contrast in light and dark themes; status
is never colour-only; headings form a proper outline; counts are announced
with their labels; all links work by keyboard; motion respects reduced-motion.
*Traces:* OUT-5.

### REQ-A-15 Bounded load at workshop scale
At workshop scale (synthetic data: up to 500 leads, 2,000 delivery
operations, 1,000 runs, 500 contacts), the connected home load completes in
under 1 second locally, with a fixed number of reads (no per-item queries)
and lists capped at 5 items. Beyond that scale, aggregate count reads are
needed (baseline-delta D-A-2), which is out of slice A.
*Traces:* OUT-5, OUT-7.

### REQ-A-16 Honest labels
Seeded data keeps its "fictional demo accounts" hint; captured sends say
"local capture only"; the fake model is named as fake.
*Traces:* OUT-7, NG-14.

## Not in slice A

- Any write action (REQ-A-13).
- A tenant-wide count of model calls with unknown outcome (D-A-3). Unknown
  model calls stay visible per run on `/runs/:id`.
- Provider and budget for reviewers and auditors (D-A-4).
- Why a delivery was deferred (D-A-5).
- Aggregate count reads (D-A-2).
- Visual direction beyond provisional tokens, unless the design days settle it
  (owner's choice, PQ-5).
- Intake, research, drafting, reply drafting, metrics (later slices).

## Questions for the owner

- **OQ-1** Is slice A your choice for Saturday? (Everything here is pending
  that choice.)
- **OQ-2** Model and budget on home for admins only (the solo founder is an
  admin), or also for reviewers and auditors? The latter is a new exposure
  and needs its own review (D-A-4).
- **OQ-3** Do you need a home-level count of model calls with unknown
  outcome, or is per-run visibility enough for now? A home count is new
  domain work (D-A-3).
- **OQ-4** What is the single most important thing home must show when you
  open the app (PQ-4)? It decides the order of the sections.
- **OQ-5** Rename "Dashboard" to "Home" in the navigation?
- **OQ-6** Ship with provisional styling if the visual direction is not
  settled by Friday night (PQ-5)?
