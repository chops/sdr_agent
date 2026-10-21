#!/usr/bin/env bash
# 5b (D-178): render the canonical PostgreSQL server-log settings
# (priv/postgres/log_settings.json) as postgresql.conf lines, in the same
# spelling as devenv's services.postgres module (true -> yes, false -> no,
# numbers bare, strings single-quoted with ' doubled), sorted by name.
#
#   bash .github/scripts/render-pg-log-settings.sh priv/postgres/log_settings.json
#
# Refuses (nonzero exit, no output) a missing or malformed file, a file holding
# more than one JSON document, a non-object,
# any key outside the exact contract, a missing key, a value of the wrong JSON
# type (an integer setting given as 0.0 included), or a string holding a
# newline, a control character or a backslash. Values themselves are pinned by
# SdrAgent.PostgresLogSettingsContractTest, not here.
set -euo pipefail

file="${1:-}"
[ -n "$file" ] && [ -f "$file" ] || { echo "render-pg-log-settings: no settings file" >&2; exit 2; }

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
out=$(jq -n -e -r -j -f "$here/render-pg-log-settings.jq" "$file") || { echo "render-pg-log-settings: refused" >&2; exit 3; }
printf '%s\n' "$out"
