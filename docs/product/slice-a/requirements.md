# Slice A requirements: operator shell and home (read-only triage starter)

- **Status:** proposed for slice A, **pending the owner's slice choice**
  (first-slice question in the P1 review). Nothing here is approved. Drafted
  2026-10-08 for gate G2 of the slice-scoped path (D-020 in
  `docs/sdlc/decisions.md`). **Revision 2:** revised for Codex's review of
  `40f76d4` (delivery buckets and clock rules, bounded reads, recovery links,
  admin card wording, audit references, ranking and testable accessibility).
- **Built on:** [brief](../brief.md) (OUT, NG, AS), [story map](../story-map.md)
  (J, F), [first slice](../first-slice.md), and the code at `origin/main`
  `98fb96e`. Grounding for every data source: [baseline-delta.md](baseline-delta.md).
- **Screens and actions:** [screen-matrix.md](screen-matrix.md).
  **Clickable prototype:** [prototype.html](prototype.html), logic in
  [prototype-logic.js](prototype-logic.js), checked by
  [check-prototype.mjs](check-prototype.mjs).

## What slice A is, and is not

Slice A redesigns the existing dashboard (`/`, `SdrAgentWeb.DashboardLive`)
into a home screen that answers "what needs me now?", inside an improved
navigation shell. It reads through public functions that already exist, as
the signed-in operator. **Its only actions are navigation** (plus the
existing sign-out, REQ-A-13).

It does **not** deliver OUT-1 (a list of companies turned into approved
drafts): that needs an intake path and the rest of the journey. Its success
on its own is narrow: the founder opens the app, sees what needs attention,
and reaches the existing safe screen for it in one click.

Roles in the app today: `admin`, `reviewer`, `auditor` (`SdrAgent.Accounts.User`).
The solo founder signs in as `admin`.

## Ranking

Proposed for the owner to confirm (OQ-7). A must blocks slice A's release; a
should is built if the musts are done and is cut first if time runs short.

| Rank | Requirements |
|---|---|
| Must | REQ-A-1, 2, 3, 4, 5, 7, 10, 11, 12, 13, 14, 15, 16, 17, 18 |
| Should | REQ-A-6 (agent activity), REQ-A-8 (model and budget card), REQ-A-9 (pipeline) |
| Later | Everything under "Not in slice A" |

## Requirements

Each requirement lists what it traces to. "Existing" means the data comes
from a function that already exists; "display change" means only the page
changes. Times in examples are Mountain Daylight Time (MDT); the product
shows every time with its zone.

### REQ-A-1 Navigation shell (must)
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

### REQ-A-2 "Needs you now" summary (must)
The top of home shows three counts, each linking to where the founder acts:
drafts awaiting review, replies to handle, and open problems.
*Traces:* OUT-3, OUT-5, J-6, J-8. *Source:* existing
(`Outreach.list_review_queue/1`, `Outreach.list_handoff_queue/1`,
`Operations.list_attention/1`).

- **Given** 3 drafts pending review, 2 replied leads and 1 open failure,
  **when** home loads, **then** it shows 3, 2 and 1, and each count links to
  `/review`, the replies list below, and the problems list below.
- **Given** all three are zero and no delivery outcome is unknown, **then**
  the summary says "Nothing needs you right now" instead of three zeros.
- **Given** all three are zero but a delivery outcome is unknown, **then**
  "Nothing needs you right now" is **not** shown.

### REQ-A-3 Drafts awaiting review (must)
Up to 5 drafts, oldest first: subject of the current revision, recipient
name, age. Each opens `/drafts/:id`, where review, edit and approve already
live. A "See all N" link opens `/review`.
*Traces:* OUT-3, J-6. *Source:* existing (as today on the dashboard).

- **Given** 7 drafts pending, **when** home loads, **then** it lists the 5
  oldest and "See all 7" links to `/review`.
- **Given** a draft subject containing apostrophes, quotes, `&` or `<…>`,
  **when** the founder clicks it, **then** that draft's page opens and the
  subject is shown as typed (checked by `check-prototype.mjs`).
- **Given** the founder clicks a draft, **then** `/drafts/:id` opens and no
  approval happens on home.

### REQ-A-4 Replies to handle (must)
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
- **Given** a lead with no company name, **then** it shows "Lead <short id>
  (no company name)"; **given** a hand-off entry with no matched reply or no
  `received_at`, **then** it shows "reply time unknown", never a made-up time.

