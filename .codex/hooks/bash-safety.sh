#!/usr/bin/env bash
set -euo pipefail

input="$(cat)"
command="$(jq -r '.tool_input.command // ""' <<<"$input")"
[[ "$(jq -r '.tool_name // ""' <<<"$input")" == "Bash" && -n "$command" ]] || exit 0

deny() {
  jq -n --arg reason "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
  exit 0
}

grep -qE 'rm[[:space:]]+(-[rRf]+[[:space:]]+)+(/[[:space:]]*$|~[[:space:]]*$)' <<<"$command" && deny "Recursive deletion of / or ~ is forbidden."
grep -qE '(curl|wget).*[|][[:space:]]*(ba)?sh' <<<"$command" && deny "Piping a network response to a shell is forbidden."
exit 0
