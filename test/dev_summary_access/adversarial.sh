#!/usr/bin/env bash
# ADR-0016 adversarial test for the dev DB summary-access role.
#
# THROWAWAY CLUSTER ONLY. It installs, uninstalls, seeds synthetic rows and
# changes privileges. It refuses (exit 2, before any psql call) unless the
# inputs name a cluster created by throwaway-cluster.sh (guard.sh; tested
# hermetically by guard-test.sh). Never point it at the dev cluster.
#
#   ADV_PGBIN=/path/to/postgresql/bin throwaway-cluster.sh init BASE   -> ROOT
#   ADV_PGBIN=... throwaway-cluster.sh start ROOT
#   ADV_PGBIN=... throwaway-cluster.sh schema ROOT   (app schema via migrations, no data)
#   eval "$(ADV_PGBIN=... throwaway-cluster.sh env ROOT | sed 's/^/export /')"
#   ADV_PGBIN=... ADV_REF_DIR=dir-with-g3-inventory.sql-and-claude-gdemo-drain.sql \
#     ADV_LOG=path test/dev_summary_access/adversarial.sh
#   ADV_PGBIN=... throwaway-cluster.sh destroy ROOT
#
# The login-side calls connect as the real LOGIN role sdr_summary_login.
# A FULL run needs ADV_REF_DIR holding the reference psql scripts with the
# pinned SHA-256 below; without it the reference comparisons do not run,
# the run is REDUCED and exits 3 even if every other check passes. Exit 0
# only for a full run with every check passing; 1 on any failure; 2 on a
# guard refusal. OPEN lines are residuals awaiting an explicit owner
# decision (ADR-0016 "Open owner choices"), not accepted gaps. The log
# holds verdicts, SQLSTATEs and hashes only, never function output or
# seeded values.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
SQL="$REPO/priv/dev_summary_access"
# shellcheck source=guard.sh
. "$HERE/guard.sh"

# --- Guard (MF3): nothing below this block runs, and no psql is started,
# unless the inputs name the throwaway cluster throwaway-cluster.sh made.
: "${ADV_PGBIN:?set ADV_PGBIN}"
PSQL="$ADV_PGBIN/psql"
GUARD_CONTROLDATA="$ADV_PGBIN/pg_controldata"
guard_verify
guard_connect_identity "$PSQL"
if [ "${1:-}" = --guard-only ]; then
  echo "GUARD OK port=$GUARD_PORT system_identifier=$GUARD_SYSID"; exit 0
fi
# Re-checked before every destructive step.
reverify() { guard_connect_identity "$PSQL"; }

CI_SU=$(guard_conninfo sdr_agent_dev postgres)
CI_LG=$(guard_conninfo sdr_agent_dev sdr_summary_login)
CI_SU_PG=$(guard_conninfo postgres postgres)
CI_LG_PG=$(guard_conninfo postgres sdr_summary_login)
CI_DEF=$(guard_conninfo sdr_agent_dev sdr_summary_definer)
LOG=${ADV_LOG:-/dev/null}
WORK=$(mktemp -d "$GUARD_ROOT/work.XXXXXX")
ALL="$WORK/login-output.all"
: > "$ALL"
PASSES=0
FAILS=0

