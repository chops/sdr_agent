# From demo to product: the SDR Agent development process

Status: **proposed** (v0.2, data revision 2026-10-08.2). It becomes the
working process only when the owner accepts it and the charter
([ADR-0014](../adr/0014-product-phase-charter.md)) at gate G0. Until then
the unattended-build charter ([ADR-0001](../adr/0001-unattended-build-operating-charter.md))
still governs.

This folder records how SDR Agent goes from a one-shot prototype to a product
that could eventually run in production. It is written for two audiences: the
three of us doing the work, and founders who want to see how a solo founder can
run a traditional software process with AI agents as the team.

| File | What it is |
|---|---|
| [`index.html`](index.html) | Interactive map: phases on a weekday timeline, each phase's activities, packet and gate, who does what, gate rules, constraints, schedule controls, and a notes panel for owner feedback. Open it in a browser from this folder. A private hosted copy for the owner: https://claude.ai/artifact/ScAk7wEuMjD5nPUZdWLKGj |
| [`sdlc-data.js`](sdlc-data.js) | The data behind the map: the detailed, versioned record of the process. `meta.revision` changes with every edit. |
| [`notes.js`](notes.js), [`check-notes.mjs`](check-notes.mjs) | Owner-note handling and its checks (`node docs/sdlc/check-notes.mjs`). |
| [`gates/`](gates/) | Gate records. A gate has passed only when its record is committed here. |
| [`journal.md`](journal.md) | The project story, including the prototype phase and each phase's retrospective. |
| [`decisions.md`](decisions.md) | Every owner decision, with status and evidence. |

Product packets live in [`../product/`](../product/). Architecture decisions
stay in [`../adr/`](../adr/).

## Why a process now

The prototype was built from a pasted architecture design. That prompt
described *how* the system should be built (which part of the stack decides,
enforces rules, runs jobs, stores the record and serves the UI), but not *who* it is for, *what* they need to do, or what the operator
should see. The agents filled that gap with reasonable guesses, and it showed:
a strong audit and approval core, a thin operator experience, and a demo that
needed a last-minute patch.

A traditional team would have agreed on the user, the problem, the
requirements and the design first, then built. This process puts those steps
back in, compressed to fit a founder with two AI agents and a deadline.

## The team

A traditional product team for a tool like this staffs a dozen or more roles.
Here there are three participants, and the owner is accountable for every
role: security, architecture, data, release, and anything run on the owner's
machine.

| Who | Roles they cover |
|---|---|
| **Charles (owner)** | Founder and product owner, design lead, data and publication owner, customer zero, exploratory tester. Approves every gate, ADR, exception and real-model budget. Runs anything on their own machine. |
| **Claude** | Product manager, designer, tech lead, delivery manager, release and configuration manager, eval golden-set steward, backup and restore procedure, support triage, writer. Reviews anything Codex authors. |
| **Codex** | Architect, security and QA lead, compliance desk research, adversarial eval set. Reviews anything Claude authors. |
| **Gap: design partners** | Two or three solo founders to test the prototype. Without them, validation is owner-only and recorded as limited. |
| **Gap: legal counsel** | Outreach law (CAN-SPAM in the US, CASL in Canada), privacy and vendor terms. Agents flag risk but give no legal advice. No real prospect is contacted until the owner consults counsel or accepts the risk in writing. |

Agents have no unattended sudo, deployment or credential authority. The full
role-by-role table is on the map.

## Phases, packets and gates

Work is reviewed and approved as seven packets (K1 to K7), not dozens of
separate documents. Stable ids link each requirement to its design, slice,
test and evidence: **REQ → J/S (journey, screen) → SL (slice) → T/EV (test,
eval) → EVD (release evidence)**.

Dates count **weekdays only**, unless the owner agrees to weekend work.

