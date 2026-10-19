#!/usr/bin/env bash
# ADR-0016 hermetic test of throwaway-cluster.sh's lifecycle entry points
# (start, stop, destroy, schema, env). No database, no real cluster: pg_ctl,
# psql, pg_controldata, lsof, nix and rm are stubs on PATH that record every
# call. Every refused input must exit 2 with a REFUSED line and make ZERO
# pg_ctl start/stop, rm, nix and psql calls. Positive controls show the
# stopped and running paths do act, on exactly the validated target. The
# schema cases show a failed, unmarked or partial migration is refused even
# when the later relation count would succeed.
#
#   test/dev_summary_access/lifecycle-test.sh [LOG]
#
# Exit 0 only if every case passes.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd -P)
LOG=${1:-/dev/null}
PASSES=0 FAILS=0
log() { printf '%s\n' "$*" | tee -a "$LOG"; }

base=$(mktemp -d "${TMPDIR:-/tmp}/d168life.XXXXXX"); base=$(cd -P "$base" && pwd -P); chmod 700 "$base"
nontemp=$(mktemp -d "$REPO/.devenv/d168life-nontemp.XXXXXX"); chmod 700 "$nontemp"
stubs="$base/stubs"; mkdir "$stubs"
CALLS="$base/calls"
sleep 600 & ALIVE=$!
sleep 600 & OTHER=$!
trap 'kill $ALIVE $OTHER 2>/dev/null; /bin/rm -rf "$base" "$nontemp"' EXIT
PORT=61888
SYSID=7234567890123456789
EXPECTED_VERSIONS=$(cd "$REPO/priv/repo/migrations" && ls -1 -- *.exs | sed -n 's/^\([0-9][0-9]*\)_.*\.exs$/\1/p' | sort | paste -sd, -)
NMIG=$(tr ',' '\n' <<<"$EXPECTED_VERSIONS" | grep -c .)

# --- stubs. STUB_STATE/listening marks "a postmaster listens on PORT". ---
cat > "$stubs/pg_ctl" <<'EOF'
#!/usr/bin/env bash
{ printf 'PGCTL'; printf ' [%s]' "$@"; printf '\n'; } >> "$STUB_CALLS"
d=; prev=
for a in "$@"; do [ "$prev" = -D ] && d=$a; prev=$a; done
case " $* " in
  *" start "*) printf '%s\n%s\n1760000000\n%s\n\n127.0.0.1\n  1   2\nready\n' "$STUB_PID" "$d" "$STUB_PORT" > "$d/postmaster.pid"
               : > "$STUB_STATE/listening" ;;
  *" stop "*) /bin/rm -f "$d/postmaster.pid" "$STUB_STATE/listening" ;;
esac
exit 0
EOF
cat > "$stubs/psql" <<'EOF'
#!/usr/bin/env bash
{ printf 'PSQL'; printf ' [%s]' "$@"; printf '\n'; } >> "$STUB_CALLS"
case "$*" in
  *pg_control_system*) printf '%s\n' "$STUB_IDENTITY" ;;
  *schema_migrations*) printf '%s\n' "$STUB_VERSIONS" ;;
  *"relname IN"*) printf '%s\n' "$STUB_TABLES" ;;
  *"count(*)"*) printf '56\n' ;;
esac
exit 0
EOF
cat > "$stubs/pg_controldata" <<'EOF'
#!/usr/bin/env bash
printf 'pg_control version number:            1800\nDatabase system identifier:           %s\n' "$STUB_SYSID"
EOF
cat > "$stubs/lsof" <<'EOF'
#!/usr/bin/env bash
[ -n "${STUB_LSOF_FAIL:-}" ] && exit 2
[ -e "$STUB_STATE/listening" ] || exit 1
for p in $STUB_LISTENERS; do printf '%s\n' "$p"; done
EOF
cat > "$stubs/nix" <<'EOF'
#!/usr/bin/env bash
printf 'NIX\n' >> "$STUB_CALLS"
case "$STUB_NIX" in
  fail) echo '** (Mix) compilation failed'; exit 1 ;;
  nomarker) echo 'some output'; exit 0 ;;
  short) echo "MIGRATED $((STUB_NMIG - 1)) migrations, all up"; exit 0 ;;
  *) echo "MIGRATED $STUB_NMIG migrations, all up"; exit 0 ;;