### REQ-A-5 Problems (must)
Open and acknowledged failures, newest first, **at most 5 shown** (the count
covers all): severity as text, class, message, when, and a link to the
subject. "Acknowledge and resolve on Runs & operations" links to
`/operations`.
*Traces:* OUT-5, F-4, F-5, F-9. *Source:* existing.

- **Given** an open critical failure, **then** it is listed with a critical
  marker that is not colour-only (text "critical").
- **Given** the founder wants to resolve it, **then** the only controls on
  home are links to `/operations` or the subject page.
- **Given** a failure whose subject has no console page (subject path is
  nil), **then** its row links to `/operations` and says so (REQ-A-18).

### REQ-A-6 Agent activity (should)
How many runs are queued or running, the 5 latest runs with status, and how
many runs ended `failed` or `budget_exhausted` with `finished_at` in the 24
hours before the **check time** (REQ-A-17). Runs without `finished_at` are
not counted as stopped. Each run opens `/runs/:id`.
*Traces:* OUT-5, F-4, F-5. *Source:* existing (`Agents.list_runs/1`), new on
home.

- **Given** a run that ended `budget_exhausted` with reason `daily_budget`,
  **then** home shows it as "Stopped: daily model budget reached" and links
  to the run. There is no retry or budget control on home.
- **Given** a run that failed at 08:01 yesterday, **when** the check time
  moves from 07:58 to 08:05 with no new event, **then** the "stopped in the
  24 hours before" count drops by one.

### REQ-A-7 Captured sends, honestly labelled (must)
Every delivery operation falls in exactly **one** bucket, decided by its
`state` and `not_before` at the check time `now` (REQ-A-17):

| Bucket | Rule |
|---|---|
| Captured | `state` is `accepted` or `delivered` |
| Deferred | `state` is `pending` or `failed_retryable`, and `not_before` is set and later than `now` |
| Queued | `state` is `pending`, and `not_before` is nil or not later than `now` |
| Retry due | `state` is `failed_retryable`, and `not_before` is nil or not later than `now` |
| Capturing now | `state` is `attempting` |
| Outcome unknown | `state` is `unknown` |
| Failed permanently | `state` is `failed_permanent` |
| Bounced | `state` is `bounced` |
| Cancelled | `state` is `cancelled` (gate refusal, revoked approval or suppression) |

The card shows every bucket and the total. Deferred shows the **earliest**
`not_before` ("next due 08:00") and, when deadlines differ, the latest
("last 09:30"). A deferral whose time has passed moves to Queued or Retry
due: it is **due, not sent**, and still has to pass the send gate, which can
defer or cancel it. The card says "Local capture only: nothing is sent to a
real inbox." Unknown is always its own bucket and links to recovery
(REQ-A-18).
*Traces:* OUT-3, OUT-5, J-7, F-8, F-9, F-13. *Source:* existing
(`Outreach.list_records(DeliveryOperation)`, states and `:defer` in
`outreach/delivery_operation.ex`), display change.

- **Given** a delivery in state `unknown`, **then** it is counted under
  "Outcome unknown", never under captured or failed, with a link to
  `/operations`.
- **Given** a `failed_retryable` delivery deferred until 08:00 and a check
  time of 07:58, **then** it is under Deferred; **at** 08:05 it is under Retry
  due, never Captured.
- **Given** pending deferrals until 08:00 and 09:30 at 07:58, **then**
  Deferred shows "next due 08:00, last 09:30"; at 08:05 the 08:00 ones are
  Queued and Deferred shows "next due 09:30".
- **Given** a `pending` delivery with no `not_before`, **then** it is Queued.
- **Given** a cancelled and a bounced delivery, **then** each is counted in
  its own bucket and the total equals the number of delivery operations.
- The reason for a deferral (quiet hours or daily cap) is not shown in slice
  A (baseline-delta D-A-5).

### REQ-A-8 Model and budget, admin only (should)
For `admin` only: the **configured** model provider and the provider **in
effect** (fake, Claude CLI, or none while calls are refused, with the
operator-safe refusal reason), **model calls reserved today** (UTC day)
against the daily limit, and the daily send cap. Reviewers and auditors do
not get this card, and **the home does not call these reads for them**: the
role check runs before `Runtime.status/0` and `Agents.daily_model_calls/1`
(baseline-delta D-A-1). The card is status only. It links to `/admin`, which
is also read-only; the provider and the budget are set in the app's reviewed
launch configuration, which only the owner changes, outside the app.
*Traces:* OUT-5, OUT-7, F-4. *Source:* existing (`Runtime.status/0`,
`Agents.daily_model_calls/1`, `Agents.daily_model_call_limit/0`,
`Compliance.daily_send_cap/0`), shown on home for admin only.

