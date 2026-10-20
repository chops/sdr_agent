#!/usr/bin/env bash
# ADR-0016 / D-173 installed-state acceptance. OWNER-RUN ONLY, after
# install.sql, revoke-public-temp-lo.sql (mode=apply) and the pg_hba edit and
# reload (OWNER-STEPS.md). Agents never run this: it connects as postgres.
#
#   priv/dev_summary_access/accept.sh 5520
#
# It must print ACCEPTANCE PASS before any agent connects. Running attest.sql
# alone is not acceptance (D-173). Read-only; it runs, in order:
#   1      attest.sql (the 36 summary-role checks), reporting only its verdict
#          and the fixed names of any failed checks;
#   2-14   accept.sql: server version, function definition hashes, TEMP and
#          large-object revocations, pg_hba rules and reload state;
#   15-17  live pg_hba checks: the login is rejected by pg_hba for the
#          postgres and template1 databases, and on sdr_agent_dev connects
#          with its reviewed session settings (SELECT of settings only).
# Output is fixed labels, counts and fixed values only, safe to report back.
# The last line is ACCEPTANCE PASS (exit 0) or ACCEPTANCE STOP (exit 3).
# Anything else, including an interrupted run or no last line, is STOP.
#
# ACCEPT_PSQL may name the psql binary (default: psql on PATH).

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PSQL=${ACCEPT_PSQL:-psql}
ATTEST_CHECKS=36
DONE=no
STOPS=0
trap '[ "$DONE" = yes ] || echo "ACCEPTANCE STOP"' EXIT
trap 'exit 3' HUP INT TERM

ok() { printf 'ACCEPT %s|ok\n' "$1"; }
stop() { STOPS=$((STOPS + 1)); printf 'ACCEPT %s|STOP%s\n' "$1" "${2:+|$2}"; }

# Every connection parameter is explicit: no libpq environment override.
for v in $(env | sed -n 's/^\(PG[A-Za-z0-9_]*\)=.*/\1/p; s/^\(PSQL[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
if env | grep -qE '^(PG|PSQL)[A-Za-z0-9_]*='; then stop "0 libpq environment cleared"; exit 3; fi
port=${1:-}
if ! [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || [ "$port" -gt 65535 ]; then stop "0 usage: accept.sh PORT"; exit 3; fi
ci() {
  printf 'host=127.0.0.1 hostaddr=127.0.0.1 port=%s dbname=%s user=%s sslmode=disable connect_timeout=10 application_name=d168-accept' \
    "$port" "$1" "$2"
}

# 1. attest.sql: the verdict only (its inventory stays with the owner).
out=$("$PSQL" -X -q -v ON_ERROR_STOP=1 -d "$(ci sdr_agent_dev postgres)" -f "$HERE/attest.sql" 2>&1); rc=$?
nfail=$(grep -c '|FAILED$' <<<"$out")
label="1 attest.sql (must be ATTEST PASS: $ATTEST_CHECKS of $ATTEST_CHECKS)"
if [ "$rc" = 0 ] && [ "$nfail" = 0 ] && [ "$(tail -1 <<<"$out")" = END-OF-SUMMARY-ATTEST ] \
   && grep -qx "ATTEST PASS: $ATTEST_CHECKS of $ATTEST_CHECKS checks hold" <<<"$out"; then
  ok "$label"
else
  stop "$label" "exit=$rc failed=$nfail"
  # Check names are fixed strings in attest.sql; their values are not shown.
  grep '|FAILED$' <<<"$out" | sed 's/ (must be.*//; s/^/ACCEPT 1 attest failed: /'
fi

# 2-14. accept.sql.
out=$("$PSQL" -X -q -At -v ON_ERROR_STOP=1 -d "$(ci sdr_agent_dev postgres)" -f "$HERE/accept.sql" 2>&1); rc=$?
grep -E '^ACCEPT [0-9]+ ' <<<"$out"
if [ "$rc" = 0 ] && [ "$(tail -1 <<<"$out")" = 'ACCEPT-SQL PASS' ] && ! grep -qE '^ACCEPT [0-9]+ .*\|STOP$' <<<"$out" \
   && [ "$(grep -cE '^ACCEPT [0-9]+ .*\|ok$' <<<"$out")" = 13 ]; then
  ok "2-14 accept.sql (must be 13 ok and ACCEPT-SQL PASS)"
else
  stop "2-14 accept.sql (must be 13 ok and ACCEPT-SQL PASS)" "exit=$rc"
fi

# 15-16. pg_hba rejects the login everywhere but sdr_agent_dev (live, so the
# loaded rules are tested, not only the file).
for db in postgres template1; do
  n=$([ "$db" = postgres ] && echo 15 || echo 16)
  out=$("$PSQL" -X -q -At -d "$(ci "$db" sdr_summary_login)" -c 'SELECT 1' 2>&1); rc=$?
  if [ "$rc" != 0 ] && grep -q 'pg_hba.conf rejects connection' <<<"$out"; then
    ok "$n login connection to database $db (must be rejected by pg_hba)"
  else
    stop "$n login connection to database $db (must be rejected by pg_hba)" "exit=$rc"
  fi
done

# 17. The login reaches sdr_agent_dev with its reviewed session settings.
# It reads settings only: no table, no function call, no write probe.
out=$("$PSQL" -X -q -At -d "$(ci sdr_agent_dev sdr_summary_login)" -c \
  "SELECT current_user = 'sdr_summary_login' AND current_database() = 'sdr_agent_dev'
          AND current_setting('default_transaction_read_only') = 'on'
          AND current_setting('search_path') = 'pg_catalog'
          AND current_setting('statement_timeout') IN ('1min', '60s')
          AND current_setting('lock_timeout') = '5s'
          AND NOT (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = current_user)" 2>&1); rc=$?
if [ "$rc" = 0 ] && [ "$out" = t ]; then
  ok "17 login connects to sdr_agent_dev with read-only default, search_path pg_catalog and timeouts"
else
  stop "17 login connects to sdr_agent_dev with read-only default, search_path pg_catalog and timeouts" "exit=$rc"
fi

if [ "$STOPS" = 0 ]; then
  DONE=yes
  echo "ACCEPTANCE PASS"
  exit 0
fi
exit 3
