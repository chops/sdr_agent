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
