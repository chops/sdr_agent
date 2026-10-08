# Project journal

The story of SDR Agent in the order it happened, with a short retrospective at
the end of each phase. Written for founders who want to see what the process
looked like from the inside, including the parts that went wrong.

## Phase 0: the prototype (Oct 6 to 8, 2026)

### The starting point

On Oct 6 the owner pasted a detailed architecture design for an AI sales
development representative (SDR) into a project scaffolding tool. Its core
rule gave each part of the stack one job: the agent framework makes
decisions, the domain layer enforces the rules, a job queue runs work
durably, the database keeps the record, the runtime keeps it alive, and the
web UI lets people operate it. (The prompt's exact wording stays out of git
until the owner answers question Q4.)

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

### Retrospective (draft, to be confirmed at G0)

- **Worked:** a written mandate, small slices, test-first work and mandatory
  peer review produced a robust core (audit trail, approval binding, durable
  jobs) very quickly.
- **Did not work:** starting from an architecture prompt instead of a product
  definition. The engine was built before anyone had decided what the operator
  should see, so the UI was thin and the demo needed a patch.
- **Change:** define the user, requirements and design before building more,
  and keep the owner in the loop at every gate instead of only at checkpoints.
