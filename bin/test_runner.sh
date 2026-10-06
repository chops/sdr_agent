#!/bin/bash
# test_runner.sh - Runs tests with structured output
# Usage: test_runner.sh [test_path] [extra_args...]
# Outputs: tmp/ai/test_runner/

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
OUTPUT_DIR="$PROJECT_DIR/tmp/ai/test_runner"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TEST_PATH="${1:-}"
shift 2>/dev/null || true
EXTRA_ARGS="$*"

mkdir -p "$OUTPUT_DIR"

# Build test command
if [ -n "$TEST_PATH" ]; then
    TEST_CMD="mix test $TEST_PATH $EXTRA_ARGS"
else
    TEST_CMD="mix test $EXTRA_ARGS"
fi

echo "Running: $TEST_CMD"
echo "---"

# Run tests and capture output
cd "$PROJECT_DIR" || exit 1
FULL_OUTPUT="$OUTPUT_DIR/full_output_$TIMESTAMP.txt"
$TEST_CMD 2>&1 | tee "$FULL_OUTPUT"
EXIT_CODE=${PIPESTATUS[0]}

# Parse results
SUMMARY_FILE="$OUTPUT_DIR/summary.md"

# Extract test counts
TESTS_LINE=$(grep -E "^[0-9]+ (tests?|doctest)" "$FULL_OUTPUT" | tail -1 || echo "0 tests")
FAILURES=$(echo "$TESTS_LINE" | grep -oE "[0-9]+ failures?" | grep -oE "[0-9]+" || echo "0")
TOTAL=$(echo "$TESTS_LINE" | grep -oE "^[0-9]+" || echo "0")

# Extract failure details
FAILURES_FILE="$OUTPUT_DIR/failures.txt"
grep -A 20 "^\s*[0-9]*)\s" "$FULL_OUTPUT" > "$FAILURES_FILE" 2>/dev/null || echo "No failures captured" > "$FAILURES_FILE"

# Extract slowest tests if available
SLOW_FILE="$OUTPUT_DIR/slow_tests.txt"
grep -A 5 "Top [0-9]* slowest" "$FULL_OUTPUT" > "$SLOW_FILE" 2>/dev/null || echo "No slow test data" > "$SLOW_FILE"

# Determine status
if [ "$EXIT_CODE" -eq 0 ]; then
    STATUS="PASS"
else
    STATUS="FAIL"
fi

cat > "$SUMMARY_FILE" << EOF
# Test Runner Summary
Generated: $TIMESTAMP

## Result: $STATUS

## Command
\`\`\`
$TEST_CMD
\`\`\`

## Counts
- Total: $TOTAL
- Failures: $FAILURES
- Exit Code: $EXIT_CODE

## Artifacts
- full_output_$TIMESTAMP.txt - Complete test output
- failures.txt - Failure details (if any)
- slow_tests.txt - Slowest tests (if available)

## Location
\`\`\`
$OUTPUT_DIR/
\`\`\`
EOF

echo ""
echo "=== TEST RUNNER COMPLETE ==="
echo ""
cat "$SUMMARY_FILE"

exit "$EXIT_CODE"
