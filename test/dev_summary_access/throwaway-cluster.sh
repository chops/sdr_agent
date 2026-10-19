#!/usr/bin/env bash
# ADR-0016: create, start, stop and destroy the disposable PostgreSQL
# cluster the adversarial test runs against. Never touches any other
# cluster: it only acts on a root it created (see guard.sh).
#
#   ADV_PGBIN=/path/to/postgresql/bin throwaway-cluster.sh init BASE
#       BASE: an existing private directory (mode 700, owned by you) under
#       /private/tmp/ or /private/var/folders/, spelled physically. Creates
#       BASE/d168-throwaway.XXXXXX (mode 700) with initdb (trust on
#       127.0.0.1 only, no Unix socket, a free port in 49152-65535) and
#       writes ROOT/manifest (root, pgdata, port, system identifier).
#       Prints ROOT.
#   ADV_PGBIN=... throwaway-cluster.sh start|stop|destroy ROOT
#       start also verifies the running server's identity; destroy stops
#       the cluster and removes ROOT after re-validating it.
#   ADV_PGBIN=... throwaway-cluster.sh env ROOT
#       prints the ADV_MANIFEST/ADV_PORT/ADV_PGDATA lines for the harness.

set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=guard.sh
. "$HERE/guard.sh"
guard_scrub_env
: "${ADV_PGBIN:?set ADV_PGBIN to the PostgreSQL bin directory}"
GUARD_CONTROLDATA="$ADV_PGBIN/pg_controldata"
cmd=${1:-}; arg=${2:-}

free_port() {
  local p i
  for i in $(seq 1 200); do
    p=$((49152 + RANDOM % 16000))
    lsof -nP -iTCP:"$p" -sTCP:LISTEN -t >/dev/null 2>&1 || { guard_port "$p"; return; }
  done
  guard_refuse "no free port found"
}

manifest_env() {
  ADV_MANIFEST="$1/manifest"
  ADV_PORT=$(guard_manifest_get "$ADV_MANIFEST" port)
  ADV_PGDATA=$(guard_manifest_get "$ADV_MANIFEST" pgdata)
  export ADV_MANIFEST ADV_PORT ADV_PGDATA
}

case "$cmd" in
  init)
    guard_physical_dir "$arg"
    [ "$(guard_stat "$arg")" = "$(id -u) 700" ] || guard_refuse "BASE '$arg' must be owned by you with mode 700"
    ok=no; for pre in $GUARD_TEMP_PREFIXES; do case "$arg/" in "$pre"?*) ok=yes ;; esac; done
    [ "$ok" = yes ] || guard_refuse "BASE '$arg' is not under $GUARD_TEMP_PREFIXES"
    root=$(mktemp -d "$arg/d168-throwaway.XXXXXX")
    chmod 700 "$root"
    root=$(cd -P "$root" && pwd -P)
    printf '%s' "$root" > "$root/$GUARD_MARKER"
    port=$(free_port)
    "$ADV_PGBIN/initdb" -D "$root/pgdata" -U postgres --auth=trust -E UTF8 --locale=C --no-instructions >"$root/initdb.log" 2>&1
    {
      echo "listen_addresses = '127.0.0.1'"
      echo "port = $port"
      echo "unix_socket_directories = ''"
      echo "max_connections = 30"
      echo "fsync = off"
    } >> "$root/pgdata/postgresql.conf"
    printf 'host all all 127.0.0.1/32 trust\n' > "$root/pgdata/pg_hba.conf"
    sysid=$("$ADV_PGBIN/pg_controldata" "$root/pgdata" | awk -F: '/^Database system identifier/ {gsub(/ /, "", $2); print $2}')
    umask 077
    printf 'd168_throwaway_manifest=1\nroot=%s\npgdata=%s\nport=%s\nsystem_identifier=%s\n' \
      "$root" "$root/pgdata" "$port" "$sysid" > "$root/manifest"
    chmod 600 "$root/manifest"
    printf '%s\n' "$root"
    ;;
  start)
    guard_root "$arg"; manifest_env "$arg"
    "$ADV_PGBIN/pg_ctl" -D "$ADV_PGDATA" -l "$arg/server.log" -w -t 30 start >/dev/null
    guard_verify
    guard_connect_identity "$ADV_PGBIN/psql"
    echo "started: port $GUARD_PORT, system identifier $GUARD_SYSID"
    ;;
  stop)
    guard_root "$arg"; manifest_env "$arg"
    "$ADV_PGBIN/pg_ctl" -D "$ADV_PGDATA" -m fast -w stop >/dev/null
    echo stopped
    ;;
  destroy)
    guard_root "$arg"; manifest_env "$arg"
    [ ! -f "$ADV_PGDATA/postmaster.pid" ] || "$ADV_PGBIN/pg_ctl" -D "$ADV_PGDATA" -m fast -w stop >/dev/null
    guard_root "$arg"
    rm -rf -- "$arg"
    [ ! -e "$arg" ] && echo "destroyed $arg"
    ;;
  schema)
    # The app schema, no data: create sdr_agent_dev and run the repo's
    # migrations through migrate_throwaway.exs in the project's Nix shell
    # (which sets PGPORT=5520, so every PG* variable is unset again there).
    guard_root "$arg"; manifest_env "$arg"
    guard_verify
    guard_connect_identity "$ADV_PGBIN/psql"
    "$ADV_PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -d "$(guard_conninfo postgres postgres)" -c "CREATE DATABASE sdr_agent_dev"
    REPO=$(cd "$HERE/../.." && pwd -P)
    nix develop "$REPO" --impure --command bash -c '
      for v in $(env | sed -n "s/^\(PG[A-Za-z0-9_]*\)=.*/\1/p"); do unset "$v"; done; unset DATABASE_URL
      if env | grep -qE "^PG[A-Za-z0-9_]*="; then echo "REFUSED: PG* variables survive in the Nix shell" >&2; exit 2; fi
      cd "$1" && MIX_ENV=dev exec mix run --no-start test/dev_summary_access/migrate_throwaway.exs "$2" "$3"' \
      _ "$REPO" "$GUARD_PORT" "$GUARD_SYSID" 2>&1 | grep -E '^(MIGRATED|REFUSED|\*\*)' || true
    "$ADV_PGBIN/psql" -X -q -At -d "$(guard_conninfo sdr_agent_dev postgres)" \
      -c "SELECT 'public relations: ' || count(*) FROM pg_catalog.pg_class WHERE relnamespace = 'public'::regnamespace AND relkind IN ('r','p','v','m')"
    ;;
  env)
    guard_root "$arg"; manifest_env "$arg"
    printf 'ADV_MANIFEST=%s\nADV_PORT=%s\nADV_PGDATA=%s\n' "$ADV_MANIFEST" "$ADV_PORT" "$ADV_PGDATA"
    ;;
  *) echo "usage: throwaway-cluster.sh init BASE | start|stop|destroy|env ROOT" >&2; exit 64 ;;
esac