| Phase | Weekdays (proposed) | Packet | Gate |
|---|---|---|---|
| P0 Prototype and inception | Oct 6 to 9 | K1 Charter and process | G0 Process agreed |
| P1 Discovery | Oct 8 to 9 | K2 Brief and discovery | G1 Brief approved |
| P2 Definition | Oct 12 to 13 | K3 Requirements, behaviour and evals | G2 Scope locked |
| P3 UX design | Oct 12 to 15 (design day proposed Oct 14) | K4 UX prototype and state map | G3 Prototype approved |
| P4 Technical design | Oct 14 to 16 | K5 Technical plan | G4 Design reviewed |
| P5 Release planning | Oct 16 | K6 Release plan | G5 Build approved (lifts the feature freeze) |
| P6 Build | Oct 19 to 28 (8 weekdays, two iterations) | Slice PRs and evidence | G6 Feature complete |
| P7 Verify and harden | Oct 29 to 30 | K7 part 1 | G7 Release candidate (Oct 30 target) |
| P8 Dog-food and release | Oct 30 to Nov 5 | K7 part 2 | G8 Go / no-go |
| P9 Workshop and learn | Nov 6 to 9 | K7 part 3 | G9 Next horizon agreed |

Phases overlap for drafting only. A phase cannot be approved until its inputs
are approved, and if an input changes, the work built on it is reviewed again.

Usability, accessibility, security and eval work start early (P2 and P3, and
build iteration 1), so P7 is a final integrated check, not where problems are
first found. The alternatives scan in P1 is timeboxed to two hours.

## How a gate passes

A gate passes only when its record is committed in [`gates/`](gates/) using
[`gates/TEMPLATE.md`](gates/TEMPLATE.md). The record holds:

- gate id and status;
- exact artifact revisions (commit SHAs);
- evidence (CI for the exact commit, test, eval and review reports);
- the reviewer, the verdict, and what happened to each finding;
- thresholds the gate binds (metrics, bug severities, budgets);
- the owner's approval: words, time with time zone, and where it was given;
- exceptions, each with scope and expiry;
- the next scope the gate authorizes, and nothing more.

Rules:

1. A date never passes a gate.
2. Material changes after review go back to the reviewer. Pull requests merge
   only on green CI for their exact commit. A recorded context-only range-diff
   can carry a prior approving review forward, never the CI result.
3. The owner settles disagreements between Claude and Codex, but that does not
   waive an unresolved security blocker. That needs a fix, or a written
   exception with scope and expiry backed by a recorded, independent security review of the exception and its mitigation, with a written disposition of the finding. If that review still finds it blocking, the gate stays blocked. Constraints that cannot be waived cannot be excepted at all.
4. G0 needs explicit acceptance of ADR-0014. Only explicit approval of G5
   lifts the feature freeze.
5. Process and hardening work may continue during the freeze, with no new
   authority: no deployments, credentials, real model calls or changes to the
   owner's machine.

## Constraints that cannot be waived

These stay in force at every gate unless the owner accepts an ADR that amends
them:

1. Captured delivery only. No code path may reach a real recipient or inbox.
2. Every approval is bound to the exact recipient and draft revision shown.
3. Suppression is checked before every delivery and cannot be bypassed.
4. No secret in git, logs, chat, process arguments or environment dumps.
5. The real model runs only through the locked-down Claude CLI on the owner's
   login, for personal local use, with no tools and a per-call check.
6. The audit trail is append-only.
7. Synthetic or owner-provided test data only.

**Bug severity:** P0 breaks a constraint, loses or corrupts data, or blocks
the core journey with no workaround. P1 breaks the core journey with a
workaround, or shows a wrong result. P2 degrades something outside the core
journey. P3 is cosmetic. G7 requires no open P0 or P1.

## Schedule controls

- Oct 19 to 28 has 8 weekdays, not 12 working days. The build is two
  iterations of about four weekdays.
- **Oct 30 is a target, not a commitment,** until G5 approves a plan whose
  build critical path (review, CI, fixes and acceptance of every must slice)
  ends by Oct 28. Oct 29 and 30 are planned verification and release-candidate
  days (P7), not buffer. There is no free contingency before Oct 30: the Oct 22
  scope-cut checkpoint is the protection, and question Q5 asks you to choose
  weekend work or a smaller must-list.
