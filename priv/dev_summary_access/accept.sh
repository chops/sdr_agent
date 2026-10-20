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
#   2-15   accept.sql: server version, function definition hashes, TEMP and
#          large-object revocations, pg_hba rules, reload state and the TCP
#          listen address;
#   16-18  live over 127.0.0.1: the login is rejected by pg_hba for the
#          postgres and template1 databases, and on sdr_agent_dev connects
#          with its reviewed session settings (SELECT of settings only);
#   19     live over every Unix socket directory the server reports: the
#          login is rejected by pg_hba for postgres, template1 and
#          sdr_agent_dev (no socket configured is reported as disabled).
# A refused connection is never counted as a pg_hba rejection.
# Output is fixed labels, counts and fixed values only, safe to report back.
# The last line is ACCEPTANCE PASS (exit 0) or ACCEPTANCE STOP (exit 3).
# Anything else, including an interrupted run or no last line, is STOP.
#
# ACCEPT_PSQL may name the psql binary (default: psql on PATH); owner-run.sh
# passes the pinned PostgreSQL 18.6 psql.

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
  printf 'host=127.0.0.1 hostaddr=127.0.0.1 port=%s dbname=%s user=%s sslmode=disable gssencmode=disable passfile=/nonexistent/d168-no-pgpass connect_timeout=10 application_name=d168-accept' \
    "$port" "$1" "$2"
}
# A Unix-socket connection: host is the socket directory, no hostaddr. The
# directory is libpq-quoted data, never conninfo syntax; check 19 accepts
# only directories made of / letters digits . _ + - so it needs no escapes.
cs() {
  printf "host='%s' port=%s dbname=%s user=sdr_summary_login sslmode=disable gssencmode=disable passfile=/nonexistent/d168-no-pgpass connect_timeout=10 application_name=d168-accept" \
    "$1" "$port" "$2"
}
# rejected OUTPUT RC: the connection failed with pg_hba's own rejection.
rejected() { [ "$2" != 0 ] && grep -q 'pg_hba.conf rejects connection' <<<"$1"; }

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

# 2-15. accept.sql.
out=$("$PSQL" -X -q -At -v ON_ERROR_STOP=1 -d "$(ci sdr_agent_dev postgres)" -f "$HERE/accept.sql" 2>&1); rc=$?
grep -E '^ACCEPT [0-9]+ ' <<<"$out"
if [ "$rc" = 0 ] && [ "$(tail -1 <<<"$out")" = 'ACCEPT-SQL PASS' ] && ! grep -qE '^ACCEPT [0-9]+ .*\|STOP$' <<<"$out" \
   && [ "$(grep -cE '^ACCEPT [0-9]+ .*\|ok$' <<<"$out")" = 14 ]; then
  ok "2-15 accept.sql (must be 14 ok and ACCEPT-SQL PASS)"
else
  stop "2-15 accept.sql (must be 14 ok and ACCEPT-SQL PASS)" "exit=$rc"
fi

# 16-17. pg_hba rejects the login everywhere but sdr_agent_dev (live, so the
# loaded rules are tested, not only the file).
for db in postgres template1; do
  n=$([ "$db" = postgres ] && echo 16 || echo 17)
  out=$("$PSQL" -X -q -At -d "$(ci "$db" sdr_summary_login)" -c 'SELECT 1' 2>&1); rc=$?
  if rejected "$out" "$rc"; then
    ok "$n login connection to database $db (must be rejected by pg_hba)"
  else
    stop "$n login connection to database $db (must be rejected by pg_hba)" "exit=$rc"
  fi
done

# 18. The login reaches sdr_agent_dev with its reviewed session settings.
# It reads settings only: no table, no function call, no write probe.
out=$("$PSQL" -X -q -At -d "$(ci sdr_agent_dev sdr_summary_login)" -c \
  "SELECT current_user = 'sdr_summary_login' AND current_database() = 'sdr_agent_dev'
          AND current_setting('default_transaction_read_only') = 'on'
          AND current_setting('search_path') = 'pg_catalog'
          AND current_setting('statement_timeout') IN ('1min', '60s')
          AND current_setting('lock_timeout') = '5s'
          AND NOT (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = current_user)" 2>&1); rc=$?
if [ "$rc" = 0 ] && [ "$out" = t ]; then
  ok "18 login connects to sdr_agent_dev with read-only default, search_path pg_catalog and timeouts"
else
  stop "18 login connects to sdr_agent_dev with read-only default, search_path pg_catalog and timeouts" "exit=$rc"
fi

# 19. Every Unix socket directory the server reports: the login is rejected
# by pg_hba for every database (the reviewed local rules reject it there).
label="19 login over every Unix socket (must be rejected by pg_hba for postgres, template1 and sdr_agent_dev)"
dirs=$("$PSQL" -X -q -At -d "$(ci sdr_agent_dev postgres)" -c "SELECT current_setting('unix_socket_directories')" 2>/dev/null); rc=$?
if [ "$rc" != 0 ]; then
  stop "$label" "socket directories unreadable"
elif [ -z "$dirs" ]; then
  ok "19 Unix socket disabled (unix_socket_directories is empty)"
else
  # The server-reported value is data. It is parsed conservatively, and the
  # whole list is validated BEFORE any probe: comma-separated entries, each
  # trimmed and then exactly '/' plus letters, digits and . _ / + -. Any
  # quote (PostgreSQL's quoted-list form), backslash, empty entry, space,
  # '=', '@' (abstract namespace) or other character STOPs with no socket
  # probed, so nothing can be read as a conninfo keyword or a second host.
  re='^/[A-Za-z0-9._/+-]+$' unsafe=no sockets=()
  # The WHOLE captured value first: only these bytes, spelled out so no
  # locale can widen them. Any LF, CR, tab or other control byte, quote,
  # backslash, '=', '@' or non-ASCII byte STOPs before the line-oriented
  # read below could see only part of the value.
  case "$dirs" in
    *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/+,\ -]*) unsafe=yes ;;
  esac
  case "$dirs" in *\"*|*\'*|*\\*|,*|*,|*,,*) unsafe=yes ;; esac
  if [ "$unsafe" = no ]; then
    IFS=',' read -r -a list <<<"$dirs"
    for d in "${list[@]}"; do
      d=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<<"$d")
      if [[ "$d" =~ $re ]]; then sockets+=("$d"); else unsafe=yes; fi
    done
  fi
  if [ "$unsafe" = yes ] || [ "${#sockets[@]}" = 0 ]; then
    stop "$label" "unsupported unix_socket_directories form; no socket probed"
  else
    bad=0
    for d in "${sockets[@]}"; do
      for db in postgres template1 sdr_agent_dev; do
        out=$("$PSQL" -X -q -At -d "$(cs "$d" "$db")" -c 'SELECT 1' 2>&1); rc=$?
        rejected "$out" "$rc" || bad=$((bad + 1))
      done
    done
    if [ "$bad" = 0 ]; then ok "$label, directories=${#sockets[@]}"; else stop "$label" "directories=${#sockets[@]} failures=$bad"; fi
  fi
fi

if [ "$STOPS" = 0 ]; then
  DONE=yes
  echo "ACCEPTANCE PASS"
  exit 0
fi
exit 3
