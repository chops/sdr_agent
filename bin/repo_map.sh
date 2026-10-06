#!/bin/bash
# repo_map.sh - Analyzes Elixir/Ash codebase structure
# Outputs: tmp/ai/repo_map/

set -euo pipefail
shopt -s nullglob

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
OUTPUT_DIR="$PROJECT_DIR/tmp/ai/repo_map"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

mkdir -p "$OUTPUT_DIR"

# Clear previous outputs
rm -f "$OUTPUT_DIR"/*.txt "$OUTPUT_DIR"/*.md

echo "Analyzing codebase structure..."

PROJECT_SHAPE="unknown"
LIB_DIRS=()
TEST_DIRS=()
MIX_FILES=()

for app_dir in "$PROJECT_DIR"/apps/*; do
    [ -d "$app_dir/lib" ] || continue
    LIB_DIRS+=("$app_dir/lib")
    [ -d "$app_dir/test" ] && TEST_DIRS+=("$app_dir/test")
    [ -f "$app_dir/mix.exs" ] && MIX_FILES+=("$app_dir/mix.exs")
done

if [ ${#LIB_DIRS[@]} -gt 0 ]; then
    PROJECT_SHAPE="umbrella"
elif [ -d "$PROJECT_DIR/lib" ]; then
    PROJECT_SHAPE="single"
    LIB_DIRS=("$PROJECT_DIR/lib")
    [ -d "$PROJECT_DIR/test" ] && TEST_DIRS=("$PROJECT_DIR/test")
    [ -f "$PROJECT_DIR/mix.exs" ] && MIX_FILES=("$PROJECT_DIR/mix.exs")
fi

count_markers() {
    local file="$1"
    grep -c "^---" "$file" 2>/dev/null || true
}

count_grep_files() {
    local pattern="$1"
    local matches
    matches=$(grep -rl "$pattern" "${LIB_DIRS[@]}" 2>/dev/null || true)
    if [ -z "$matches" ]; then
        echo 0
    else
        printf '%s\n' "$matches" | wc -l | tr -d ' '
    fi
}

# 0. Project shape / apps
{
    echo "=== Project Shape ==="
    echo "Shape: $PROJECT_SHAPE"
    if [ "$PROJECT_SHAPE" = "umbrella" ]; then
        echo ""
        echo "=== Child Apps ==="
        for app_dir in "$PROJECT_DIR"/apps/*/; do
            [ -d "$app_dir" ] || continue
            APP_NAME=$(basename "$app_dir")
            MODULES=$(find "$app_dir/lib" -name "*.ex" 2>/dev/null | wc -l | tr -d ' ')
            echo "- $APP_NAME ($MODULES modules)"
        done
    elif [ "$PROJECT_SHAPE" = "single" ]; then
        MODULES=$(find "$PROJECT_DIR/lib" -name "*.ex" 2>/dev/null | wc -l | tr -d ' ')
        echo "- $(basename "$PROJECT_DIR") ($MODULES modules)"
    else
        echo "No lib/ or apps/*/lib directories found"
    fi
} > "$OUTPUT_DIR/apps.txt"