log() { printf '%s\n' "$*" | tee -a "$LOG"; }
pass() { PASSES=$((PASSES + 1)); log "PASS $*"; }
fail() { FAILS=$((FAILS + 1)); log "FAIL $*"; }
residual() { log "OPEN $*"; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

su() { "$PSQL" -X -q -At -F'|' -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -d "$CI_SU" "$@"; }
lg() { "$PSQL" -X -q -At -F'|' -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -d "$CI_LG" "$@"; }

log "== ADR-0016 adversarial run $(date -u +%Y-%m-%dT%H:%M:%SZ) port=$GUARD_PORT system_identifier=$GUARD_SYSID server=$(su -c 'SHOW server_version')"
log "   repo head $(git -C "$REPO" rev-parse HEAD 2>/dev/null)$(git -C "$REPO" diff --quiet HEAD 2>/dev/null || echo ' +uncommitted changes')"
for f in install.sql attest.sql uninstall.sql optional-revoke-temp.sql; do log "   $f sha256 $(sha "$SQL/$f")"; done
log "   seed.sql sha256 $(sha "$HERE/seed.sql")  canaries.sql sha256 $(sha "$HERE/canaries.sql")"

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
# script_refused NAME MARKER-PATTERN psql-args...: exit 3, a REFUSED line, no END marker.
script_refused() {
  local name=$1 pat=$2 out rc; shift 2
  out=$("$PSQL" -X -q -At -v ON_ERROR_STOP=1 "$@" 2>&1); rc=$?
  if [ "$rc" = 3 ] && grep -q "$pat" <<<"$out" && ! grep -q '^END-OF-' <<<"$out"; then pass "$name: exit 3, refused, no END marker"
  else fail "$name: exit=$rc $(grep -m1 -E 'REFUSED|ERROR|END-OF' <<<"$out" | cut -c1-120)"; fi
}

roles_present() { su -c "select count(*) from pg_roles where rolname in ('sdr_summary_login', 'sdr_summary_definer')"; }
fn_inventory() { su -f "$SQL/attest.sql" 2>/dev/null | grep '^G summary functions|'; }

# attest_ok LABEL: exit 0, END marker last, no FAILED row.
attest_ok() {
  local out rc
  out=$(su -f "$SQL/attest.sql" 2>&1); rc=$?
  if [ "$rc" = 0 ] && [ "$(tail -1 <<<"$out")" = END-OF-SUMMARY-ATTEST ] && ! grep -q '|FAILED$' <<<"$out"; then
    pass "$1: attest PASS ($(grep -c '(must be' <<<"$out") machine checks, exit 0)"
  else fail "$1: attest exit=$rc $(grep '|FAILED$' <<<"$out" | cut -d'|' -f1 | tr '\n' ';' | cut -c1-300)"; fi
}

# mutant NAME EXPECTED-FAILED-CHECK APPLY-SQL REVERT-SQL [lg|su|su_pg]
# Applies a privilege mutation; attest must refuse (exit 3, ATTEST REFUSED,
# the named check FAILED, no END marker); then reverts and re-attests.
mutant() {
  local name=$1 want=$2 apply=$3 revert=$4 who=${5:-su} out rc failed
  case "$who" in
    lg) lg -c "SET default_transaction_read_only = off" -c "$apply" >/dev/null 2>&1 ;;
    su_pg) "$PSQL" -X -q -v ON_ERROR_STOP=1 -d "$CI_SU_PG" -c "$apply" >/dev/null 2>&1 ;;
    *) su -c "$apply" >/dev/null 2>&1 ;;
  esac
  out=$(su -f "$SQL/attest.sql" 2>&1); rc=$?
  failed=$(grep '|FAILED$' <<<"$out" | cut -d'|' -f1 | sed 's/ (must be.*//' | tr '\n' ';')
  if [ "$rc" = 3 ] && grep -q '^ATTEST REFUSED' <<<"$out" && ! grep -q END-OF-SUMMARY-ATTEST <<<"$out" \
     && grep -qF "$want" <<<"$failed"; then pass "attest refuses $name (exit 3; FAILED: $failed)"
  else fail "attest did not refuse $name: exit=$rc failed=$failed"; fi
  case "$who" in
    su_pg) "$PSQL" -X -q -v ON_ERROR_STOP=1 -d "$CI_SU_PG" -c "$revert" >/dev/null 2>&1 ;;
    *) su -c "$revert" >/dev/null 2>&1 ;;
  esac
  attest_ok "after reverting $name"
}

norm_fn() { awk -F'|' '$4!="target" && $4!="END" {o=$4; for(i=5;i<=NF;i++) if($i!="") o=o "|" $i; print o}' | sort; }
# Reference psql output: drop markers and blanks, join non-empty fields, and
# map the one seeded out-of-vocabulary event type as the functions do.
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

# Reference scripts (the owner-reviewed psql versions), pinned.
REF_G3_SHA256=602e9429eeb0e858bb9ca119dea1f6f1f60b637858dcc06296f23aea6735f250
REF_DRAIN_SHA256=908c2829cb323adfc8b1365e72c11f15861e2cad69316fffef2052f931c8c41e
FULL=yes
if [ -z "${ADV_REF_DIR:-}" ]; then
  FULL=no; log "REDUCED: ADV_REF_DIR is not set; the reference comparisons will NOT run"
else
  for pair in "g3-inventory.sql $REF_G3_SHA256" "claude-gdemo-drain.sql $REF_DRAIN_SHA256"; do
    set -- $pair
    got=$( [ -f "$ADV_REF_DIR/$1" ] && sha "$ADV_REF_DIR/$1" )
    if [ "$got" = "$2" ]; then log "   reference $1 sha256 $got (pinned)"
    else FULL=no; fail "reference $1 sha256 '${got:-missing}' is not the pinned $2"; fi
  done
fi

# --- 1. Install, refusals, atomicity, attestation. ---
log "-- 1 install, refusals and attestation"
reverify
if [ "$(roles_present)" != 0 ]; then
  out=$(su -f "$SQL/uninstall.sql" 2>&1)
  [ "$(tail -1 <<<"$out")" = END-OF-SUMMARY-UNINSTALL ] || { fail "uninstall of a previous install: $(grep -m1 -E 'REFUSED|ERROR' <<<"$out")"; exit 1; }
fi
out=$(su -f "$SQL/install.sql" 2>&1); rc=$?
if [ "$rc" = 0 ] && [ "$(tail -1 <<<"$out")" = END-OF-SUMMARY-INSTALL ]; then pass "install completes (exit 0)"; else fail "install: exit=$rc $(grep -m1 ERROR <<<"$out")"; exit 1; fi
attest_ok "after install"
before=$(fn_inventory)
out=$(su -f "$SQL/install.sql" 2>&1); rc=$?
if [ "$rc" = 3 ] && grep -q 'ERROR:  42710:' <<<"$out" && ! grep -q END-OF-SUMMARY-INSTALL <<<"$out" && [ "$before" = "$(fn_inventory)" ]; then
  pass "second install refuses atomically (exit 3, 42710), installed functions unchanged"
