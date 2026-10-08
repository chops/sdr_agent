# From demo to product: the SDR Agent development process

Status: **proposed** (v0.1, 2026-10-08). Becomes the working process when the
owner approves gate G0.

This folder records how SDR Agent goes from a one-shot prototype to a product
that could eventually run in production. It is written for two audiences: the
three of us doing the work, and founders who want to see how a solo founder can
run a traditional software process with AI agents as the team.

| File | What it is |
|---|---|
| [`index.html`](index.html) | Interactive map: phases on a timeline, each phase's activities, artifacts and gate, who does what, and a notes panel for owner feedback. Open it in a browser from this folder. A private hosted copy for the owner: https://claude.ai/artifact/ScAk7wEuMjD5nPUZdWLKGj |
| [`sdlc-data.js`](sdlc-data.js) | The data behind the map. This is the detailed, versioned record of the process and its status. |
| [`journal.md`](journal.md) | The project story, including the prototype phase and each phase's retrospective. |
| [`decisions.md`](decisions.md) | Every owner decision: what, when, why, and what was rejected. |

Product artifacts (brief, requirements, designs, plans) live in
[`../product/`](../product/). Architecture decisions stay in
[`../adr/`](../adr/).

## Why a process now

The prototype was built from a pasted architecture design. That prompt
described *how* the system should be built (Jido decides, Ash governs, Oban
executes, Postgres remembers, OTP keeps it alive, Phoenix lets humans operate
it), but not *who* it is for, *what* they need to do, or what the operator
should see. The agents filled that gap with reasonable guesses, and it showed:
a strong audit and approval core, a thin operator experience, and a demo that
needed a last-minute patch.

A traditional team would not have started there. It would have agreed on the
user, the problem, the requirements and the design first, then built. This
process puts those steps back in, compressed to fit a founder with two AI
agents and a deadline.

## The team

A traditional product team for a tool like this would staff about a dozen
roles. Here there are three participants and two gaps.

| Who | Roles they cover |
|---|---|
| **Charles (owner)** | Founder and product owner, design lead (visual direction and taste), customer zero, exploratory tester, final approver of every gate. |
| **Claude** | Product manager, product designer, tech lead and delivery manager, technical writer; builds slices through subagents. |
| **Codex** | Architect and security reviewer, QA lead, compliance desk research, eval red-teamer; builds slices it is assigned. |
| **Gap: design partners** | Two or three solo founders to test the prototype. Without them, only the owner and two agents check the design. |
| **Gap: legal counsel** | Outreach law (CAN-SPAM in the US, CASL in Canada), privacy and vendor terms. Agents can flag risk but cannot give legal advice. Nothing contacts a real prospect until the owner consults counsel or accepts the risk in writing. |

The full role-by-role mapping is in the map's "The team" section.

## The phases

Each phase ends with a gate. Only the owner approves a gate.

| Phase | Dates (proposed) | Produces | Gate |
|---|---|---|---|
| P0 Prototype and inception | Oct 6 to 8 | Playbook, map, journal, decision log, prototype assessment, product-phase charter | G0 Process agreed |
| P1 Discovery | Oct 7 to 9 | Questionnaire and answers, persona, competitive scan, assumptions map, product brief | G1 Brief approved |
| P2 Definition | Oct 9 to 11 | Requirements with acceptance criteria, non-functional requirements, agent behaviour spec, eval plan, compliance desk review | G2 Scope locked |
| P3 UX design | Oct 10 to 14 | Screen inventory, journey and state map, wireframes, design-day directions, tokens, clickable prototype, usability findings | G3 Prototype approved |
| P4 Technical design | Oct 12 to 15 | Gap analysis, technical design, ADRs, entity-model delta, threat model, test strategy | G4 Design reviewed |
| P5 Release planning | Oct 15 | Slice plan and board, risk register, definitions of ready and done, release criteria | G5 Build approved (feature freeze lifts) |
| P6 Build | Oct 16 to 27 | Slices merged in about three four-day iterations, each ending in a live demo | G6 Feature complete |
| P7 Verify and harden | Oct 28 to 30 | Acceptance, eval, security and accessibility reports; release candidate | G7 Release candidate |
| P8 Dog-food and release | Oct 30 to Nov 5 | Dog-food log, install guide, workshop runbook, release notes | G8 Go / no-go |
| P9 Workshop and learn | Nov 6 to 9 | Feedback synthesis, retrospective, production roadmap, founder case study | G9 Next horizon agreed |

Phases overlap where a traditional team would also overlap them: technical
design starts once wireframes exist, and the design day sits inside UX design.

**The trade-off in this schedule.** A traditional team would spend four to
eight weeks on discovery through planning for a first release. The agents draft
fast, so here it takes about a week. The bottleneck is the owner's review time
and Codex's review throughput, not drafting. Every planning day still comes out
of the build window, which is why the must-list is expected to shrink at G2.

## How a piece of work moves

Every artifact, from the brief to a pull request, goes through the same steps:

1. **Draft.** The author writes it in the repository on its own branch.
2. **Peer review.** The other agent reviews it in writing and returns a verdict.
   Author and reviewer are never the same agent.
3. **Owner review.** The owner reads or clicks through it and leaves notes,
   either in the interactive pages (copied into chat) or directly in chat.
4. **Revise.** The author addresses every note. Disagreements between Claude
   and Codex go to the owner with both positions stated.
5. **Approve and commit.** The owner approves, the PR merges, and
   [`decisions.md`](decisions.md) records the decision.

## Cadence

- **Daily status** in chat: what moved, what is blocked, what needs the owner.
- **Gate review** at the end of each phase.
- **Design critique** during UX design.
- **Iteration demo** about every four days during the build, live in the app.
- **Retrospective** at the end of each phase: three lines, recorded in the
  journal.

## Working agreements

1. Author and reviewer are never the same agent.
2. Only the owner approves a gate, an ADR, an exception or a real-model budget.
   Agents never infer approval.
3. Everything durable lives in git: artifacts, decisions, feedback and
   retrospectives.
4. The feature freeze holds until gate G5. Hardening and process work may
   continue.
5. Disagreements between Claude and Codex go to the owner with both positions,
   not a merged compromise.
6. Nothing in this release touches a real prospect, a real inbox or a real send
   path.

## Interactive artifacts

Phases that benefit from clicking rather than reading get an HTML page next to
their markdown. Planned pages: this process map, the operator journey and state
map, wireframes, the design-day directions, the clickable prototype and the
release-plan board. Each page:

- renders from a data file committed beside it, so its content is reviewable
  in a diff;
- opens straight from the repository folder, with no build step or server;
- keeps owner notes in the browser until they are copied into chat, after which
  Claude commits them, so feedback ends up in git too.

## Open questions for the owner

These are also on the map, with space to answer.

1. Do we work weekends, and which day is the design day?
2. Can you recruit two or three solo founders for a 30-minute prototype test
   around Oct 13 to 14?
3. How do you prefer to review: notes on the interactive pages, a Claude Doc
   with comments, or GitHub PR comments?
4. May we quote your original prompt, your discovery answers and your chat
   messages verbatim in git? The draft journal already quotes one message.
5. Is a build window of about 12 days acceptable, given the must-list may
   shrink at G2?
