---
name: entity-discovery
description: Discover and document the entities, attributes, relationships, invariants, and lifecycle rules a change touches, before implementation starts. Use during Phase 1/2 planning when the Entity Model trigger fires, or standalone to map a domain ("map out the entities for X").
allowed-tools: Read, Grep, Glob, Write, Edit, Bash(*)
---

# Entity Discovery

Produces the Entity Model artifact: an inline org table (or Markdown table
in a legacy `.md` plan) enumerating the domain entities a change touches —
never a separate file. The trigger list and lifecycle belong to the project's
`AGENTS.md` "Entity Model" section.

## When Invoked From `plan`

The `plan` skill evaluates the Entity Model trigger during Phase 1/2. When
it fires, `plan` invokes this skill's table-building + soft-stop logic
inline, before writing "Affected Modules." This skill does not write a
separate file in that case — its output becomes a section of the plan
document already being authored.

## When Invoked Standalone

("Map out the entities for X", "discover the domain model for Y") — walk
the same table-building process below, then either:
- insert the result into an existing plan's Entity Model section (`Edit`
  the relevant `notes/features/*.org` or `*.md` file), or
- if there's no plan document yet, return the table directly so the caller
  can decide where it belongs.

## Trigger Evaluation (do this first, always)

Require the table when the change:
- Introduces or changes a persisted domain concept
- Adds/changes a persisted domain entity or record
- Adds/changes a meaningful attribute or invariant (tightening an existing
  constraint counts — a bug fix that adds a missing validation is in scope)
- Adds/changes a relationship or its cardinality
- Adds/changes an ownership or authorization boundary
- Adds/changes a state transition (action/lifecycle rule)
- Adds/changes a backend action or event contract — even when the
  surfacing request reads as "just UI" (a status badge that needs a new
  enum attribute is not UI-only)

**"Meaningful attribute" scope:**
- *Included:* persisted fields, enums/types, calculations, aggregates,
  embedded/value objects, action arguments that shape persisted state.
- *Excluded:* purely presentational/derived client-side values with no
  server contract.

**Escape hatch** — only when none of the above apply (template/markup,
CSS/Tailwind, component layout, static copy, client-side JS hooks,
reordering already-exposed data, and *no* new/changed resource, attribute,
calculation, aggregate, relationship, identity, policy, action, or backend
event contract):

```
Entity Model trigger: no
Reason: no new/changed attributes, relationships, calculations, aggregates,
policies, actions, or backend event contracts; change is Tailwind/copy only.
```

This field is always literally present — `trigger: yes` or `trigger: no`
plus a one-line reason. A missing field means the evaluation wasn't done,
not a valid skip.

## Table Spec

Columns:

| Column | Purpose |
|--------|---------|
| Entity | Name of the domain concept |
| New / Existing | Net-new, or a change to something already modeled? |
| Purpose | One line: why this entity exists |
| Attributes | `name : type, required/nullable, default, identity/unique, constraint` |
| Relationships | direction, cardinality, optionality (separate from cardinality), identity/unique scope, FK source/destination, delete/ownership behavior |
| Invariants / Lifecycle | allowed state transitions, terminal states, transition guards, side effects — not the same as Policy/Actor |
| Policy/Actor | who can invoke which action, under what condition |
| Open Questions | anything unresolved that blocks implementation |

**Scale to the change:** small triggered changes get a delta — only
new/changed rows, never a full redraw of an untouched-but-adjacent
resource.

**Existing-side delta rule:** if a new/changed relationship affects an
existing entity's cardinality, ownership, or policy, that existing entity
gets its own delta row. To skip the row, the note must be the literal form
`existing dependency: unchanged — relationship/policy/lifecycle impact
checked, none found` — free-form "unchanged because..." prose does not
satisfy this rule; it's itself a new escape hatch.

A diagram (Mermaid `erDiagram`) may be added as an optional supplement for
a non-trivial graph, but it is never the source of truth — it can't express
implementation-level constraints and policies, and it drifts easily. The table is the
contract.

## Soft-Stop Review (only when `trigger: yes`)

Before the caller proceeds to "Affected Modules," the table gets an
independent adversarial pass. Read `capabilities.ai_pair` and
`capabilities.codex_review` from `.workflow/recipe.json` when present; a
missing capability is unavailable, never silently enabled.

### Reviewer precedence

1. When `ai_pair=true`, review through `ap` (ai-pair peer protocol):
   - Generate a unique `msg_id` (`m_<epoch_ns>_<random hex>`) and RFC3339 UTC
     `ts`.
   - Write a `schema_version: "1.0"`, `kind: "ask"` envelope containing the
     table, `from.agent: "claude"`, `to.agent: "codex"`.
   - Stage under `$AI_PAIR_INBOX/outbox/<ts>-<msg_id>.json`, then atomically
     rename it into `$AI_PAIR_INBOX/inbox/`.
   - Wake the peer with `ap send`; poll inbox and processed trees for a
     correlated Codex reply until the monotonic 600-second deadline.
2. Otherwise, when `codex_review=true`, use the installed Codex plugin to
   launch an independent Codex subagent with the table and review rubric.
   Record the subagent invocation identifier and its verbatim verdict.
3. Otherwise, request explicit human sign-off. Record the named reviewer,
   timestamp, and explicit verdict in the plan. An inferred acknowledgement
   or the author approving their own table does not count.

No self-review. Do not skip a configured higher-precedence reviewer merely
because a lower-precedence reviewer is easier to reach. If the selected
reviewer is unavailable or times out, record `UNREVIEWED`; do not silently
fall through after a failed attempt.

Verdicts:
   - **PASS** — proceed to Affected Modules.
   - **NEEDS-REVIEW** — address each flagged concern (accept with stated
     reasoning, or revise), then re-run this soft-stop.
   - **BLOCKED** — a concrete defect was found; revise the table, then
     re-run this soft-stop.
   - **UNREVIEWED** — the selected reviewer is unavailable, times out, or
     supplies no explicit verdict. **This blocks Phase 3 outright.** Say so
     plainly rather than proceeding.

Record the configured capabilities, reviewer kind, reviewer identity or
correlation/invocation ID, evidence timestamp, and verdict inline in the plan,
never in a separate file.

## Retroactive Scope (Non-Goals)

- No backfill requirement — a pre-existing, untouched resource never needs
  its full model retroactively documented, only what's changing now.
- A bug fix that corrects an invariant (e.g. adding a missing format
  constraint) *does* trigger — intentional, not a loophole.
- Reverse-generation of tables for already-existing entities is a distinct,
  not-yet-built tool — not part of this gate.

## Output Format

When producing a fresh table (standalone or for a new plan), return:
- The trigger decision (`trigger: yes/no` + reason)
- The table (org syntax by default; Markdown pipe table if editing a
  legacy `.md` plan)
- The soft-stop verdict, if the trigger fired
- Path to the plan document the table now lives in, or a note that no plan
  exists yet and the caller should create one