# 1. Directory structure
echo "=== Directory Structure ===" > "$OUTPUT_DIR/structure.txt"
if [ ${#LIB_DIRS[@]} -gt 0 ]; then
    for lib_dir in "${LIB_DIRS[@]}"; do
        echo "--- $lib_dir ---"
        find "$lib_dir" -maxdepth 3 -type d 2>/dev/null | head -50
        echo ""
    done >> "$OUTPUT_DIR/structure.txt"
else
    echo "No lib directories found" >> "$OUTPUT_DIR/structure.txt"
fi

# 2. Ash Resources
echo "=== Ash Resources ===" > "$OUTPUT_DIR/resources.txt"
if [ ${#LIB_DIRS[@]} -gt 0 ]; then
    grep -rl "use Ash.Resource" "${LIB_DIRS[@]}" 2>/dev/null | while read -r file; do
        echo "--- $file ---"
        grep -E "(defmodule|use Ash\.Resource|attributes do|attribute |belongs_to |has_many |has_one )" "$file" 2>/dev/null | head -30
        echo ""
    done >> "$OUTPUT_DIR/resources.txt" || true
fi
if ! grep -q "^---" "$OUTPUT_DIR/resources.txt"; then
    echo "No Ash resources found" >> "$OUTPUT_DIR/resources.txt"
fi

# 3. Ash Domains
echo "=== Ash Domains ===" > "$OUTPUT_DIR/domains.txt"
if [ ${#LIB_DIRS[@]} -gt 0 ]; then
    grep -rl "use Ash.Domain" "${LIB_DIRS[@]}" 2>/dev/null | while read -r file; do
        echo "--- $file ---"
        grep -E "(defmodule|use Ash\.Domain|resources do|resource )" "$file" 2>/dev/null | head -20
        echo ""
    done >> "$OUTPUT_DIR/domains.txt" || true
fi
if ! grep -q "^---" "$OUTPUT_DIR/domains.txt"; then
    echo "No Ash domains found" >> "$OUTPUT_DIR/domains.txt"
fi

# 4. Actions summary
echo "=== Actions ===" > "$OUTPUT_DIR/actions.txt"
if [ ${#LIB_DIRS[@]} -gt 0 ]; then
    grep -rh -A 50 "actions do" "${LIB_DIRS[@]}" 2>/dev/null | grep -E "(create |read |update |destroy |action )" | sort | uniq -c | sort -rn >> "$OUTPUT_DIR/actions.txt" || true
fi
if [ "$(wc -l < "$OUTPUT_DIR/actions.txt" | tr -d ' ')" -le 1 ]; then
    echo "No actions found" >> "$OUTPUT_DIR/actions.txt"
fi

# 5. Phoenix Controllers/LiveViews
echo "=== Phoenix Controllers ===" > "$OUTPUT_DIR/phoenix.txt"
if [ ${#LIB_DIRS[@]} -gt 0 ]; then
    find "${LIB_DIRS[@]}" -name "*_controller.ex" 2>/dev/null >> "$OUTPUT_DIR/phoenix.txt" || true
fi
echo "" >> "$OUTPUT_DIR/phoenix.txt"
echo "=== Phoenix LiveViews ===" >> "$OUTPUT_DIR/phoenix.txt"
if [ ${#LIB_DIRS[@]} -gt 0 ]; then
    find "${LIB_DIRS[@]}" -name "*_live.ex" 2>/dev/null >> "$OUTPUT_DIR/phoenix.txt" || true
    grep -rl "use.*LiveView" "${LIB_DIRS[@]}" 2>/dev/null >> "$OUTPUT_DIR/phoenix.txt" || true
fi

# 6. Test files
echo "=== Test Structure ===" > "$OUTPUT_DIR/tests.txt"
if [ ${#TEST_DIRS[@]} -gt 0 ]; then
    TEST_FILE_COUNT=$(find "${TEST_DIRS[@]}" -name "*.exs" -type f 2>/dev/null | wc -l | tr -d ' ')
    echo "Total test files: $TEST_FILE_COUNT" >> "$OUTPUT_DIR/tests.txt"
    for test_dir in "${TEST_DIRS[@]}"; do
        echo "--- $test_dir ---"
        find "$test_dir" -maxdepth 2 -type d 2>/dev/null
        echo ""
    done >> "$OUTPUT_DIR/tests.txt"
else
    echo "No test directories" >> "$OUTPUT_DIR/tests.txt"
fi

# 7. Dependencies
echo "=== Key Dependencies ===" > "$OUTPUT_DIR/deps.txt"
if [ ${#MIX_FILES[@]} -gt 0 ]; then
    for mix_file in "${MIX_FILES[@]}"; do
        APP_NAME=$(basename "$(dirname "$mix_file")")
        [ "$PROJECT_SHAPE" = "single" ] && APP_NAME=$(basename "$PROJECT_DIR")
        DEPS=$(grep -E "^\s+\{:(ash|phoenix|plug|jason|req)" "$mix_file" 2>/dev/null || true)
        if [ -n "$DEPS" ]; then
            echo "--- $APP_NAME ---"
            echo "$DEPS"
            echo ""
        fi
    done >> "$OUTPUT_DIR/deps.txt"
fi
if [ "$(wc -l < "$OUTPUT_DIR/deps.txt" | tr -d ' ')" -le 1 ]; then
    echo "No key deps found" >> "$OUTPUT_DIR/deps.txt"
fi

# Generate summary
case "$PROJECT_SHAPE" in
    umbrella) APPS_COUNT=$(find "$PROJECT_DIR/apps" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ') ;;
    single) APPS_COUNT=1 ;;
    *) APPS_COUNT=0 ;;
esac
RESOURCES_COUNT=$(count_markers "$OUTPUT_DIR/resources.txt")
DOMAINS_COUNT=$(count_markers "$OUTPUT_DIR/domains.txt")
if [ ${#LIB_DIRS[@]} -gt 0 ]; then
    CONTROLLERS_COUNT=$(find "${LIB_DIRS[@]}" -name "*_controller.ex" 2>/dev/null | wc -l | tr -d ' ')
    LIVEVIEWS_COUNT=$(count_grep_files "use.*LiveView")
else
    CONTROLLERS_COUNT=0
    LIVEVIEWS_COUNT=0
fi
if [ ${#TEST_DIRS[@]} -gt 0 ]; then
    TESTS_COUNT=$(find "${TEST_DIRS[@]}" -name "*.exs" -type f 2>/dev/null | wc -l | tr -d ' ')
else
    TESTS_COUNT=0
fi

cat > "$OUTPUT_DIR/summary.md" << EOF
# Repository Map Summary
Generated: $TIMESTAMP

## Project Shape
- Shape: $PROJECT_SHAPE

## Counts
- Apps: $APPS_COUNT
- Ash Resources: $RESOURCES_COUNT
- Ash Domains: $DOMAINS_COUNT
- Phoenix Controllers: $CONTROLLERS_COUNT
- LiveViews: $LIVEVIEWS_COUNT
- Test Files: $TESTS_COUNT

## Artifacts Generated
- apps.txt - Project shape and app/module counts
- structure.txt - Directory layout
- resources.txt - Ash resource definitions
- domains.txt - Ash domain definitions
- actions.txt - Action patterns
- phoenix.txt - Controllers and LiveViews
- tests.txt - Test structure
- deps.txt - Key dependencies

## Quick Reference
\`\`\`
$OUTPUT_DIR/
\`\`\`
EOF

echo ""
echo "=== REPO MAP COMPLETE ==="
echo ""
cat "$OUTPUT_DIR/summary.md"
