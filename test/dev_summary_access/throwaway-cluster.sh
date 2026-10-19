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
#   ADV_PGBIN=... throwaway-cluster.sh start|stop|destroy|schema|env ROOT
#
# Before ANY pg_ctl action, connection or removal, every action validates
# ROOT offline (guard_offline: private temporary root, regular private
# manifest with the exact version and root, canonical allowed port, PGDATA
# exactly the physical non-symlink ROOT/pgdata, control-file system
# identifier). Then:
#   start   requires the stopped state and the configured endpoint
#           (guard_stopped), launches with that endpoint on the command
#           line, then requires the running identity and the server's own.
#   stop    requires the running identity (guard_running: postmaster.pid
#           PGDATA, port, 127.0.0.1, live PID, sole listener) and the
#           server's own before signalling.
#   destroy as stop if running; then re-validates offline and the stopped
#           state, and only then removes ROOT. Any drift refuses.
#   schema  requires the running identity; creates sdr_agent_dev and runs
#           the repo's migrations; exits nonzero unless the migration
#           command succeeds, prints its success marker, and
#           schema_migrations equals the repository's migration set.
#   env     prints the ADV_MANIFEST/ADV_PORT/ADV_PGDATA lines.
# Every refusal exits 2 having run no pg_ctl, psql, nix or rm.

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
    guard_offline "$arg"; guard_stopped
    "$ADV_PGBIN/pg_ctl" -D "$GUARD_PGDATA" -l "$GUARD_ROOT/server.log" -w -t 30 \
      -o "-p $GUARD_PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" start >/dev/null
    guard_running
    guard_connect_identity "$ADV_PGBIN/psql"
    echo "started: port $GUARD_PORT, system identifier $GUARD_SYSID"
    ;;
  stop)
    guard_offline "$arg"; guard_running
    guard_connect_identity "$ADV_PGBIN/psql"
    "$ADV_PGBIN/pg_ctl" -D "$GUARD_PGDATA" -m fast -w stop >/dev/null
    echo stopped
    ;;
  destroy)
    guard_offline "$arg"
    if [ -e "$GUARD_PGDATA/postmaster.pid" ] || [ -L "$GUARD_PGDATA/postmaster.pid" ]; then
      guard_running
      guard_connect_identity "$ADV_PGBIN/psql"
      "$ADV_PGBIN/pg_ctl" -D "$GUARD_PGDATA" -m fast -w stop >/dev/null
    fi
    # Re-validate the same root, now stopped, immediately before removal.
    root=$GUARD_ROOT
    guard_offline "$root"; guard_stopped
    [ "$GUARD_ROOT" = "$root" ] || guard_refuse "root changed during destroy"
    rm -rf -- "$GUARD_ROOT"
    echo "destroyed $GUARD_ROOT"
    ;;
  schema)
    # The app schema, no data, from the repo's own migrations through
    # migrate_throwaway.exs in the project's Nix shell (which sets
    # PGPORT=5520, so every PG* variable is unset again there).
    guard_offline "$arg"; guard_running
    guard_connect_identity "$ADV_PGBIN/psql"
    REPO=$(cd "$HERE/../.." && pwd -P)
    expected=$(cd "$REPO/priv/repo/migrations" && ls -1 -- *.exs | sed -n 's/^\([0-9][0-9]*\)_.*\.exs$/\1/p' | sort | paste -sd, -)
    n_expected=$(tr ',' '\n' <<<"$expected" | grep -c .)
    [ "$n_expected" -gt 0 ] || guard_refuse "no repository migrations found"
    "$ADV_PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -d "$(guard_conninfo postgres postgres)" -c "CREATE DATABASE sdr_agent_dev"
    if mig_out=$(nix develop "$REPO" --impure --command bash -c '
      for v in $(env | sed -n "s/^\(PG[A-Za-z0-9_]*\)=.*/\1/p"); do unset "$v"; done; unset DATABASE_URL
      if env | grep -qE "^PG[A-Za-z0-9_]*="; then echo "REFUSED: PG* variables survive in the Nix shell" >&2; exit 2; fi
      cd "$1" && MIX_ENV=dev exec mix run --no-start test/dev_summary_access/migrate_throwaway.exs "$2" "$3"' \
      _ "$REPO" "$GUARD_PORT" "$GUARD_SYSID" 2>&1); then mig_rc=0; else mig_rc=$?; fi
    # Diagnostics only; success is decided below.
    grep -E '^(MIGRATED|REFUSED|\*\*)' <<<"$mig_out" >&2 || true
    [ "$mig_rc" = 0 ] || guard_refuse "migration command exited $mig_rc: schema NOT prepared"
    grep -qx "MIGRATED $n_expected migrations, all up" <<<"$mig_out" \
      || guard_refuse "no migration success marker for all $n_expected migrations: schema NOT prepared"
    got=$("$ADV_PGBIN/psql" -X -q -At -v ON_ERROR_STOP=1 -d "$(guard_conninfo sdr_agent_dev postgres)" \
      -c "SELECT string_agg(version::text, ',' ORDER BY version) FROM public.schema_migrations") \
      || guard_refuse "schema_migrations unreadable: schema NOT prepared"
    [ "$got" = "$expected" ] || guard_refuse "schema_migrations is not exactly the repository's $n_expected migrations: schema NOT prepared"
    tables=$("$ADV_PGBIN/psql" -X -q -At -v ON_ERROR_STOP=1 -d "$(guard_conninfo sdr_agent_dev postgres)" \
      -c "SELECT count(*) FROM pg_catalog.pg_class WHERE relnamespace = 'public'::regnamespace AND relkind = 'r' AND relname IN ('agent_runs', 'oban_jobs', 'model_invocations', 'model_result_releases', 'audit_events', 'audit_exports', 'payloads', 'model_call_grants', 'model_call_allocations')") \
      || guard_refuse "relation check failed: schema NOT prepared"
    [ "$tables" = 9 ] || guard_refuse "only $tables of the 9 tables the interface reads exist: schema NOT prepared"
    rels=$("$ADV_PGBIN/psql" -X -q -At -v ON_ERROR_STOP=1 -d "$(guard_conninfo sdr_agent_dev postgres)" \
      -c "SELECT count(*) FROM pg_catalog.pg_class WHERE relnamespace = 'public'::regnamespace AND relkind IN ('r','p','v','m')")
    echo "SCHEMA-READY migrations=$n_expected public_relations=$rels"
    ;;
  env)
    guard_offline "$arg"
    printf 'ADV_MANIFEST=%s\nADV_PORT=%s\nADV_PGDATA=%s\n' "$GUARD_MANIFEST" "$GUARD_PORT" "$GUARD_PGDATA"
    ;;
  *) echo "usage: throwaway-cluster.sh init BASE | start|stop|destroy|schema|env ROOT" >&2; exit 64 ;;
esac