else fail "second install was not an atomic refusal (exit=$rc)"; fi
script_refused "install in another database" '^REFUSED: connect to sdr_agent_dev' -d "$CI_SU_PG" -f "$SQL/install.sql"
script_refused "install by a non-superuser" '^REFUSED: run as a superuser' -d "$CI_LG" -f "$SQL/install.sql"
script_refused "uninstall in another database" '^REFUSED: connect to sdr_agent_dev' -d "$CI_SU_PG" -f "$SQL/uninstall.sql"
script_refused "uninstall by a non-superuser" '^REFUSED: uninstall needs a superuser' -d "$CI_LG" -f "$SQL/uninstall.sql"
script_refused "optional TEMP revoke without a mode" '^REFUSED: pass -v mode' -d "$CI_SU" -f "$SQL/optional-revoke-temp.sql"
script_refused "optional TEMP revoke in another database" '^REFUSED: run against sdr_agent_dev' -d "$CI_SU_PG" -v mode=apply -f "$SQL/optional-revoke-temp.sql"
script_refused "optional TEMP apply by a non-superuser" '^REFUSED: apply needs a superuser' -d "$CI_LG" -v mode=apply -f "$SQL/optional-revoke-temp.sql"
log "   summary function hashes (full SHA-256):"
fn_inventory | awk -F'|' '{print "   " $2 " prosrc_sha256=" $11 " functiondef_sha256=" $12}' | tee -a "$LOG"
HASHES1=$(fn_inventory | cut -d'|' -f2,11,12)

# --- 1b. Effective-privilege attestation refuses every unreviewed route. ---
log "-- 1b attestation mutations (each must refuse, then pass once reverted)"
mutant "a direct-only SECURITY DEFINER function granted to the login" "X SECURITY DEFINER" \
  "CREATE FUNCTION public.adv_secdef_payloads() RETURNS bigint LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog AS 'SELECT count(*) FROM public.payloads'; REVOKE ALL ON FUNCTION public.adv_secdef_payloads() FROM PUBLIC; GRANT EXECUTE ON FUNCTION public.adv_secdef_payloads() TO sdr_summary_login" \
  "DROP FUNCTION public.adv_secdef_payloads()"
su -c "CREATE FUNCTION public.adv_secdef_payloads() RETURNS bigint LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog AS 'SELECT count(*) FROM public.payloads'; REVOKE ALL ON FUNCTION public.adv_secdef_payloads() FROM PUBLIC; GRANT EXECUTE ON FUNCTION public.adv_secdef_payloads() TO sdr_summary_login" >/dev/null 2>&1
[ "$(lg -c "select public.adv_secdef_payloads() is not null" 2>&1)" = t ] \
  && pass "that mutation is a real route: the login runs owner code on payloads through it" || fail "direct-grant mutation not callable by the login"
su -c "DROP FUNCTION public.adv_secdef_payloads()" >/dev/null
mutant "an extra definer content-column grant, SELECT(content) on public.payloads" "E definer SELECT columns not on the reviewed list" \
  "GRANT SELECT (content) ON public.payloads TO sdr_summary_definer" "REVOKE SELECT (content) ON public.payloads FROM sdr_summary_definer"
mutant "a table SELECT grant to the login (public.payloads)" "E table-level or sequence" \
  "GRANT SELECT ON public.payloads TO sdr_summary_login" "REVOKE SELECT ON public.payloads FROM sdr_summary_login"
mutant "a PUBLIC column grant on a content column" "E login column privileges" \
  "GRANT SELECT (content) ON public.payloads TO PUBLIC" "REVOKE SELECT (content) ON public.payloads FROM PUBLIC"
mutant "a PUBLIC-executable SECURITY DEFINER function naming neither role" "X SECURITY DEFINER" \
  "CREATE FUNCTION public.adv_secdef_public() RETURNS bigint LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog AS 'SELECT count(*) FROM public.payloads'" \
  "DROP FUNCTION public.adv_secdef_public()"
mutant "a SECURITY DEFINER function reached through a role membership" "X SECURITY DEFINER" \
  "CREATE ROLE adv_holder NOLOGIN; CREATE FUNCTION public.adv_secdef_held() RETURNS bigint LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog AS 'SELECT 1::bigint'; REVOKE ALL ON FUNCTION public.adv_secdef_held() FROM PUBLIC; GRANT EXECUTE ON FUNCTION public.adv_secdef_held() TO adv_holder; GRANT adv_holder TO sdr_summary_login" \
  "REVOKE adv_holder FROM sdr_summary_login; DROP FUNCTION public.adv_secdef_held(); DROP ROLE adv_holder"
mutant "a PUBLIC untrusted-language function wrapping a server-file reader" "X untrusted-language" \
  "CREATE FUNCTION public.adv_rf(text, bigint, bigint) RETURNS text LANGUAGE internal STRICT AS 'pg_read_file_off_len'" \
  "DROP FUNCTION public.adv_rf(text, bigint, bigint)"
