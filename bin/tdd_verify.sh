#!/bin/bash
# tdd_verify.sh - Verifies tests fail correctly for TDD gate
# Usage: tdd_verify.sh <test_file_or_path>
# Outputs: tmp/ai/tdd_verify/
#
# Exit codes:
#   0 = VERIFIED (tests fail with assertion errors, proceed to Phase 4b)
#   1 = NEEDS_REVIEW (tests fail but need human review)
#   2 = BLOCKED (tests pass or don't compile, cannot proceed)

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
OUTPUT_DIR="$PROJECT_DIR/tmp/ai/tdd_verify"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TEST_PATH="${1:-}"

mkdir -p "$OUTPUT_DIR"

if [ -z "$TEST_PATH" ]; then
    echo "ERROR: No test path provided"
    echo "Usage: tdd_verify.sh <test_file_or_path>"
    exit 2
fi

cd "$PROJECT_DIR" || exit 2

echo "=== TDD Verification ==="
echo "Test path: $TEST_PATH"
echo "---"

# Step 1: Verify project compiles
echo ""
echo "Step 1: Checking compilation..."
COMPILE_OUTPUT="$OUTPUT_DIR/compile_$TIMESTAMP.txt"
if ! mix compile 2>&1 | tee "$COMPILE_OUTPUT"; then
    echo ""
    echo "BLOCKED: Compilation failed. Tests cannot be verified."
    cat > "$OUTPUT_DIR/verify_result.md" << EOF
# TDD Verification: BLOCKED

**Generated:** $TIMESTAMP
**Test Path:** $TEST_PATH

## Reason: Compilation Failure

Tests cannot be verified because the project does not compile.

## Action Required

Fix compilation errors before proceeding to Phase 4a.

## Compile Output

See: compile_$TIMESTAMP.txt
EOF
    cat "$OUTPUT_DIR/verify_result.md"
    exit 2
fi

# Step 2: Run tests and capture output
echo ""
echo "Step 2: Running tests..."
TEST_OUTPUT="$OUTPUT_DIR/test_output_$TIMESTAMP.txt"
mix test "$TEST_PATH" --trace 2>&1 | tee "$TEST_OUTPUT"
TEST_EXIT=${PIPESTATUS[0]}

# Step 3: Analyze results
echo ""
echo "Step 3: Analyzing results..."

# Extract test counts from output
TESTS_LINE=$(grep -E "^[0-9]+ (tests?|doctest)" "$TEST_OUTPUT" | tail -1 || echo "")
if [ -n "$TESTS_LINE" ]; then
    TOTAL_TESTS=$(echo "$TESTS_LINE" | grep -oE "^[0-9]+" || echo "0")
    FAILURES=$(echo "$TESTS_LINE" | grep -oE "[0-9]+ failures?" | grep -oE "[0-9]+" || echo "0")
else
    TOTAL_TESTS="0"
    FAILURES="0"
fi

# Count assertion errors vs runtime errors
# Note: grep -c outputs "0" on no matches but exits 1, so use || VAR=0 pattern
ASSERTION_FAILURES=$(grep -c "AssertionError\|assert.*failed\|refute.*failed\|Expected\|expected" "$TEST_OUTPUT" 2>/dev/null) || ASSERTION_FAILURES=0
RUNTIME_ERRORS=$(grep -c "\*\* (" "$TEST_OUTPUT" 2>/dev/null) || RUNTIME_ERRORS=0
# Subtract assertion errors from runtime error count (they also match ** pattern)
ASSERTION_MATCHES=$(grep -c "\*\* (ExUnit.AssertionError)" "$TEST_OUTPUT" 2>/dev/null) || ASSERTION_MATCHES=0
ACTUAL_RUNTIME_ERRORS=$((RUNTIME_ERRORS - ASSERTION_MATCHES))
if [ "$ACTUAL_RUNTIME_ERRORS" -lt 0 ]; then
    ACTUAL_RUNTIME_ERRORS=0