- **Given** the fake provider is configured, **then** the card says
  "Configured: fake model. In effect: fake model. No AI calls leave this machine."
- **Given** the real provider is configured and refusing calls, **then** the
  card shows "In effect: none" and the operator-safe refusal message.
- **Given** a reviewer or auditor, **then** the card is absent **and** neither
  actorless read is invoked (backend test, not CSS).
- **Given** an admin demoted to reviewer, **when** the next reload fires,
  **then** the card disappears and the actorless reads are not invoked.
- **Given** `Runtime.status/0` or the count raises or returns an error,
  **then** the card shows "Model status unavailable" with no raw internals and
  no value from a previous load.

### REQ-A-9 Pipeline by stage (should)
Lead counts by stage group, as on today's dashboard.
*Traces:* J-9. *Source:* existing.

### REQ-A-10 States (must)
Home has designed states:

- **Loading:** a skeleton on the first (disconnected) render; nothing is read
  until the live connection is up (as today).
- **Error:** if any read is refused or fails, the whole home is withheld with
  an operator-safe message, and nothing previously shown stays on screen
  (fail closed, as today). The message offers "Try again" (reload) and a link
  to Runs & operations, which applies its own access rules.
- **Refused on refresh:** if a reload is refused after data was shown, the
  same withheld state replaces everything.
- **Empty:** each section has its own empty message; the capture-only label
  stays visible.
- **Stale:** when the live connection drops, a banner says "Connection lost:
  numbers may be out of date" until it reconnects.
- **Unknown:** unknown delivery outcomes are a named count (REQ-A-7), never
  folded into success or failure.

*Traces:* OUT-5, F-9, F-13.

- **Given** the domain refuses one read for the signed-in operator, **then**
  no section is shown and the withheld message appears.
- **Given** home has loaded and the next reload is refused, **then** no value
  from the earlier load remains on screen.
- **Given** the socket disconnects, **then** the stale banner appears within
  2 seconds and disappears on reconnect after a fresh reload.

### REQ-A-11 Live refresh (must)
Home reloads through `SdrAgentWeb.LiveRefresh` (ADR-0012): a committed audit
event triggers one debounced re-read of everything, as the freshly
revalidated user. Access and auth events are ignored. A demoted or disabled
operator is redirected or signed out on the next reload. Clock-only changes
are handled by REQ-A-17, not by refresh.
*Traces:* OUT-5. *Source:* existing.

### REQ-A-12 Auditor views are recorded (must)
For an `auditor`, every home load and every event-driven reload records
**exactly one** `record_view` access through the existing
`AuditedView.record/4`, **before** anything is rendered; if it cannot be
written, nothing is shown. The reference convention, extending today's:

- `target_resource`: `"Dashboard"` (unchanged).
- `target_ref`, in this order: every draft id in the review queue and every
  failure id in the attention list (as today, even beyond the 5 shown); then,
  for the rows shown, the current revision id behind each draft's subject and
  the recipient contact id behind its recipient, the lead, reply and assessment ids of
  each reply shown, and the run ids shown. An empty list records `"none"`.
- `purpose`: names the aggregate counts shown without listing their rows:
  "home: review queue, attention, hand-off queue, runs, delivery counts by
  state, lead counts by stage". Deliveries, leads and runs that are only
  counted are covered by this purpose text, not by ids.

Supporting reads that are never displayed (the full contact index, all runs
used for counting) are not named. The minute tick (REQ-A-17) renders no new
records and records nothing.
*Traces:* OUT-3, audit constraints. *Source:* existing
(`SdrAgentWeb.AuditedView.record/4`).

- **Given** an auditor opens home, **then** exactly one `record_view` access
  is appended, with the ids above.
- **Given** an empty home, **then** exactly one access with `"none"`.
- **Given** an event-driven reload, **then** exactly one more access, and no
  reload is triggered by that access (access events are ignored).
- **Given** the minute tick, **then** no access is appended.