mutant "an outgoing definer membership (pg_read_all_data)" "B role memberships" \
  "GRANT pg_read_all_data TO sdr_summary_definer" "REVOKE pg_read_all_data FROM sdr_summary_definer"
mutant "definer USAGE on a sequence" "E table-level or sequence" \
  "GRANT USAGE ON SEQUENCE public.oban_jobs_id_seq TO sdr_summary_definer" "REVOKE USAGE ON SEQUENCE public.oban_jobs_id_seq FROM sdr_summary_definer"
mutant "the login persisting its own session default (ALTER ROLE self SET statement_timeout = 0)" "A login session defaults" \
  "ALTER ROLE sdr_summary_login SET statement_timeout = 0" "ALTER ROLE sdr_summary_login SET statement_timeout = '60s'" lg
mutant "a raised connection limit" "A role attributes" \
  "ALTER ROLE sdr_summary_login CONNECTION LIMIT 10" "ALTER ROLE sdr_summary_login CONNECTION LIMIT 2"
mutant "a per-database setting for the login" "A per-database settings" \
  "ALTER ROLE sdr_summary_login IN DATABASE sdr_agent_dev SET search_path = public" "ALTER ROLE sdr_summary_login IN DATABASE sdr_agent_dev RESET search_path"
mutant "a widened definer default ACL" "I default ACLs" \
  "ALTER DEFAULT PRIVILEGES FOR ROLE sdr_summary_definer GRANT EXECUTE ON FUNCTIONS TO PUBLIC" \
  "ALTER DEFAULT PRIVILEGES FOR ROLE sdr_summary_definer REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC"
mutant "a changed function search_path" "G summary function shape" \
  "ALTER FUNCTION summary.g3_inventory_v1() SET search_path = public, pg_catalog" \
  "ALTER FUNCTION summary.g3_inventory_v1() SET search_path = pg_catalog, pg_temp"
mutant "a replaced function body (CREATE OR REPLACE)" "G g3_inventory_v1 prosrc sha256" \
  "DO \$m\$ BEGIN EXECUTE replace(pg_get_functiondef('summary.g3_inventory_v1()'::regprocedure), '-- 5. Context only', '-- 5. Context only (changed)'); END \$m\$" \
  "DO \$m\$ BEGIN EXECUTE replace(pg_get_functiondef('summary.g3_inventory_v1()'::regprocedure), '-- 5. Context only (changed)', '-- 5. Context only'); END \$m\$"
mutant "an extra EXECUTE grant on a summary function" "G summary function grants" \
  "CREATE ROLE adv_extra NOLOGIN; GRANT EXECUTE ON FUNCTION summary.g3_inventory_v1() TO adv_extra" \
  "REVOKE EXECUTE ON FUNCTION summary.g3_inventory_v1() FROM adv_extra; DROP ROLE adv_extra"
mutant "a large object created by the login" "J large objects owned by either role" \
  "SELECT lo_create(0)" "SELECT lo_unlink(m.oid) FROM pg_largeobject_metadata m WHERE m.lomowner = 'sdr_summary_login'::regrole" lg
mutant "an object added to schema summary" "F objects in schema summary" \
  "CREATE TABLE summary.adv_t (i int)" "DROP TABLE summary.adv_t"
mutant "a grant to the login in another database" "M dependency records" \
  "CREATE TABLE public.adv_other (i int); GRANT SELECT ON public.adv_other TO sdr_summary_login" "DROP TABLE public.adv_other" su_pg
[ "$(fn_inventory | cut -d'|' -f2,11,12)" = "$HASHES1" ] && pass "function hashes unchanged after all mutations and reverts" || fail "function hashes drifted"

# --- 1c. Uninstall validates everything before dropping anything. ---
log "-- 1c uninstall drift refusals, then clean uninstall and reinstall"
drift() {
  local name=$1 pat=$2 apply=$3 revert=$4 who=${5:-su} lo
  case "$who" in lg) lg -c "SET default_transaction_read_only = off" -c "$apply" >/dev/null 2>&1 ;; *) su -c "$apply" >/dev/null 2>&1 ;; esac
  lo=$(su -c "select count(*) from pg_largeobject_metadata")
  script_refused "uninstall with $name" "$pat" -d "$CI_SU" -f "$SQL/uninstall.sql"
  [ "$(roles_present)" = 2 ] && [ "$(su -c "select count(*) from pg_proc where pronamespace = 'summary'::regnamespace")" = 2 ] \
    && [ "$(su -c "select count(*) from pg_largeobject_metadata")" = "$lo" ] \
    && pass "  ... and nothing was dropped (roles, functions, large objects intact)" || fail "  ... uninstall with $name changed state"
  su -c "$revert" >/dev/null 2>&1
}
drift "a large object owned by the login" "REFUSED: 1 dependency record" "SELECT lo_create(0)" \
  "SELECT lo_unlink(m.oid) FROM pg_largeobject_metadata m WHERE m.lomowner = 'sdr_summary_login'::regrole" lg
