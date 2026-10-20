#!/usr/bin/env bash
# ADR-0016 hermetic test of priv/dev_summary_access/accept.sh: it fails
# closed. No database is involved: psql is a stub (ACCEPT_PSQL) that records
# every call and answers from fixture files. Every case checks the exit
# status, the last line (ACCEPTANCE PASS only when everything holds,
# otherwise ACCEPTANCE STOP) and that every printed line is a fixed label
# line.
#
#   test/dev_summary_access/accept-test.sh [LOG]
#
# Exit 0 only if every case passes.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd -P)
ACCEPT="$REPO/priv/dev_summary_access/accept.sh"
LOG=${1:-/dev/null}
PASSES=0 FAILS=0
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
pass() { PASSES=$((PASSES + 1)); log "PASS $*"; }
fail() { FAILS=$((FAILS + 1)); log "FAIL $*"; }

base=$(mktemp -d "${TMPDIR:-/tmp}/d168accept.XXXXXX"); base=$(cd -P "$base" && pwd -P); chmod 700 "$base"
trap 'rm -rf "$base"' EXIT
FX="$base/fx"; mkdir "$FX"
export STUB_FX="$FX" STUB_CALLS="$base/psql.calls"

cat > "$base/psql" <<'EOF'
#!/usr/bin/env bash
# Stub psql: record the call and the libpq-relevant environment, then answer.
{ printf 'CALL'; printf ' [%s]' "$@"; printf '\n'; printf 'ENV %s\n' "$(env | grep -E '^(PG|PSQL)' | cut -d= -f1 | sort | tr '\n' ' ')"; } >> "$STUB_CALLS"
args="$*"
answer() {
  [ -f "$STUB_FX/$1.out" ] && /bin/cat "$STUB_FX/$1.out"
  if [ -f "$STUB_FX/$1.sleep" ]; then sleep "$(/bin/cat "$STUB_FX/$1.sleep")" & echo $! > "$STUB_FX/sleep.pid"; wait $!; fi
  exit "$(/bin/cat "$STUB_FX/$1.rc" 2>/dev/null || echo 0)"
}
case "$args" in
  *attest.sql*) answer attest ;;
  *accept.sql*) answer acceptsql ;;
  *dbname=postgres\ user=sdr_summary_login*) answer reject_postgres ;;
  *dbname=template1\ user=sdr_summary_login*) answer reject_template1 ;;
  *dbname=sdr_agent_dev\ user=sdr_summary_login*) answer login ;;
esac
echo "stub: unexpected call" >&2; exit 99
EOF
chmod 700 "$base/psql"

