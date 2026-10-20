#!/usr/bin/env bash
# ADR-0016 / D-173 owner path, run for real through owner-run.sh on two
# THROWAWAY clusters only (throwaway-cluster.sh + guard.sh), each with a
# short-path Unix socket so the devenv cluster's local endpoint is
# exercised:
#   A  the target: app schema from the repository's migrations;
#   B  a decoy with log_connections on. Every owner-run.sh command runs
#      through the exact launch documented in OWNER-STEPS.md, from a zsh
#      caller whose environment is hostile: aimed at B (PGHOST=B's socket,
#      PGHOSTADDR, PGPORT, PGSERVICE + PGSERVICEFILE, PGDATABASE, PGUSER,
#      PGDATA, PGOPTIONS='-c default_transaction_read_only=on', PSQLRC) and
#      at the shell (decoy bash/env/psql/pg_dump/git on PATH, BASH_ENV, ENV,
#      SHELLOPTS+PS4, BASHOPTS, exported functions). B must log no
#      connection, no sentinel may run, and A's writes must succeed
#      (PGOPTIONS would make them fail).
# On A it also shows the acceptance check STOPs on a local-rule tamper and
# on the same-second edit-not-reloaded schedule (where the r4 check would
# have passed), and passes only after the rules are effectively loaded.
# Never the dev cluster: both clusters are created here and destroyed at
# the end; the guard refuses anything else.
#
#   ADV_PGBIN=<postgresql-18.6 bin> test/dev_summary_access/owner-path-test.sh BASE [LOG]
#   BASE: a private (mode 700) physical directory under /private/tmp or
#   /private/var/folders.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/../.." && pwd -P)
# shellcheck source=guard.sh
. "$HERE/guard.sh"
guard_scrub_env
: "${ADV_PGBIN:?set ADV_PGBIN}"
BASE=${1:?usage: owner-path-test.sh BASE [LOG]}
LOG=${2:-/dev/null}
PSQL="$ADV_PGBIN/psql"
GUARD_CONTROLDATA="$ADV_PGBIN/pg_controldata"
TC="$HERE/throwaway-cluster.sh"
PASSES=0 FAILS=0
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
pass() { PASSES=$((PASSES + 1)); log "PASS $*"; }
fail() { FAILS=$((FAILS + 1)); log "FAIL $*"; }
sum() { shasum -a 256 "$1" | cut -d' ' -f1; }

W=$(mktemp -d "$BASE/owner-path.XXXXXX"); chmod 700 "$W"
SOCKA=$(mktemp -d /private/tmp/d168sA.XXXXXX); SOCKB=$(mktemp -d /private/tmp/d168sB.XXXXXX); chmod 700 "$SOCKA" "$SOCKB"
ROOTA="" ROOTB=""
cleanup() {
  local r
  if [ -n "${OWNER_PATH_KEEP:-}" ]; then log "   kept: $ROOTA $ROOTB $W"; return; fi
  for r in "$ROOTA" "$ROOTB"; do [ -n "$r" ] && ADV_PGBIN=$ADV_PGBIN bash "$TC" destroy "$r" >/dev/null 2>&1; done
  rmdir "$SOCKA" "$SOCKB" 2>/dev/null
  chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"
}
trap cleanup EXIT