fi

# Extract failure details for summary
FAILURE_DETAILS="$OUTPUT_DIR/failure_details.txt"
grep -A 10 "^\s*[0-9]*)" "$TEST_OUTPUT" > "$FAILURE_DETAILS" 2>/dev/null || echo "No detailed failures captured" > "$FAILURE_DETAILS"

# Determine verification status
if [ "$TEST_EXIT" -eq 0 ]; then
    # Tests passed - BAD for TDD verification
    VERIFY_STATUS="BLOCKED"
    REASON="Tests passed unexpectedly. The feature may already be implemented, or test assertions are too weak."
    GATE_DECISION="Cannot proceed to Phase 4b. Investigate why tests pass."
    FINAL_EXIT=2
elif [ "$TOTAL_TESTS" -eq 0 ]; then
    # No tests found
    VERIFY_STATUS="BLOCKED"
    REASON="No tests found at the specified path."
    GATE_DECISION="Cannot proceed. Ensure tests exist at: $TEST_PATH"
    FINAL_EXIT=2
elif [ "$ASSERTION_FAILURES" -gt 0 ] && [ "$ACTUAL_RUNTIME_ERRORS" -eq 0 ]; then
    # All failures are assertion-based - GOOD
    VERIFY_STATUS="VERIFIED"
    REASON="All $FAILURES test(s) fail with assertion errors as expected for TDD."
    GATE_DECISION="PROCEED to Phase 4b. Tests are verified failing."
    FINAL_EXIT=0
elif [ "$ACTUAL_RUNTIME_ERRORS" -gt 0 ] && [ "$ASSERTION_FAILURES" -gt 0 ]; then
    # Mix of assertion and runtime errors - needs review
    VERIFY_STATUS="NEEDS_REVIEW"
    REASON="Tests fail with a mix of assertion errors ($ASSERTION_FAILURES) and runtime errors ($ACTUAL_RUNTIME_ERRORS). Runtime errors may indicate test setup issues."
    GATE_DECISION="Human review required. Fix runtime errors or confirm they're expected."
    FINAL_EXIT=1
elif [ "$ACTUAL_RUNTIME_ERRORS" -gt 0 ]; then
    # Only runtime errors - likely test setup issue
    VERIFY_STATUS="NEEDS_REVIEW"
    REASON="Tests fail with runtime errors only (no assertion failures). This usually indicates missing test setup, undefined modules, or incorrect imports."
    GATE_DECISION="Human review required. Likely need to fix test file before proceeding."
    FINAL_EXIT=1
else
    # Fallback - tests fail but unclear why
    VERIFY_STATUS="NEEDS_REVIEW"
    REASON="Tests fail but failure type unclear. Manual review recommended."
    GATE_DECISION="Human review required."
    FINAL_EXIT=1
fi

# Write verification result
cat > "$OUTPUT_DIR/verify_result.md" << EOF
# TDD Verification: $VERIFY_STATUS

**Generated:** $TIMESTAMP
**Test Path:** $TEST_PATH

## Summary

| Metric | Value |
|--------|-------|
| Total tests | $TOTAL_TESTS |
| Failures | $FAILURES |
| Assertion failures | $ASSERTION_FAILURES |
| Runtime errors | $ACTUAL_RUNTIME_ERRORS |
| Test exit code | $TEST_EXIT |

## Reason

$REASON

## Gate Decision

**$GATE_DECISION**

## Artifacts

- \`test_output_$TIMESTAMP.txt\` - Complete test output
- \`failure_details.txt\` - Extracted failure information
- \`compile_$TIMESTAMP.txt\` - Compilation output

## Location

\`\`\`
$OUTPUT_DIR/
\`\`\`
EOF

echo ""
echo "=== TDD VERIFICATION COMPLETE ==="
echo ""
cat "$OUTPUT_DIR/verify_result.md"

exit $FINAL_EXIT
