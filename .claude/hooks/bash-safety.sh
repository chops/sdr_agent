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
# SCRATCH DELETES - allowed without asking (D-234, ADR-0020)
# =============================================================================
# Only one rm whose flags are -r/-R/-f and whose every target is a literal
# absolute path strictly inside the agents' scratch folder, with no ".", ".."
# or symlink on the path. The command may hold only letters, digits, spaces
# and . _ - / so no shell syntax reaches the parse. Anything else falls
# through, unchanged, to the rules below.

SCRATCH_ROOT="/private/tmp/claude-501/-Users-charles-src-SDR-agent"

# scratch_target <word>: true for a path strictly below SCRATCH_ROOT.
scratch_target() {
    local target="$1" rest path segment IFS='/'
    local -a segments

    case "$target" in
        "$SCRATCH_ROOT"/*) ;;
        *) return 1 ;;
    esac
    rest="${target:$((${#SCRATCH_ROOT} + 1))}"
    case "$rest" in
        *[!/]*) ;;
        *) return 1 ;;
    esac

    segments=($target)
    path=""
    for segment in "${segments[@]}"; do
        if [ -z "$segment" ]; then
            continue
        fi
        case "$segment" in
            . | ..) return 1 ;;
        esac
        path="$path/$segment"
        if [ -L "$path" ]; then
            return 1
        fi
    done
    return 0
}

# scratch_delete_only <tool JSON> <command>: true only for the allowed case.
scratch_delete_only() {
    local input="$1" command="$2" sent_length word saw_target=0 IFS=' '
    local -a words

    case "$command" in
        *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\ ._/-]*) return 1 ;;
    esac
    # The same length as sent: a dropped NUL or a stripped newline is refused.
    sent_length=$(printf '%s' "$input" | jq -r '.tool_input.command | length') || return 1
    if [ "$sent_length" != "${#command}" ]; then
        return 1
    fi

    set -f
    words=($command)
    set +f
    if [ "${#words[@]}" -lt 2 ] || [ "${words[0]}" != "rm" ]; then
        return 1
    fi
    for word in "${words[@]:1}"; do
        if [ "$saw_target" -eq 0 ]; then
            case "$word" in
                -*)
                    case "${word#-}" in
                        '' | *[!rRf]*) return 1 ;;
                    esac
                    continue
                    ;;
            esac
        fi
        saw_target=1
        if ! scratch_target "$word"; then
            return 1
        fi
    done
    [ "$saw_target" -eq 1 ]
}

if scratch_delete_only "$INPUT" "$COMMAND"; then
    exit 0
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
