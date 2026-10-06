#!/bin/bash
# static_analysis.sh - Runs static analysis tools
# Outputs: tmp/ai/static_analysis/

set -uo pipefail

# Find timeout command: prefer 'timeout' (nix/Linux), fallback to 'gtimeout' (Homebrew)
if command -v timeout &>/dev/null; then
    TIMEOUT_CMD="timeout"
elif command -v gtimeout &>/dev/null; then
    TIMEOUT_CMD="gtimeout"
else
    # No timeout available - skip dialyzer timeout protection
    TIMEOUT_CMD=""
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
OUTPUT_DIR="$PROJECT_DIR/tmp/ai/static_analysis"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

mkdir -p "$OUTPUT_DIR"
cd "$PROJECT_DIR" || exit 1

# Track overall status
OVERALL_STATUS="PASS"
declare -A TOOL_STATUS

echo "Running static analysis suite..."
echo "================================"

# 1. Compile with warnings as errors
echo ""
echo "=== Compile Check ==="
COMPILE_OUTPUT="$OUTPUT_DIR/compile.txt"
if mix compile --warnings-as-errors 2>&1 | tee "$COMPILE_OUTPUT"; then
    TOOL_STATUS[compile]="PASS"
    echo "Compile: PASS"
else
    TOOL_STATUS[compile]="FAIL"
    OVERALL_STATUS="FAIL"
    echo "Compile: FAIL"
fi

# 2. Format check
echo ""
echo "=== Format Check ==="
FORMAT_OUTPUT="$OUTPUT_DIR/format.txt"
if mix format --check-formatted 2>&1 | tee "$FORMAT_OUTPUT"; then
    TOOL_STATUS[format]="PASS"
    echo "Format: PASS"
else
    TOOL_STATUS[format]="FAIL"
    OVERALL_STATUS="FAIL"
    echo "Format: FAIL"
fi

# 3. Credo (if available)
echo ""
echo "=== Credo ==="
CREDO_OUTPUT="$OUTPUT_DIR/credo.txt"
if mix credo --strict 2>&1 | tee "$CREDO_OUTPUT"; then
    TOOL_STATUS[credo]="PASS"
    echo "Credo: PASS"
else
    # Check if credo is not installed vs actual failures
    if grep -q "could not be found" "$CREDO_OUTPUT"; then
        TOOL_STATUS[credo]="SKIP"
        echo "Credo: SKIP (not installed)"
    else
        TOOL_STATUS[credo]="FAIL"
        OVERALL_STATUS="FAIL"
        echo "Credo: FAIL"
    fi
fi

# 4. Dialyzer (if PLT exists)
echo ""
echo "=== Dialyzer ==="
DIALYZER_OUTPUT="$OUTPUT_DIR/dialyzer.txt"
DIALYXIR_PLT_EXISTS=false
for dialyxir_dir in "$PROJECT_DIR"/_build/dev/dialyxir*; do
    if [ -d "$dialyxir_dir" ]; then
        DIALYXIR_PLT_EXISTS=true
        break
    fi
done

if [ "$DIALYXIR_PLT_EXISTS" = true ] || [ -f "$PROJECT_DIR/.dialyzer_plt" ]; then
    if ${TIMEOUT_CMD:-} ${TIMEOUT_CMD:+300} mix dialyzer 2>&1 | tee "$DIALYZER_OUTPUT"; then
        TOOL_STATUS[dialyzer]="PASS"
        echo "Dialyzer: PASS"
    else
        TOOL_STATUS[dialyzer]="FAIL"
        OVERALL_STATUS="FAIL"
        echo "Dialyzer: FAIL"
    fi
else
    # Try running anyway - it may build PLT
    if ${TIMEOUT_CMD:-} ${TIMEOUT_CMD:+300} mix dialyzer 2>&1 | tee "$DIALYZER_OUTPUT"; then
        TOOL_STATUS[dialyzer]="PASS"
        echo "Dialyzer: PASS"
    else
        if grep -q "could not be found\|PLT\|dialyxir" "$DIALYZER_OUTPUT"; then
            TOOL_STATUS[dialyzer]="SKIP"
            echo "Dialyzer: SKIP (not configured)"
        else
            TOOL_STATUS[dialyzer]="FAIL"
            OVERALL_STATUS="FAIL"
            echo "Dialyzer: FAIL"
        fi
    fi
