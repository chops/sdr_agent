---
name: review
description: Review code changes with categorized feedback. Use for PR review or self-review before commits.
allowed-tools: Read, Grep, Glob, Bash(git diff:*), Bash(git log:*), Bash(git show:*)
---

# Code Review

Perform strict diff review with categorized output. This is a **read-only** skill—no edits allowed.

## Scope

Review can target:
- Staged changes: `git diff --cached`
- Unstaged changes: `git diff`
- Branch diff: `git diff main...HEAD`
- Specific commits: `git show <sha>`

## Review Checklist

### Ash Boundaries
- [ ] No direct struct mutations
- [ ] No lower-level persistence mutations on Ash resources
- [ ] Actions are explicit and policy-protected
- [ ] Domain boundaries respected

### Correctness
- [ ] Logic matches intent
- [ ] Edge cases handled
- [ ] Error paths covered
- [ ] No silent failures

### Security
- [ ] Policies not weakened
- [ ] No secrets in diff
- [ ] Authorization checks present
- [ ] Input validation at boundaries

### Testing
- [ ] New behavior has tests
- [ ] Policy tests include allow AND deny
- [ ] Tests use domain API, not internals

### Architecture Artifacts
- [ ] ADR created if architectural decision was made (see `AGENTS.md` "Architecture Decisions")
- [ ] ADR status is "Accepted" (not still "Proposed")
- [ ] Architecture diagrams updated if structure changed

### Style
- [ ] Formatted (`mix format`)
- [ ] No warnings (`mix compile --warnings-as-errors`)
- [ ] Clear naming
- [ ] No dead code

## Output Format

Categorize findings:

```markdown
## must_fix
- [file:line] Issue description (blocking)

## important
- [file:line] Issue description (should address)

## optional
- [file:line] Suggestion (nice to have)

## summary
Brief overall assessment.
```

## Constraints

- **Read-only** — no edits during review
- **Be specific** — include file:line references
- **Be decisive** — categorize clearly, don't hedge
- **Ash-first lens** — prioritize domain integrity
