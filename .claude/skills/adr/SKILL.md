---
name: adr
description: Create Architecture Decision Record for documenting decisions. Use when making architectural choices.
allowed-tools: Read, Glob, Write
---

# Architecture Decision Record (ADR)

Creates structured ADR documents to record architectural decisions.

## Location

ADRs are stored in `docs/adr/` with sequential numbering:
- `0000-adr-template.md` - Reference template (reserved)
- `0001-[decision-name].md` - First decision
- `0002-[decision-name].md` - Second decision
- etc.

## Workflow

### 1. Determine Next Number

```bash
# Find highest existing ADR number
ls docs/adr/*.md 2>/dev/null | grep -oE '[0-9]{4}' | sort -n | tail -1
```

If no ADRs exist, start with `0001`.

### 2. Create ADR File

Use the template structure below. File name format: `NNNN-kebab-case-title.md`

### 3. Set Initial Status

- **Proposed**: When created during planning (Phase 2)
- **Accepted**: When plan is approved (Phase 3)

## Template Structure

```markdown
---
status: proposed
date: YYYY-MM-DD
supersedes: null
---

# ADR-NNNN: [Title]

## Status

Proposed

## Context

[Problem, forces, constraints, business needs that prompted this decision.
What is the issue that motivates this decision or change?]

## Options Considered

### Option 1: [Name]

[Description of the option]

**Pros:**
- ...

**Cons:**
- ...

### Option 2: [Name]

[Description of the option]

**Pros:**
- ...

**Cons:**
- ...

## Decision

[Chosen solution, clearly stated. Start with "We will..." or "We have decided to..."]

## Justification

[Reasoning behind selection, explaining the trade-offs made.
Why was this option chosen over the alternatives?]

## Consequences

### Positive

- [Expected benefits]

### Negative

- [Accepted downsides, risks, or costs]

### Neutral

- [Side effects that are neither good nor bad]
```

## Status Transitions

| From | To | When |
|------|-----|------|
| Proposed | Accepted | Plan containing ADR is approved |
| Accepted | Deprecated | Decision no longer applies (not replaced) |
| Accepted | Superseded | New ADR replaces this one |

When superseding, update the old ADR's status and add `superseded_by: NNNN` to frontmatter.

## When to Create ADR

**Create ADR when:**
- Multiple approaches were explicitly compared
- Choosing between technologies, patterns, or libraries
- Decision constrains future options (lock-in)
- Trade-off analysis was performed
- Deviating from established patterns

**Do NOT create ADR for:**
- Implementation details within established patterns
- Bug fixes
- Routine features using existing patterns
- Refactoring without architectural impact

## Output Format

After creating ADR, report:
- ADR number and title
- File path
- Summary of decision
- Status (Proposed/Accepted)

Example:
```
Created ADR-0003: Use PostgreSQL for Primary Database
Path: docs/adr/0003-use-postgresql-for-primary-database.md
Decision: PostgreSQL for ACID compliance and Ash integration
Status: Proposed (pending plan approval)
```
