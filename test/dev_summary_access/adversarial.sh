#!/usr/bin/env bash
# ADR-0016 adversarial test for the dev DB summary-access role.
#
# THROWAWAY CLUSTER ONLY. It installs, uninstalls, seeds synthetic rows and
# changes privileges. Never point it at the dev cluster (5520) or any owner
# database. Start a scratch cluster first (initdb into a scratch dir, a
# non-default port, trust on 127.0.0.1), restore the app schema only (no
# data) into a database named sdr_agent_dev on it, then:
#
#   ADV_PGBIN=/path/to/postgresql/bin ADV_PORT=55468 ADV_PGDATA=/private/tmp/.../pgdata \
#   [ADV_REF_DIR=dir with g3-inventory.sql and claude-gdemo-drain.sql] \
#   [ADV_LOG=path] test/dev_summary_access/adversarial.sh
#
# The login-side calls connect as the real LOGIN role sdr_summary_login.
# Exit 0 only if every check passes. RESIDUAL lines are known, accepted gaps
# (ADR-0016 "Residual risks"), not failures. The log holds verdicts and
# SQLSTATEs only, never function output or seeded values.

set -u
: "${ADV_PGBIN:?set ADV_PGBIN}" "${ADV_PORT:?set ADV_PORT}" "${ADV_PGDATA:?set ADV_PGDATA}"
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SQL="$ROOT/priv/dev_summary_access"
LOG=${ADV_LOG:-/dev/null}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/d168adv.XXXXXX")
ALL="$WORK/login-output.all"
: > "$ALL"
PSQL="$ADV_PGBIN/psql"
H=127.0.0.1
PASSES=0
FAILS=0

log() { printf '%s\n' "$*" | tee -a "$LOG"; }
pass() { PASSES=$((PASSES + 1)); log "PASS $*"; }
fail() { FAILS=$((FAILS + 1)); log "FAIL $*"; }
residual() { log "RESIDUAL $*"; }

su() { "$PSQL" -X -q -At -F'|' -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -h $H -p "$ADV_PORT" -U postgres -d sdr_agent_dev "$@"; }
lg() { "$PSQL" -X -q -At -F'|' -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -h $H -p "$ADV_PORT" -U sdr_summary_login -d sdr_agent_dev "$@"; }