### REQ-A-13 Read-only (must)
Home and the shell offer **navigation only**, plus the existing sign-out
link, which is an authentication action that already exists, not a domain
write and not new. Excluded from slice A, and from home in general unless a
later slice adds them through its own gates:

- approve, reject or edit a draft;
- acknowledge or resolve a failure;
- retry a run or a webhook; cancel an operation;
- reconcile an unknown delivery;
- raise any budget, switch the model provider, change settings;
- assign a lead, import or create anything.

*Traces:* OUT-3, constraints (approval binding, owner-only budget).

- **Given** any role, **when** home renders, **then** it contains no form,
  `phx-click` or button that calls a domain write.

### REQ-A-14 Accessibility (must)
Checks, each pass or fail, in light and dark themes:

1. Text contrast at least 4.5:1 (3:1 for text 24px and up, or 18.66px bold),
   measured on every text colour pair the home and shell use.
2. Every status (severity, run status, delivery bucket, provider) has a text
   label, never colour alone.
3. Headings go h1, h2, h3 with no skipped level.
4. Each summary count's accessible name includes its label ("3 drafts to
   review").
5. Every link and control is reachable and usable by keyboard, with a
   visible focus indicator.
6. With reduced motion requested, there is no smooth scrolling or animation.

*Traces:* OUT-5.

### REQ-A-15 Bounded load at workshop scale (must)
The connected load uses a fixed set of reads plus a capped number of
per-item reads (baseline-delta, "Read budget"):

- 9 list reads (leads, review queue, deliveries, attention, hand-off queue
  (3 internal reads), runs, and contacts filtered to the shown drafts'
  `recipient_contact_id`s), plus the admin card's status and count reads;
- at most 5 per-item revision fetches (the 5 drafts shown);
- at most 5 subject-path fetches, only for shown problems whose subject is
  not already among the loaded deliveries or runs;
- one audit write for an auditor.

Lists are capped at 5 rows **before** subject paths or revisions are
resolved. **Target**, to be measured at G4 with worst-case synthetic
fixtures (500 leads, 2,000 delivery operations, 1,000 runs, 200 attention
failures, 100 hand-off leads with replies, 50 drafts pending): connected
load under 1 second locally. The target is not yet measured. Bounded count
reads would be new contracts (D-A-2) and are out of slice A.
*Traces:* OUT-5, OUT-7.

### REQ-A-16 Honest labels (must)
Seeded data keeps its "fictional demo accounts" hint; captured sends say
"local capture only"; the fake model is named as fake; in every state.
*Traces:* OUT-7, NG-14.

### REQ-A-17 Times and freshness (must)
The home separates **when the data was read** from **when its times were
checked**:

- It shows "Data as of <time> <zone>" (last load or reload) and "times
  checked at <time>".
- Once a minute while connected, it re-checks clock-derived values against
  the current time **from the rows already loaded, without new reads**:
  delivery buckets (REQ-A-7) and the 24-hour stopped-run window (REQ-A-6).
- The model-call count is per **UTC day** (it resets at 18:00 MDT). When the
  UTC date changes while the page is open, the home runs one normal reload
  (the same path as an event-driven reload, with revalidation). At most one
  such reload per UTC day.
- Event-driven reloads (REQ-A-11) are unchanged; the minute tick never
  replaces them.

*Traces:* OUT-5, F-9, F-13. *Source:* display change (view-level timer).

- **Given** a deferral until 08:00, data read at 07:58 and no event, **when**
  the check time passes 08:00, **then** it moves to Queued or Retry due
  within a minute, and "data as of" still says 07:58.
- **Given** the page is open across 18:00 MDT, **then** exactly one reload
  runs and the reserved-call count shows the new UTC day.
- **Given** the minute tick, **then** no read or audit write happens.

### REQ-A-18 Recovery navigation (must)
Home offers read-only paths to recovery, never recovery itself:

- The "Outcome unknown" count, when above zero, has a link "Reconcile N
  unknown outcome(s) on Runs & operations" to `/operations`.
- A failure whose subject has no console page links to `/operations`.
- The withheld state links to Runs & operations (REQ-A-10).

*Traces:* OUT-5, F-9, F-13.

- **Given** one unknown delivery, **then** home shows a link to
  `/operations` next to the count, and following it opens Runs & operations.
- **Given** a failure with no subject page, **then** its row opens
  `/operations`.

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
- **OQ-7** Do you agree with the must and should ranking above?