good() {
  rm -f "$FX"/*
  { printf 'G summary functions|...\n'; printf 'A roles present (must be 2)|2\n'; printf 'ATTEST PASS: 36 of 36 checks hold\n'; printf 'END-OF-SUMMARY-ATTEST\n'; } > "$FX/attest.out"
  { for n in 2 3 4 5 6 7 8 9 10 11 12 13 14; do printf 'ACCEPT %s check %s (must be x)|x|ok\n' "$n" "$n"; done; printf 'ACCEPT-SQL PASS\n'; } > "$FX/acceptsql.out"
  for db in postgres template1; do
    printf 'psql: error: connection to server at "127.0.0.1", port 61999 failed: FATAL:  pg_hba.conf rejects connection for host "127.0.0.1", user "sdr_summary_login", database "%s", no encryption\n' "$db" > "$FX/reject_$db.out"
    echo 2 > "$FX/reject_$db.rc"
  done
  echo t > "$FX/login.out"
}

# run NAME WANT(pass|stop) [STOP-LABEL-NUMBER] [CALLS] [-- accept.sh args]
run() {
  local name=$1 want=$2 label=${3:-} calls=${4:-} out rc last ncalls; shift 4
  [ "${1:-}" = -- ] && shift
  : > "$STUB_CALLS"
  out=$(env ACCEPT_PSQL="${STUB_PSQL:-$base/psql}" PGHOST=evil.invalid PGPORT=5520 PGSERVICE=evil PGDATABASE=sdr_agent_dev PSQLRC=/nonexistent \
        bash "$ACCEPT" "$@" 2>&1); rc=$?
  last=$(tail -1 <<<"$out"); ncalls=$(grep -c '^CALL' "$STUB_CALLS")
  local why=""
  if [ "$want" = pass ]; then
    [ "$rc" = 0 ] && [ "$last" = "ACCEPTANCE PASS" ] || why="$why exit=$rc last='$last'"
  else
    [ "$rc" = 3 ] && [ "$last" = "ACCEPTANCE STOP" ] || why="$why exit=$rc last='$last'"
    grep -q '^ACCEPTANCE PASS' <<<"$out" && why="$why printed-PASS"
    [ -z "$label" ] || grep -qE "^ACCEPT $label .*\|STOP(\||$)" <<<"$out" || why="$why no-STOP-for-$label"
  fi
  grep -vqE '^ACCEPT(ANCE)? ' <<<"$out" && why="$why non-label-line"
  [ -z "$calls" ] || [ "$ncalls" = "$calls" ] || why="$why psql-calls=$ncalls"
  grep -q '^ENV .*[A-Z]' "$STUB_CALLS" && why="$why libpq-env-reached-psql"
  if grep '^CALL' "$STUB_CALLS" | grep -v 'host=127.0.0.1 hostaddr=127.0.0.1 port=' | grep -q .; then why="$why implicit-endpoint"; fi
  [ -z "$why" ] && pass "$name" || fail "$name:$why"
}

log "== ADR-0016 accept.sh hermetic test $(date -u +%Y-%m-%dT%H:%M:%SZ) bash $BASH_VERSION accept.sh sha256 $(shasum -a 256 "$ACCEPT" | cut -d' ' -f1)"
good; run "all components hold: ACCEPTANCE PASS with 5 explicit-endpoint psql calls, hostile PG*/PSQLRC never reach psql" pass "" 5 -- 61999
grep -q 'port=61999 dbname=sdr_agent_dev user=postgres' "$STUB_CALLS" && pass "attest and accept.sql run as postgres on sdr_agent_dev at the given port" || fail "superuser connection string"

for p in "" 05520 +5520 " 5520" 5520.0 0x15a0 70000 0 abc; do
  good; run "port '${p}' refused before any psql call" stop 0 0 -- "$p"
done
good; run "a missing port argument refused before any psql call" stop 0 0 --

good; echo 3 > "$FX/attest.rc"; run "attest.sql exits 3" stop 1 "" -- 61999
good; sed -i.bak '$d' "$FX/attest.out"; run "attest.sql output without its END marker" stop 1 "" -- 61999
good; sed -i.bak 's/36 of 36/35 of 35/' "$FX/attest.out"; run "attest.sql passing a different number of checks" stop 1 "" -- 61999
good; { printf 'E table-level or sequence privileges of either role (any route) (must be 0)|1|FAILED\n'; /bin/cat "$FX/attest.out"; } > "$FX/attest.new" && mv "$FX/attest.new" "$FX/attest.out"
out=$(env ACCEPT_PSQL="$base/psql" bash "$ACCEPT" 61999 2>&1)
grep -qxF 'ACCEPT 1 attest failed: E table-level or sequence privileges of either role (any route)' <<<"$out" && ! grep -q '|1|FAILED' <<<"$out" \
  && pass "a FAILED attest row is reported by its fixed name only, never its value" || fail "attest failure reporting"
run "a FAILED attest row even with a PASS line" stop 1 "" -- 61999

good; echo 3 > "$FX/acceptsql.rc"; run "accept.sql exits 3" stop 2-14 "" -- 61999
good; sed -i.bak '$d' "$FX/acceptsql.out"; run "accept.sql without ACCEPT-SQL PASS" stop 2-14 "" -- 61999
good; sed -i.bak 's/^ACCEPT 9 \(.*\)|ok$/ACCEPT 9 \1|STOP/' "$FX/acceptsql.out"; run "accept.sql with one STOP row (and a PASS line)" stop 9 "" -- 61999
good; sed -i.bak '/^ACCEPT 13 /d' "$FX/acceptsql.out"; run "accept.sql with only 12 ok rows" stop 2-14 "" -- 61999
good; : > "$FX/acceptsql.out"; run "accept.sql printing nothing" stop 2-14 "" -- 61999

good; : > "$FX/reject_postgres.out"; echo 0 > "$FX/reject_postgres.rc"; run "the login reaches database postgres" stop 15 "" -- 61999
good; echo 'psql: error: FATAL:  role "sdr_summary_login" does not exist' > "$FX/reject_template1.out"; run "template1 refused for another reason than pg_hba" stop 16 "" -- 61999
good; echo f > "$FX/login.out"; run "the login session settings are not the reviewed ones" stop 17 "" -- 61999
good; echo 2 > "$FX/login.rc"; run "the login cannot reach sdr_agent_dev" stop 17 "" -- 61999

good; STUB_PSQL=/nonexistent/psql run "psql not found" stop 1 0 -- 61999

# Interrupted mid-run: the last line must still be ACCEPTANCE STOP.
good; echo 30 > "$FX/acceptsql.sleep"
: > "$STUB_CALLS"
env ACCEPT_PSQL="$base/psql" bash "$ACCEPT" 61999 > "$base/int.out" 2>&1 & APID=$!
for _ in $(seq 1 50); do grep -q accept.sql "$STUB_CALLS" 2>/dev/null && break; sleep 0.1; done
kill -TERM "$APID"
for _ in $(seq 1 50); do [ -s "$FX/sleep.pid" ] && break; sleep 0.1; done
kill "$(/bin/cat "$FX/sleep.pid")" 2>/dev/null
wait "$APID"; rc=$?
[ "$(tail -1 "$base/int.out")" = "ACCEPTANCE STOP" ] && [ "$rc" = 3 ] && ! grep -q '^ACCEPTANCE PASS' "$base/int.out" \
  && pass "interrupted (SIGTERM) mid-run: last line ACCEPTANCE STOP, exit $rc" || fail "interrupted run: exit=$rc last='$(tail -1 "$base/int.out")'"

log "== accept: $PASSES passed, $FAILS failed"
[ "$FAILS" = 0 ]