- **WIP limit:** one deep Codex review at a time, at most two slices in flight.
- **Rework:** plan two review rounds per packet, and two to four for slices
  touching security, data or transactions.
- **Response time:** the owner reviews a ready packet within one working day.
- **Scope-cut trigger:** fewer than half of the must slices merged by Oct 22,
  or a critical path past Oct 28, cuts scope to the minimum core journey agreed
  at G2.
- **Workshop fallback:** the last approved release tag with the fake model and
  synthetic data, plus a rehearsed walkthrough. Decided before Nov 5, so no
  last-minute live patch is ever needed.

## Release readiness

G5 defines, and G8 checks:

- supported OS and tool versions, and a fake-model-first install from a clean
  clone;
- synthetic data only; no-send negative tests;
- credential, proxy and tool isolation;
- backup **and restore**, tested end to end;
- recovery from unknown outcomes;
- cost, budget and provenance limits; any real-model evaluation budget
  approved separately by the owner;
- a rehearsed workshop fallback.

G8 also binds the release tag and commit to the evidence, publishes a
limitations list, and has the owner approve every claim the workshop will make.

## Change control after scope is locked

From G2 on, every change request goes through: request, written impact
(experience, data, authority, budget, schedule), independent review, owner
decision, then revision and re-review of the affected packets, tests and gate
records. A request never silently reopens a locked gate or widens
captured-only, synthetic-data or local-only scope.

After the workshop, Claude triages feedback and defects within two working
days, Codex reviews fixes, and the owner sets priorities.

## Publication policy

- The repository is public. Committing or pushing is publishing, and deleting
  later does not take it back.
- Never in git: credentials, keys, tokens, prospect or contact data, private
  interview notes, raw chat transcripts.
- The owner's words are quoted only with consent. So far: the build-first
  rejection quote (decision D-013).
- Design-partner notes need their consent, stay private, and only sanitized
  findings go in git.
- Session handoffs and agent working reports stay private unless sanitized.
- When unsure, keep it private and ask.

## How a piece of work moves

1. **Draft.** The author writes it on its own branch.
2. **Independent review.** The other agent reviews in writing and returns a
   verdict. Codex reviews Claude's work; Claude reviews Codex's.
3. **Revise and re-review.** Every finding is addressed; material changes go
   back to the same reviewer until no blocking finding is left.
4. **Owner review.** The owner reads or clicks through it and leaves notes. A
   note that changes substance sends it back to step 3.
5. **Approve and record.** The owner approves in chat, Claude writes the gate
   record, and the PR merges on green CI for that exact commit.

## Owner notes on the interactive pages

Notes typed on the map are kept in that browser only. If the browser cannot
save them (private windows, blocked storage, some embedded viewers), the page
says so in red and the notes will be lost on reload. Copy them (or download
them, when the page is opened directly from the repository) and paste them to
Claude. Every export names the data revision and a fingerprint of the exact
data shown.

Notes are feedback, not approvals, and they are not in git until Claude
commits them. Approvals are given in chat and written into a gate record.

## Cadence

- **Daily status** each working morning in chat.
- **Gate review** at the end of each phase.
- **Design critique** during UX design.
- **Iteration demo** at the end of each build iteration, live in the app.
- **Retrospective** at the end of each phase: three lines, in the journal.

## Open questions for the owner

These are also on the map, with space to answer.

1. Do we work weekends? Which day is the design day (proposed Oct 14)?
2. Can you recruit two or three solo founders for a 30-minute prototype test
   around Oct 15?
3. How do you prefer to review: notes on the interactive pages, a Claude Doc
   with comments, or GitHub PR comments?
4. Beyond the build-first quote you chose to keep, may we quote your original
   prompt, your discovery answers or other chat messages in git?
5. Weekdays only leave 8 build days (Oct 19 to 28) and no slack before the
   Oct 30 target. Do you prefer weekend work, or a smaller must-list?
