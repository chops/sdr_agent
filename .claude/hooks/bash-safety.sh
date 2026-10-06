#!/bin/bash
#
# Pre-tool safety hook for Bash commands
# Blocks destructive commands, asks for confirmation on risky ones
#
# Exit codes:
#   0 = allow
#   2 = block
#   JSON output with permissionDecision = ask for confirmation
#

set -e

# Read JSON input from stdin
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# Only process Bash tool
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Empty command = allow
if [ -z "$COMMAND" ]; then
    exit 0
fi

# =============================================================================
# BLOCKERS - These commands are NEVER allowed (exit 2)
# =============================================================================

# rm -rf / or rm -rf ~
if echo "$COMMAND" | grep -qE 'rm\s+(-[rRf]+\s+)+/\s*$'; then
    echo "BLOCKED: rm -rf / is forbidden" >&2
    exit 2
fi

if echo "$COMMAND" | grep -qE 'rm\s+(-[rRf]+\s+)+~\s*$'; then
    echo "BLOCKED: rm -rf ~ is forbidden" >&2
    exit 2
fi

# Piped execution from network
if echo "$COMMAND" | grep -qE 'curl\s+.*\|\s*(ba)?sh'; then
    echo "BLOCKED: curl | sh is forbidden - download and inspect scripts first" >&2
    exit 2
fi

if echo "$COMMAND" | grep -qE 'wget\s+.*\|\s*(ba)?sh'; then
    echo "BLOCKED: wget | bash is forbidden - download and inspect scripts first" >&2
    exit 2
fi

if echo "$COMMAND" | grep -qE 'curl.*-s.*\|'; then
    # Allow curl -s for status checks, but block piped execution
    if echo "$COMMAND" | grep -qE 'curl.*\|\s*(ba)?sh'; then
        echo "BLOCKED: Piping curl to shell is forbidden" >&2
        exit 2
    fi
fi

# =============================================================================
# ASK - These commands require confirmation (JSON output)
# =============================================================================

ask_permission() {
    local reason="$1"
    echo "{\"permissionDecision\": \"ask\", \"permissionDecisionReason\": \"$reason\"}"
    exit 0
}

# rm -rf (general)
if echo "$COMMAND" | grep -qE 'rm\s+(-[rRf]+\s+)+'; then
    ask_permission "rm -rf detected - confirm recursive deletion"
fi

# git destructive operations
if echo "$COMMAND" | grep -qE 'git\s+reset\s+--hard'; then
    ask_permission "git reset --hard will discard uncommitted changes"
fi

if echo "$COMMAND" | grep -qE 'git\s+clean\s+-[a-z]*f[a-z]*d'; then
    ask_permission "git clean -fd will delete untracked files and directories"
fi

if echo "$COMMAND" | grep -qE 'git\s+push\s+.*--force'; then
    ask_permission "git push --force can overwrite remote history"
fi

# Elixir/Ecto destructive operations
if echo "$COMMAND" | grep -qE 'mix\s+ecto\.drop'; then
    ask_permission "mix ecto.drop will DELETE the database"
fi

if echo "$COMMAND" | grep -qE 'mix\s+ecto\.reset'; then
    ask_permission "mix ecto.reset will DROP and recreate the database"
fi

# SQL destructive operations
if echo "$COMMAND" | grep -qiE 'DROP\s+(TABLE|DATABASE)'; then
    ask_permission "DROP TABLE/DATABASE detected - this is destructive"
fi

if echo "$COMMAND" | grep -qiE 'TRUNCATE'; then
    ask_permission "TRUNCATE will delete all rows from the table"
fi

if echo "$COMMAND" | grep -qiE 'DELETE\s+FROM\s+\w+\s*;?\s*$'; then
    ask_permission "DELETE without WHERE clause will delete all rows"
fi

# System operations
if echo "$COMMAND" | grep -qE '\bsudo\b'; then
    ask_permission "Command requires elevated privileges (sudo)"
fi

# =============================================================================
# ALLOW - Command passed all checks
# =============================================================================

exit 0