fi

# 5. Sobelow security scan (if available)
echo ""
echo "=== Sobelow Security ==="
SOBELOW_OUTPUT="$OUTPUT_DIR/sobelow.txt"
if mix sobelow --config 2>&1 | tee "$SOBELOW_OUTPUT"; then
    TOOL_STATUS[sobelow]="PASS"
    echo "Sobelow: PASS"
else
    if grep -q "could not be found" "$SOBELOW_OUTPUT"; then
        TOOL_STATUS[sobelow]="SKIP"
        echo "Sobelow: SKIP (not installed)"
    else
        TOOL_STATUS[sobelow]="FAIL"
        OVERALL_STATUS="FAIL"
        echo "Sobelow: FAIL"
    fi
fi

# 6. Deps audit (if available)
echo ""
echo "=== Deps Audit ==="
AUDIT_OUTPUT="$OUTPUT_DIR/deps_audit.txt"
if mix deps.audit 2>&1 | tee "$AUDIT_OUTPUT"; then
    TOOL_STATUS[deps_audit]="PASS"
    echo "Deps Audit: PASS"
else
    if grep -q "could not be found\|Unknown" "$AUDIT_OUTPUT"; then
        TOOL_STATUS[deps_audit]="SKIP"
        echo "Deps Audit: SKIP (not installed)"
    else
        TOOL_STATUS[deps_audit]="FAIL"
        OVERALL_STATUS="FAIL"
        echo "Deps Audit: FAIL"
    fi
fi

# Count issues from each tool
COMPILE_WARNINGS=$(grep -c "warning:" "$COMPILE_OUTPUT" 2>/dev/null) || COMPILE_WARNINGS=0
COMPILE_ERRORS=$(grep -c "error:" "$COMPILE_OUTPUT" 2>/dev/null) || COMPILE_ERRORS=0
CREDO_ISSUES=$(grep -c "┃" "$CREDO_OUTPUT" 2>/dev/null) || CREDO_ISSUES=0
DIALYZER_WARNINGS=$(grep -c "warning:" "$DIALYZER_OUTPUT" 2>/dev/null) || DIALYZER_WARNINGS=0
SOBELOW_ISSUES=$(grep -cE "^\[.+\]" "$SOBELOW_OUTPUT" 2>/dev/null) || SOBELOW_ISSUES=0

# Generate summary
cat > "$OUTPUT_DIR/summary.md" << EOF
# Static Analysis Summary
Generated: $TIMESTAMP

## Overall: $OVERALL_STATUS

## Tool Results
| Tool | Status |
|------|--------|
| Compile | ${TOOL_STATUS[compile]:-SKIP} |
| Format | ${TOOL_STATUS[format]:-SKIP} |
| Credo | ${TOOL_STATUS[credo]:-SKIP} |
| Dialyzer | ${TOOL_STATUS[dialyzer]:-SKIP} |
| Sobelow | ${TOOL_STATUS[sobelow]:-SKIP} |
| Deps Audit | ${TOOL_STATUS[deps_audit]:-SKIP} |

## Issue Counts
- Compile Warnings: $COMPILE_WARNINGS
- Compile Errors: $COMPILE_ERRORS
- Credo Issues: $CREDO_ISSUES
- Dialyzer Warnings: $DIALYZER_WARNINGS
- Sobelow Issues: $SOBELOW_ISSUES

## Artifacts
- compile.txt - Compilation output
- format.txt - Format check output
- credo.txt - Credo analysis
- dialyzer.txt - Dialyzer output
- sobelow.txt - Security scan
- deps_audit.txt - Dependency audit

## Location
\`\`\`
$OUTPUT_DIR/
\`\`\`
EOF

echo ""
echo "=== STATIC ANALYSIS COMPLETE ==="
echo ""
cat "$OUTPUT_DIR/summary.md"

# Exit with failure if any tool failed
if [ "$OVERALL_STATUS" = "FAIL" ]; then
    exit 1
fi
exit 0