# Start a throwaway root with a Unix socket: the same offline and stopped
# guards as throwaway-cluster.sh start, then the running and server identity.
DEVENV_HBA='local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
local   replication     all                                     trust
host    replication     all             127.0.0.1/32            trust
host    replication     all             ::1/128                 trust'
start_with_socket() {
  local root=$1 sock=$2 extra=$3
  ( guard_offline "$root"; guard_stopped
    printf '%s\n' "$DEVENV_HBA" > "$GUARD_PGDATA/pg_hba.conf"
    "$ADV_PGBIN/pg_ctl" -D "$GUARD_PGDATA" -l "$root/server.log" -w -t 30 \
      -o "-p $GUARD_PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=$sock $extra" start >/dev/null
    guard_running; guard_connect_identity "$PSQL" ) || { log "FAIL could not start $root"; exit 1; }
}
ROOTA=$(ADV_PGBIN=$ADV_PGBIN bash "$TC" init "$BASE") && ROOTB=$(ADV_PGBIN=$ADV_PGBIN bash "$TC" init "$BASE") || { log "FAIL init"; exit 1; }
start_with_socket "$ROOTA" "$SOCKA" ""
start_with_socket "$ROOTB" "$SOCKB" "-c log_connections=on"
guard_offline "$ROOTA"; PA=$GUARD_PORT; PGDA=$GUARD_PGDATA
guard_offline "$ROOTB"; PB=$GUARD_PORT; PGDB=$GUARD_PGDATA
log "== ADR-0016 owner path through owner-run.sh $(date -u +%Y-%m-%dT%H:%M:%SZ): A port $PA socket $SOCKA, decoy B port $PB socket $SOCKB"
out=$(ADV_PGBIN=$ADV_PGBIN bash "$TC" schema "$ROOTA" 2>&1) && grep -q '^SCHEMA-READY' <<<"$out" || { log "FAIL schema on A"; exit 1; }
guard_offline "$ROOTA"; guard_running; guard_connect_identity "$PSQL"
SUA="host=127.0.0.1 hostaddr=127.0.0.1 port=$PA dbname=sdr_agent_dev user=postgres sslmode=disable"
"$PSQL" -X -q -d "host=127.0.0.1 hostaddr=127.0.0.1 port=$PB dbname=postgres user=postgres sslmode=disable" -c "CREATE DATABASE sdr_agent_dev" >/dev/null
su_a() { "$PSQL" -X -q -At -v ON_ERROR_STOP=1 -d "$SUA" "$@"; }
b_conns() { grep -c 'connection received' "$ROOTB/server.log"; }

# The package runs from a git copy of this worktree, so --commit binds it.
REPO="$W/repo"; mkdir -p "$REPO/priv" "$REPO/docs/adr"
cp -Rp "$SRC/priv/dev_summary_access" "$REPO/priv/"; cp -p "$SRC/docs/adr/0016-dev-db-summary-access.md" "$REPO/docs/adr/"
g() { env -i PATH=/usr/bin:/bin HOME="$W" /usr/bin/git -C "$REPO" -c user.name=t -c user.email=t@example.invalid "$@"; }
g init -q && g add -A && g commit -q -m fixture
C=$(g rev-parse HEAD)
OR="$REPO/priv/dev_summary_access/owner-run.sh"
log "   package copied from $(git -C "$SRC" rev-parse HEAD)$(git -C "$SRC" diff --quiet HEAD -- priv/dev_summary_access docs/adr || echo ' +uncommitted') owner-run.sh sha256 $(sum "$OR")"

# Every owner-run.sh call uses the EXACT launch documented in OWNER-STEPS.md,
# from a hostile zsh caller (hostile-launch.sh: decoy bash/env/psql/pg_dump/
# git on PATH, BASH_ENV, ENV, SHELLOPTS+PS4, BASHOPTS, exported functions).
# shellcheck source=hostile-launch.sh
. "$HERE/hostile-launch.sh"
hostile_setup "$W/hl"
LAUNCH=$(launch_line "$REPO/priv/dev_summary_access/OWNER-STEPS.md")
[ -n "$LAUNCH" ] || { log "FAIL no documented launch line"; exit 1; }
log "   documented launch: $LAUNCH"
printf '[decoy]\nhost=127.0.0.1\nhostaddr=127.0.0.1\nport=%s\ndbname=sdr_agent_dev\nuser=postgres\n' "$PB" > "$W/pg_service.conf"
printf '\\set ON_ERROR_STOP off\n' > "$W/psqlrc"
BP="$W/backups"; mkdir -m 700 "$BP"
OUT="$W/out"
# orun NAME ok|refused COMMAND ARGS...
orun() {
  local name=$1 want=$2 rc; shift 2
  HOSTILE_EXTRA=(PGHOST="$SOCKB" PGHOSTADDR=127.0.0.1 PGPORT="$PB" PGSERVICE=decoy PGSERVICEFILE="$W/pg_service.conf"
                 PGDATABASE=sdr_agent_dev PGUSER=postgres PGDATA="$PGDB" "PGOPTIONS=-c default_transaction_read_only=on"
                 PGCONNECT_TIMEOUT=1 PSQLRC="$W/psqlrc")
  hostile_call zsh "$LAUNCH" "$OR" "$OUT" "$@"; rc=$?
  if [ -s "$HL_SENT" ]; then fail "$name: a sentinel or decoy ran: $(tr '\n' ';' < "$HL_SENT")"; : > "$HL_SENT"; return; fi
  if [ "$want" = ok ]; then
    [ "$rc" = 0 ] && [ "$(tail -1 "$OUT")" = "OWNER-RUN $1 OK" ] && pass "$name" \
      || fail "$name: exit=$rc $(tail -1 "$OUT") $(grep -E '^ACCEPT .*\|STOP' "$OUT" | cut -c1-300 | tr '\n' ';')"
  else
    [ "$rc" = 3 ] && tail -1 "$OUT" | grep -q '^OWNER-RUN REFUSED' && pass "$name (refused)" || fail "$name: exit=$rc $(tail -1 "$OUT")"
  fi
}
A=(--commit "$C" --port "$PA")
accept_labels() { grep -E '^ACCEPT [0-9]+ .*\|STOP' "$OUT" | cut -d' ' -f2 | sort -un | tr '\n' ' '; }
stop_on() { local n miss=""; for n in $2; do grep -qE "^ACCEPT $n .*\|STOP" "$OUT" || miss="$miss $n"; done
  [ -z "$miss" ] && grep -qx 'ACCEPTANCE STOP' "$OUT" && pass "acceptance STOPs on $1 (STOP: $(accept_labels))" || fail "acceptance on $1: missing STOP$miss; STOP: $(accept_labels)"; }
