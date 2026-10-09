# Story map: SDR Agent workshop release

- **Status:** draft for gate G1, revised 2026-10-08 after Codex review of
  `8e08d0a`.
- **Method step:** 2, user story mapping.
- **Built on:** the [outcome brief](brief.md) (OUT and NG IDs) and the current
  prototype.

The backbone reads left to right in the order a solo founder works. Under each
step are the tasks, marked by what the prototype already has:

- **built:** exists and reviewed in the prototype, possibly with a thin UI;
- **partial:** the domain support exists but the operator experience does not;
- **new:** neither exists yet.

## Backbone

| J-1 Set up | J-2 Bring in leads | J-3 Define the campaign | J-4 Research | J-5 Draft | J-6 Review and approve | J-7 Captured send | J-8 Replies | J-9 Results |
|---|---|---|---|---|---|---|---|---|
| Install and sign in | Upload a CSV | Write the ICP | Agent researches each account | Agent writes the first email | Open the review queue | Capture the approved email | See replies that need action | See what happened this week |

## Tasks under each step

### J-1 Set up

- **Install, create the admin, sign in:** built (`mix sdr.bootstrap_admin`); install guide new.
- **Check the model:** partial. The admin page shows whether it is fake or real Claude, but there is no guided check.
- **Sender identity, campaign time zone and quiet hours:** partial. The
  fields exist on the campaign in the domain; there is no setup screen.
- **Booking link:** new.
- **Paste writing samples for the voice:** new.

### J-2 Bring in leads

- **Synthetic seed (`mix sdr.demo.seed`):** built. The fallback that lets the
  rest of the journey be exercised while an intake path is built.
- **CSV upload, with a preview, validation and duplicate check:** new.
- **Add one lead by hand:** new as a workflow. `Sales.create_account`,
  `create_contact` and `create_lead` exist as guarded functions, but there is
  no screen and no intake pipeline.
- **Workshop core: one intake path, chosen by the owner at G2** (CSV upload or
  add-by-hand), plus the synthetic seed as fallback. Both intake paths are new
  work, and either one admits only reserved synthetic or owner test contacts
  (NG-14).
- **Suppressed or duplicate contacts are shown, not silently dropped:** partial (suppression exists).
- **HubSpot import (optional add-on, read-only):** design only (PR #29, paused).

### J-3 Define the campaign

- **ICP criteria:** partial. The `IcpDefinition` resource exists; no screen.
- **Brand guidelines and voice:** new.
- **Enroll leads:** partial. `enroll_lead` exists; no screen.

### J-4 Research

- **Run research on a lead:** built (assign, agent run), with fixture research only.
- **Live web research with safe fetching and citations:** new.
- **Watch progress, usage (model calls and tokens) and the model used:**
  built (run detail), thin.

### J-5 Draft

- **Evidence-backed draft with cited sentences and risk flags:** built.
- **Voice from brand guidelines and samples:** new.

### J-6 Review and approve

- **Review queue, oldest first:** built.
- **One draft, with its recipient, revision, citations and risk flags:** built.
- **Edit, which creates a new revision:** built.
- **Approve for capture, bound to the exact recipient and revision:** built.
- **Reject with a reason:** built.
- **Keyboard-driven queue:** new.

### J-7 Captured send

- **Quiet hours, daily quota and suppression checks before capture:** built.
- **Captured message visible, with its delivery outcome:** built, thin.
- **Unknown outcomes surfaced with a safe next step:** partial.

### J-8 Replies

- **Reply classified (interested, not now, unsubscribe and so on):** built.
- **Interested reply handed to the founder:** built.
- **Drafted response with the booking link, for approval:** new. Today the
  prototype classifies and hands off only. Acceptance uses a simulated, signed
  test reply (OUT-6).

### J-9 Results

- **Counts:** leads, drafts awaiting review, approvals, captures: built (dashboard).
- **Active founder time, approval rate, edit size, recorded usage per draft
  (calls and tokens, not dollars):** new. Approval rate and edit size are
  indicators only (OUT-4).

### Across all steps

- **Home and action queue:** what needs you now, what the agent is doing, problems, budget, real or fake model. Partial (dashboard and operations).
- **Recover from failures:** acknowledge and resolve with a note. Built (operations).
- **Audit trail and exports for the Auditor role:** built.

## Release lines

**Workshop release** (a candidate backlog for Nov 6, not a committed
minimum; the must-list is set at G2 and sized at G5):

- J-1 install and sign in, model check, booking link, writing samples;
- J-2 one intake path (CSV or add-by-hand, owner's choice) plus the synthetic
  seed fallback;
- J-3 ICP, brand guidelines and enrollment;
- J-4 live web research, done safely;
- J-5 voice-aware draft;
- J-6 the whole review step;
- J-7 captured send with recovery;
- J-8 interested-reply draft with the booking link;
- J-9 basic results;
- home and action queue.

**Later** (see NG IDs in the brief): bulk approve, AI edit suggestions, learning
from edits, phone channel, external alerts, ICP lead discovery, HubSpot
writeback, scheduling, metrics that need real sending.

**Most of this is new work.** One intake UI, live web research (safe
fetching, citations, prompt-injection evals), campaign and voice setup with
writing samples, booking settings, interested-reply drafting and the new
metrics are all unbuilt. Review, approval binding, captured delivery,
recovery and audit already exist. The release line is therefore a hypothesis
until G5 checks dependencies and capacity.

**First build slice** (Saturday Oct 10): one narrow slice from the release
above. The candidates are in [first-slice.md](first-slice.md). Slices are
chosen one at a time: after the first, priority goes to unlocking a usable
input → draft → review → capture journey, not to a fixed A → B → C order.

## Failure cases the design must handle

| ID | What goes wrong | Where | What the founder should see |
|---|---|---|---|
| F-1 | CSV has bad rows or missing columns | J-2 | Row-level errors before anything is created; fix and retry |
| F-2 | A contact is a duplicate or suppressed | J-2, J-7 | Shown and explained; never silently dropped or silently sent |
| F-3 | Research finds too little evidence | J-4, J-5 | "Not enough evidence" instead of a confident draft; options to add a source or skip |
| F-4 | Model budget runs out mid-batch | J-4, J-5 | Clear stop: what finished and what did not. Only the owner can raise the budget, within reviewed hard caps; nothing raises it automatically and no unapproved model calls are made |
| F-5 | The model call fails or is refused | J-4, J-5 | Shown as failed or refused, with the reason. A retry is offered only where repeating the operation is safe |
| F-6 | The draft changed while the founder was reviewing it | J-6 | Approval refused, with what changed and a prompt to review again |
| F-7 | The founder rejects the same lead's draft twice | J-6 | Proposed behaviour, not in the prototype: option to stop drafting for this lead, with the reasons kept |
| F-8 | Quiet hours or the daily quota defer a capture | J-7 | Shown as deferred, with the time it will go |
| F-9 | Capture outcome unknown after a crash | J-7 | Unknown state with a safe resolve path; never a duplicate |
| F-10 | A reply cannot be classified with confidence | J-8 | Handed to the founder as "needs a look", not guessed |
| F-11 | A web page tries to instruct the model | J-4 | Treated as untrusted text and flagged; the agent gains no new ability |
| F-12 | A research URL is unsafe or unreachable | J-4 | Skipped with a reason; research continues on other sources |
| F-13 | A model call's outcome is unknown (no confirmed result) | J-4, J-5 | Shown as unknown, never as failed or succeeded. Resolved by reconciliation; retried only where the operation's contract says a repeat is safe, never blindly |
