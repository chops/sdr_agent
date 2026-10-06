---
name: pr-ready
description: Verify pre-merge checklist before PR creation. Use before creating PRs.
allowed-tools: Bash(mix:*), Bash(git:*), Read, Grep
---

# PR Readiness Check

Verify all pre-merge requirements before creating a pull request.

## Checklist Execution

Run each check and report status:

### 1. Code Quality
```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict  # if installed
```

### 2. Tests
```bash
mix test
```

### 3. Security (if installed)
```bash
mix sobelow --config
mix deps.audit
```

### 4. Architecture Artifacts
- Check if the plan for this work required an ADR (look at `notes/features/` or `notes/fixes/` for the plan's ADR section)
- If required: verify ADR exists in `docs/adr/` with status "Accepted"
- If architecture changed: verify maintained diagrams were updated according to the project doctrine

### 5. Type Checking (if configured)
```bash
mix dialyzer
```

### 6. Git State
```bash
git status
git log --oneline main..HEAD
```

## Output Format

```markdown
## PR Readiness Report

| Check | Status | Notes |
|-------|--------|-------|
| Format | PASS/FAIL | |
| Compile | PASS/FAIL | warnings count |
| Credo | PASS/FAIL/SKIP | issue count |
| Tests | PASS/FAIL | X passed, Y failed |
| Sobelow | PASS/FAIL/SKIP | findings count |
| ADR | PASS/FAIL/SKIP | Accepted / missing / not required |
| Diagrams | PASS/FAIL/SKIP | updated / not required |
| Dialyzer | PASS/FAIL/SKIP | errors count |

## Blocking Issues
- [List any FAIL items that must be resolved]

## Commit Summary
- [Brief description of changes in this PR]

## Ready for PR: YES/NO
```

## Constraints

- All PASS required for "Ready: YES"
- SKIP is acceptable (tool not installed)
- FAIL blocks PR creation
- No secrets in diff (check for .env, credentials, tokens)

## If Not Ready

List specific failures and remediation steps. Do not create PR until all checks pass.

## If Ready

Suggest PR title and body format:
```markdown
## Summary
[1-3 bullet points]

## Test plan
[How to verify the changes]
```
