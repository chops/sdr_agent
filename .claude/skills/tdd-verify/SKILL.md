---
name: tdd-verify
description: Verify tests fail correctly for TDD gate. Use between Phase 4a and 4b.
allowed-tools: Bash(mix:*, bash:*), Read
---

# TDD Verification

Verifies that tests fail correctly before implementation begins. This is the gate between Phase 4a (write tests) and Phase 4b (implement).

## Arguments

- `$ARGUMENTS` - Test file or path to verify (required)

## Execution

```bash
bash "${CLAUDE_PROJECT_DIR:-.}/bin/tdd_verify.sh" $ARGUMENTS
```

## Verification Statuses

| Status | Exit Code | Meaning | Action |
|--------|-----------|---------|--------|
| **VERIFIED** | 0 | Tests fail with assertion errors | Proceed to Phase 4b |
| **NEEDS_REVIEW** | 1 | Tests fail but not cleanly | Human must confirm |
| **BLOCKED** | 2 | Tests pass or don't compile | Cannot proceed |

## What Makes Tests "Verified Failing"

Tests are verified failing when ALL conditions are met:

- Tests compile and execute (no syntax/import errors)
- Tests fail with `ExUnit.AssertionError` (not crashes)
- Failure messages indicate missing implementation
- Zero tests pass unexpectedly

## Output Format

```
TDD Verification: [STATUS]

Summary:
- Total tests: N
- Failures: N
- Assertion failures: N
- Runtime errors: N

Reason: [explanation]

Gate Decision: [PROCEED / REVIEW / BLOCKED]
```

## Artifacts

Results written to `tmp/ai/tdd_verify/`:
- `verify_result.md` - Summary and gate decision
- `test_output_*.txt` - Complete test output
- `failure_details.txt` - Extracted failure information
- `compile_*.txt` - Compilation output

## After Running

1. Read the verification status
2. If VERIFIED: Proceed to Phase 4b implementation
3. If NEEDS_REVIEW: Present findings to human for confirmation
4. If BLOCKED: Do not proceed; investigate the issue

## Common Issues

| Issue | Cause | Resolution |
|-------|-------|------------|
| Tests pass | Feature already implemented | Investigate; strengthen assertions |
| Runtime errors | Missing module/function | Fix test imports and setup |
| No tests found | Wrong path | Verify test file exists |
| Compilation failure | Syntax error in test | Fix test file syntax |
