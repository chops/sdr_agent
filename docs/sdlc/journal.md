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

### Sprint 1, day 2 (Tue Oct 13), mid-day checkpoint (11:00 MDT)

Day 2 went to the calibration harness: R0-07 part E, the code that will
make one supervised calibration attempt per owner confirmation, within the
four-attempt G-R0 grant (two per profile), and record what came back. All
of it is on the `r0-07e-harness` branch (draft PR #146). Nothing merged to
`main` today (Denver time) so far. Codex reviews every piece in two steps: it
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
  - it signals a process only while its recorded root identity still
    matches; a changed or unverifiable root is never signalled;
  - anything it cannot confirm is reported as an unconfirmed cleanup,
    which keeps the lock and stops the console.
- **The claim on the reservation** (E4c-c1). The console's lock id is
  recorded on the call's reservation event, so a crash cannot lose which
  call the lock belongs to.
- **The recovery action** (E4c-c2). It safely settles stranded calibration
  calls under the reviewed rules (never launched, observed quiet, or owner
  attestation), keeps the attempt charged, and never treats a sent call as
  proven unlaunched.
- **The sealed one-shot authority** (d1a, approved at 10:49 MDT). The
  registry that will support the staging exemption. It is not connected to
  dispatch yet (part d1b), so on its own it lets no call through.

**In review at this checkpoint:**

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

### Sprint 1, day 2 (Tue Oct 13), afternoon checkpoint (as of 15:30 MDT)

The afternoon finished the budget binding and the staging exemption, and
got the console's last part designed. Of its four pieces, the launch
receipt (d3a) is approved, the reserved-call wrapper (d3b) is in review, and
`calibrate` (d3c) and `calibrate-recover` (d3d) are not yet built. Everything is still on
the `r0-07e-harness` branch (draft PR #146). Nothing from it merged to
`main` today; the morning journal entry (#148) did.

**Approved by Codex as components since the checkpoint** (each approval
covers that piece only, not a merge, a real call or any spend):

- **The G-R0 budget binding** (d2a and d2b).
  - A calibration call can be reserved only against the owner's G-R0 grant
    at the exact version the console selected, and only while that
    profile's allocation is open.
  - At launch the same binding is checked again: an amended, revoked,
    swapped or unreadable binding stops the call before it starts, and the
    charge stays where it was.
- **The staging exemption** (d1b). One private, unnamed server may make one
  call, and only:
  - for the fixed calibration prompt;
  - after using up a one-shot authority entry;
  - after the reservation, its run and its stored request are re-checked
    under the launch locks.

  Every other call stays blocked as today. A request refused by the
  checks before the entry is used (wrong server, input, claims or witness)
  leaves the entry untouched; a refusal at launch admission comes after the
  entry is used, and the entry stays used up.
- **The launch receipt** (d3a, the first part of the console commands).
  After the CLI starts, the server reports the process it launched, or
  says it could not prove it. The check is bounded by the call's deadline,
  cannot crash the server, and cannot outlive it.

**In review at this checkpoint:**

- **The reserved-call wrapper** (d3b): the console's way to settle its own
  call through the existing settlement code, after re-checking the target.
  Codex has requested changes once (a request-shape check); not approved.

**Designed, not yet built:** `calibrate` and `calibrate-recover` (d3c and
d3d). Codex passed their design after three rounds.
- **Failure paths:** every failure point has a stated outcome.
- **One writer:** the command is the only writer of its lock record.
- **Recovery stays with the owner:** any attempt that may have reached the
  model needs a typed `STOPPED` and an audited attestation until open
  question OQ-E3 is decided.

No real model call has been made; the budget for them is still zero.

**What we learned:**

- **Process lifetimes need their own design.** The launch receipt went back
  three times, each for a different gap:
  - a slow check could stretch an expired call into a late success;
  - a crashing check could take the server down;
  - a stuck check could outlive the server.

  Each was found by a short probe and became a test first.
- **A negative test has to observe the negative directly.** The wrapper's
  "never calls the provider" tests first only checked side effects. A probe
  that called the staged provider and then returned invalid still passed
  them; no real model was involved. They now trace the server and require
  zero provider calls.

### Sprint 1, day 2 (Tue Oct 13), evening checkpoint (as of 18:12 MDT)

As of 18:12 the console's `calibrate` command (d3c) is built and approved
by Codex as code, except for one setup step. Everything is still on the
`r0-07e-harness` branch (draft PR #146). Nothing from it is merged to
`main`.

**Status of the console commands** (each approval covers that piece
only, not a merge, a real call or any spend):

- **d3a, the launch receipt:** approved.
- **d3b, the reserved-call wrapper:** approved.
- **d3c, `calibrate`:** approved as code in three parts.
  - **Test-first:** the core behavior followed tests that Codex verified
    as failing before the code was written, and so did each fix round's
    regressions.
  - **The exception:** the console script's two new forwarding tests were
    written after the script was edited. That was disclosed, and they
    were checked later.
  - **The outcome and the evidence file.** An unreadable witness store
    now reads as "unreadable", not "missing". The evidence uses the
    committed records and, for a call that was sent, the witness check's
    actual result; no observation is invented. Malformed input is refused
    rather than crashing. Two fix rounds.
  - **The command.** One attended call from start to finish: claim,
    checks, the owner's typed confirmation, one launch, observation,
    evidence, latch and release. Each tested failure row keeps or releases
    the lock as designed. A launch refused by the budget check stops its
    run with that exact refusal before anything is latched. One fix
    round: a probe error could be retried into a success, a later failure
    lost the evidence file from its report, and the lock was in the wrong
    folder.
  - **Still open:** creating the evidence folder on first use. Its design
    is in its second review round, because the first version could have
    replaced an existing empty folder.
- **d3d, `calibrate-recover`:** not started.

**Also staged:** a test clock for the console's private model server
(8.14.10), queued for review. Without it, these tests pass only until
G-R0's fixed window closes (Sun Oct 18, 23:59 MDT).

No real model call has been made; the budget for them is still zero.

**Estimate given at the owner's request:**
- **Code merged:** Thu Oct 15 at best, Fri Oct 16 to Mon Oct 19 more
  likely.
- **Then:** owner-attended steps, estimated at 1 to 1.5 elapsed days.
  Overall, Oct 16 to 20.
- **The main risk** is G-R0's window. If the merge slips past about Sat
  Oct 17, the real calls may need a renewed window; no renewal is
  approved.

**What we learned:**

- **A test that stops at "not built yet" proves little about its own
  fixtures.** Every new test failed on the missing command after the
  shared setup but before its own per-test fixtures ran. A separate run of
  those fixtures found a budget-grant fixture that could never have been
  selected. It was fixed before review.
- **Error paths lose state quietly.** A failure after the evidence file was
  written still reported "no evidence", because the success path's updates
  never reached the error branch. Codex found it with a short probe; each
  step now carries what it has reached.
- **"Create only" has to be checked against the real filesystem call.** A
  rename used to publish a new folder can replace an existing empty one.
  The design now uses a create call that fails when the name exists.

### Sprint 1, day 3 (Wed Oct 14), end of day (as of 22:45 MDT)

**The standup.** Sprint 1 missed its exit: R0-07 grew from one story into
about 12 PRs over Oct 12 and 13, and the owner only learned of the miss
today. The owner approved forecast v2.2 (R0 by Sat Oct 17, conditional;
H1 Oct 20 to 23; B1 Oct 23 to 26; B2 Oct 26 to 29) and said: "we're going
to have to be more disciplined about early notifications if it looks like
we're falling behind." Five tripwires were approved for same-day notice:

1. a story grows past its planned PRs or slices;
2. the same item gets "changes requested" a second time;
3. a critical-chain item is not started on its planned day, or passes
   its window;
4. an owner gate is needed within 24 hours and is not scheduled;
5. a daily on-track, at-risk or slipping line for each critical-chain
   item.

**Merged to `main`:**

- **#146, the calibration harness** (R0-07 slice E), at 11:20 MDT. It is
  the owner-run `calibrate` and `calibrate-recover` commands, in test
  builds only. No real model call has been made; the budget is still zero.
- **#137, the Home inbox contract** (C1-01), at 14:31 MDT, after the owner
  said "merge it".

**Owner decisions** (each is a design or scope decision, not a merge or
spend approval):

- **C4, run settings:** the metadata-only logging amendment to ADR-0005
  was accepted as written, after the owner first questioned it. The owner
  answered all seven open questions. The main change: "i don't think
  there should be a hard ceiling that no setting can change. that's not
  user-friendly." The revised C4 design lets the owner raise or lower
  every operational limit in the app, up to what the database column can
  store, with an audited confirmation of what was raised. Budgets and the
  separate safeguards still bound everything. This is a design decision;
  nothing is built yet.
- **C3, lead admission:** the ADR-0009 amendment was accepted, and the
  three open questions were answered with Claude's recommendations. The
  scoped G5 implementation approval was given. One new rule: CSV, HubSpot
  and agent-found leads skip a company whose last lead ended converted or
  in nurture.
- **5b, PostgreSQL server logs:** the owner approved the direction (keep
  them as retained files, with a disclosure). Nothing is configured yet;
  a small proposal comes first.
- **The B2 walkthrough** is confirmed for Oct 16 to 17.

**Reviews:**

- **C3** passed Codex's review of the revision (round 5).
- **C4** passed at its third revision (3.2), after two rounds on one
  number. See the misstep below. It now waits for the owner's G5.
- **C1-02, the Home inbox reads** (Codex's branch), went through
  test-first and code review. It is approved, and Codex's full test run
  passed (2,276 tests). It is not merged.

**The blocker: a HIGH security advisory in Bandit,** the web server
(EEF-CVE-2026-105659, published 10:54 MDT). It affects the version we
lock, 1.12.5. There is no fixed release yet, only an upstream fix in
git. Codex showed that plain HTTP is affected too. Under ADR-0008 a HIGH
advisory is never ignored, so nothing can merge. Codex recommends
pinning the reviewed upstream fix with HTTP/2 turned off, under a
reviewed ADR. The other option is to wait for a release. That choice is
the owner's, and it is open.

**Calibration** preparation was ready for the 17:00 slot. At 16:48 main
had the harness, the pinned CLI and the database were in place, and Codex
had approved the spend disclosure as accurate for presenting to the owner
(not as approval to spend). Still outstanding before any call: creating
G-R0, the owner's own account and billing check, and the command's live
checks. At 22:44 the owner moved it to first thing Thu Oct 15. Nothing was run, no server was started and G-R0
was not created.

**Critical-chain status:**

- **R0 (Oct 17): at risk.** It needs calibration on Oct 15 and five more
  build items (C2-02, R0-04, R0-05, C9-04, C9-06). None of the five was
  started today: the day went to C3, C4 and the C1-02 review. This was
  reported to the owner today.
- **Merges: slipping** while the Bandit decision is open. Each blocked day
  costs about a day.
- **G-R0's window** closes Sun Oct 18 at 23:59 MDT.

**Follow-up issues:** #151 (a flaky CI test), #152 (a reviewer's Home
leaves out some released drafts), #153 (Home's draft reads must respect
the real-data switch).

**What we learned:**

- **Check a runtime limit by running it.** A remembered timer limit was
  wrong for the Erlang version we pin. Codex's probe of the pinned
  runtime settled it in one step.
- **Don't commit while a full test run is going.** A commit made during
  the run changed the source hash that a compile-time check embeds, and
  the run had to prove that the test sources were unchanged.

### Sprint 1, day 4 (Thu Oct 15), mid-day checkpoint (as of 11:55 MDT)

**Calibration, attempted and stopped safely.** At 07:57 the owner ran the
console with Claude walking each step. They created the console's first
admin and the single G-R0 grant (4 attempts, 2 + 2 proof allocations,
expiring Oct 19 05:59 UTC). The first form attempt was refused because
the grant-level Profiles boxes were unticked; the review step didn't flag
it, a small follow-up. The owner confirmed included-only billing, the CLI
login and the disclosure. The first `calibrate claude_cli_opus` stopped at
preflight with `witness_store_untrusted`: **no invocation, no reservation,
no attempt spent.** Cause, confirmed by Codex with a no-start probe: the
console runs the test build, which never reads `SDR_WITNESS_STORE_ROOT`,
and the merged harness's tests had injected the root themselves. Codex
also found the console inherited the test build's 1 s result wait.

**R0-07f, the fix.** Contract (Codex PASS at `0ee216e`), RED (VERIFIED at
`ce859ce`, after one round fixing a detached-task crash, fixture
pre-promotion, a missing real `apply!` probe and control-character
directories), GREEN, then one code-review round (direct `mix` checked the
root before parsing argv; docs). Codex APPROVE at `f01cae0`; PR #162 CI
green. Awaiting the owner's merge decision.

**Bandit HIGH (EEF-CVE-2026-105659).** The owner chose option B (D-130).
ADR-0008 amendment approved by Codex after one correction round
(mechanism wording, scheme-level `http_2_options`), accepted by the owner
(D-132). PR #161: full-SHA Git pin to `d88b219`, HTTP/2 off on every
listener, four regression tests on a hermetic HTTP/2 listener (three fail
on 1.12.5, all pass on the pin), Codex code approval including a live
LiveView probe. **Merged at 11:30 MDT (`1272ff8`).** Merges are unblocked.

**C2-02b2α.** The owner accepted the ADR-0004 amendment at `80771e5`
(D-131) after asking whether Codex had reviewed it (it had, and confirmed
the copy-only follow-up). GREEN: the reaper receipt, the launch hold, the
start allocator and the coordinator; all 68 RED tests and the migrated
slice a/b1 suites pass; full gate 2368 passed. Codex's GREEN review
requested changes (MF1-MF6: blocked switches released at restart,
adoption conditions, a direct-action bypass, an uncertified receipt, the
stop bound, rollback after a failed start). Fixed at `8b20acd` with
Codex's eight probes kept as regressions; `main` and the planning docs
merged in; the integrated gate is running.

**Tripwires fired today:** 3 (calibration missed its morning window), 2
(R0-07f and b2α each needed a second round), 1 earlier (5 PRs for C2-02).
All were reported the same day.

**Open with the owner:** #162 merge, then resuming calibration at step 4;
the scoped C4 G5.

### Sprint 1, day 4 (Thu Oct 15), afternoon

**Merges and gates.** The owner merged #162 (R0-07f, D-133) and passed
the scoped C4 G5 (D-134: RED then GREEN for C4-01a and C4-01b; not merge,
real-data or model-call approval).

**Calibration resumed.** With `SDR_WITNESS_STORE_ROOT` exported, `check`
reported the witness store as trusted. `calibrate claude_cli_opus`
finished with outcome **match** (invocation `01a140e1`, evidence sha256
`0c2e3735`), and Codex passed the evidence. One of the four attempts is
spent. The Sonnet attempt is next and is the owner's to run.

**C2-02b2α approved after five review rounds.** Codex requested changes
at `bce5653`, `5e10978`, `1d04d7a` and `e8a67a6`, and approved at
`ace975a`. The later rounds were narrower:
- holding a survivor before any database read;
- adopting only with the exact child, the desired profile and its own live
  reaper lease;
- one deadline across the stop and the receipt;
- a retried block that re-reads the switch and never writes a second
  event.

One round reached Codex unformatted and failed the gate at its first
step. Every finding is kept as a regression test. Full gate at `ace975a`:
2394 passed.

**Integration.** #159 and #160 had failed CI only at the dependency
audit, because they predated the Bandit pin. Main merged cleanly through
the stack (#159 `8935b2f`, #160 `0a247d5`, new PR #163 `c4a29b8`). Codex
approved the three integration deltas (71, 127 and 418 independent tests).
Its first three test runs started together and hit PostgreSQL's
connection limit (53300); it disclosed that and reran them one at a time
cleanly. Our full gate on `c4a29b8`: 2426 passed, with no 53300.

**The owner accepted the stack (D-135).** #159 merged at `3c54fa5` and
#160 at `3527984`. Branch protection requires an up-to-date branch, so
#160 and #163 each needed main merged in again. Both new heads have trees
identical to the reviewed ones, verified with `git diff`. #163 merged at
`22db5c0`. C2-02 slices a, b1 and b2α are on main; nothing is activated.

**Tripwires fired this afternoon:** 2 (b2α's third and fourth CHANGES
REQUESTED), reported as each arrived.

**Next:** the Sonnet calibration, then Codex's evidence review; b2β and
slice c; C4-01a/b RED; R0-05. The R0-06 forecast stays Fri Oct 23 (Mon
Oct 26 without weekend work).

### Sprint 1, day 4 (Thu Oct 15), evening (through 21:00 MDT)

**The stop, and the decision to keep going.** After the C2-02 stack
merged, Claude posted a status report and stopped. It should have
started the next work, which was already authorized. Codex, given
nothing to review, sat idle for about two hours. The owner asked why,
called for a standup, and then decided to work through the night and the
weekend (D-136). Every status report now goes out as work starts, never
in place of it.

**Contracts, all passed by Codex:**

| Contract | Drafts | Head | What it covers |
|---|---|---|---|
| b2β, the attended resolver | 4 | `e60943c` | A blocked switch's one exit, to failed |
| Slice c, restart and status | 3 | `401df6f` | Restart behaviour, and a cross-checked status sample |
| R0-05, the admin page | 3 | `fbc3203` | The model card, the switch, the resolver UI |

- **b2β:** the admin's typed attestation goes through the coordinator.
  Draft 3 had proposed a narrow lease-release power, but its binding
  argument was wrong: a server can replace its own reaper without a new
  start. Draft 4 withdrew the power. A dead lease now stays a held hard
  conflict, ended by the operator. The proposed ADR-0004 amendment waits
  for the owner.
- **Slice c:** it narrows the plan's "clean pending → failed at boot"
  branch, because a restart can never prove that earlier CLI work
  stopped. That is OQ-1, for the owner. Status reports the last
  confirmed observations, cross-checked within a bounded sample.
- **R0-05:** each review freezes while it is being submitted or its
  outcome is uncertain.

**RED, verified by Codex:**

| Slice | Head | Rounds | Notes |
|---|---|---|---|
| b2β | `a9a60c4` | 3 | 59 failing as intended |
| C4-01a | `e8dcda3` | 2 | 72 tests |
| Slice c | `1cb8506` | 2 | 3 tests stay staged until b2β GREEN |

Each round came with throwaway stub evidence. Codex's critical b2β
finding: `LedgerCall`'s connection watchdog ends a paused transaction at
2.25 s, so a settlement test can't hold a writer open past the 15 s
deadline. That needed an independent held transaction.

**A b2α bug, found by the slice-c RED.** A coordinator restart whose
first start is held leaves a pending switch pending forever. It fails
closed, but has no exit. Codex confirmed it, and it is fixed as a
prerequisite inside b2β GREEN.

**C4-01a GREEN** was built by a background agent. Codex requested
changes twice, each round narrower:
- **Round 1:** a span leak on malformed input; the repeated-character
  secret-rule shortcut (rejected, with test data changed instead); the
  ADR-0005 error-path controls, required before merge.
- **Round 2:** an atom/string key alias that splits validation from
  casting, and worker-boundary tests that checked only a marker.

The full gate passes, with 2503 tests. It isn't on the R0-06 path.

**Small items:**
- **PR #164:** a grant with no profile ticked is now flagged at the review
  step (the owner's morning error). RED verified, gate green, and in code
  review.
- **The test scripts' zero-count bug:** those files are owned by the
  project factory, so the fix goes upstream, for the owner to decide.
- **Codex's pre-reads** of b2β and slice c caught design risks before the
  drafts were written.

**Waiting on the owner:**
- the ADR-0004 C2-02b2β amendment, which gates b2β GREEN and so the
  critical path;
- slice-c OQ-1;
- the Sonnet calibration (G-R0 expires Sun Oct 18, 23:59 MDT).

**Tripwires fired:**
- 2: b2β took 4 contract drafts; C4-01a GREEN had two CHANGES REQUESTED;
- 3: the two-hour idle stop.

All were reported as they happened. The R0-06 forecast is Fri Oct 23
with weekend work, and at risk if b2β GREEN takes as many rounds as b2α.

### Sprint 1, day 5 (Fri Oct 16), overnight to morning (as of 07:40 MDT)

**Owner decisions:** the ADR-0004 C2-02b2β amendment (D-138; OQ-5 stays
open), slice-c OQ-1 (D-139), the Sonnet calibration this morning (D-140),
and R0-05 MF3 option B (D-141).

**Approved by Codex, CI green, waiting for the owner's merge call:**

| PR | Slice | Head | Notes |
|---|---|---|---|
| #165 | C4-01a, run settings and metadata-only Repo logging | `0bbd69d` | Includes the ADR-0005 error-path controls: the primary exception filter and a boundary on all 12 workers |
| #166 | C4-01b, the settings page | `5eeac38` | Stacked on #165 |
| #167 | C2-02b2β, the attended resolver | `ac95b9f` | Includes the b2α boot-gap correction |
| #168 | C2-02c, restart and status | `6de84ff` | Stacked on #167; includes the drain fix below |

All four were CLEAN against main `397dcda` at 07:37.

**A flaky drain, found and fixed.** The full gate failed about 1 run in
20 with `drain_failed`. The drain retried a busy connection only on an
exact message, but the test sandbox prefixes it ("could not checkout the
connection owned by…"). A probe at the b2β baseline showed the bug was
older than this slice. It now matches by suffix, as `LedgerCall` already
did, with a regression test. Afterwards the six-file focused command
(94 tests) ran clean 10 of 10 times (seed 0 six times, seeds 7 and 99
twice each), and the seven-file 104-test suite and a full gate passed.

**R0-05, the admin page:**
- **Contract and RED:** the contract passed at draft 3 (`fbc3203`). RED
  was verified at `00c4998`, with 39 tests failing as intended.
- **GREEN:** Codex's review found three must-fix items. Two are fixed at
  `cce173f`: re-checking the user's access when an async result arrives,
  and binding the stored-switch line to the reviewed switch.
- **The third, MF3,** was about crash reports, which can copy the typed
  confirmation into a log. The proposed fix, tagging every process that
  holds the text, missed the coordinator and supervisor reports.
- **The choice:** Codex recommended the narrower option B, and the owner
  chose it, accepting the stated residual risks. Under B the page refuses
  any text but the exact phrase itself, so arbitrary input never leaves
  it.
- **Next:** the revised ADR-0005 amendment and contract draft 4
  (`d0c80ff`) are with Codex. Then the RED amendments, GREEN and the PR.
  R0-05 lands after #165.

**Waiting on the owner:**
- the four merges, in order: #165 → #166, then #167 → #168;
- the Sonnet calibration (G-R0 expires Sun Oct 18, 23:59 MDT);
- OQ-R5-1 (SettingsLive crash reports);
- OQ-5;
- later, accepting the ADR-0005 R0-05 amendment, and the R0-05 manual try.

**Tripwires:**
- **2:** R0-05 GREEN had a CHANGES REQUESTED round, and its ADR draft was
  NEEDS-REVIEW.
- **4:** the calibration is today, and G-R0 expires within 48 hours.

R0-06 is still forecast for Fri Oct 23. It is tight: R0-05 needs about a
day more, and the merges are the owner's call.

### Sprint 1, day 5 (Fri Oct 16), mid-morning (as of 09:45 MDT)

**R0-05:**
- **Docs:** the owner chose option B (D-141). Codex passed the rewritten
  ADR-0005 amendment and the interface, draft 4 (`d0c80ff`).
- **RED:** verified at `1ddd1a2`, with 15 tests failing as intended out
  of 62.
- **Merge:** C4-01a (#165) is merged into the R0-05 branch for its
  exception filter. Codex passed that merge.
- **Next:** GREEN waits only on the owner accepting the ADR text.

**Unblocked after Bandit, approved, CI green:**
- #158 (R0-04) and #157 (C9-04): updated from main, full gates green,
  integration approved.
- #169 (C1-02, Codex's branch, no PR until now): updated from main, full
  gate green (2531 passed), integration approved.
- #170 (C9-06 evidence, stacked on #169): Codex approved it. Its full
  gate runs after #169 merges.

**R0-06:**
- The evidence record and owner runbook (#171, draft) passed at draft 3,
  after two NEEDS-REVIEW rounds.
- Codex ruled that the acceptance needs two actual attempts per profile;
  that question (OQ-R6-1) is with the owner.
- Ordinary real calls stay staged after R0-06.

**#166 held.** Codex's OQ-R5-1 pre-read found the settings page's
private content in more places than the channel:
- the loaded settings, for every role;
- the editor's state;
- the raw last message;
- the separate WebSocket transport process;
- the synchronous save stack.

Tagging the page alone doesn't keep C4's private-content promise. That
needs full holder and reporter coverage under its own ADR-0005 section,
or a new, explicit owner exception. #166 is no longer
"ready to merge unconditionally". It isn't on the R0-06 path. #165 is
unaffected.

**Misstep:** the G-R0 expiry weekday (it is Sunday). See the table.

**Tripwires:**
- **2:** the R0-06 record took two NEEDS-REVIEW rounds.
- **4:** the calibration attempts are due by Sun Oct 18, 23:59 MDT, and
  the attempt count is undecided.

### Sprint 1, day 5 (Fri Oct 16), afternoon and evening

**Calibration closed.** Sonnet attempt 3 PASS. Attempt 2 (Oct 15) got a retrospective PASS, and the owner accepted its missed review-before-next stop (D-145). G-R0 used 3 of 4 attempts.

**Merged:** #165, #167, #168, #158, #157, #169, and #172, the promotion of the Opus and Sonnet 2.1.294 tuples (D-146).

**R0-05:**
- Option-B GREEN approved; final integration `c8f6f23` approved.
- The owner chose a reviewed test-only rehearsal driver for the browser check (D-147). It was approved at `0b68813` after one CHANGES REQUESTED round.

**Tripwire 3:** layer 1 missed the owner's "late-night tonight" target. It was reported the next morning.

### Sprint 1, day 6 (Sat Oct 17): layer 1 closed

- **#170 merged** (`aea5729`; owner yes, D-148).
- **R0-05 browser check:**
  - **Driver fix:** the first owner run refused the password before any input, because the driver read it from the wrong device and in cooked mode. Fixed at `02ad8d8` and approved.
  - **Defect found:** the owner's run found a real one. A browser can't submit a mismatched confirmation, because the button stayed disabled until the text was exact, so the reset could never be reached. The owner chose to fix it (D-149): contract draft 5, RED `3f89303` verified, GREEN `3d27aad`.
  - **Gates:** the first full gate hit an unrelated CountPoolTest setup race (#175); the rerun passed with 2890 tests.
  - **Pass:** the owner's `_r5` run passed four of four checks with a clean stop. The owner accepted the gap that the exit code wasn't captured, and #173 merged (`6f271ab`, D-150).
- **R0-06 trial:**
  - **Snapshot tool:** the full read-only Mix snapshot command went to the backlog (#176), and the owner chose a reviewed SQL and shell snapshot instead (D-151). It took three Codex rounds (v1 and v2 CHANGES REQUESTED, v3 approved, 31/31 tests).
  - **Instance:** the existing dev app on port 4120, with the store measured at the owner's proxy capture root.
  - **Trial steps:** they took two CHANGES REQUESTED rounds, and draft 3 was approved.
  - **Run:** the owner ran Opus → Sonnet → Opus at `6f271ab`. All three checkpoints were complete with the same BEAM, with no change to invocations, grants, links or store counts, one new ready start per leg, and two completed switches. Codex gave a qualified technical PASS (`9f2ed2b2`). The owner accepted the omitted pre-run helper-hash check (D-152), then accepted R0-06 and closed layer 1 (D-153).
  - **Record:** #171, Codex PASS at `63284b9`; it merges after CI.
- **#171 merged** (`1381b37`) and #54 closed.
- **Layer 2 started** (D-154): Claude drafts E1 and E3, and Codex authors C1-03 and the H1 packet. Nov 6 keeps the full core (D-155).
  - **Contract:** draft 4 passed Codex at `ed819b7`. The owner accepted the E1/E3 scope and acknowledged the B5' residual (D-156, about 23:00 MDT).
  - **E1 plan:** `l2-e1` at `d5a70f8`, sent to Codex for review. No RED before PASS.
  - **C1-03 slice A:** RED verified and GREEN approved on condition (Claude's focused run passed 287/287). Codex's full gate at `0d46aad` is running.
- **Main CI** failed twice on flakes: CountPoolTest `:noproc` (#175), which at the time looked like it cascaded into KernelTest in CI (Sunday's reproduction found a separate cause, #178), and test 15's OwnershipError (#177). Both are queued after C1-03's gate frees the database slot.

**Tripwire 2** fired several times today: the snapshot helper, the trial steps and the #171 record each needed a second CHANGES REQUESTED round. They were reported to the owner as they happened.

### Sprint 1, day 7 (Sun Oct 18): E1 built (as of 02:20 MDT)

- **E1 (PR #181):** the plan took three revisions to PASS (`e9200cf`). RED took two rounds: the first had fixture defects, among them a trigger-mode leak and race cleanup that was too broad; the amended RED was verified at `28622af`. A transient run of the planned code, never committed, showed every later assertion and race barrier executes, and found three test bugs. GREEN `9c64247`, with the tests unchanged since RED; full gate 2920 passed; Codex APPROVE. It waits for the owner's merge decision.
- **Flake fixes:**
  - **#175 (PR #179):** CountPoolTest now also retries the `:noproc` teardown exit.
  - **#177 (PR #180):** the cause was the default 120 s sandbox ownership timeout under CI load; the module now sets 200 s.
  - **Status:** both are Codex-approved and CI-green, and they wait for the owner's merge decision.
  - **#178:** main's KernelTest failure is a separate cause, provenance snapshots kept by committed fixtures. Codex owns it.
- **G3:** the read-only inventory query and the owner's steps passed Codex. They wait for the owner to run them and give a handling decision.
- **E3:**
  - **Plan:** four revisions. Codex found a real bypass: a request with no `:calibration` key could take the ordinary path. The final design refuses a proof run at launch admission, from the locked run, and keeps the gate's own locked authority read. PASS at `e462d48`.
  - **RED:** 287 tests, two rounds, VERIFIED at `1f05a24`. GREEN `09d04ef`; Codex conditional APPROVE, and its focused run passed 287/287.
  - **Full gate:** FAIL, 2984/2988. The only failures are the four KernelTest #178 tests.
- **#178 (PR #182):** reproduced. It is deterministic within one VM: a committed fixture keeps the provenance snapshot of the VM's cached identity. It was not reproduced in the three cross-VM trials, because their first-collection config differed; an identical build and config could still give the same content-addressed key. This corrected Claude's first diagnosis. Fixed in test code only; Codex conditional APPROVE. Its combined run hit #175, because #179 is not yet merged.
- **Merge order waiting for the owner (as of 02:20):** #179 (#175), #180 (#177), #181 (E1), #182 (#178). Then main goes into E3 for its full gate. Superseded at midday by D-157.

### Sprint 1, day 7 (Sun Oct 18): midday (as of 12:44 MDT)

- **Merges delegated (D-157):** the owner: "i no longer want to be the blocker for merge decisions". Claude and Codex now merge once Codex has approved the exact head commit, CI is green and the branch is up to date (rules in #183, Codex APPROVE at `dd209aff`).
- **Merged:** #179 (`52b7b22`) and #180 (`42be75f`).
- **#182:** rebased to `0ed00d9`; the CountPool + KernelTest pair passed on seeds 0 to 3, and the full gate passed (2896 passed, 1 skipped, 4 excluded). Codex is reviewing it for merge.
- **Daily standup page:** the owner asked for an interactive standup they can answer and annotate. It is live, Codex's view first; the owner's first answers are recorded as D-158 (start B2 drafting now) and D-159 (stale-PR triage delegated). G3 is scheduled for today.
- **Records:** the decision log and journal branches had never been PR'd, so D-110 to D-157 were not on main. They are now #184 and #185. D-110 and D-111 had ids and citations but no rows; they were restored from the owner's Oct 12 words.
- **Merge watcher stopped:** Claude's script for merging approved PRs was blocked by Codex, which reproduced two ways it could accept unreviewed code (see Missteps). Merges are by hand until a reviewed replacement exists, and any new head, including a rebase, needs Codex's fresh sign-off.

### Sprint 1, day 7 (Sun Oct 18): evening (as of 22:30 MDT)

**Merged, all by Claude under D-157:**
- **#181 E1** (`ccb0238`), **#182 #178** (`2b82912`), **#187 E3** (`258283d`), **#190 #188** (`c033612`), **#183** (the merge rules), **#189** (the B2 requirements and entity model), **#184** (decisions D-110 to D-170), **#185** (the journal) and **#186** (the B2 mockups).
- Each merged pinned to Codex's sign-off on its exact head, with green CI and the branch up to date.
- Every rebase got its own fresh sign-off.
- #154 and #155 were closed as superseded.

**Layer 2:**
- **G3 closed (D-162).** The owner ran the inventory. The first run failed with `psql` not on PATH; the query never ran, and the log was kept. The second run, through the dev-shell `psql`, completed with exit 0 and the end marker. The owner chose disposition A: explicit acceptance, with no repair. It retains the 12 real and 6 Fake candidate `parsed_output` copies (not proven plaintext) and leaves 144 inconsistent-binding and 14 unbound events unresolved. "Never exported" is the owner's attestation, not independent proof.
- **E3** merged with its full gate at a fixed head (2994 passed), so layer 2's code was done about three days ahead of its forecast (a forecast scenario, not a performance guarantee).

**#188**, a new AdminLiveSwitch flake on #183's CI:
- **Process:** diagnosed, planned in two rounds, RED in two rounds, then GREEN.
- **Fix:** only the exact shared-sandbox queue drop is retried; the matching row is returned with no re-read.
- **Proof:** six mutants were each caught.
- **Gate:** the first full gate failed on credo nesting; the rerun passed (3013).

**B2:**
- **Walkthrough:** the owner's algorithm walkthrough was held in chat, with no real data and the notes kept private. The owner accepted the requirements wording (D-163 to D-167); LinkedIn is option 1, fixed steps in the owner's browser (D-164); the screenshot changes are direction only (D-165).
- **Entity model:** Codex PASS after five rounds, for planning only. B2 code waits on C3-02/03, the C5 guard and C4 settings.

**G-DEMO** (D-169 to D-171):
- **Procedure:** three review rounds, and the run report validated on 28 disposable fixtures.
- **The grant:** the owner created G-DEMO (3 attempts for b1, a 60-minute window, and the b1/b2/b5 workshop reserve). The workshop allocation was missed in the form and added by one owner-authorized corrective edit, with 0 attempts consumed.
- **Assign was refused before any run or job was created:** assignment needs an offering-profile setting, and this build has no settings page (C4-01b, #166). Nothing was charged.
- **Close-out:** after the window closed, the final check passed and the owner lifted the freeze: **no run**.

**Owner tools:**
- **Standup page:** the interactive standup page is live, Codex's view first, and checked every 30 minutes.
- **D-168:** agents may run reviewed read-only summary checks on the dev database. Not yet built; Codex set the security requirements.

**Overnight (owner asked):**
- C4-01b (#166) rebased onto main and its full gate running;
- the D-168 ADR and adversarial tests being drafted;
- C3-02 next.

**Waiting for the owner:**
- the 5b decision and the SettingsLive protection gate, before any private settings content, including the offering profile;
- authorizing the revised G-DEMO attempt.

### Sprint 1, day 8 (Mon Oct 19): three flaky tests fixed, one in review (as of 09:30 MDT)

**Merged under D-157:**
- Overnight: **#166** C4-01b, the settings page (`14c2d64`), merged by Claude; **#195** C1-03 slice A, written by Codex, approved by Claude at its exact head and merged by Codex.
- Today, by Claude:
  - **#199** the #197 fix (`0f4fc2a`), **#200** the #198 fix (`791466e`), **#196** the #194 fix (`9110987`), **#141** the C3-01 lead-admission contract (`0d2a64c`) and **#192** the journal (`687f877`).
- Each of Claude's merges was pinned to Codex's sign-off on its exact head, with green CI on that head and the branch up to date. Every rebase got its own fresh sign-off. #141 was a draft, and was marked ready first (D-159).

**Main's flaky tests:**
- **#197** (calibration console): two tests ran the command in a process that read the real clock, while the test grant's expiry is fixed at 05:59 UTC. Fixed test-only, with a gated command that checks the frozen clock before it runs.
- **#198** (reaper): the identified-launch test used a stand-in program that could exit before its lookup.
  - The fix is a held-handshake fixture.
  - A repair followed after a mutant left an orphan process. Every test cleanup now journals its proof that the program stopped, and a module-level collector fails visibly on anything unproven.
  - Proof: three seeds, nine mutants, and the full gate including `mix precommit`.
- **#194** (restart attestation): the test now awaits admission and attestation on one restarted incarnation.
- **#201** (demo reset), new on main CI at `9110987`: the reset's count saw 2 other connections where the test held 1.
  - A metadata-only probe did not reproduce it. The database's statistics show autoanalyze visited the freshly seeded demo database at 14:27:36, after the last probe run ended at 14:26:49. No worker row and no overcount were captured. By the PostgreSQL source, the old all-backend count would include such a worker if one were connected at count time.
  - The cause of the CI failure is not established.
  - The fix (#202) counts every backend type except exactly `"autovacuum worker"`, the one type a non-forced `DROP DATABASE` asks to exit itself (PostgreSQL 18.6 source). Codex approved it; CI is pending.
- No test was rerun to get a green.

**C3-02 lead admission:**
- The plan's facts were refreshed at post-#141 main: no drift.
- Codex found that the agent's qualification write can supersede a row, so it contends with the planned override on the same unique entry.
- Plan r5 to r7 make the agent's write lock the lead first, and add scheduled race tests.
- Codex gave r7 a technical PASS. RED waits on the owner's six decisions, the D0 docs, and a final entity and module review PASS after both.

**Waiting for the owner:** the G-DEMO attempt-2 sentences and choices, 5b (#156), D-168 (#193), C3-02's Q-O1 to Q-O6, and #29 and #37. All are on the standup page.

### Sprint 1, day 9 (Tue Oct 20): C3-02 half built (as of 09:25 MDT)

**Merged since the last entry, under D-157:**
- **#202** (`425d7c9`): the #201 demo-reset fix.
- **#203** and **#204**: the journal and the D-172 to D-179 decisions.
- **#205**: D-180, G-DEMO attempt 2 closed QUALIFIED.
- **#206**: C3-02's D0 docs and the ADR-0009 amendment.
- **#193**: D-168's install package (ADR-0016), merged at `14de644`. Its tree is identical to Codex's r7-approved head, `99c0163`.

Main is green at `14de644`.

**G-DEMO attempt 2 (D-177, D-180):** the owner authorized one rehearsal window and changed the lead to Juniper Crate Labs.
- **The call:** one real Opus call completed and was charged (1 of 3). The result gate withheld its output (`witness_missing`): the reply was not exactly one text block (`response_block_unsupported`). Which blocks it held is not established.
- **No retry.** The freeze lifted after the owner's closeout.
- **The fix:** projection v4. Its plan (r5) and its proposed ADR-0005 amendment text passed Codex review. A read-only decision-link diagnostic (r4) also passed. Both wait on the owner.

**C3-02 lead admission:**
- **Failing tests and slices:** the three failing-test stages (RED-1 to RED-3) were approved. Build slices G1 to G3 were approved after Codex findings G2-1, G3-1, G3-2 and G3-2b. G3-2b led to an owned call envelope that bounds DBConnection's untimed queue wait.
- **G4 (`fb5166a`):** `admit_lead` and `Assignment.queue`, built under Codex's nine design rulings. Item 8 was amended: `address?/2` also matches domain suppression on the email host, so a closed-scope classifier replaced it.
- **G4's full gate:** 193 to 105 failing; 88 tests newly pass, none newly fail.
  - One test literal was wrong (T-H3: an empty `jsonb[]` prints as `{}`). It was corrected in `16d18ff`, accepted by Codex.
  - Codex's G4 review found three input gaps: control characters in an email, raw 16-byte uuids, and step 9 judging the raw stored domain.
  - Their failing tests (`c8f2717`, exactly seven, each at its intended assertion) were approved. The minimal fix (`fb2474e`) is in its gate.
- **Merge prerequisite:** after C3-02 the app refuses to start if the owner's database holds a retired or mismatched `SDRAgent` row at the code's current version; that stops for a reviewed owner disposition. Rows at other versions are retained history, and a missing current-version row bootstraps normally with a valid singleton tenant. No version bump, deletion or rewrite is implied. The preflight was reviewed in four rounds and its tooling approved at r4; the final-candidate code receipt and the owner's installed-state check are still separate steps.
  - It is an owner-run, read-only, metadata-only check with an exact output format and a classifier.
  - The agent's code receipt is fail-closed. A shell path guard runs before the explicit Mix verification, fetch and build sequence (devenv's shell setup still runs `mix hex.info` earlier), because `mix run` writes into the build path before a Mix-based guard can run.
  - The code fingerprint at `16d18ff` (`f490cb2e`) equals main's.

**5b (D-178):** the implementation plan passed Codex review for failing tests in two rounds.
- **No known-red merge.** The configured disposable full gate is exact-head CI. The owner activates at the reviewed candidate before merge.
- **One typed JSON settings source.** devenv's actually generated `postgresql.conf` is checked, not its settings attrset.
- **A source-by-source audit:** extensions, loaded modules, preloads and dotted settings names.
- **Status:** the failing tests are being written on `c4-5b-impl`. 5b's implementation slipped a day behind C3-02 (noted on the standup page).

**Owner decision:** D-181, install D-168 today, after the agents release the shared database.

**Waiting for the owner:**
- the D-168 install and acceptance;
- the projection v4 ADR amendment;
- the witness diagnostic;
- the B2 search provider and key;
- #29 and #37.

### Sprint 1, day 10 (Wed Oct 21): projection v4 built (as of 09:40 MDT)

**Merged since the last entry, under D-157:**
- **#207** (`c9c7e9b`): decisions D-181 to D-183 and the Oct 20 journal.
- **#209** (`fcdcb9b`): the #208 fix. `WitnessRoot.mkdir!` now allocates collision-resistant roots, and the scan test cleans up its own root.

Main is green at `fcdcb9b`.

**Projection v4, T1 to T6 (D-182): built and approved; the merge waits on the owner.**
- **Failing tests:** RED was approved after one repair round. Nine failures were MatchErrors from custom-message pattern asserts, not assertion failures. They were reshaped into assertion-safe guards (`00c2345`): the same 20 failures, now with zero runtime errors.
- **The build:** an author agent wrote it in five slices, and Claude gated it.
  - T1: `compare_v4/4`, a syntactic layout grammar with a fixed precedence.
  - T2: the evidence R group.
  - T3: the selector, which tries v4 only after a contract-valid v3 `:unsupported`.
  - T4: the mismatch-head lineage rule, in put_link, `WitnessLineage` and the DB trigger. The DB side comes from a new frozen-body migration, `20261021101539`.
  - T5 and T6 needed no production change.
- **Gates:** all 40 intended failures pass; 7 mutants were each killed by a named test.
  - The rebase onto `fcdcb9b` was pure (range-diff 9/9 `=`).
- **Review rounds after GREEN:**
  - G1: strict-Credo cleanup on the v4-changed files.
  - G2: labeled `WM-RECEIPT` lines for the external migration campaign.
  - G2-F1: the campaign's cleanup facts are now enforced, not just printed.
- **Final head `d4aeae8`:**
  - focused 185 passed; external campaign 2/2 with 107 receipts; `bin/verify` and precommit 3221 passed each;
  - codegen clean; strict Credo 0 on the changed files, with 0 new findings against main;
  - Codex G2/source APPROVE; draft PR #211, CI green.
- **Waiting on the owner:** whether to accept the gate as "no new strict findings". Project-wide strict Credo exits nonzero on 473 pre-existing findings in files v4 doesn't touch.

**C3-02:**
- G4 was approved at `069a9ff`.
- G5 (the atomic admission cutover) is built at `58571c3`: 106 to 97 failing, 0 new.
- Codex asked for a stronger migration proof, with two parts:
  - committed synthetic legacy rows, shown unchanged across up/down/up;
  - a fail-closed driver.
- The driver is on protocol round 3:
  - a single exclusive `CREATE DATABASE`;
  - a closed PG environment;
  - a supervisor that signals only its own unreaped child.

  Its DB-free stub control passes all 18 scenarios.

**5b:**
- **CI blocker:** the CI run at `6af6121` failed in `bin/verify`. devenv.nix is a whole-file unit owned by the project factory, and the factory has no re-receipt path. Codex and Claude both pick an owner-approved, one-unit receipt revision with an ADR, merged atomically with the config. It is waiting on the owner.
- **Renderer:** the one-document fix (G1) passed at `e027972`.
- **Sink test:** the plan is on round 4. Codex review found that the launcher attaches to any live process-compose and inherits PG* targeting. It also found nested restart policies, truncating per-process logs and a second process-compose log sink. The scope grew well past the original estimate.

**Waiting for the owner:**
- the v4 Credo gate decision;
- the 5b receipt decision;
- the D-168 install and the witness diagnostic (D-181, D-183; neither has run yet);
- v4 T7's grant start and expiry;
- the B2 search provider and key;
- #29 and #37.

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
| **Oct 13: three verification reports wrongly said the dev build compiled.** The non-test (dev) build failed to compile with warnings as errors. The held RED test failures were disclosed separately. | The gate script piped the compile output through `tail` without keeping the step's exit status, which hid the failure. | Codex caught it; one extra review round on part E's claim binding. | The gate now checks each step's own exit status and reports PASS or FAIL per step. |
| **Oct 13: Claude's reply watcher missed a review verdict.** A watcher read its list of message ids with `cat`, which is aliased to another tool in this shell, so the list came back empty and nothing ever matched. | The alias was known but not applied to watcher scripts. | A verified-tests verdict sat unread until Claude checked the inbox by hand; no work was lost. | Watchers read with `/bin/cat` and stop if the list is empty. |
| **Oct 13: a test claimed a case it could not reach.** The test "a launch that never opened sends no receipt" used a missing CLI, but the launcher always opens `/bin/sh` first, so a launch did open. | The fixture's premise was not checked against how the launcher starts processes. | One extra review round on the launch receipt. Claude and Codex each found it independently. | The case was split: a real refusal before launch, and a missing CLI that is treated as launched. |
| **Oct 13: Claude's inbox watcher moved its own messages.** A watcher matched Claude's own follow-up note and moved two messages meant for Codex out of the shared inbox before Codex read them. | The watcher matched a message id, not who sent it. | Restored within minutes; no message was lost. | Watchers only match replies sent by Codex to Claude. |
| **Oct 14: Sprint 1's missed exit reached the owner only on its last day.** R0-07 had grown from one story into about 12 PRs over Oct 12 and 13. | Growth was reported as progress, not as a schedule risk; there was no rule for when to warn. | The owner learned of the miss at standup, with no time to re-plan before it. | Forecast v2.2 and five approved tripwires that require same-day notice (see the Oct 14 entry). |
| **Oct 14: C4's time limit was wrong twice.** The first maximum (one day) was a fixed policy ceiling, which the owner's decision against hard ceilings had just ruled out. The second came from a remembered timer limit that the pinned Erlang runtime does not have. | The first was not checked against the owner's decision, and the second was not checked against the running system. | Two extra review rounds on C4; the second "changes requested" tripped tripwire 2, reported to the owner the same day. | Codex probed the pinned runtime. The revised design bounds every limit by the stored 32-bit integer maximum, and the packet requires a test at that boundary when it is built. Runtime limits are checked by running them. |
| **Oct 15: calibration's first attempt stopped at preflight.** `calibrate claude_cli_opus` refused with `witness_store_untrusted`. | The console runs the test build, which never read `SDR_WITNESS_STORE_ROOT`; the harness's tests had injected the root themselves, so no test exercised the real console path. | About two hours of the calibration window. No attempt or spend; fixed by R0-07f (#162). | The console now reads the root as a plan input, and a test runs the real `Calibrate.run` path. |
| **Oct 15: one b2α review round reached Codex unformatted.** The gate failed at its first step (format). | New regression files were written and the gate was started without running `mix format --check-formatted` first. | One review round. | Run the format check after writing files and before the gate. |
| **Oct 15: the first integration gate started without dependencies.** After main brought in the Bandit Git pin, the worktrees had not fetched it, and compile, credo and the audit all failed. | A dependency source change needs `mix deps.get` in every worktree; the merge was conflict-free, so nothing prompted it. | One aborted gate start, minutes. | Run `mix deps.get` after any merge that changes `mix.lock`. |
| **Oct 15: Claude pulled main into the owner's calibration checkout mid-sequence.** After #163 merged, `~/src/SDR_agent` was fast-forwarded from `3b2caaa` (the code Opus ran on) to `22db5c0`, which adds a migration and the coordinator. | Habit of refreshing the main checkout after a merge; it is the owner's console checkout and calibration was still open. | None: caught within a minute, before any command ran there; reset with `--keep` to `3b2caaa`. | Leave the owner's checkout alone during calibration; inspect main in a worktree or with `git fetch`. |
| **Oct 15: Claude stopped with authorized work queued.** After the C2-02 merges, Claude posted a status and ended its turn instead of starting C4-01a RED and the b2β contract. Codex, told 'no action needed', went idle. | A milestone reached while waiting on an owner action was treated as a stopping point, despite the standing 'keep going until I say stop'. | About 2 hours of both agents idle, 15:30–17:30. | Status reports go out as the next item starts. Codex gets work or an optional pre-read whenever it would otherwise idle. |
| **Oct 15: notes for a review reached Codex empty.** The C4-01a RED author notes were written through the shell's `cat`, which is aliased to `bat`, and arrived at zero bytes. | Claude's own memory warns about the alias, and Claude used the wrong command anyway. | Minutes: Codex asked for them. | Notes files are written with the Write tool, and the byte count is checked before sending. |
| **Oct 16: Claude recorded OQ-5 as accepted under D-138.** The owner had accepted the ADR-0004 C2-02b2β amendment and OQ-2, not OQ-5. | The amendment's open questions were summarized as one item when the decision was written. | Minutes: caught before any work relied on it, and corrected in the decision log. | Each open question in an owner decision is recorded separately, as accepted or still open. |
| **Oct 15–16: Claude gave the G-R0 expiry as "Saturday Oct 18".** It is Sunday Oct 18, 23:59 MDT (2026-10-19 05:59 UTC); the timestamp was right, the weekday wrong. It went into D-140, the journal and several owner messages. | The weekday was typed from memory, against Claude's own rule to derive weekdays with `date`. | None in time (the real deadline is a day later than stated), but the owner was told the wrong day while planning attended calibration attempts. Codex caught it (`e87584b5`). | D-140 and the journal corrected; weekdays come from `date -d`, never by hand. |
| **Oct 16: Claude's calibration ledger missed the Oct 15 Sonnet attempt.** | The ledger was compiled from conversation memory, not from the database. | Codex's read-only snapshot found it; the ledger was corrected and the missed stop disclosed (D-145). | Ledger counts come from Codex's read-only database snapshot, never from conversation. |
| **Oct 16: Claude sent Codex the wrong SHA for a review** (`e826e7f` instead of `1d7d5c4`). | It was typed by hand. | Minutes; corrected with a reply envelope. | Copy SHAs from `git rev-parse` output. |
| **Oct 16: the owner found Claude's messages too verbose.** | Claude explained background when the owner needed decisions. | Owner time. | Asks are numbered, one line each, with Claude's pick. |
| **Oct 17: the resolver's mismatch reset was unreachable in a real browser.** | The tests submitted the form directly (`render_submit`), which bypasses the disabled button. No one checked that a browser could reach that path. | A contract, RED, GREEN and full-gate cycle, plus four owner reruns. | Draft 5 keeps the button enabled while editing. The browser check stays as the owner's evidence. |
| **Oct 17: a rehearsal run used the old code.** The owner's `_r2` run reported `code: 02ad8d8`. | The checkout switch to `c745380` didn't happen, and the instructions didn't ask the owner to confirm the SHA. | One wasted run. | Owner instructions include `git rev-parse` checks with the expected value. |
| **Oct 17: Claude's snapshot helper wrongly reported failures as "complete".** v1: a failed `find` or `lsof` still printed complete, and a changed BEAM wasn't compared. v2: an unreadable root read as zero, writable ancestors were accepted, and the environment was cleaned after child processes had already started. | The happy path was tested; the failure paths weren't. | Two CHANGES REQUESTED rounds, about 2 hours. | v3: every observation's exit is checked, the environment boundary is applied before anything runs, and there are regression tests for each reproduced failure. |
| **Oct 17: Claude's test harness reassigned HOME and ran `rm -rf` on it.** Two further test-only bugs: fixtures were allocated in a subshell, and a check called the dev shell's `stat`. | Throwaway scripting habits. | Codex refused to rerun the harness; one round. | The harness uses `mktemp -d` fixtures only, never deletes, and calls system tools by absolute path. |
| **Oct 17: Claude left the approved helper-hash check out of the owner's trial steps.** | Claude condensed the approved steps into a short message and dropped one. | A disclosed deviation that the owner accepted (D-152). | Relayed owner steps must match the approved document's steps one to one. |
| **Oct 17: the layer 2 contract funded an origin, not a bucket.** Draft 3 set the allocation's `applies_to` to `:assignment`, which is a run origin; allocations take buckets (`:b1`). | The two vocabularies were mixed while writing; `UsageBucket.bucket/2` wasn't checked. | One NEEDS-REVIEW round (Codex `a0f0e923`). | Draft 4 names the bucket and the mapping, and RED asserts them separately. |
| **Oct 17: Claude wrote the Nov 6 workshop start as MDT.** Daylight time ends Nov 1, so 00:00 on Nov 6 is MST (07:00 UTC), not MDT. | The offset was worked out by hand, against Claude's own rule to derive dates with `date`. | The same NEEDS-REVIEW round. | Offsets come from `TZ=America/Denver date`, as weekdays do. |
| **Oct 18: Claude sent Codex a review request with a blank commit ID.** A plan edit failed, so nothing was committed, but the message was sent anyway. | The send came after a `;` in the same shell command, so it ran even when the commit step before it failed. | Minutes: a correction with the right ID followed. | Peer sends are chained with `&&` after a check that the commit ID is not empty. |
| **Oct 18: Claude's merge watcher could have merged unreviewed code.** The script accepted a rebased head when every `git range-diff` line contained " = ", a check a changed commit with "=" in its subject passes; range-diff also ignores merge commits, so a hidden tree change would pass too. | Claude wrote and ran it before review, treating it as automation of a manual step. | No wrong merge: #180 was patch-identical (checked by hand), and the one premature #181 attempt was refused by GitHub. Codex requested the stop, and Claude stopped both watchers within the hour. | Watchers stopped; merges by hand; any new head needs Codex's sign-off; a replacement must accept only the exact approved commit, fail closed and have mocked tests before it runs. |
| **Oct 18: the G-DEMO procedure never checked that the assignment settings existed.** It assumed **Assign** would check them, but nobody confirmed an offering profile was set, and this build has no settings page. | The prerequisite was described ("Assign checks them itself") rather than verified before the owner's session. | The owner's first-run attempt ended as no run, after about two hours of an attended session. Nothing was charged. | Owner procedures check every input a step consumes before the attended session, not just that a refusal would be safe. |
| **Oct 18: an unclear conditional step made the owner stop the app.** Step C1 said "if anything has started, stop the app"; the owner read it as an instruction and stopped it. | The conditional was buried in a bullet under a step. | A restart and an extra pre-grant check, both approved by Codex; no grant existed yet. | Stop conditions in owner steps are set apart and worded "only if …". |
| **Oct 18: a broken mutant run passed every mutant.** The #188 mutation script ran inside the dev shell, where it did not change the file, so all six "mutants" were the unchanged fix. | The script's effect wasn't checked before trusting the result. | None: it was caught before review, because the file didn't match the saved fix, then rerun and disclosed. | Each mutant is applied and confirmed `[mutated]` before its test run. |
| **Oct 19: an approved diagnostic test failed to compile.** The #198 B1 diagnostic passed a parse-only check but failed at compile time (a nested `&` capture). | Parsing proves syntax only. The file wasn't compiled before its exact hash was approved. | One re-approval round and one spent DB slot. | Transient test files are compiled without a database (`mix run --no-start` with `Code.require_file`) before their hash is submitted. |
| **Oct 19: a mutant left an orphan test process.** One #198 mutant stopped its owner without ending the stand-in program, which kept running. | The test cleanup tore down its actors without proof that the program had exited. | One Codex-approved, guarded one-off stop of that exact process, with a disclosed gap of about 25 s between its checks and the stop. | The repair: every cleanup journals its proof, never tears down without a receipt, and a collector fails the module on anything unproven. |
| **Oct 19: the #198 gate skipped `mix precommit` and used `--force`.** The gate ran verify, credo and the audit, and forced the dev compile. | The gate script was carried over unreviewed from #194's. | One extra gate run; Codex caught it. | The gate is `mix precommit` plus the dev compile with warnings as errors, without `--force` unless stale state is shown. |
| **Oct 19: C3-02's base refresh assumed the agent's qualification write is root-only.** | It was inferred from the one current caller (ScoreLead), not from the action's accepted inputs and existing tests. | Codex review MF1, then plan r5 to r7. | Action contracts are inventoried from their inputs and existing tests, not from today's call sites. |
| **Oct 19: Claude drafted "main CI is green again" for the owner while main was red.** Main's own run after the #196 merge had failed (#201). | Only each PR's own CI was checked, not main's run after the merge. | None: caught before the standup was posted. | Main's post-merge CI is checked before main's status is reported. |
| **Oct 20: a G3 regression was reported as planned RED.** T-A17, a completed control inside a RED file, newly failed; Claude counted it as planned because it sat in a RED file. | Failures were classified by file membership, not by diffing failing names against the previous approved head. | One Codex review round. | Every slice now reports newly failing and newly passing names against the last approved head (`faildiff.py`). |
| **Oct 20: a gate result could not be counted.** The authoring agent edited two test files three minutes into Claude's G2 full run. | The author was not told to freeze during the run. | One full rerun. | Authors freeze before every gate; manifests record dirty state before and after. |
| **Oct 20: three synthetic preflight receipts were malformed, and one was wrongly classified COMPATIBLE.** BSD `sed` dropped the newline Claude meant to insert. | The fixtures were generated with a GNU-style `sed` idiom and not inspected. | Minutes; caught before review. | The fixtures were regenerated in Python and the byte content checked; the r3 report disclosed it. |
| **Oct 21: 5b's CI failed on the factory receipt.** Editing devenv.nix failed `bin/verify`, because the file is a whole-file factory-owned unit. | Claude's local 5b gates ran tests only, not `bin/verify-workflow`, and nobody checked whether devenv.nix was generator-owned. | A red CI run and an owner decision now on 5b's path. | Before editing generated config, check `.workflow/receipt.json`'s owned units, and run `bin/verify-workflow` locally. |
| **Oct 21: a review request sat unanswered for about 4 hours.** Claude sent C3-02 G5's review request with `ap send` only, which writes no envelope. | `ap send` is the wake-up channel; it has no `msg_id` to reply to and leaves nothing in the inbox. | About 4 hours of G5 review latency. | Every review, approval or slot request goes through `ap consult`; overdue reviews are searched for by head SHA. |
| **Oct 21: v4's RED had nine runtime errors.** Custom-message pattern asserts raise MatchError, not an assertion failure, when the code is missing. | The known assertion-form rule was not applied to the new test files before RED. | One RED review round. | Assertion-safe `match?` guards come before destructuring; the forms are checked before a RED run. |
| **Oct 21: G5's migration proof driver did not fail closed.** It had only `set -u`, masked statuses through grep, ran psql without `ON_ERROR_STOP`, and printed values instead of asserting them. | It was written as an observation script, not as a gate. | One review round and a rewrite (protocol r2, then r3). | Proof drivers are fail-closed and come with a database-free stub control showing that a failure can't reach cleanup or "success". |
