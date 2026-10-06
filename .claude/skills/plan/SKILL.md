---
name: plan
description: Design before implement - explore codebase and create implementation plan. Use before any non-trivial changes.
allowed-tools: Read, Grep, Glob, Task, LSP
---

# Implementation Plan

Create a detailed implementation plan before making changes. This is a **read-only** exploration phase - no file edits allowed.

## Workflow

1. **Understand the request** - Clarify scope and constraints
2. **Entity Model evaluation** - Evaluate the Entity Model trigger (see `AGENTS.md` "Entity Model" and the `entity-discovery` skill) *before* looking at affected modules — the model should inform module boundaries, not be backfilled after. If triggered: produce the table, then use the configured independent reviewer (`ai_pair`, `codex_review`, or explicit human sign-off) for the soft-stop (PASS/NEEDS-REVIEW/BLOCKED/UNREVIEWED) before continuing. Follow the precedence in `entity-discovery`; UNREVIEWED blocks Phase 3 outright and self-review never counts. If not triggered: record `Entity Model trigger: no` + a one-line reason (never omit the field).
3. **Identify affected modules** - Find relevant files, resources, actions
4. **Analyze existing patterns** - Understand current implementation approach
5. **List 3-7 minimal steps** - Concrete, actionable implementation steps
6. **Identify required tests** - What tests need to be added/modified
7. **Call out risks** - Edge cases, breaking changes, policy implications
8. **ADR evaluation** - Does this plan make an architectural decision? (see `AGENTS.md` "Architecture Decisions"). If YES → create ADR with status "Proposed" in `docs/adr/` and reference it in the plan. If NO → state "No ADR required" with brief justification.
9. **Wait for human approval** - Do NOT proceed to implementation

## Exploration Tools

Use these tools to understand the codebase:

- `Grep` - Find usage patterns, references, implementations
- `Glob` - Locate relevant files by pattern
- `Read` - Examine file contents
- `LSP` - Find definitions, references, implementations
- `Task` (Explore) - Delegate complex codebase exploration

## Output Format

Present the plan in this structure:

```markdown
## Summary
One sentence describing what will be implemented.

## Entity Model
`Entity Model trigger: yes | no`
`Reason: <one line>`

If triggered: the entity/attribute/relationship/invariant table (see the
`entity-discovery` skill for the column spec and existing-side delta rule),
followed by the soft-stop verdict (PASS/NEEDS-REVIEW/BLOCKED/UNREVIEWED).
If not triggered: the reason line above is sufficient, nothing else needed.

## Affected Modules
- `path/to/file.ex` - Brief description of changes

## Implementation Steps
1. Step with specific file:line references
2. Step with specific file:line references
3. ...

## Required Tests
- [ ] Test scenario 1
- [ ] Test scenario 2

## Risks & Considerations
- Risk or edge case to consider

## ADR
- **Required:** YES / NO
- **Justification:** [Why this is/isn't an architectural decision — reference the project doctrine triggers]
- **ADR file:** `docs/adr/NNNN-title.md` (if required)

## Questions (if any)
- Clarification needed before proceeding
```

## Constraints

- **NO file edits** - This is exploration only
- **NO implementation** - Plan first, implement after approval
- **Smallest change** - Plan should achieve goal with minimal diff
- **Ash boundaries** - Respect domain/resource/action separation
- **Test coverage** - Every behavior change needs a test
- **Entity model first** - Resolve the Entity Model section before Affected Modules; when triggered, an UNREVIEWED soft-stop blocks Phase 3

## After Planning

Wait for explicit approval before proceeding to implementation. The human must confirm the plan is acceptable before any edits begin.
