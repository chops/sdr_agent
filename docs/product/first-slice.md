# First build slice: candidates for Saturday, Oct 10

- **Status:** proposal for the owner, written 2026-10-08. Nothing here is
  approved. Building starts only after gates G1 to G5 pass for the chosen slice
  (owner decision, Oct 8: build starts Saturday with a narrow first slice).
- **Built on:** [brief](brief.md) and [story map](story-map.md).

## What makes a good first slice

- It sits on the core journey (J-1 to J-9), not off to the side.
- It changes as little underneath as possible:
  - no new integrations;
  - no new kind of data or new data owner;
  - no new real-model calls (the budget is zero);
  - no change to the approval, suppression or audit rules.
- Its screens, actions and states can be designed and task-tested by Friday
  night.
- It is useful by itself and makes later slices easier.

## Candidates

### A. Operator shell and home (recommended)

- **What it is:**
  - the new app frame: layout, navigation between the screens, and the visual
    direction from the design days;
  - the home screen: what needs you now (drafts to review, replies to handle,
    problems), what the agent is doing, real or fake model, budget, and
    unknown outcomes.
- **Story map:** home and action queue (across all steps), J-9 counts.
- **What changes underneath:** nothing in the domain. It reads through public
  functions that already exist, as the signed-in person:
  - `Outreach.list_review_queue/1`, `Outreach.list_handoff_queue/1`;
  - `Operations.list_attention/1`;
  - `Agents.list_runs/1`;
  - `AI.ModelProvider.Runtime.status/0`.
- **Value:** every later screen lives inside this frame. The home screen
  answers "what do I do now?", which the founder needs first.
- **Risk:** low for the domain. The main risk is the visual direction not
  being settled by Friday; then the frame ships with provisional design
  tokens that are swapped later.
- **Evidence needed:**
  - **G2:** requirements and acceptance criteria for the home screen and
    navigation, including the empty, loading, error and unknown states.
  - **G3:** home and navigation in the clickable prototype, walked through by
    the owner without help.
  - **G4:**
    - confirm there is no entity or domain change, so no entity delta;
    - a short threat note (reads stay under existing policies, no new data
      shown to roles that cannot see it today);
    - a LiveView test plan.
  - **G5:** the slice plan, CI, rollback (revert the UI), and the next slice
    named.

### B. Review workspace

- **What it is:**
  - the redesigned review step: a queue you move through with the keyboard;
  - one draft at a time, with its exact recipient, revision, cited evidence
    and risk flags;
  - edit, reject with a reason, and approve for capture.
- **Story map:** J-6 (and part of J-5).
- **What changes underneath:** the screens only. It uses the existing
  `edit_draft`, `approve/3` and `reject/3` with their binding to the exact
  recipient and revision. It may need one new read: the next and previous
  draft in the queue.
- **Value:** the trust moment of the whole product (OUT-2, OUT-3). It shows
  off the evidence and the approval binding.
- **Risk:** medium. It is the security-sensitive screen: the approval must
  stay bound to what is visible, and stale approvals must be refused clearly
  (F-6). Expect more review rounds.
- **Evidence needed:**
  - **G2:** acceptance criteria for review, edit, reject and approve,
    including F-6 and F-7.
  - **G3:** the review step task-tested in the prototype.
  - **G4:**
    - confirm the binding contract is unchanged;
    - a threat note on the stale and concurrent approval UI;
    - tests for refused stale approvals;
    - an independent check of the keyboard shortcuts so that no single key
      approves without a visible confirmation of the target.
  - **G5:** as for A.

### C. CSV import

- **What it is:** upload a CSV, preview it, validate it, check for duplicates
  and suppressed contacts, then create accounts, contacts and leads.
- **Story map:** J-2, with F-1 and F-2.
- **What changes underneath:** a new way for data to enter:
  - an import action;
  - row-level validation;
  - where each row came from;
  - duplicate rules;
  - handling of personal data in uploaded files.
- **Value:** needed for the workshop: founders must bring their own lists.
- **Risk:** higher. This is a new data path, so it needs an entity delta with
  an independent PASS, a threat model (spreadsheet formula injection, file
  size, personal data in the audit trail) and import tests. Too much to close
  by Friday night alongside the design days.
- **Evidence needed:** the full G2 to G5 set, including the entity PASS.

## Recommendation

1. **Saturday: A, the operator shell and home.** It changes no business rules
   or data, it frames everything after it, and it turns the design days
   straight into something you can use.
2. **Next: B, the review workspace,** as soon as its own G2 to G5 evidence is
   ready, likely Sunday or Monday.
3. **Then C, CSV import,** after its entity delta and threat model are
   reviewed.

## What stays frozen, whichever you pick

- Any new domain resource, action, data path or integration not named in the
  chosen slice.
- Live web research, HubSpot, ICP lead discovery and any new alert channel.
- Real model calls (the budget is zero until you approve more).
- Changes to approval binding, suppression, idempotency or the audit trail.

## Questions for the owner

1. A, B or C for Saturday, or a combination you prefer?
2. Is it acceptable for A to ship with provisional design tokens if the visual
   direction is not settled by Friday night?
3. For the home screen: what is the single most important thing it must show
   when you open the app?