# --- Guard: refuse anything that is not the named throwaway cluster. ---
if [ "$ADV_PORT" = 5520 ]; then echo "REFUSED: 5520 is the dev cluster"; exit 2; fi
case "$ADV_PGDATA" in /private/tmp/*|/tmp/*) ;; *) echo "REFUSED: ADV_PGDATA must be under /private/tmp or /tmp"; exit 2;; esac
DD=$(su -c "SHOW data_directory" 2>/dev/null)
if [ "$DD" != "$ADV_PGDATA" ] && [ "$DD" != "$(cd "$ADV_PGDATA" 2>/dev/null && pwd -P)" ]; then
  echo "REFUSED: the server on $ADV_PORT is not the cluster at ADV_PGDATA"; exit 2
fi

log "== ADR-0016 adversarial run $(date -u +%Y-%m-%dT%H:%M:%SZ) port=$ADV_PORT server=$(su -c 'SHOW server_version')"
log "   repo head $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)$(git -C "$ROOT" diff --quiet 2>/dev/null || echo '+dirty')"
log "   install.sql sha256 $(shasum -a 256 "$SQL/install.sql" | cut -c1-16)  attest.sql sha256 $(shasum -a 256 "$SQL/attest.sql" | cut -c1-16)"

# Run as the login, keep its output for the leak check, return it.
lgc() { local out; out=$(lg "$@" 2>&1); printf '%s\n' "$out" >> "$ALL"; printf '%s\n' "$out"; }

# expect_err NAME SQLSTATE psql-args...   (as the login)
expect_err() {
  local name=$1 code=$2 out; shift 2
  out=$(lgc "$@")
  if grep -q "ERROR:  $code:" <<<"$out"; then pass "$name ($code)"
  else fail "$name: expected $code, got: $(grep -m1 -E 'ERROR|FATAL' <<<"$out" | cut -c1-140 || echo 'no error')"; fi
}
# expect_err_su NAME SQLSTATE psql-args...   (as the superuser, for SET ROLE probes)
expect_err_su() {
  local name=$1 code=$2 out; shift 2
  out=$(su "$@" 2>&1)
  if grep -q "ERROR:  $code:" <<<"$out"; then pass "$name ($code)"
  else fail "$name: expected $code, got: $(grep -m1 -E 'ERROR|FATAL' <<<"$out" | cut -c1-140 || echo 'no error')"; fi
}

norm_fn() { awk -F'|' '$4!="target" && $4!="END" {o=$4; for(i=5;i<=NF;i++) if($i!="") o=o "|" $i; print o}' | sort; }
# Reference psql output: drop markers and blanks, join non-empty fields, and
# apply the functions' label sanitization to the one seeded odd event type.
norm_ref() {
  grep -vE '^(target|END-OF)' | grep -v '^$' |
    awk -F'|' '{o=""; for(i=1;i<=NF;i++) if($i!="") o=o (o==""?"":"|") $i; print o}' |
    sed 's/|model\.Y<b>SEEDSECRET-BOUNDTYPE|/|other|/' | sort
}
G3="select * from summary.g3_inventory_v1()"
PRE="select * from summary.gdemo_drain_v1('pre', null, null, null)"
POST="select * from summary.gdemo_drain_v1('post', '2026-10-19T02:20:00Z', 3, '{b1,b2,b5}')"
POST_WRONG="select * from summary.gdemo_drain_v1('post', '2026-10-19T02:20:00Z', 4, '{b1,b2,b5}')"
field() { awk -F'|' -v s="$1" -v f="$2" '$4==s {print $f; exit}'; }

# --- 1. Install, atomicity, attestation. ---
log "-- 1 install and attestation"
if [ "$(su -c "select count(*) from pg_roles where rolname like 'sdr\_summary\_%'")" != 0 ]; then
  su -f "$SQL/uninstall.sql" >/dev/null 2>&1 || { fail "uninstall of a previous install"; exit 1; }
fi
out=$(su -f "$SQL/install.sql" 2>&1)
if [ "$(tail -1 <<<"$out")" = END-OF-SUMMARY-INSTALL ]; then pass "install completes"; else fail "install: $(grep -m1 ERROR <<<"$out")"; exit 1; fi
before=$(su -f "$SQL/attest.sql" | grep '^G summary functions|')
out=$(su -f "$SQL/install.sql" 2>&1)
after=$(su -f "$SQL/attest.sql" | grep '^G summary functions|')
if grep -q 'ERROR:  42710:' <<<"$out" && ! grep -q END-OF-SUMMARY-INSTALL <<<"$out" && [ "$before" = "$after" ]; then
  pass "second install refuses atomically (42710), installed functions unchanged"
else fail "second install was not an atomic refusal"; fi
out=$("$PSQL" -X -q -v ON_ERROR_STOP=1 -h $H -p "$ADV_PORT" -U postgres -d postgres -f "$SQL/install.sql" 2>&1)
if grep -q '^REFUSED: connect to sdr_agent_dev' <<<"$out"; then pass "install refuses another database"; else fail "install ran outside sdr_agent_dev"; fi

attest_check() {
  local label=$1 out bad
  out=$(su -f "$SQL/attest.sql" 2>&1)
  if [ "$(tail -1 <<<"$out")" != END-OF-SUMMARY-ATTEST ]; then fail "$label: attest incomplete"; return; fi
  bad=$(awk -F'|' '$1 ~ /\(must be [^)]*\)$/ { m=$1; sub(/.*\(must be /, "", m); sub(/\)$/, "", m); if ($2 != m) print $1 "=" $2 }' <<<"$out")
  if [ -z "$bad" ]; then pass "$label: every attest check holds ($(grep -c '(must be' <<<"$out") checks)"
  else fail "$label: $bad"; fi
}
attest_check "attest after install"
su -f "$SQL/attest.sql" | grep '^G summary functions|' | awk -F'|' '{print "   " $2 " prosrc_sha256=" substr($12,1,16) " def_sha256=" substr($13,1,16)}' | tee -a "$LOG"

# --- 2. Seed synthetic data, then compare with the reviewed psql scripts. ---
log "-- 2 expected counts"
su -f "$HERE/seed.sql" >/dev/null 2>&1 || { fail "seed"; exit 1; }
compare() {
  local name=$1 call=$2 ref; shift 2
  if [ -z "${ADV_REF_DIR:-}" ]; then log "SKIP $name: no ADV_REF_DIR"; return; fi
  ref=$("$PSQL" -X -q -At -F'|' -v ON_ERROR_STOP=1 -h $H -p "$ADV_PORT" -U postgres -d sdr_agent_dev "$@" 2>&1 | norm_ref)
  if [ "$(lgc -c "$call" | norm_fn)" = "$ref" ] && [ -n "$ref" ]; then pass "$name matches the reviewed psql script ($(wc -l <<<"$ref" | tr -d ' ') rows)"
  else fail "$name differs from the reviewed psql script"; fi
}
compare "g3 inventory" "$G3" -f "${ADV_REF_DIR:-}/g3-inventory.sql"
compare "drain pre, undrained" "$PRE" -v phase=pre -f "${ADV_REF_DIR:-}/claude-gdemo-drain.sql"
compare "drain post, undrained" "$POST" -v phase=post -v start_at=2026-10-19T02:20:00Z -v b1_attempts=3 -v workshop_buckets=b1,b2,b5 -f "${ADV_REF_DIR:-}/claude-gdemo-drain.sql"
v=$(lgc -c "$POST" | field CHECK 5)
[ "$v" = "STOP: a DRAIN row is not 0" ] && pass "undrained post verdict is STOP" || fail "undrained post verdict: $v"
# Drain the fence (superuser, synthetic rows), then GO with the reviewed
# terms and STOP with any other term.
su -c "update public.agent_runs set status = 'succeeded' where status = 'queued'" \
   -c "delete from public.oban_jobs where queue = 'research'" \
   -c "update public.model_invocations set status = 'completed' where status = 'reserved'" >/dev/null
compare "drain pre, drained" "$PRE" -v phase=pre -f "${ADV_REF_DIR:-}/claude-gdemo-drain.sql"
compare "drain post, drained" "$POST" -v phase=post -v start_at=2026-10-19T02:20:00Z -v b1_attempts=3 -v workshop_buckets=b1,b2,b5 -f "${ADV_REF_DIR:-}/claude-gdemo-drain.sql"
compare "drain post, wrong b1 term" "$POST_WRONG" -v phase=post -v start_at=2026-10-19T02:20:00Z -v b1_attempts=4 -v workshop_buckets=b1,b2,b5 -f "${ADV_REF_DIR:-}/claude-gdemo-drain.sql"
v=$(lgc -c "$POST" | field CHECK 5); [ "$v" = GO ] && pass "drained post with reviewed terms is GO" || fail "drained post verdict: $v"
# As in the psql script, a G-DEMO-like grant off the reviewed terms counts
# as unexpected authority (4c), and 4d finds no match.
out=$(lgc -c "$POST_WRONG")
v=$(field CHECK 5 <<<"$out"); d=$(awk -F'|' '$4 ~ /^AUTHORITY 4d/ {print $10}' <<<"$out")
[ "$v" = "STOP: unexpected authority" ] && [ "$d" = 0 ] && pass "wrong b1 term is STOP (4d=0)" || fail "wrong-term verdict: $v 4d=$d"
v=$(lgc -c "$G3" | field END 5); [ "$v" = complete ] && pass "g3 END is complete" || fail "g3 END: $v"
row=$(lgc -c "$G3" | head -1)
[ "$(cut -d'|' -f1,3,4 <<<"$row")" = "sdr_agent_dev|summary.g3_inventory_v1|target" ] && grep -qE '^[^|]*\|20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\|' <<<"$row" \
  && pass "results carry target, UTC read time and function version" || fail "target row: $row"

# Row bound: a section at its limit makes the result incomplete, fail-closed.
su -c "select testseed.ins('oban_jobs', jsonb_build_object('queue', 'q' || lpad(g::text, 3, '0'), 'state', 'available', 'worker', 'W')) from generate_series(1, 150) g" >/dev/null
out=$(lgc -c "$PRE")
n=$(grep -c '|CONTEXT 2 other queues pending' <<<"$out")
[ "$n" = 100 ] && [ "$(field END 5 <<<"$out")" = truncated ] && [ "$(field CHECK 5 <<<"$out")" = "STOP: a section reached its row limit (incomplete)" ] \
  && pass "150 distinct queues: 100 rows, END truncated, CHECK STOP" || fail "row bound: rows=$n END=$(field END 5 <<<"$out")"
su -c "delete from public.oban_jobs where queue ~ '^q[0-9]{3}\$'" >/dev/null

# --- 3. The login reads no table, writes nothing, defines nothing. ---
log "-- 3 data, write and DDL denial (login, read-only default switched off)"
OFF="SET default_transaction_read_only = off"
denied=0; total=0
for t in $(su -c "select format('%I.%I', 'public', c.relname) from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r','p','v','m') order by 1"); do
  total=$((total + 1))
  out=$(lgc -c "select 1 from $t where false")
  grep -q 'ERROR:  42501:' <<<"$out" && denied=$((denied + 1))
done
[ "$total" -gt 0 ] && [ "$denied" = "$total" ] && pass "SELECT denied on every public relation ($denied/$total, 42501)" || fail "SELECT denied on $denied of $total public relations"
out=$(lgc -c "select 1 from public.payloads where false")
grep -q 'ERROR:  42501:' <<<"$out" || fail "payloads readable"
expect_err "INSERT agent_runs" 42501 -c "$OFF" -c "insert into public.agent_runs default values"
expect_err "UPDATE model_invocations" 42501 -c "$OFF" -c "update public.model_invocations set status = 'x' where false"
expect_err "DELETE payloads" 42501 -c "$OFF" -c "delete from public.payloads where false"
expect_err "TRUNCATE audit_events" 42501 -c "$OFF" -c "truncate public.audit_events"
expect_err "COPY payloads out" 42501 -c "copy public.payloads to stdout"
expect_err "INSERT with read-only default on" 25006 -c "insert into public.agent_runs default values"
expect_err "CREATE TABLE in public" 42501 -c "$OFF" -c "create table public.adv_t (i int)"
expect_err "CREATE SCHEMA" 42501 -c "$OFF" -c "create schema adv"
expect_err "CREATE FUNCTION in summary" 42501 -c "$OFF" -c "create function summary.adv() returns int language sql as 'select 1'"
expect_err "CREATE OR REPLACE g3_inventory_v1" 42501 -c "$OFF" -c "create or replace function summary.g3_inventory_v1() returns int language sql as 'select 1'"
expect_err "ALTER FUNCTION SECURITY INVOKER" 42501 -c "$OFF" -c "alter function summary.g3_inventory_v1() security invoker"
expect_err "ALTER FUNCTION OWNER" 42501 -c "$OFF" -c "alter function summary.g3_inventory_v1() owner to sdr_summary_login"
expect_err "DROP FUNCTION" 42501 -c "$OFF" -c "drop function summary.gdemo_drain_v1(text, timestamptz, integer, text[])"
lgc -c "$OFF" -c "grant execute on function summary.g3_inventory_v1() to public" >/dev/null 2>&1
[ "$(su -c "select has_function_privilege('public', 'summary.g3_inventory_v1()', 'EXECUTE')")" = f ] \
  && pass "GRANT EXECUTE TO PUBLIC by the login has no effect" || fail "login granted EXECUTE to PUBLIC"

# --- 4. No escalation. ---
log "-- 4 escalation"
expect_err "SET ROLE sdr_summary_definer" 42501 -c "set role sdr_summary_definer"
expect_err "SET ROLE postgres" 42501 -c "set role postgres"
expect_err "SET SESSION AUTHORIZATION postgres" 42501 -c "set session authorization postgres"
expect_err "pg_read_file" 42501 -c "select pg_read_file('/etc/hosts')"
expect_err "pg_ls_dir" 42501 -c "select pg_ls_dir('.')"
expect_err "pg_stat_file" 42501 -c "select pg_stat_file('postgresql.conf')"
expect_err "server-side lo_import" 42501 -c "$OFF" -c "select lo_import('/etc/hosts')"
expect_err "COPY TO server file" 42501 -c "$OFF" -c "copy (select 1) to '/tmp/d168adv-should-not-exist'"
expect_err "COPY FROM PROGRAM" 42501 -c "$OFF" -c "create temp table adv_c (t text)" -c "copy adv_c from program 'true'"
expect_err "ALTER ROLE self" 42501 -c "$OFF" -c "alter role sdr_summary_login createdb"
expect_err "GRANT definer to self" 42501 -c "$OFF" -c "grant sdr_summary_definer to sdr_summary_login"
out=$("$PSQL" -X -q -h $H -p "$ADV_PORT" -U sdr_summary_definer -d sdr_agent_dev -c "select 1" 2>&1)
grep -q 'not permitted to log in' <<<"$out" && pass "definer cannot log in" || fail "definer login: $(head -1 <<<"$out")"
# The definer's own reach, probed by the superuser assuming it.
expect_err_su "definer SELECT payloads.content" 42501 -c "set role sdr_summary_definer" -c "select content from public.payloads where false"
expect_err_su "definer SELECT model_call_grants.name" 42501 -c "set role sdr_summary_definer" -c "select name from public.model_call_grants where false"
expect_err_su "definer SELECT * model_invocations" 42501 -c "set role sdr_summary_definer" -c "select * from public.model_invocations where false"
expect_err_su "definer INSERT agent_runs" 42501 -c "set role sdr_summary_definer" -c "insert into public.agent_runs default values"
expect_err_su "definer UPDATE model_call_grants" 42501 -c "set role sdr_summary_definer" -c "update public.model_call_grants set status = 'x' where false"
expect_err_su "definer CREATE in public" 42501 -c "set role sdr_summary_definer" -c "create table public.adv_d (i int)"
expect_err_su "definer pg_read_file" 42501 -c "set role sdr_summary_definer" -c "select pg_read_file('/etc/hosts')"

# --- 5. Shadowing: temp objects and caller settings change nothing. ---
log "-- 5 shadowing"
base_g3=$(lgc -c "$G3" | norm_fn)
base_post=$(lgc -c "$POST" | norm_fn)
shadow=(-c "$OFF" -c "set search_path = pg_temp, public, pg_catalog"
  -c "create temp table model_invocations (id uuid, tenant_id uuid, ledger_generation int, provider text, status text, profile_id text, agent_run_id uuid)"
  -c "insert into pg_temp.model_invocations select gen_random_uuid(), gen_random_uuid(), 1, 'shadow', 'completed', 'p', null from generate_series(1, 50)"
  -c "create temp table model_call_grants (id uuid, tenant_id uuid, status text, starts_at timestamp, expires_at timestamp, revoked_at timestamp, total_attempts int, per_utc_day_attempts int, profile_ids text[])"
  -c "create temp view agent_runs as select gen_random_uuid() as id, 'queued'::text as status"
  -c "create function pg_temp.adv_true(text, text) returns boolean language sql as 'select true'"
  -c "create operator pg_temp.~ (leftarg = text, rightarg = text, function = pg_temp.adv_true)"
  -c "create function pg_temp.count(anyelement) returns bigint language sql as 'select 999::bigint'"
  -c "set \"TimeZone\" = 'Pacific/Kiritimati'" -c "set datestyle = 'SQL, DMY'")
[ "$(lgc "${shadow[@]}" -c "$G3" | norm_fn)" = "$base_g3" ] && pass "g3 unchanged under temp tables, views, operator and function shadows" || fail "g3 changed under shadowing"
[ "$(lgc "${shadow[@]}" -c "$POST" | norm_fn)" = "$base_post" ] && pass "drain unchanged under the same shadows and caller TimeZone" || fail "drain changed under shadowing"
residual "login can create TEMP objects in its own session (PUBLIC TEMP default); optional-revoke-temp.sql removes it"

# --- 6. Argument validation: fixed errors, input never echoed. ---
log "-- 6 unsafe arguments"
bad_args() {
  local field=$1 args=$2 out
  out=$(lgc -c "select * from summary.gdemo_drain_v1($args)")
  if grep -q "ERROR:  22023: invalid_argument: $field\$" <<<"$out" \
     && ! grep -qi 'SEEDSECRET\|<b>\|drop table\|02:20:30\|b6\|{{' <<<"$out"; then pass "rejects $field: ($args)"
  else fail "argument ($args): $(grep -m1 -E 'ERROR' <<<"$out" | cut -c1-120 || echo accepted)"; fi
}
bad_args phase "'SEEDSECRET-ARG', null, null, null"
bad_args phase "null, null, null, null"
bad_args phase "'pre''; drop table public.payloads; --', null, null, null"
bad_args phase "'POST', '2026-10-19T02:20:00Z', 3, '{b1}'"
bad_args start_at "'post', null, 3, '{b1}'"
bad_args start_at "'post', '2026-10-19T02:20:30Z', 3, '{b1}'"
bad_args b1_attempts "'post', '2026-10-19T02:20:00Z', 0, '{b1}'"
bad_args b1_attempts "'post', '2026-10-19T02:20:00Z', 6, '{b1}'"
bad_args b1_attempts "'post', '2026-10-19T02:20:00Z', null, '{b1}'"
bad_args workshop_buckets "'post', '2026-10-19T02:20:00Z', 3, null"
bad_args workshop_buckets "'post', '2026-10-19T02:20:00Z', 3, '{}'"
bad_args workshop_buckets "'post', '2026-10-19T02:20:00Z', 3, '{b2,b1}'"
bad_args workshop_buckets "'post', '2026-10-19T02:20:00Z', 3, '{b1,b1}'"
bad_args workshop_buckets "'post', '2026-10-19T02:20:00Z', 3, '{b1,b6}'"
bad_args workshop_buckets "'post', '2026-10-19T02:20:00Z', 3, '{SEEDSECRET-BUCKET}'"
bad_args workshop_buckets "'post', '2026-10-19T02:20:00Z', 3, '{{b1},{b2}}'"
bad_args workshop_buckets "'post', '2026-10-19T02:20:00Z', 3, '{b1,b2,b3,b4,b5,b5}'"
bad_args workshop_buckets "'post', '2026-10-19T02:20:00Z', 3, '{b1,NULL}'"
bad_args "pre takes no terms" "'pre', '2026-10-19T02:20:00Z', null, null"
bad_args "pre takes no terms" "'pre', null, 3, null"
bad_args "pre takes no terms" "'pre', null, null, '{b1}'"

# --- 7. Operational bounds (not security guarantees). ---
log "-- 7 operational bounds"
expect_err "caller statement_timeout cancels a call" 57014 -c "set statement_timeout = '1ms'" -c "select count(*) from summary.g3_inventory_v1(), generate_series(1, 200000)"
su -c "begin" -c "lock table public.model_invocations in access exclusive mode" -c "select pg_sleep(12)" -c "commit" >/dev/null 2>&1 &
LOCKER=$!
sleep 1
expect_err "function lock_timeout (5s) under an exclusive lock" 55P03 -c "$G3"
expect_err "statement_timeout under an exclusive lock" 57014 -c "set statement_timeout = '1s'" -c "$G3"
wait $LOCKER
lg -c "select pg_sleep(6)" >/dev/null 2>&1 & S1=$!
lg -c "select pg_sleep(6)" >/dev/null 2>&1 & S2=$!
sleep 1.5
out=$("$PSQL" -X -q -h $H -p "$ADV_PORT" -U sdr_summary_login -d sdr_agent_dev -c "select 1" 2>&1)
grep -q 'too many connections for role' <<<"$out" && pass "third concurrent login session refused (CONNECTION LIMIT 2)" || fail "connection limit: $(head -1 <<<"$out")"
wait $S1 $S2
expect_err "login may lower its read-only default only for itself; writes still denied" 42501 -c "$OFF" -c "insert into public.payloads default values"
v=$(lgc -c "show statement_timeout"); { [ "$v" = 60s ] || [ "$v" = 1min ]; } && pass "login session default statement_timeout is 60s" || fail "statement_timeout default: $v"
residual "the login can change its own timeouts and read-only default; they bound accidents, not a hostile caller"

# --- 8. Residuals: probed and recorded. ---
log "-- 8 residuals"
out=$("$PSQL" -X -q -At -h $H -p "$ADV_PORT" -U sdr_summary_login -d postgres -c "select current_database()" 2>&1)
[ "$out" = postgres ] && residual "login can CONNECT to other databases via the PUBLIC CONNECT default (catalog metadata only); owner option: pg_hba line" \
  || pass "login cannot connect to another database"
oid=$(lgc -c "$OFF" -c "select lo_create(0)" | tail -1)
if grep -qE '^[0-9]+$' <<<"$oid"; then
  residual "login can create large objects (no privilege governs it); attest J detects any it owns"
  out=$(su -f "$SQL/attest.sql" | grep '^J large objects owned by either role')
  [ "$out" = "J large objects owned by either role (must be 0)|1" ] && pass "attest detects the login's large object" || fail "attest missed the large object: $out"
  su -c "select lo_unlink($oid)" >/dev/null
else pass "login cannot create large objects"; fi
residual "the cluster uses trust auth on 127.0.0.1: any local process can connect as any role, so the role is a procedural boundary there"

# --- 9. Optional TEMP revoke. ---
log "-- 9 optional TEMP revoke"
acl0=$(su -c "select datacl::text from pg_database where datname = 'sdr_agent_dev'")
out=$(su -v mode=inventory -f "$SQL/optional-revoke-temp.sql" 2>&1)
[ "$(su -c "select datacl::text from pg_database where datname = 'sdr_agent_dev'")" = "$acl0" ] && grep -q 'INVENTORY (nothing changed)' <<<"$out" \
  && pass "inventory mode changes nothing" || fail "inventory mode changed the ACL"
out=$(su -f "$SQL/optional-revoke-temp.sql" 2>&1)
grep -q '^REFUSED: pass -v mode' <<<"$out" && pass "no mode refuses" || fail "no-mode run was not refused"
su -v mode=apply -f "$SQL/optional-revoke-temp.sql" >/dev/null 2>&1
expect_err "CREATE TEMP after optional revoke" 42501 -c "$OFF" -c "create temp table adv_t (i int)"
[ "$(lgc -c "$G3" | norm_fn)" = "$base_g3" ] && pass "functions unaffected by the TEMP revoke" || fail "functions changed after TEMP revoke"
su -c "grant temp on database sdr_agent_dev to public" >/dev/null
attest_check "attest at end"

# --- 10. Nothing seeded as secret ever reached the login. ---
log "-- 10 leakage"
n=$(grep -c 'SEEDSECRET\|<b>\|<script>\|/SEEDSECRET-PATH' "$ALL")
[ "$n" = 0 ] && pass "no seeded secret, raw label or path in $(wc -l < "$ALL" | tr -d ' ') lines of login output and errors" || fail "$n leaked lines"
long=$(awk -F'|' 'NF == 10 { for (i = 5; i <= 9; i++) if (length($i) > 64) c++ } END { print c + 0 }' "$ALL")
[ "$long" = 0 ] && pass "every k field of every result row is at most 64 characters" || fail "$long over-long fields"

rm -rf "$WORK"
log "== $PASSES passed, $FAILS failed"
[ "$FAILS" = 0 ]
