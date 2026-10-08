# Story map: SDR Agent workshop release

- **Status:** draft for gate G1, written 2026-10-08.
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
- **Booking link, sender name, working hours:** new.
- **Paste writing samples for the voice:** new.

### J-2 Bring in leads

- **CSV upload, with a preview, validation and duplicate check:** new.
- **Add one lead by hand:** partial. `Sales.create_account`, `create_contact` and `create_lead` exist, but there is no screen.
- **Suppressed or duplicate contacts are shown, not silently dropped:** partial (suppression exists).
- **HubSpot import (optional add-on, read-only):** design only (PR #29, paused).

### J-3 Define the campaign

- **ICP criteria:** partial. The `IcpDefinition` resource exists; no screen.
- **Brand guidelines and voice:** new.
- **Enroll leads:** partial. `enroll_lead` exists; no screen.

### J-4 Research

- **Run research on a lead:** built (assign, agent run), with fixture research only.
- **Live web research with safe fetching and citations:** new.
- **Watch progress, cost and the model used:** built (run detail), thin.

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
- **Drafted response with the booking link, for approval:** new.

### J-9 Results

- **Counts:** leads, drafts awaiting review, approvals, captures: built (dashboard).
- **Time saved, approval rate, edit size, cost per draft:** new.

### Across all steps

- **Home and action queue:** what needs you now, what the agent is doing, problems, budget, real or fake model. Partial (dashboard and operations).
- **Recover from failures:** acknowledge and resolve with a note. Built (operations).
- **Audit trail and exports for the Auditor role:** built.

## Release lines

**Workshop release** (the musts for Nov 6, pending G2):

- J-1 install and sign in, model check, booking link, writing samples;
- J-2 CSV upload and add one by hand;
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

**First build slice** (Saturday Oct 10): one narrow slice from the release
above. The candidates and the recommendation are in
[first-slice.md](first-slice.md).

## Failure cases the design must handle

| ID | What goes wrong | Where | What the founder should see |
|---|---|---|---|
| F-1 | CSV has bad rows or missing columns | J-2 | Row-level errors before anything is created; fix and retry |
| F-2 | A contact is a duplicate or suppressed | J-2, J-7 | Shown and explained; never silently dropped or silently sent |
| F-3 | Research finds too little evidence | J-4, J-5 | "Not enough evidence" instead of a confident draft; options to add a source or skip |
| F-4 | Model budget runs out mid-batch | J-4, J-5 | Clear stop, what finished, what did not, and how to raise the budget |
| F-5 | The model call fails or its outcome is unknown | J-4, J-5 | Marked unknown, never retried blindly; a safe retry action |
| F-6 | The draft changed while the founder was reviewing it | J-6 | Approval refused, with what changed and a prompt to review again |
| F-7 | The founder rejects the same lead's draft twice | J-6 | Option to stop drafting for this lead, with the reasons kept |
| F-8 | Quiet hours or the daily quota defer a capture | J-7 | Shown as deferred, with the time it will go |
| F-9 | Capture outcome unknown after a crash | J-7 | Unknown state with a safe resolve path; never a duplicate |
| F-10 | A reply cannot be classified with confidence | J-8 | Handed to the founder as "needs a look", not guessed |
| F-11 | A web page tries to instruct the model | J-4 | Treated as untrusted text and flagged; the agent gains no new ability |
| F-12 | A research URL is unsafe or unreachable | J-4 | Skipped with a reason; research continues on other sources |