esac
EOF
cat > "$stubs/rm" <<'EOF'
#!/usr/bin/env bash
{ printf 'RM'; printf ' [%s]' "$@"; printf '\n'; } >> "$STUB_CALLS"
exit 0
EOF
chmod 755 "$stubs"/*

# mkroot DIR [running|stopped] [manifest-port] [pid-port]
mkroot() {
  local r=$1 state=${2:-running} mport=${3:-$PORT} pport=${4:-${3:-$PORT}}
  /bin/rm -rf "$r"; mkdir -p "$r/pgdata"; chmod 700 "$r" "$r/pgdata"
  printf '%s' "$r" > "$r/.d168-throwaway-root"
  printf 'd168_throwaway_manifest=1\nroot=%s\npgdata=%s\nport=%s\nsystem_identifier=%s\n' \
    "$r" "$r/pgdata" "$mport" "$SYSID" > "$r/manifest"
  chmod 600 "$r/manifest"
  printf "listen_addresses = '127.0.0.1'\nport = %s\nunix_socket_directories = ''\n" "$mport" > "$r/pgdata/postgresql.conf"
  if [ "$state" = running ]; then
    printf '%s\n%s\n1760000000\n%s\n\n127.0.0.1\n  1   2\nready\n' "$ALIVE" "$r/pgdata" "$pport" > "$r/pgdata/postmaster.pid"
  fi
}
sedi() { local f=$1 t; shift; t=$(sed "$@" "$f") && printf '%s\n' "$t" > "$f"; }

# run ACTION ROOT [VAR=VALUE ...]: the real throwaway-cluster.sh under stubs.
# The stub state ("listening") follows the fixture's postmaster.pid.
run() {
  local action=$1 root=$2; shift 2
  : > "$CALLS"; /bin/rm -rf "$base/state"; mkdir "$base/state"
  [ -e "$root/pgdata/postmaster.pid" ] && : > "$base/state/listening"
  OUT=$(env -i HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" PATH="$stubs:/usr/bin:/bin:/usr/sbin:/sbin" \
    STUB_CALLS="$CALLS" STUB_STATE="$base/state" STUB_SYSID="$SYSID" STUB_PID="$ALIVE" STUB_PORT="$PORT" \
    STUB_LISTENERS="$ALIVE" STUB_IDENTITY="$SYSID|$root/pgdata|$PORT|$PORT" \
    STUB_VERSIONS="$EXPECTED_VERSIONS" STUB_TABLES=9 STUB_NIX=good STUB_NMIG="$NMIG" \
    ADV_PGBIN="$stubs" "$@" "$BASH" "$HERE/throwaway-cluster.sh" "$action" "$root" 2>&1)
  RC=$?
  N_START=$(grep -c '^PGCTL.*\[start\]' "$CALLS"); N_STOP=$(grep -c '^PGCTL.*\[stop\]' "$CALLS")
  N_RM=$(grep -c '^RM' "$CALLS"); N_NIX=$(grep -c '^NIX' "$CALLS"); N_PSQL=$(grep -c '^PSQL' "$CALLS")
}
ok() { PASSES=$((PASSES + 1)); log "PASS $*"; }
bad() { FAILS=$((FAILS + 1)); log "FAIL $*"; }

# refused NAME ROOT-BUILDER-ARGS... : every action on that root refuses
# with zero start, stop, rm, nix and psql calls.
refused_all() {
  local name=$1 root=$2; shift 2
  local a
  for a in start stop destroy schema env; do
    [ -n "${REBUILD:-}" ] && eval "$REBUILD"
    run "$a" "$root" "$@"
    if [ "$RC" = 2 ] && grep -q '^REFUSED: ' <<<"$OUT" && [ "$N_START$N_STOP$N_RM$N_NIX$N_PSQL" = 00000 ]; then
      ok "$a refused, 0 pg_ctl/rm/nix/psql calls: $name ($(grep -m1 '^REFUSED' <<<"$OUT" | cut -c1-100))"
    else
      bad "$a $name: exit=$RC start=$N_START stop=$N_STOP rm=$N_RM nix=$N_NIX psql=$N_PSQL out=$(head -2 <<<"$OUT" | tr '\n' ' ' | cut -c1-160)"
    fi
  done
}

log "== ADR-0016 lifecycle hermetic test $(date -u +%Y-%m-%dT%H:%M:%SZ) bash $BASH ($BASH_VERSION) throwaway-cluster.sh sha256 $(shasum -a 256 "$HERE/throwaway-cluster.sh" | cut -d' ' -f1) guard.sh sha256 $(shasum -a 256 "$HERE/guard.sh" | cut -d' ' -f1)"

# --- positive controls ---
G="$base/d168-throwaway.good"
mkroot "$G" stopped; run start "$G"
call=$(grep '^PGCTL' "$CALLS")
if [ "$RC" = 0 ] && [ "$N_START" = 1 ] && [ "$N_STOP$N_RM" = 00 ] && grep -qF "[-D] [$G/pgdata]" <<<"$call" \
   && grep -qF "[-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories='']" <<<"$call" && grep -q '^started' <<<"$OUT"; then
  ok "start on a valid stopped root: 1 pg_ctl start on exactly its pgdata with the manifest endpoint on the command line, then running + server identity"
else bad "start positive: exit=$RC start=$N_START call=$call out=$OUT"; fi
mkroot "$G" running; run stop "$G"
{ [ "$RC" = 0 ] && [ "$N_STOP" = 1 ] && [ "$N_START$N_RM" = 00 ] && grep -qF "[-D] [$G/pgdata]" "$CALLS"; } \
  && ok "stop on a valid running root: 1 pg_ctl stop on exactly its pgdata, after the identity query" || bad "stop positive: exit=$RC stop=$N_STOP out=$OUT"
mkroot "$G" stopped; run destroy "$G"
{ [ "$RC" = 0 ] && [ "$N_START$N_STOP" = 00 ] && [ "$N_RM" = 1 ] && grep -qxF "RM [-rf] [--] [$G]" "$CALLS"; } \
  && ok "destroy of a valid stopped root: no pg_ctl, 1 rm of exactly that root" || bad "destroy stopped positive: exit=$RC rm=$N_RM out=$OUT"
mkroot "$G" running; run destroy "$G"
{ [ "$RC" = 0 ] && [ "$N_STOP" = 1 ] && [ "$N_RM" = 1 ] && grep -qxF "RM [-rf] [--] [$G]" "$CALLS" \
  && [ "$(grep -E '^(PGCTL|RM) ' "$CALLS" | awk '{print $1}' | tr '\n' ' ')" = "PGCTL RM " ]; } \
  && ok "destroy of a valid running root: pg_ctl stop, then re-validation, then 1 rm of exactly that root" || bad "destroy running positive: exit=$RC stop=$N_STOP rm=$N_RM out=$OUT"
mkroot "$G" running; run schema "$G"
{ [ "$RC" = 0 ] && [ "$N_NIX" = 1 ] && grep -q "^SCHEMA-READY migrations=$NMIG " <<<"$OUT"; } \
  && ok "schema on a valid running root: migration marker and all $NMIG versions -> SCHEMA-READY" || bad "schema positive: exit=$RC out=$OUT"
mkroot "$G" stopped; run env "$G"
{ [ "$RC" = 0 ] && grep -qx "ADV_PORT=$PORT" <<<"$OUT" && [ "$N_START$N_STOP$N_RM$N_NIX$N_PSQL" = 00000 ]; } \
  && ok "env on a valid root prints the manifest values and runs nothing" || bad "env positive: $OUT"

# --- refused inputs: every action, zero calls ---
NT="$nontemp/d168-throwaway.ext"; mkroot "$NT" running
E="$base/d168-throwaway.extpgdata"
REBUILD='mkroot "$E" running; sedi "$E/manifest" "s|^pgdata=.*|pgdata=$NT/pgdata|"'
refused_all "manifest pgdata points at another cluster's physical data directory" "$E"
unset REBUILD
mkroot "$G" running; ln -sfn "$G" "$base/d168-throwaway.rootlink"
refused_all "ROOT is a symlink to a valid root" "$base/d168-throwaway.rootlink"
L="$base/d168-throwaway.mlink"
REBUILD='mkroot "$L" running; /bin/cp -p "$L/manifest" "$base/manifest.copy"; /bin/rm "$L/manifest"; ln -s "$base/manifest.copy" "$L/manifest"'
refused_all "manifest is a symlink" "$L"
P="$base/d168-throwaway.plink"
REBUILD='mkroot "$P" running; /bin/rm -rf "$P/pgdata"; ln -s "$NT/pgdata" "$P/pgdata"'
refused_all "pgdata is a symlink to a non-temporary cluster" "$P"
X="$base/d168-throwaway.port"
for p in 5520 05520 +5520 4120 ' 61888' 1024; do
  REBUILD="mkroot \"\$X\" running '$p'"
  refused_all "manifest port '$p'" "$X"
done
unset REBUILD
mkroot "$G" running
refused_all "changed control-file system identifier" "$G" STUB_SYSID=7000000000000000001
N="$nontemp/d168-throwaway.nontempgood"; mkroot "$N" running
refused_all "valid-looking root outside the temporary prefixes" "$N"
V="$base/d168-throwaway.ver"
REBUILD='mkroot "$V" running; sedi "$V/manifest" "s|^d168_throwaway_manifest=1|d168_throwaway_manifest=2|"'
refused_all "manifest version 2" "$V"
REBUILD='mkroot "$V" running; printf "port=5520\n" >> "$V/manifest"'
refused_all "manifest with an extra line" "$V"
REBUILD='mkroot "$V" running; chmod 644 "$V/manifest"'
refused_all "manifest mode 644" "$V"
REBUILD='mkroot "$V" running; printf "%s" "$G" > "$V/.d168-throwaway-root"'
refused_all "marker names another root" "$V"
REBUILD='mkroot "$V" running; sedi "$V/manifest" "s|^root=.*|root=$G|"'
refused_all "manifest root names another root" "$V"
unset REBUILD

# --- running-identity refusals: stop, destroy and schema (start refuses a running root too) ---
refused_run() {
  local name=$1 root=$2; shift 2
  local a
  for a in start stop destroy schema; do
    eval "$REBUILD"; run "$a" "$root" "$@"
    if [ "$RC" = 2 ] && grep -q '^REFUSED: ' <<<"$OUT" && [ "$N_START$N_STOP$N_RM$N_NIX$N_PSQL" = 00000 ]; then
      ok "$a refused, 0 pg_ctl/rm/nix/psql calls: $name ($(grep -m1 '^REFUSED' <<<"$OUT" | cut -c1-100))"
    else bad "$a $name: exit=$RC start=$N_START stop=$N_STOP rm=$N_RM nix=$N_NIX psql=$N_PSQL out=$(head -2 <<<"$OUT" | tr '\n' ' ' | cut -c1-160)"; fi
  done
}
REBUILD='mkroot "$G" running'
refused_run "listener PID is not the postmaster" "$G" STUB_LISTENERS="$OTHER"
refused_run "a second process listens on the port" "$G" STUB_LISTENERS="$ALIVE $OTHER"
REBUILD='mkroot "$G" running; sedi "$G/pgdata/postmaster.pid" "1s|.*|$OTHER|"'
refused_run "postmaster.pid PID differs from the listener" "$G"
REBUILD='mkroot "$G" running; sedi "$G/pgdata/postmaster.pid" "1s|.*|999999|"'
refused_run "postmaster.pid PID not alive" "$G"
REBUILD='mkroot "$G" running; sedi "$G/pgdata/postmaster.pid" "2s|.*|$NT/pgdata|"'
refused_run "postmaster.pid names another data directory" "$G"
REBUILD='mkroot "$G" running "$PORT" 5520'
refused_run "postmaster.pid port is 5520" "$G"

# --- server identity: one read-only identity query, then nothing ---
for a in start stop destroy schema; do
  [ "$a" = start ] && mkroot "$G" stopped || mkroot "$G" running
  run "$a" "$G" STUB_IDENTITY="7000000000000000001|$G/pgdata|$PORT|$PORT"
  # start launched before it could ask the server; it must then refuse and do nothing more.
  want_start=0; [ "$a" = start ] && want_start=1
  if [ "$RC" = 2 ] && grep -q '^REFUSED: server identity' <<<"$OUT" && [ "$N_PSQL" = 1 ] && [ "$N_START" = "$want_start" ] \
     && [ "$N_STOP$N_RM$N_NIX" = 000 ]; then
    ok "$a with a different server identity: refused after 1 identity query; no stop, rm or migration"
  else bad "$a server identity: exit=$RC start=$N_START stop=$N_STOP rm=$N_RM nix=$N_NIX psql=$N_PSQL"; fi
done

# --- start-specific: the stopped state and configured endpoint ---
S="$base/d168-throwaway.start"
refused_start() {
  local name=$1; shift
  eval "$REBUILD"; run start "$S" "$@"
  if [ "$RC" = 2 ] && grep -q '^REFUSED: ' <<<"$OUT" && [ "$N_START$N_STOP$N_RM$N_NIX$N_PSQL" = 00000 ]; then
    ok "start refused, 0 calls: $name ($(grep -m1 '^REFUSED' <<<"$OUT" | cut -c1-100))"
  else bad "start $name: exit=$RC start=$N_START psql=$N_PSQL out=$(head -1 <<<"$OUT")"; fi
}
REBUILD='mkroot "$S" stopped; sedi "$S/pgdata/postgresql.conf" "s|^port = .*|port = 5520|"'
refused_start "postgresql.conf port 5520"
REBUILD='mkroot "$S" stopped; printf "port = 5520\n" > "$S/pgdata/postgresql.auto.conf"'
refused_start "postgresql.auto.conf overrides the port"
REBUILD='mkroot "$S" stopped; printf "include = '"'"'/tmp/x.conf'"'"'\n" >> "$S/pgdata/postgresql.conf"'
refused_start "postgresql.conf includes another file"
REBUILD='mkroot "$S" stopped; sedi "$S/pgdata/postgresql.conf" "s|^listen_addresses = .*|listen_addresses = '"'"'*'"'"'|"'
refused_start "postgresql.conf listens beyond 127.0.0.1"
REBUILD='mkroot "$S" stopped'
refused_start "lsof fails (a broken lsof must not read as no listener)" STUB_LSOF_FAIL=1
# A foreign listener already on the manifest port while the cluster is stopped.
mkroot "$S" stopped
: > "$CALLS"; /bin/rm -rf "$base/state"; mkdir "$base/state"; : > "$base/state/listening"
OUT=$(env -i HOME="$HOME" PATH="$stubs:/usr/bin:/bin:/usr/sbin:/sbin" STUB_CALLS="$CALLS" STUB_STATE="$base/state" STUB_SYSID="$SYSID" \
  STUB_LISTENERS="$OTHER" ADV_PGBIN="$stubs" "$BASH" "$HERE/throwaway-cluster.sh" start "$S" 2>&1); RC=$?
[ "$RC" = 2 ] && grep -q '^REFUSED: port' <<<"$OUT" && [ "$(grep -c '' "$CALLS")" = 0 ] \
  && ok "start refused, 0 calls: another process already listens on the manifest port" || bad "start with a foreign listener: exit=$RC $(head -1 <<<"$OUT")"

# --- schema: failure propagation, marker and full migration state ---
schema_refused() {
  local name=$1; shift
  mkroot "$G" running; run schema "$G" "$@"
  if [ "$RC" -ne 0 ] && grep -q '^REFUSED: ' <<<"$OUT" && ! grep -q '^SCHEMA-READY' <<<"$OUT"; then
    ok "schema refused (exit $RC, no SCHEMA-READY): $name ($(grep -m1 '^REFUSED' <<<"$OUT" | cut -c1-100))"
  else bad "schema $name: exit=$RC out=$(tr '\n' ' ' <<<"$OUT" | cut -c1-200)"; fi
}
schema_refused "migration command exits 1 although the relation count would succeed" STUB_NIX=fail
schema_refused "migration exits 0 with no success marker" STUB_NIX=nomarker
schema_refused "success marker for fewer migrations than the repository has" STUB_NIX=short
schema_refused "marker present but schema_migrations is partial" STUB_VERSIONS="$(cut -d, -f1-3 <<<"$EXPECTED_VERSIONS")"
schema_refused "marker present but schema_migrations has an extra version" STUB_VERSIONS="$EXPECTED_VERSIONS,29990101000000"
schema_refused "migrations recorded but an interface table is missing" STUB_TABLES=8

log "== lifecycle: $PASSES passed, $FAILS failed"
[ "$FAILS" = 0 ]
