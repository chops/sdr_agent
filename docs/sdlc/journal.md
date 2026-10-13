# Project journal

The story of SDR Agent in the order it happened, with a short retrospective at
the end of each phase. Written for founders who want to see what the process
looked like from the inside, including the parts that went wrong.

## Phase 0: the prototype (Oct 6 to 8, 2026)

### The starting point

On Oct 6 the owner pasted a detailed architecture design for an AI sales
development representative (SDR) into a project scaffolding tool. Its core
rule (quoted with the owner's consent, decision D-018):

> Jido decides. Ash governs. Oban executes durably. Postgres remembers. OTP
> keeps it alive. Phoenix lets humans operate it.

The design covered the system's layers, its domain objects and how the agent
should be supervised. It said little about who would use the product or what
their day would look like.

### The unattended build

The owner delegated most decisions to two AI agents, Claude Code and Codex CLI,
working side by side, under a written mandate
([ADR-0001](../adr/0001-unattended-build-operating-charter.md)). The mandate
listed decisions the owner had already made, what the agents could decide
alone, and conditions that had to stop the build. Codex was consulted on every
firm decision. The work was cut into fourteen slices (S0 to S13), each built
test-first by one agent and reviewed by the other before it merged.

Notable turns:

- **Provider pivot (Oct 7).** The first real model was Codex app-server on the
  owner's existing Codex login. Its built-in tool surface could not be fully
  disabled and verified, so that adapter was left disabled behind a
  fail-closed check. The owner approved the Claude CLI on their own login
  instead, locked down to no tools, no plugins and a per-call check that it
  really had none ([ADR-0004](../adr/0004-model-provider.md)).
- **Audit first.** Every agent decision, model call and human approval goes
  into a hash-chained ledger, anchored with signatures and timestamps. If you
  trust the signing key and the timestamp evidence, later changes to recorded
  events can be detected. That does not prove the records are complete or
  true.
- **Wire witness.** The owner chose to delay the demo until model calls could
  be matched against what actually crossed the network. A match needs the one
  reviewed CLI version and request shape; any other call stays marked
  "inferred". Choosing to wait for this capability is not proof that every
  demo call was reconciled.

Snapshot at `main` `438f6a2` on Oct 8: 34 merged pull requests, about 280
commits and close to a thousand automated tests. Those numbers show how much
was built and tested. They do not show that the product is validated with
users, or that two agents equal a team of human specialists.

### The demo

The owner demoed the product live at an AI meetup on the evening of Oct 7,
using the real model. Two things the demo needed (wiring the real model into
the app, and showing the agent's risk flags) were not finished in time. They
ran on an unreviewed local patch, which was reverted after the demo and rebuilt
properly through the normal review process the same night.

### After the demo

The owner asked for the highest quality product possible. The agents hardened
what existed: real model wiring, a strict allowlist for the environment of
every child process, and the wire witness switched on for one exact reviewed
configuration. A free HubSpot developer
portal was filled with synthetic companies and contacts for a future CRM
integration.

Then the agents proposed a plan to keep building. The owner rejected it (quoted
with the owner's consent, decision D-013):

> I want to nail down the features and functionality of this product before
> beginning production work. And I also want to determine what the UI/UX
> should look like for human operators.

The owner asked what other parts of the planning process had been neglected.
New feature work was frozen.

### Discovery begins

The owner answered a discovery questionnaire about users, jobs, success
measures, scope, operator experience, agent behaviour, data, deployment and
business goals. Claude and Codex reviewed the answers separately. Both found
the wish list too large for the three weeks before the Nov 6 workshop. The
owner chose:

- the workshop promise: a **first-touch copilot** for solo founders, not a fully
  autonomous SDR;
- **desktop only** for this release;
- emails **captured, never sent**;
- **HubSpot as an optional add-on**, with CSV and manual entry as the core way
  leads arrive.

On Oct 8 the owner asked for a traditional software process, worked through by
the three of us together, with durable artifacts committed to git. Claude
drafted it; Codex requested changes (unrecorded gate approvals, factual
errors in this journal and the decision log, owner notes that could be lost
silently, a schedule that counted weekends as working days, and too many
separate documents). This folder is the revision.

### A machine restart (Oct 8)

The owner's terminal misbehaved and the machine had to restart mid-phase.
Before it did, Claude and Codex each wrote a private handoff: exact session
ids, how to resume each one, what a reboot would wipe, and the next action.
Codex checked Claude's handoff and found seven errors, which Claude fixed.
Files that lived only in temporary folders were copied somewhere durable
first, leaving out anything that held login tokens.

After the restart, Claude reopened its exact conversation. The pair launcher
started a fresh Codex rather than the old one, so Claude closed it and
relaunched Codex into its exact previous session, which also picked up the
newer installed Codex release. One slip on the way: Codex's startup update
prompt accepted "Update now" by mistake; the install failed harmlessly
because the Nix store is read-only. Later that morning the owner asked for
all three agents on their latest releases. Codex needed nothing, the Gemini
analyst moved to the new agy release in the same conversation, and Codex
restarted Claude onto the new Claude release from its own pane, because a
process cannot safely replace itself.

### Gate G0 (Oct 8)

The owner answered the plan's five open questions from the interactive map:
work seven days a week, hold the design days on Oct 8 and 9, treat one
founder conversation the owner had already had as enough outside validation,
review through notes on dedicated pages pasted into chat, and allow quoting
of the owner's own words.

Meanwhile the owner asked how to shape the product before writing code:
describe what the founder should be able to do, then the architecture, then
each piece's role, then the screens. Claude and Codex answered separately.
Both agreed to start with the founder and keep the existing stack. They
differed on when to design screens; Codex's view (sketch screens early and
check feasibility alongside) won. The combined seven-step method went onto an
interactive discussion page.

The owner then accepted the charter (ADR-0014) and the method, and chose to
start building on Saturday Oct 10 with one narrow first slice, after that
slice has passed its own gates. Codex had pointed out that moving the start to
Monday would be a schedule change, not an interpretation, so the owner chose
between the two explicitly. The gate record is
[`gates/G0.md`](gates/G0.md).

### Retrospective (approved by the owner as written, D-027)

- **Worked:** a written mandate, small slices, test-first work and mandatory
  peer review produced a robust core (audit trail, approval binding, durable
  jobs) very quickly.
- **Did not work:** starting from an architecture prompt instead of a product
  definition. The engine was built before anyone had decided what the operator
  should see, so the UI was thin and the demo needed a patch.
- **Change:** define the user, requirements and design before building more,
  and keep the owner in the loop at every gate instead of only at checkpoints.

## Phase 1: the build (from Oct 12, 2026)

### Planning (Oct 11)

The owner walked the prep documents item by item and asked Claude and Codex
for a build plan that reaches a working MVP on time. Codex reviewed the plan
three times before the owner approved it (D-097). The rest of the day went
to the backlog and the money:

- **Backlog.** 82 stories across ten epics and nine shared contracts went into
  GitHub Issues, with a milestone per three-day sprint and a project board.
- **Budgets.** The owner granted two real-model budgets: four calibration
  calls and 200 demo calls. Both are usable only after the code that
  enforces them is merged.
- **Billing.** Included subscription usage only.
- **Real data.** The owner approved a data flow that lets the app work with
  real companies and people.

### Sprint 1, day 1 (Mon Oct 12), mid-day checkpoint

**Goals for the day:**

- retire the riskiest R0 unknown (can the app run its own pinned CLI?);
- get the first budget-check code into review;
- draft the witness rule change;
- get the R0 readiness packet through review and G5.

**Done and merged** (each with Codex's independent approval of the exact
commit and green CI on it):

- **ADR-0004 R0 amendment** (PR #39). The owner accepted it: an app-owned
  pinned CLI, closed Opus and Sonnet profiles, an audited switch, and
  owner-only call budgets.
- **ADR-0014 amendment 2** (PR #125). Constraint 7 now allows real companies
  and people in the owner's local instance only, behind an off-by-default
  switch, with simple retention rules.
- **ADR-0005 R0 amendment** (PR #128). The owner chose "accurate out of the
  gate":
  - four calibration calls in isolation;
  - a call refused before it spends anything unless its exact model setup is
    approved;
  - each result used only after its own wire record matches.
- **The R0 readiness packet and gate record G5-R0** (PR #124). Its
  data-model design took three review rounds and fixed seven real defects.
  The owner answered the open questions: any human admin may change budgets,
  there is no Telegram in the app, and there are no inferred calls.
- **Budget records** (PR #130), after three review rounds. Only a current
  human admin can change a budget, each change is one validated bundle, and
  every row change is audited.
- **The app's own pinned Claude CLI 2.1.294** (PR #131), after four review
  rounds. It is bound to one reviewed artifact by store path and checksum,
  never runs `claude` from `PATH`, and refuses every real call until the
  profile and witness work lands. GC-root rotation is safe across concurrent
  runs and interrupts.
- **Security fix** (PR #40): `decimal` 3.1.2 for an advisory that did not
  reach our code.
- **Test fix** (PR #123): a flaky test fixed at its cause.

**In review at this checkpoint:**

- **The queue-time budget check** (PR #132), after three review rounds:
  - the check is enforced by the record itself;
  - a lock order that cannot deadlock against budget edits;
  - one clock reading taken after the locks;
  - a refused run linked to the exact alert its refusal created.
- **Docs:** this journal and the decision log (PR #127), and the screenshot
  wording (PR #129).

**How the work was done:**

- **Pilot.** The owner approved a pilot of reviewer-side helper subagents
  (D-111). Codex used one or two read-only helpers on the larger reviews; one
  of their suggestions was wrong and was rejected after checking.
- **Subagents.** Claude used subagents for two of its stories, under its own
  review before Codex's.

**Not done yet:**

- Codex's Home inbox contract draft (C1-01) did not start: review work
  displaced it. It moves to day 2, alongside the Opus and Sonnet profiles
  (R0-03).

**What we learned:**

- **Review is the real limit**, as planned: about twenty review rounds in
  one day.
- **Reviews found real defects:** deadlocks, bypasses, a clock race, and
  a lock theft that Codex reproduced with its own test. None was cosmetic.
- **The local gate differed from CI.** Our local gate did not run Credo, and
  that cost a re-approval round. Claude now runs it before every push.
- **Pronouns.** Some log entries used "he" for the owner, whose pronouns
  were never stated; the wording is now neutral.

### Sprint 1, day 1 (Mon Oct 12), evening checkpoint

**Merged after the mid-day checkpoint** (each with Codex's approval of the
exact commit and green CI on it):

- **Queue-time budget check** (PR #132) and the **docs** PRs #127 and #129.
- **The budget editor on `/admin`** (PR #134). Its review found that an
  unrelated edit could move a budget window by an hour across the November
  clock change; untouched times now keep their stored value exactly.
- **Closed model profiles, Opus and Sonnet** (PR #135).
- **Launch-time budget check** (PR #136). Its review found three real
  defects: a stopped run could still launch, a caller that died while queued
  left a reservation forever, and a caller that died during the check could
  still start the CLI. All three are fixed.
- **The R0-07 design** (PR #133) and **part A of its code** (PR #139):
  - an exact allowlist of approved model setups;
  - an immutable record of each result's release;
  - generation-2 Claude CLI output unreadable for business use until
    released, with the audit log keeping only a fingerprint of it.
- **The calibration console** (PR #138), where the owner will create the
  G-R0 budget: one fixed database, local port 4124 only, no reset path, no
  model server, and its own private secrets.

**In review or in progress at this checkpoint:**

- **R0-07 part C** (PR #143), the per-call result check. Codex found five
  real defects; all five are fixed and back in review.
- **R0-07 part B**, the refusal before spend. Its design passed in round 9;
  the code is written but not yet pushed or reviewed.
- **Designs that passed entity review:**
  - lead admission (C3-01, four rounds);
  - run settings (C4-01, two rounds), together with a logging amendment to
    ADR-0005.

  Both now wait on the owner's questions and ADR acceptances.

**Home inbox (C1 and H1):**

- **First mockup rejected.** The owner found the first Home mockup too
  wordy and unlike a CRM.
- **Two new concepts compared.** Claude and Codex each built one.
- **Concept A chosen.** The owner picked Claude's concept A, with two
  changes:
  - a collapsible sidebar;
  - a view showing exactly what changed in an edited email.

  The owner confirmed both, and the phone layout. ADR-0015 is still
  proposed.

**What we learned:**

- **The design packets kept finding gaps.** Parts B and C of R0-07 each
  surfaced several undecided questions when coding started. Stopping to get
  a ruling was slower but caught real problems.
- **A mockup made for engineers does not test a founder's task.** The
  owner's honest "I'm not sure how to answer" was the most useful finding of
  the walk.

### Sprint 1, day 2 (Tue Oct 13), mid-day checkpoint

Day 2 went to the calibration harness: R0-07 part E, the code that will
make the one tightly supervised real call per model and record what came
back. All of it is on the `r0-07e-harness` branch (draft PR #146). Nothing
merged to `main` today so far. Codex reviews every piece in two steps: it
first confirms the new tests fail for the right reason, then reviews the
code that makes them pass.

**Approved by Codex as components** (each approval covers that piece only,
not a merge, a real call or any spend):

- **The launch record** (E4c-a). It is the console's on-disk lock. It now
  has `aborted` and `recovered` states, an owner attestation kept beside it,
  and a release that checks again before it deletes anything.
- **The isolation check** (E4c-b). Before any reservation, it launches a
  harmless shell the same way the real CLI will be launched. It proves the
  shell runs in its own process group, then confirms it is gone. Four
  review rounds tightened it:
  - it cleans up only a directory it created itself;
  - it is bounded in time, even when the caller dies;
  - it never signals a process it cannot prove it started;
  - anything it cannot confirm is reported as an unconfirmed cleanup,
    which keeps the lock and stops the console.
- **The claim on the reservation** (E4c-c1). The console's lock id is
  recorded on the call's reservation event, so a crash cannot lose which
  call the lock belongs to.
- **The recovery action** (E4c-c2). It closes out a call after a crash,
  backed by an audited owner attestation.

**In review at this checkpoint:**

- **The sealed one-shot authority** (d1a). It lets exactly one private
  server call through the staging block.
- **The G-R0 budget binding** (d2a). The call may only spend from the
  owner's G-R0 budget, at the exact version the console selected.

No real model call has been made; the budget for them is still zero.

**What we learned:**

- **Reviewing with small probes finds real gaps.** Most of Codex's findings
  today came from short probe tests:
  - a float process id that compared equal to an integer;
  - a raw message that named another process as the caller;
  - a grant created in the gap between two locks.

  Each became a test before its fix.
- **"Passed" has to mean each step passed.** See the misstep below.

## Missteps

Things that went wrong, kept here on the owner's request (D-027). Each row
says what happened, why, what it cost and what changed.

| What happened | Why | Cost | What changed |
|---|---|---|---|
| **Oct 7: the demo ran on an unreviewed patch.** Real-model wiring and the agent's risk flags were not finished in time, so they ran on a local patch nobody had reviewed. | The engine was built before the operator experience was defined, and the work did not fit the time before the meetup. | The live demo used unreviewed code. The patch was reverted after the demo and the work rebuilt through normal review the same night. | Feature freeze and the product-phase process: define and gate work before building it (D-009, D-019). |
| **Oct 8 to 10: owner input on the shaping page went unread for over a day.** Notes written on the shaping discussion page, including the framing that the founder's tasks differ from the SDR's, were found only during the walkthrough. | The page was not checked for new owner input. | The framing arrived late, and the P1 story map, built around the founder doing SDR work, had to be rebuilt. | The framing was adopted (D-029), P1 rebuilt around it (D-031), and the page closed read-only with its answers in git (D-030). |
| **Found Oct 10: an agent CLI update broke the app's real-model path.** Updating the agents moved the system Claude CLI from 2.1.291 to 2.1.294. | The refresh did not account for the app's version pin; the app used the same system CLI as the agents. | App real-model calls failed closed (`version_attestation_drift`), so no output was accepted without a matching attestation, but the real-model path was unusable and the witness configuration no longer applied. | R0: an app-only pinned Claude CLI runtime, decoupled from the agents' CLIs (D-087; ADR-0004 R0 amendment, PR #39). Agent CLI bumps are covered by the proposed ADR-0014 amendment 1 (D-028). |
| **Oct 11: Claude misread the R0 terms as API-first.** The owner asked for a connector for "my AI model of choice", naming several providers; Claude read it as switching to paid API keys, and Codex's first R0 memo was also API-first. | The terms listed API providers; the owner's intent (keep the subscription CLI as the tested path and make later swaps easy) was not checked before reshaping began. | An owner correction and a second reshaping round; Codex's API-first memo was replaced. | R0 is the pinned Claude CLI on the owner's subscription plus a clean provider seam, with no API-key adapter in R0 (D-087). |
| **Oct 12: a flaky ClaudeCLI test turned CI red on PR #39.** A lifecycle test read the fake CLI's launch record while it was still being written (985 of 986 tests passed). | The test fake wrote its launch record in place, not atomically, and the test polls for it. | A red CI run and a separate test-only PR before merging. | PR #123: the fake writes a partial file and renames it, and test cleanup removes leftovers. No production code changed and no assertion was weakened. |
| **Oct 12: local checks passed while CI failed.** A Codex-approved budget PR would have failed CI on Credo (nesting depth). | The local gate (`bin/verify`) does not run Credo; CI does. | One extra review round on PRs #130 and #131. | Claude runs `mix credo` before every push. |
| **Oct 12: Claude's walk questions primed the owner.** Before the mockups existed, Claude explained the five walk questions in plain words that hinted at the answers. | Claude tried to help the owner answer questions written for engineers. | The first walk is prompted evidence, not an unprimed usability test; this is recorded in the H1 notes. | The walk now uses Codex's neutral script, and Claude does not explain the answers. |
| **Oct 12: a pushed design update went unannounced.** A subagent pushed the R0-07 part C round-7 design but did not report it, so Codex was not asked to review it. | Claude relied on the subagent's report instead of checking the branch. | About half an hour of delay on the critical path, which also delayed the Home concept B mockup. | Claude checks branches directly and asks subagents to report each pushed commit. |
| **Oct 12: tests were written after the code in two part C commits.** RED was captured afterwards by running the new tests against the old code. | A subagent wrote the code first under time pressure. | Weaker evidence that the tests drive the behaviour; disclosed in PR #143. | Disclosed rather than hidden; the process rule (failing test first) stands. |
| **Oct 12, evening: the account hit its weekly usage limit.** Both background subagents stopped mid-gate with a 429 error. | The weekly limit is shared by every Claude session on the account; how much each session used was not measured. | Unfinished full gates on R0-07 parts B and C, and a checkpoint and login refresh. | No subagents for now; one full test suite at a time in the main session. If the limit returns, stop, keep the work, and tell the owner. |
| **Oct 13: three gate reports overstated a passing build.** The non-test (dev) build failed to compile with warnings as errors, but the reports said the gate was green. | The gate script piped the compile output through `tail`, which hid the step's exit status. | Codex caught it; one extra review round on part E's claim binding. | The gate now checks each step's own exit status and reports PASS or FAIL per step. |
| **Oct 13: Claude's inbox watcher moved its own messages.** A watcher matched Claude's own follow-up note and moved two messages meant for Codex out of the shared inbox before Codex read them. | The watcher matched a message id, not who sent it. | Restored within minutes; no message was lost. | Watchers only match replies sent by Codex to Claude. |