drift "a table in schema summary" "REFUSED: schema summary holds 1 object" "CREATE TABLE summary.adv_t (i int)" "DROP TABLE summary.adv_t"
drift "an extra definer column grant" "REFUSED: 1 dependency record" "GRANT SELECT (content) ON public.payloads TO sdr_summary_definer" \
  "REVOKE SELECT (content) ON public.payloads FROM sdr_summary_definer"
drift "a definer membership" "REFUSED: a summary role has 1 role membership" "GRANT pg_read_all_data TO sdr_summary_definer" \
  "REVOKE pg_read_all_data FROM sdr_summary_definer"
reverify
out=$(su -f "$SQL/uninstall.sql" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(tail -1 <<<"$out")" = END-OF-SUMMARY-UNINSTALL ] && [ "$(roles_present)" = 0 ] \
  && [ "$(su -c "select count(*) from pg_namespace where nspname = 'summary'")" = 0 ] \
  && pass "clean uninstall removes both roles and the schema (exit 0)" || fail "clean uninstall: exit=$rc $(grep -m1 -E 'REFUSED|ERROR' <<<"$out")"
out=$(su -f "$SQL/install.sql" 2>&1)
[ "$(tail -1 <<<"$out")" = END-OF-SUMMARY-INSTALL ] && pass "reinstall completes" || { fail "reinstall"; exit 1; }
attest_ok "after reinstall"
[ "$(fn_inventory | cut -d'|' -f2,11,12)" = "$HASHES1" ] && pass "reinstalled function hashes equal the first install's" || fail "reinstall hashes differ"

# --- 2. Seed synthetic data, then compare with the reviewed psql scripts. ---
log "-- 2 expected counts"
reverify
su -f "$HERE/seed.sql" >/dev/null 2>&1 || { fail "seed"; exit 1; }
compare() {
  local name=$1 call=$2 ref; shift 2
  if [ "$FULL" != yes ]; then log "NOT RUN $name: no pinned reference script (REDUCED run)"; return; fi
  ref=$("$PSQL" -X -q -At -F'|' -v ON_ERROR_STOP=1 -d "$CI_SU" "$@" 2>&1 | norm_ref)
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
out=$(lgc -c "$POST_WRONG")
v=$(field CHECK 5 <<<"$out"); d=$(awk -F'|' '$4 ~ /^AUTHORITY 4d/ {print $10}' <<<"$out")
[ "$v" = "STOP: unexpected authority" ] && [ "$d" = 0 ] && pass "wrong b1 term is STOP (4d=0)" || fail "wrong-term verdict: $v 4d=$d"
v=$(lgc -c "$G3" | field END 5); [ "$v" = complete ] && pass "g3 END is complete" || fail "g3 END: $v"
row=$(lgc -c "$G3" | head -1)
[ "$(cut -d'|' -f1,3,4 <<<"$row")" = "sdr_agent_dev|summary.g3_inventory_v1|target" ] && grep -qE '^[^|]*\|20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\|' <<<"$row" \
  && pass "results carry target, UTC read time and function version" || fail "target row: $row"

# Row bounds. Unknown labels collapse into one 'other' row; a section at
# its row limit makes the result incomplete, fail-closed.
su -c "select testseed.ins('oban_jobs', jsonb_build_object('queue', 'q' || lpad(g::text, 3, '0'), 'state', 'available', 'worker', 'W')) from generate_series(1, 150) g" >/dev/null
out=$(lgc -c "$PRE")
n=$(grep -c '|CONTEXT 2 other queues pending (not part of the fence)|other|available|' <<<"$out")
[ "$n" = 1 ] && ! grep -qE '\|q[0-9]{3}\|' <<<"$out" && [ "$(field END 5 <<<"$out")" = complete ] \
  && pass "150 unknown queues: one 'other' row, no queue name returned, END complete" || fail "unknown queues: other rows=$n"
su -c "delete from public.oban_jobs where queue ~ '^q[0-9]{3}\$'" >/dev/null
su -c "SET session_replication_role = replica" -c "select testseed.ins('model_invocations', jsonb_build_object('ledger_generation', (1000 + g)::text, 'provider', 'claude_cli', 'status', 'completed', 'profile_id', 'fake')) from generate_series(1, 150) g" >/dev/null
out=$(lgc -c "$G3")
n=$(grep -c '|1 invocations|' <<<"$out")
[ "$n" = 100 ] && [ "$(field END 5 <<<"$out")" = truncated ] && pass "g3: 150 generations give 100 rows and END truncated" || fail "g3 row bound: rows=$n END=$(field END 5 <<<"$out")"
out=$(lgc -c "$POST")
[ "$(field END 5 <<<"$out")" = truncated ] && [ "$(field CHECK 5 <<<"$out")" = "STOP: a section reached its row limit (incomplete)" ] \
  && pass "drain: the same rows give END truncated and CHECK STOP" || fail "drain row bound: END=$(field END 5 <<<"$out")"
su -c "SET session_replication_role = replica" -c "delete from public.model_invocations where ledger_generation > 1000" >/dev/null

# --- 2b. Vocabulary canaries and malformed metadata (MF2). ---
log "-- 2b vocabulary canaries and malformed grant metadata"
reverify
su -f "$HERE/canaries.sql" >/dev/null 2>&1 || { fail "canaries"; exit 1; }
out=$(lgc -c "$G3")
[ "$(field END 5 <<<"$out")" = complete ] && pass "g3 with canaries is complete" || fail "g3 with canaries END: $(field END 5 <<<"$out")"
for want in '|1 invocations|1|other|completed|' '|2 gen2 claude_cli|other|other|' '|2 releases|other|' '|4 audit exports|other|1|1|1|' \
            '|3 candidate payload keys|gen1 claude_cli|other|changes|parsed_output|non-null|' '|3 candidate payload keys|gen1 other|other|previous|refusal|null|' \
            '|3 candidate canonical keys|gen1 claude_cli|other|parsed_output|'; do
  grep -qF "$want" <<<"$out" && pass "g3 groups an unknown value as: $want" || fail "g3 missing row: $want"
done
out=$(lgc -c "$POST")
[ "$(field END 5 <<<"$out")" = incomplete ] && [ "$(field CHECK 5 <<<"$out")" = "STOP: malformed grant or allocation terms (incomplete)" ] \
  && pass "drain with malformed allocations: END incomplete, CHECK STOP" || fail "drain malformed: END=$(field END 5 <<<"$out") CHECK=$(field CHECK 5 <<<"$out")"
n=$(grep -c '|CONTEXT 4 allocations of active unexpired grants by key, buckets and window state|[a-z0-9_]*|malformed|' <<<"$out")
[ "$n" = 7 ] && pass "7 malformed applies_to arrays (unknown, NULL, repeated, 1000 members, 2-D, empty, 5000-byte member) shown only as 'malformed'" || fail "malformed rows: $n"
grep -qF '|CONTEXT 4 allocations of active unexpired grants by key, buckets and window state|other|{b1}|' <<<"$out" && pass "unknown allocation key grouped as 'other'" || fail "unknown key row"
grep -qF '|CONTEXT 1 runs by status|other|||||1' <<<"$out" && pass "unknown run status grouped as 'other'" || fail "run status row"
grep -qF '|CONTEXT 2 other queues pending (not part of the fence)|other|available|' <<<"$out" && pass "lowercase queue 'privateclient' grouped as 'other'" || fail "queue row"
grep -qF '|CONTEXT 5 releases by disposition|other|||||1' <<<"$out" && pass "unknown disposition grouped as 'other'" || fail "disposition row"
bytes=$(lgc -c "$POST" | wc -c | tr -d ' ')
[ "$bytes" -lt 20000 ] && pass "drain output with every canary is $bytes bytes (bounded)" || fail "drain output $bytes bytes"
su -c "SET session_replication_role = replica" -c "delete from public.model_call_allocations where grant_id = '00000000-0000-7000-8000-0000000000b1' and key not in ('b1', 'workshop')" \
   -c "delete from public.model_invocations where status = 'seedsecretstatus' or provider = 'seedsecretprovider'" \
   -c "delete from public.audit_events where event_type in ('model.seedsecret', 'model.invocation.seedsecret2')" \
   -c "delete from public.model_result_releases where disposition = 'seedsecretdisposition'" \
   -c "delete from public.audit_exports where status = 'seedsecretexport'" \
   -c "delete from public.agent_runs where status = 'seedsecretrun'" \
   -c "delete from public.oban_jobs where queue = 'privateclient'" >/dev/null
v=$(lgc -c "$POST" | field CHECK 5); [ "$v" = GO ] && pass "canaries removed: drained post is GO again" || fail "after canary cleanup: $v"

# --- 3. The login reads no table and cannot write application data. ---
log "-- 3 data, write and DDL denial (login, read-only default switched off)"
OFF="SET default_transaction_read_only = off"
denied=0; total=0
for t in $(su -c "select format('%I.%I', 'public', c.relname) from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r','p','v','m') order by 1"); do
  total=$((total + 1))
  out=$(lgc -c "select 1 from $t where false")
  grep -q 'ERROR:  42501:' <<<"$out" && denied=$((denied + 1))
done
[ "$total" -gt 0 ] && [ "$denied" = "$total" ] && pass "SELECT denied on every public relation ($denied/$total, 42501)" || fail "SELECT denied on $denied of $total public relations"
expect_err "INSERT agent_runs" 42501 -c "$OFF" -c "insert into public.agent_runs default values"
expect_err "UPDATE model_invocations" 42501 -c "$OFF" -c "update public.model_invocations set status = 'x' where false"
expect_err "DELETE payloads" 42501 -c "$OFF" -c "delete from public.payloads where false"
expect_err "TRUNCATE audit_events" 42501 -c "$OFF" -c "truncate public.audit_events"
expect_err "COPY payloads out" 42501 -c "copy public.payloads to stdout"
expect_err "INSERT with read-only default on" 25006 -c "insert into public.agent_runs default values"
expect_err "nextval on an app sequence" 42501 -c "$OFF" -c "select nextval('public.oban_jobs_id_seq')"
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
expect_err "ALTER ROLE self CREATEDB" 42501 -c "$OFF" -c "alter role sdr_summary_login createdb"
expect_err "ALTER ROLE self CONNECTION LIMIT" 42501 -c "$OFF" -c "alter role sdr_summary_login connection limit 10"
expect_err "GRANT definer to self" 42501 -c "$OFF" -c "grant sdr_summary_definer to sdr_summary_login"
expect_err "create a replication slot" 42501 -c "$OFF" -c "select pg_create_physical_replication_slot('adv')"
out=$("$PSQL" -X -q -d "$CI_DEF" -c "select 1" 2>&1)
grep -q 'not permitted to log in' <<<"$out" && pass "definer cannot log in" || fail "definer login: $(head -1 <<<"$out")"
# The definer's own reach, probed by the superuser assuming it.
expect_err_su "definer SELECT payloads.content" 42501 -c "set role sdr_summary_definer" -c "select content from public.payloads where false"
expect_err_su "definer SELECT model_call_grants.name" 42501 -c "set role sdr_summary_definer" -c "select name from public.model_call_grants where false"
expect_err_su "definer SELECT * model_invocations" 42501 -c "set role sdr_summary_definer" -c "select * from public.model_invocations where false"
expect_err_su "definer INSERT agent_runs" 42501 -c "set role sdr_summary_definer" -c "insert into public.agent_runs default values"
expect_err_su "definer UPDATE model_call_grants" 42501 -c "set role sdr_summary_definer" -c "update public.model_call_grants set status = 'x' where false"
expect_err_su "definer CREATE in public" 42501 -c "set role sdr_summary_definer" -c "create table public.adv_d (i int)"
expect_err_su "definer pg_read_file" 42501 -c "set role sdr_summary_definer" -c "select pg_read_file('/etc/hosts')"
# By design the definer CAN read the content-bearing columns it is granted;
# only the fixed function outputs bound what leaves (ADR-0016).
[ "$(su -c "set role sdr_summary_definer" -c "select count(payload) >= 0 and count(canonical_bytes) >= 0 from public.audit_events" 2>&1 | tail -1)" = t ] \
  && pass "definer can read audit_events.payload and canonical_bytes (granted; disclosure bounded by the function outputs only)" || fail "definer payload read probe"

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
  -c "create operator pg_temp.= (leftarg = text, rightarg = text, function = pg_temp.adv_true)"
  -c "create function pg_temp.count(anyelement) returns bigint language sql as 'select 999::bigint'"
  -c "set \"TimeZone\" = 'Pacific/Kiritimati'" -c "set datestyle = 'SQL, DMY'")
[ "$(lgc "${shadow[@]}" -c "$G3" | norm_fn)" = "$base_g3" ] && pass "g3 unchanged under temp tables, views, ~ and = operators and a count function" || fail "g3 changed under shadowing"
[ "$(lgc "${shadow[@]}" -c "$POST" | norm_fn)" = "$base_post" ] && pass "drain unchanged under the same shadows and caller TimeZone" || fail "drain changed under shadowing"
residual "TEMP: the login can create temporary objects in its own session (PUBLIC TEMP default); optional-revoke-temp.sql removes it on owner approval"

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
out=$("$PSQL" -X -q -d "$CI_LG" -c "select 1" 2>&1)
grep -q 'too many connections for role' <<<"$out" && pass "third concurrent login session refused (CONNECTION LIMIT 2)" || fail "connection limit: $(head -1 <<<"$out")"
wait $S1 $S2
expect_err "login may lower its read-only default only for itself; writes still denied" 42501 -c "$OFF" -c "insert into public.payloads default values"
v=$(lgc -c "show statement_timeout"); { [ "$v" = 60s ] || [ "$v" = 1min ]; } && pass "login session default statement_timeout is 60s" || fail "statement_timeout default: $v"
residual "SETTINGS: the login can change its own timeouts and read-only default, per session and persistently (ALTER ROLE self SET); attest detects the persistent form, and they bound accidents, not a hostile caller"

# --- 8. Open owner choices: probed and recorded. ---
log "-- 8 open owner choices"
out=$("$PSQL" -X -q -At -d "$CI_LG_PG" -c "select current_database()" 2>&1)
[ "$out" = postgres ] && residual "OTHER DATABASES: the login can CONNECT to other databases on the cluster via the PUBLIC CONNECT default; what it can do there is not attested by this database's catalogs" \
  || pass "login cannot connect to another database"
oid=$(lgc -c "$OFF" -c "select lo_create(0)" | tail -1)
if grep -qE '^[0-9]+$' <<<"$oid"; then
  residual "LARGE OBJECTS: the login can create large objects (no privilege governs it); attest refuses while any exists"
  su -c "select lo_unlink($oid)" >/dev/null
else pass "login cannot create large objects"; fi
residual "CONNECTION BOUNDARY: the cluster uses trust auth on 127.0.0.1: any local process can connect as any role, so the role is a procedural boundary there"

# --- 9. Optional TEMP revoke. ---
log "-- 9 optional TEMP revoke"
acl0=$(su -c "select datacl::text from pg_database where datname = 'sdr_agent_dev'")
out=$(su -v mode=inventory -f "$SQL/optional-revoke-temp.sql" 2>&1)
[ "$(su -c "select datacl::text from pg_database where datname = 'sdr_agent_dev'")" = "$acl0" ] && grep -q 'INVENTORY (nothing changed)' <<<"$out" \
  && pass "inventory mode changes nothing" || fail "inventory mode changed the ACL"
reverify
su -v mode=apply -f "$SQL/optional-revoke-temp.sql" >/dev/null 2>&1
expect_err "CREATE TEMP after optional revoke" 42501 -c "$OFF" -c "create temp table adv_t (i int)"
[ "$(lgc -c "$G3" | norm_fn)" = "$base_g3" ] && pass "functions unaffected by the TEMP revoke" || fail "functions changed after TEMP revoke"
su -c "grant temp on database sdr_agent_dev to public" >/dev/null
attest_ok "at end"

# --- 10. Nothing seeded as secret ever reached the login; outputs closed. ---
log "-- 10 leakage and closed vocabulary"
n=$(grep -ci 'seedsecret\|privateclient\|<b>\|<script>' "$ALL")
[ "$n" = 0 ] && pass "no seeded secret or canary (case-insensitive), raw label or path in $(wc -l < "$ALL" | tr -d ' ') lines of login output and errors" || fail "$n leaked lines"
VOCAB="$WORK/vocab"
printf '%s\n' other malformed null non-null changes previous arguments parsed_output validation_errors refusal \
  closed not_yet_open open complete truncated incomplete pre post GO \
  'STOP: a section reached its row limit (incomplete)' 'STOP: malformed grant or allocation terms (incomplete)' \
  'STOP: a DRAIN row is not 0' 'STOP: unexpected authority' 'STOP: G-DEMO does not match the reviewed terms exactly once' \
  'unbound: no invocation id' 'unbound: invocation not found' 'inconsistent binding' \
  claude_cli codex_app_server fake completed failed reserved sent unknown claude_cli_opus claude_cli_sonnet \
  calibration released withheld building budget_exhausted cancelled queued running succeeded \
  agent default delivery followup integration reconciliation research available discarded executing retryable scheduled \
  b1 b2 b3 b4 b5 daily_use proof rehearsal workshop \
  model.allocation.released model.grant.allocation_changed model.grant.allocation_created model.grant.allocation_released \
  model.grant.created model.grant.revoked model.grant.terms_changed model.invocation.completed model.invocation.failed \
  model.invocation.reserved model.invocation.sent model.invocation.unknown model.launch.refused \
  model.profile.setting_initialized model.profile.switch_blocked model.profile.switch_completed model.profile.switch_failed \
  model.profile.switch_requested model.profile.switch_resolved model.reservation.refused model.result.calibration \
  model.result.released model.result.withheld model.server.start_allocated model.server.start_failed \
  model.server.start_ready model.server.start_started > "$VOCAB"
bad=$(awk -F'|' -v vf="$VOCAB" '
  BEGIN { while ((getline l < vf) > 0) ok[l] = 1 }
  /^sdr_agent_dev\|20[0-9-]+T[0-9:]+Z\|summary\./ {
    rows++
    if (NF != 10) { b++; next }
    for (i = 5; i <= 9; i++) {
      v = $i
      if (v == "" || (v in ok) || v ~ /^[0-9]+$/ || v ~ /^gen[0-9]+ (claude_cli|codex_app_server|fake|other)$/ \
          || v ~ /^\{(b[1-5]|proof)(,(b[1-5]|proof)){0,5}\}$/) continue
      b++
    }
  }
  END { print (b + 0) " " (rows + 0) }' "$ALL")
[ "${bad%% *}" = 0 ] && [ "${bad##* }" -gt 0 ] && pass "every k field of all ${bad##* } result rows is a reviewed label, a number or a canonical bucket set" || fail "closed vocabulary: ${bad%% *} out-of-vocabulary fields in ${bad##* } rows"
long=$(awk -F'|' '/^sdr_agent_dev\|/ && NF == 10 { for (i = 5; i <= 9; i++) if (length($i) > 64) c++ } END { print c + 0 }' "$ALL")
[ "$long" = 0 ] && pass "every k field of every result row is at most 64 characters" || fail "$long over-long fields"

rm -rf "$WORK"
if [ "$FULL" = yes ]; then
  log "== FULL RUN: $PASSES passed, $FAILS failed"
  [ "$FAILS" = 0 ]
else
  log "== REDUCED RUN (reference comparisons not run; NOT the full acceptance suite): $PASSES passed, $FAILS failed"
  [ "$FAILS" = 0 ] && exit 3 || exit 1
fi
