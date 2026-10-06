#!/bin/bash
# debug_bundle.sh - Collects error context for debugging
# Usage: debug_bundle.sh [error_file:line] [search_term]
# Outputs: tmp/ai/debug/

set -uo pipefail
shopt -s nullglob

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
OUTPUT_DIR="$PROJECT_DIR/tmp/ai/debug"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BUNDLE_DIR="$OUTPUT_DIR/bundle_$TIMESTAMP"

ERROR_REF="${1:-}"
SEARCH_TERM="${2:-}"

mkdir -p "$BUNDLE_DIR"
cd "$PROJECT_DIR" || exit 1

PROJECT_SHAPE="unknown"
SEARCH_DIRS=()
for app_dir in "$PROJECT_DIR"/apps/*; do
    [ -d "$app_dir/lib" ] && SEARCH_DIRS+=("$app_dir/lib")
    [ -d "$app_dir/test" ] && SEARCH_DIRS+=("$app_dir/test")
done
if [ ${#SEARCH_DIRS[@]} -gt 0 ]; then
    PROJECT_SHAPE="umbrella"
else
    [ -d "$PROJECT_DIR/lib" ] && SEARCH_DIRS+=("$PROJECT_DIR/lib")
    [ -d "$PROJECT_DIR/test" ] && SEARCH_DIRS+=("$PROJECT_DIR/test")
    [ ${#SEARCH_DIRS[@]} -gt 0 ] && PROJECT_SHAPE="single"
fi

echo "Collecting debug bundle..."
echo "=========================="

# 1. Collect recent logs
echo "=== Collecting Logs ==="
LOGS_DIR="$BUNDLE_DIR/logs"
mkdir -p "$LOGS_DIR"

if [ -d "$PROJECT_DIR/log" ]; then
    tail -500 "$PROJECT_DIR/log/dev.log" 2>/dev/null > "$LOGS_DIR/dev_log_tail.txt" || echo "No dev.log" > "$LOGS_DIR/dev_log_tail.txt"
    tail -500 "$PROJECT_DIR/log/test.log" 2>/dev/null > "$LOGS_DIR/test_log_tail.txt" || echo "No test.log" > "$LOGS_DIR/test_log_tail.txt"
fi

if [ -f "$PROJECT_DIR/log/dev.log" ]; then
    grep -i "error\|exception\|crash\|failed" "$PROJECT_DIR/log/dev.log" 2>/dev/null | tail -100 > "$LOGS_DIR/error_lines.txt" || true
fi

# 2. Collect stacktraces from test output
echo "=== Collecting Stacktraces ==="
STACK_DIR="$BUNDLE_DIR/stacktraces"
mkdir -p "$STACK_DIR"

if [ -d "$PROJECT_DIR/tmp/ai/test_runner" ]; then
    LATEST_TEST=$(
        find "$PROJECT_DIR/tmp/ai/test_runner" -name "full_output_*.txt" -type f 2>/dev/null |
            while read -r test_file; do
                printf '%s\t%s\n' "$(stat -f %m "$test_file" 2>/dev/null || stat -c %Y "$test_file" 2>/dev/null || echo 0)" "$test_file"
            done |
            sort -rn |
            head -1 |
            cut -f2-
    )
    if [ -n "$LATEST_TEST" ]; then
        grep -A 30 "^\*\* (.*Error)" "$LATEST_TEST" 2>/dev/null > "$STACK_DIR/test_errors.txt" || true
        grep -A 30 "stacktrace:" "$LATEST_TEST" 2>/dev/null >> "$STACK_DIR/test_errors.txt" || true
    fi
fi

# 3. Collect relevant source files
echo "=== Collecting Source Files ==="
SRC_DIR="$BUNDLE_DIR/source"
mkdir -p "$SRC_DIR"

if [ -n "$ERROR_REF" ]; then
    FILE=$(echo "$ERROR_REF" | cut -d: -f1)
    LINE=$(echo "$ERROR_REF" | cut -d: -f2)

    if [ -f "$PROJECT_DIR/$FILE" ]; then
        START=$((LINE - 50))
        [ $START -lt 1 ] && START=1

        echo "--- $FILE:$LINE ---" > "$SRC_DIR/error_context.txt"
        sed -n "${START},$((LINE + 50))p" "$PROJECT_DIR/$FILE" >> "$SRC_DIR/error_context.txt"
        cp "$PROJECT_DIR/$FILE" "$SRC_DIR/"
    fi
fi

# 4. Search for related files if search term provided
if [ -n "$SEARCH_TERM" ]; then
    echo "=== Searching for: $SEARCH_TERM ==="
    SEARCH_DIR="$BUNDLE_DIR/search"
    mkdir -p "$SEARCH_DIR"

    if [ ${#SEARCH_DIRS[@]} -gt 0 ]; then
        grep -rl -- "$SEARCH_TERM" "${SEARCH_DIRS[@]}" 2>/dev/null | head -20 > "$SEARCH_DIR/matching_files.txt" || true
        grep -rn -B3 -A3 -- "$SEARCH_TERM" "${SEARCH_DIRS[@]}" 2>/dev/null | head -200 > "$SEARCH_DIR/context.txt" || true
    else
        echo "No lib/test directories found for project shape detection" > "$SEARCH_DIR/matching_files.txt"
        echo "No lib/test directories found for project shape detection" > "$SEARCH_DIR/context.txt"
    fi
fi

# 5. Collect compile state
echo "=== Collecting Compile State ==="
STATE_DIR="$BUNDLE_DIR/state"
mkdir -p "$STATE_DIR"

mix compile 2>&1 | head -100 > "$STATE_DIR/compile_output.txt" || true
mix deps.tree 2>&1 | head -50 > "$STATE_DIR/deps_tree.txt" || true

# 6. Collect environment info
echo "=== Collecting Environment ==="
ENV_FILE="$BUNDLE_DIR/environment.txt"
{
    echo "=== Project Shape ==="
    echo "$PROJECT_SHAPE"
    echo ""
    echo "=== Elixir Version ==="
    elixir --version 2>/dev/null || echo "elixir not found"
    echo ""
    echo "=== Mix Environment ==="
    echo "MIX_ENV=${MIX_ENV:-dev}"
    echo ""
    echo "=== Recent Git Activity ==="
    git log --oneline -5 2>/dev/null || echo "Not a git repo"
    echo ""
    echo "=== Modified Files ==="
    git status --short 2>/dev/null || echo "Not a git repo"
} > "$ENV_FILE"

# 7. Generate summary
FILES_COUNT=$(find "$BUNDLE_DIR" -type f | wc -l | tr -d ' ')

cat > "$BUNDLE_DIR/summary.md" << EOF
# Debug Bundle Summary
Generated: $TIMESTAMP

## Input
- Error Reference: ${ERROR_REF:-"(none)"}
- Search Term: ${SEARCH_TERM:-"(none)"}
- Project Shape: $PROJECT_SHAPE

## Contents
- Files Collected: $FILES_COUNT

### Directories
- logs/ - Recent application logs and error extracts
- stacktraces/ - Extracted error stacktraces
- source/ - Relevant source files with context
- search/ - Files matching search term
- state/ - Compile output and dependency info
- environment.txt - Runtime environment info

## Bundle Location
\`\`\`
$BUNDLE_DIR/
\`\`\`

## Usage

Read specific files based on error type:
- Compile errors: state/compile_output.txt
- Runtime errors: logs/error_lines.txt
- Test failures: stacktraces/test_errors.txt
- Source context: source/error_context.txt
EOF

echo ""
echo "=== DEBUG BUNDLE COMPLETE ==="
echo ""
cat "$BUNDLE_DIR/summary.md"
echo ""
echo "Bundle location: $BUNDLE_DIR"