n0=$(b_conns)
[ "$n0" -ge 1 ] && pass "positive control: decoy B's log records connections ($n0 so far, from this test's own setup)" || fail "decoy B logs no connections at all"

# 1. The owner path in OWNER-STEPS.md order.
orun "preflight" ok preflight "${A[@]}" --pgdata "$PGDA"
orun "backup" ok backup "${A[@]}" --pgdata "$PGDA" --backup-parent "$BP"
BK=$(sed -n 's/^BACKUP-DIR //p' "$OUT")
tables=$(su_a -c "SELECT count(*) FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relkind = 'r'")
[ -n "$BK" ] && [ "$(grep -c ' TABLE DATA public ' "$BK/toc.txt")" = "$tables" ] && cmp -s "$BK/pg_hba.conf.before" "$PGDA/pg_hba.conf" \
  && pass "backup holds table data for all $tables public tables of A and A's pg_hba.conf" || fail "backup content"
orun "install (PGOPTIONS read-only would have made it fail)" ok install "${A[@]}" --backup "$BK"
orun "revoke-inventory" ok revoke-inventory "${A[@]}"
orun "revoke-apply" ok revoke-apply "${A[@]}" --backup "$BK"
orun "accept before pg_hba" refused accept "${A[@]}"
stop_on "the revokes without pg_hba (the login reaches every database over TCP and the socket)" "13 16 17 19"
orun "hba-apply" ok hba-apply "${A[@]}" --pgdata "$PGDA" --backup "$BK"
orun "accept after hba-apply" ok accept "${A[@]}"
[ "$(grep -c '|ok$' "$OUT")" = 20 ] && grep -q '^ACCEPT 19 login over every Unix socket .*directories=1|ok$' "$OUT" \
  && pass "  ... 20 ok lines, the Unix-socket probe ran against A's real socket" || fail "  ... accept lines"
WANT="$W/applied"; cp -p "$PGDA/pg_hba.conf" "$WANT"
out=$("$PSQL" -X -q -At -d "host=$SOCKA port=$PA dbname=postgres user=sdr_summary_login sslmode=disable" -c 'select 1' 2>&1)
grep -q 'pg_hba.conf rejects connection' <<<"$out" && pass "direct probe: the login is rejected by pg_hba over A's Unix socket" || fail "socket probe: $out"

# 2. A local-rule tamper, effectively loaded: STOP on the file and the live socket.
rules=$(grep -vE '^[[:space:]]*(#|$)' "$REPO/priv/dev_summary_access/pg_hba-summary.conf")
tampered() { { sed -n 1,5p <<<"$rules"; /bin/cat "$BK/pg_hba.conf.before"; } > "$PGDA/pg_hba.conf"; }
tampered
orun "hba-reload of the tampered file" ok hba-reload "${A[@]}" --pgdata "$PGDA"
orun "accept with the local reject rules removed and loaded" refused accept "${A[@]}"
stop_on "a local-rule tamper" "13 19"

