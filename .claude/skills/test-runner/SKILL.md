---
name: test-runner
description: Run tests with structured output and failure summaries. Use when running tests, checking test status, or debugging test failures.
allowed-tools: Bash(*), Read
---

# Test Runner

Run the test runner script to execute tests with structured artifact output.

## Arguments

- `$ARGUMENTS` - Optional: specific test file/path and extra mix test args
  - Example: `test/my_app/my_test.exs:42` - Run specific test
  - Example: `test/` - Run the whole suite (umbrella: `apps/my_app/test/` for one app)
  - Example: `--only integration` - Run tagged tests

## Execution

```bash
bash "${CLAUDE_PROJECT_DIR:-.}/bin/test_runner.sh" $ARGUMENTS
```

## After Running

1. Check the exit code (0 = pass, non-zero = fail)
2. Review artifacts in `tmp/ai/test_runner/`:
   - `summary.md` - Pass/fail status and counts
   - `full_output_*.txt` - Complete test output
   - `failures.txt` - Extracted failure details
   - `slow_tests.txt` - Performance data if available

## Output Format

Return a 5-10 bullet summary including:
- PASS/FAIL status
- Test counts (total, failures)
- List of failing tests (if any) with file:line references
- Brief description of failure reasons
- Path to full output for details

Do NOT paste full test output. Summarize and reference artifact paths.
