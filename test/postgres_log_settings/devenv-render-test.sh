#!/usr/bin/env bash
# 5b (D-178; Codex 5b plan r2 amendment 1): the postgresql.conf that the
# locked devenv module actually generates for this checkout (not the
# services.postgres.settings attrset) holds exactly the approved contract
# lines, in devenv's spelling, plus devenv's own three topology lines,
# unchanged. Needs a Nix build, so it runs outside `mix test`:
#
#   bash test/postgres_log_settings/devenv-render-test.sh
#
# from the repository root. Prints DEVENV-RENDER-PASS (exit 0) or
# DEVENV-RENDER-FAIL <reason> (exit 1). Starts no PostgreSQL and reads no
# existing data directory or log.
set -euo pipefail
fail() { echo "DEVENV-RENDER-FAIL $1"; exit 1; }

root=$(git rev-parse --show-toplevel) || fail no-repo
cd "$root"
expected="test/postgres_log_settings/expected-contract.conf"
[ -f "$expected" ] || fail no-expected-file

sys=$(nix eval --impure --raw --expr builtins.currentSystem) || fail no-system
nix build --impure --no-link ".#devenv-up" >/dev/null 2>&1 || fail devenv-up-build
start=$(nix eval --impure --raw ".#devShells.${sys}.default.config.processes.postgres.exec") || fail no-exec
[ -f "$start" ] || fail start-script-missing

setups=$(grep -oE '/nix/store/[a-z0-9]{32}-setup-postgres' "$start" | sort -u)
[ "$(printf '%s\n' "$setups" | grep -c .)" = 1 ] || fail setup-script-not-unique
confs=$(grep -oE '/nix/store/[a-z0-9]{32}-postgresql\.conf' "$setups/bin/setup-postgres" | sort -u)
[ "$(printf '%s\n' "$confs" | grep -c .)" = 1 ] || fail conf-not-unique
grep -qF "cp $confs \"\$PGDATA/postgresql.conf\"" "$setups/bin/setup-postgres" || fail conf-not-copied-to-pgdata

conf=$(cat "$confs"; echo)
topology=$(printf '%s\n' "$conf" | grep -E '^(listen_addresses|port|unix_socket_directories) = ' || true)
contract=$(printf '%s\n' "$conf" | grep -vE '^(listen_addresses|port|unix_socket_directories) = ' | grep -v '^$' || true)

# Topology is devenv's own: the address and port from devenv.nix, and the
# socket in devenv's per-project runtime directory, whose parent depends on
# the platform ($XDG_RUNTIME_DIR on Linux, $TMPDIR or /tmp on macOS). The
# observed lines are printed on failure (paths only, no data).
topo_fail() { fail "$1 [$(printf '%s\n' "$topology" | tr '\n' ';')]"; }
printf '%s\n' "$topology" | grep -qx "listen_addresses = '127.0.0.1'" || topo_fail topology-listen
printf '%s\n' "$topology" | grep -qx "port = 5520" || topo_fail topology-port
printf '%s\n' "$topology" | grep -qxE "unix_socket_directories = '/[^']*/devenv-[0-9a-f]+/postgres'" || topo_fail topology-socket
[ "$(printf '%s\n' "$topology" | grep -c .)" = 3 ] || topo_fail topology-count

[ "$contract" = "$(cat "$expected")" ] || fail contract-lines-differ
echo DEVENV-RENDER-PASS