# 3. The same-second schedule: active rules lack the local rejects; the file
# is corrected within the same second as the last reload, not reloaded.
same=no
for i in 1 2 3 4 5 6 7 8; do
  tampered
  l0=$(su_a -c "select pg_conf_load_time()")
  su_a -c "select pg_reload_conf()" >/dev/null
  for _ in $(seq 1 100); do [ "$(su_a -c "select pg_conf_load_time() > '$l0'")" = t ] && break; done
  /bin/cat "$WANT" > "$PGDA/pg_hba.conf"
  r=$(su_a -F'|' -c "select date_trunc('second', pg_conf_load_time()) = (pg_stat_file(current_setting('hba_file'))).modification, pg_conf_load_time() >= (pg_stat_file(current_setting('hba_file'))).modification")
  if [ "${r%%|*}" = t ]; then same=yes; OLD=${r#*|}; break; fi
  sleep 0.3
done
if [ "$same" = yes ]; then
  log "   same-second schedule confirmed (attempt $i): the reload and the corrected file share one second; the r4 check (load >= mtime) reads '$OLD'"
  cmp -s "$PGDA/pg_hba.conf" "$WANT" && pass "the on-disk file is the correct applied content" || fail "on-disk file"
  orun "accept on the same-second edit-not-reloaded state" refused accept "${A[@]}"
  stop_on "the same-second edit-not-reloaded state (file correct, socket still open)" "14 19"
  grep -qE '^ACCEPT 13 .*\|ok$' "$OUT" && pass "  ... while the file check (13) alone reads ok" || fail "  ... check 13"
else fail "could not produce the same-second schedule in 8 attempts"; fi
orun "hba-reload (effective apply)" ok hba-reload "${A[@]}" --pgdata "$PGDA"
orun "accept after the effective reload" ok accept "${A[@]}"
[ "$(/usr/bin/stat -f '%Lp' "$PGDA/pg_hba.conf")" = "$(/usr/bin/stat -f '%Lp' "$BK/pg_hba.conf.before")" ] && pass "pg_hba.conf mode kept" \
  || fail "pg_hba.conf mode: live $(/usr/bin/stat -f '%Lp' "$PGDA/pg_hba.conf") backup copy $(/usr/bin/stat -f '%Lp' "$BK/pg_hba.conf.before")"

# 4. Rollback through owner-run.sh.
orun "end-login-sessions" ok end-login-sessions "${A[@]}"
orun "uninstall" ok uninstall "${A[@]}"
orun "revoke-restore" ok revoke-restore "${A[@]}"
orun "hba-restore" ok hba-restore "${A[@]}" --pgdata "$PGDA" --backup "$BK"
cmp -s "$PGDA/pg_hba.conf" "$BK/pg_hba.conf.before" && [ "$(find "$PGDA" -name '.pg_hba.conf.d173.*' | wc -l | tr -d ' ')" = 0 ] \
  && pass "rollback: A's pg_hba.conf is the backup copy byte for byte, no staging file" || fail "rollback pg_hba"
[ "$(su_a -c "select count(*) from pg_roles where rolname like 'sdr_summary_%'")" = 0 ] \
  && [ "$(su_a -c "select has_database_privilege('public', 'sdr_agent_dev', 'TEMP') and has_function_privilege('public', 'lo_create(oid)', 'EXECUTE')")" = t ] \
  && pass "rollback: roles gone, PUBLIC TEMP and large-object EXECUTE back" || fail "rollback state"
orun "accept after rollback" refused accept "${A[@]}"

# 5. Nothing reached the decoy or used the hostile PATH.
[ "$(b_conns)" = "$n0" ] && pass "decoy B logged no connection during every owner-run.sh step (hostile PGHOST, PGHOSTADDR, PGPORT, PGSERVICE, PGSERVICEFILE, PGDATABASE, PGUSER, PGDATA, PGOPTIONS)" \
  || fail "decoy B logged $(( $(b_conns) - n0 )) connections"
[ ! -s "$HL_SENT" ] && pass "no startup file, exported function, xtrace or decoy binary ran in any launch" || fail "sentinels: $(tr '\n' ';' < "$HL_SENT")"

log "== owner-path: $PASSES passed, $FAILS failed"
[ "$FAILS" = 0 ]
