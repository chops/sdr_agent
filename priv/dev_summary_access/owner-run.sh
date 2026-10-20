#!/bin/bash
# ADR-0016 / D-173: the ONE owner execution context. Every owner command in
# OWNER-STEPS.md runs through this script; agents never run it.
#
# It is started ONLY by this exact clean launch, which fixes the environment
# before any shell starts (no caller PATH, BASH_ENV, ENV, exported function
# or shell option variable can reach bash):
#
#   /usr/bin/env -i PATH=/usr/bin:/bin HOME=/var/empty /bin/bash --noprofile --norc \
#     /ABSOLUTE/PATH/priv/dev_summary_access/owner-run.sh COMMAND ...
#
# The file is deliberately not executable. Its first check refuses any other
# launch (another bash, a relative $0, or any variable besides PATH, HOME and
# those bash itself sets). That check cannot undo what another launch ran at
# startup: the clean launch is the boundary; the check only makes any other
# launch fail instead of continuing.
#
#   owner-run.sh COMMAND --commit SHA --port PORT [--pgdata DIR] [--backup DIR]
#                        [--backup-parent DIR]
#
# COMMAND, in OWNER-STEPS.md order:
#   preflight         --pgdata              confirm commit, binaries and server
#   backup            --pgdata --backup-parent   fresh private backup
#   install           --backup              install.sql
#   revoke-inventory                        revoke-public-temp-lo.sql, read-only
#   revoke-apply      --backup              revoke-public-temp-lo.sql apply
#   hba-apply         --pgdata --backup     stage, validate, atomically replace,
#                                           reload and wait until effective
#   hba-reload        --pgdata              reload and wait until effective
#   accept                                  accept.sh
#   end-login-sessions                      terminate sdr_summary_login sessions
#   uninstall                               uninstall.sql
#   revoke-restore                          revoke-public-temp-lo.sql restore
#   hba-restore       --pgdata --backup     restore the backup copy atomically
#
# The execution context is fixed here, not inherited:
#   * binaries: the pinned PostgreSQL 18.6 Nix store path below, each one
#     checked to report 18.6; system tools from /usr/bin and /bin only;
#   * every child process, git included, runs under `env -i` (no PG*,
#     PSQL*, PGHOSTADDR, PGSERVICE, PGSERVICEFILE, PGOPTIONS, PGPASSFILE,
#     PGDATA, GIT_* or any other variable), with HOME=/var/empty;
#   * every connection names host=127.0.0.1 hostaddr=127.0.0.1, the given
#     port, an explicit database and user postgres, sslmode and gssencmode
#     off, passfile=/nonexistent/d168-no-pgpass, connect_timeout=10, lock_timeout=10s and
#     statement_timeout=300s;
#   * the data directory is never taken from the environment: commands that
#     touch pg_hba.conf need --pgdata, which must equal the server's own
#     data_directory, with hba_file exactly <pgdata>/pg_hba.conf;
#   * every command requires --commit, the full reviewed SHA, and refuses
#     unless the checkout is at exactly that commit with the package and
#     ADR-0016 unmodified and no untracked or ignored file in the package.
# Writing commands also require a verified --backup (BACKUP-COMPLETE and an
# exact MANIFEST). Each command ends with "OWNER-RUN <command> OK" (exit 0)
# or "OWNER-RUN REFUSED: <reason>" (exit 3).

# --- the clean-launch check, before anything else ------------------------
if [ "${BASH:-}" != /bin/bash ] || [ "${PATH:-}" != /usr/bin:/bin ] || [ "${HOME:-}" != /var/empty ] \
   || [ -n "${BASH_ENV+set}${ENV+set}" ]; then
  echo "OWNER-RUN REFUSED: not started by the documented clean launch (OWNER-STEPS.md)"; exit 3
fi
case "$0" in
  /*) ;;
  *) echo "OWNER-RUN REFUSED: not started by the documented clean launch (relative path)"; exit 3 ;;
esac
if /usr/bin/env | /usr/bin/grep -vqE '^(PATH|HOME|PWD|SHLVL|OLDPWD|_)='; then
  echo "OWNER-RUN REFUSED: not started by the documented clean launch (inherited environment)"; exit 3
fi
set -u
set -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$HERE/../.." && pwd -P)
PINNED_PGBIN=/nix/store/zndqgdxn4p28iyax8raza3pfn7lkjw64-postgresql-18.6/bin
PGVER=18.6
SEAM_MARKER=.d168-owner-run-test-stubs
# Test seam for the hermetic stub test only: a file in this package naming a
# stub directory that holds the stub marker. The reviewed package has no such
# file, and check_commit refuses any file not committed at the reviewed
# commit, so the seam acts only in a test's own throwaway repository, and it
# then refuses protected ports.
SEAM_FILE="$HERE/.d168-owner-run-test-pgbin"
CMD=${1:-}
[ $# -gt 0 ] && shift

refuse() { printf 'OWNER-RUN REFUSED: %s\n' "$*"; exit 3; }
note() { printf 'OWNER-RUN %s\n' "$*"; }

COMMIT="" PORT="" PGD="" BACKUP="" BPARENT=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || refuse "option $1 needs a value"
  case "$1" in
    --commit) COMMIT=$2 ;;
    --port) PORT=$2 ;;
    --pgdata) PGD=$2 ;;
    --backup) BACKUP=$2 ;;
    --backup-parent) BPARENT=$2 ;;
    *) refuse "unknown option $1" ;;
  esac
  shift 2
done

case "$CMD" in
  preflight|backup|install|revoke-inventory|revoke-apply|hba-apply|hba-reload|accept|end-login-sessions|uninstall|revoke-restore|hba-restore) ;;
  *) refuse "unknown command '$CMD' (see the header of owner-run.sh)" ;;
esac

PGBIN=$PINNED_PGBIN
if [ -e "$SEAM_FILE" ]; then
  SEAM_PGBIN=$(/bin/cat "$SEAM_FILE")
  [ -f "$SEAM_PGBIN/$SEAM_MARKER" ] || refuse "test binaries without the stub marker"
  PGBIN=$SEAM_PGBIN
  note "TEST STUB BINARIES (protected ports refused)"
fi

# --- validation helpers -------------------------------------------------
stat_um() {
  case "$(uname -s)" in
    Darwin) /usr/bin/stat -f '%u %Lp' "$1" 2>/dev/null ;;
    *) stat -c '%u %a' "$1" 2>/dev/null ;;
  esac
}
# physical_dir PATH LABEL: an existing directory spelled physically.
physical_dir() {
  local d=$1 phys
  case "$d" in /*) ;; *) refuse "$2 '$d' is not an absolute path" ;; esac
  case "$d/" in */./*|*/../*|*//*) refuse "$2 '$d' has a ., .. or empty segment" ;; esac
  [ -d "$d" ] && [ ! -L "$d" ] || refuse "$2 '$d' is not a directory"
  phys=$(cd -P -- "$d" 2>/dev/null && pwd -P) || refuse "$2 '$d' cannot be resolved"
  [ "$phys" = "$d" ] || refuse "$2 '$d' is not physical (resolves to '$phys')"
}
check_port() {
  [[ "$PORT" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$PORT" -le 65535 ] || refuse "--port must be a canonical port number"
  if [ "$PGBIN" != "$PINNED_PGBIN" ] && { [ "$PORT" = 5520 ] || [ "$PORT" = 4120 ]; }; then
    refuse "test stub binaries never run against a protected port"
  fi
}
check_binaries() {
  local b v
  for b in psql pg_dump pg_dumpall pg_restore; do
    [ -x "$PGBIN/$b" ] || refuse "$PGBIN/$b is missing"
    v=$(run "$PGBIN/$b" --version 2>/dev/null)
    [ "$v" = "$b (PostgreSQL) $PGVER" ] || refuse "$b is not PostgreSQL $PGVER"
  done
}
G() { env -i PATH=/usr/bin:/bin HOME=/var/empty /usr/bin/git -C "$REPO" "$@"; }
check_commit() {
  [[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || refuse "--commit must be the full 40-character reviewed SHA"
  [ "$HERE" = "$REPO/priv/dev_summary_access" ] || refuse "owner-run.sh is not inside its repository"
  [ "$(G rev-parse HEAD 2>/dev/null)" = "$COMMIT" ] || refuse "the checkout is not at the reviewed commit"
  G diff --quiet "$COMMIT" -- priv/dev_summary_access docs/adr/0016-dev-db-summary-access.md \
    || refuse "the package or ADR-0016 differs from the reviewed commit"
  [ -z "$(G status --porcelain --ignored -- priv/dev_summary_access docs/adr/0016-dev-db-summary-access.md)" ] \
    || refuse "the package has uncommitted, untracked or ignored files"
  note "commit $COMMIT"
}
# run CMD...: a child process with no inherited environment.
run() { env -i PATH=/usr/bin:/bin HOME=/var/empty LC_ALL=C TZ=UTC "$@"; }
ci() {
  printf "host=127.0.0.1 hostaddr=127.0.0.1 port=%s dbname=%s user=postgres sslmode=disable gssencmode=disable passfile=/nonexistent/d168-no-pgpass connect_timeout=10 application_name=d168-owner-run options='-c lock_timeout=10s -c statement_timeout=300s'" \
    "$PORT" "$1"
}
psql_su() { local db=$1; shift; run "$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -d "$(ci "$db")" "$@"; }
# One identity query; with --pgdata, the server's data_directory and
# hba_file must be exactly that directory and <pgdata>/pg_hba.conf.
IDENT_SOCKETS="" IDENT_LISTEN=""
check_server() {
  local out ver dd hba su
  out=$(psql_su postgres -At -F'|' -c "SELECT current_setting('server_version'), current_setting('data_directory'), current_setting('hba_file'), (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = current_user), current_setting('listen_addresses'), current_setting('unix_socket_directories')" 2>/dev/null) \
    || refuse "cannot connect as postgres to 127.0.0.1:$PORT"
  IFS='|' read -r ver dd hba su IDENT_LISTEN IDENT_SOCKETS <<<"$out"
  [ "$ver" = "$PGVER" ] || refuse "server is not PostgreSQL $PGVER"
  [ "$su" = t ] || refuse "postgres is not a superuser"
  if [ -n "$PGD" ]; then
    [ "$dd" = "$PGD" ] || refuse "the server's data_directory is not --pgdata"
    [ "$hba" = "$PGD/pg_hba.conf" ] || refuse "the server's hba_file is not <pgdata>/pg_hba.conf"
  fi
  note "server $ver at 127.0.0.1:$PORT${PGD:+, data_directory and hba_file confirmed}"
}
check_pgdata() {
  [ -n "$PGD" ] || refuse "--pgdata is required for $CMD"
  physical_dir "$PGD" "--pgdata"
  [ "$(stat_um "$PGD" | cut -d' ' -f1)" = "$(id -u)" ] || refuse "--pgdata is not owned by you"
}
MANIFEST_FILES=(sdr_agent_dev.dump globals.sql pg_hba.conf.before toc.txt)
manifest() { (cd "$1" && run shasum -a 256 "${MANIFEST_FILES[@]}"); }
check_backup() {
  [ -n "$BACKUP" ] || refuse "--backup is required for $CMD"
  physical_dir "$BACKUP" "--backup"
  [ "$(stat_um "$BACKUP")" = "$(id -u) 700" ] || refuse "--backup is not yours with mode 700"
  [ -f "$BACKUP/BACKUP-COMPLETE" ] && [ ! -L "$BACKUP/BACKUP-COMPLETE" ] || refuse "--backup is not a complete backup"
  [ -f "$BACKUP/MANIFEST" ] && [ "$(manifest "$BACKUP" 2>/dev/null)" = "$(/bin/cat "$BACKUP/MANIFEST")" ] \
    || refuse "--backup does not match its MANIFEST"
  note "backup verified"
}
# run_sql FILE END-MARKER [psql args...]: the script's own output is shown.
run_sql() {
  local f=$1 marker=$2 out rc; shift 2
  out=$(psql_su sdr_agent_dev "$@" -f "$HERE/$f" 2>&1); rc=$?
  printf '%s\n' "$out"
  [ "$rc" = 0 ] && [ "$(tail -1 <<<"$out")" = "$marker" ] || refuse "$f did not end with $marker (exit $rc)"
}

HBA_RULES() { grep -vE '^[[:space:]]*(#|$)' "$HERE/pg_hba-summary.conf"; }
# write_hba CONTENT-FILE EXPECT-LIVE-FILE: replace the live hba file with
# exactly CONTENT-FILE's bytes, only if it still equals EXPECT-LIVE-FILE.
# Stages into a fresh private file in the same directory, checks the staged
# bytes and mode, re-checks the live file, then renames atomically. A
# refusal inside leaves the live file as it was before THIS write and
# removes only the staged file; LABEL (third argument) says which write.
STAGE=""
trap '[ -n "$STAGE" ] && [ -f "$STAGE" ] && rm -f -- "$STAGE"' EXIT
write_hba() {
  local want=$1 expect=$2 lbl=$3 hba="$PGD/pg_hba.conf" mode
  [ -f "$hba" ] && [ ! -L "$hba" ] || refuse "$lbl: pg_hba.conf is not a regular file; this write changed nothing"
  [ "$(stat_um "$hba" | cut -d' ' -f1)" = "$(id -u)" ] || refuse "$lbl: pg_hba.conf is not owned by you; this write changed nothing"
  cmp -s "$hba" "$expect" || refuse "$lbl: pg_hba.conf is not in the expected state; this write changed nothing"
  mode=$(stat_um "$hba" | cut -d' ' -f2)
  STAGE=$( (umask 077 && mktemp "$PGD/.pg_hba.conf.d173.XXXXXXXX") 2>/dev/null) || { STAGE=""; refuse "$lbl: cannot create a staging file; this write changed nothing"; }
  [ -f "$STAGE" ] && [ ! -L "$STAGE" ] && [ ! -s "$STAGE" ] || refuse "$lbl: staging file is not fresh; this write changed nothing"
  /bin/cat "$want" > "$STAGE" && cmp -s "$STAGE" "$want" || refuse "$lbl: staging write failed; this write changed nothing"
  chmod "$mode" "$STAGE" && [ "$(stat_um "$STAGE")" = "$(id -u) $mode" ] || refuse "$lbl: cannot set the staged mode; this write changed nothing"
  cmp -s "$hba" "$expect" || refuse "$lbl: pg_hba.conf changed during staging; this write changed nothing"
  mv -f -- "$STAGE" "$hba" || refuse "$lbl: atomic replace failed; check pg_hba.conf and report this stage"
  STAGE=""
}
# Reload so that the acceptance check can count it effective: wait until the
# server clock is at least one second past the file's mtime, signal, then
# wait until pg_conf_load_time() is newer than before and at least one
# second after that mtime, with the mtime unchanged.
# reload_and_wait STATE: STATE says what is on disk, for the refusal text.
reload_and_wait() {
  local lm l0 m ok _ st=$1
  lm=$(psql_su postgres -At -F'|' -c "SELECT pg_conf_load_time()::text, (pg_stat_file(current_setting('hba_file'))).modification::text") \
    || refuse "cannot read the reload state"
  l0=${lm%%|*} m=${lm#*|}
  for _ in $(seq 1 50); do
    ok=$(psql_su postgres -At -c "SELECT now() >= '$m'::timestamptz + interval '1100 milliseconds'") || refuse "cannot read the server clock"
    [ "$ok" = t ] && break; sleep 0.2
  done
  [ "$ok" = t ] || refuse "server clock did not pass the pg_hba.conf mtime"
  [ "$(psql_su postgres -At -c 'SELECT pg_reload_conf()')" = t ] || refuse "pg_reload_conf() failed"
  for _ in $(seq 1 50); do
    ok=$(psql_su postgres -At -c "SELECT pg_conf_load_time() > '$l0'::timestamptz AND pg_conf_load_time() >= '$m'::timestamptz + interval '1 second' AND (pg_stat_file(current_setting('hba_file'))).modification = '$m'::timestamptz") \
      || refuse "cannot read the reload state"
    [ "$ok" = t ] && break; sleep 0.2
  done
  [ "$ok" = t ] || refuse "the reload did not take effect after the last pg_hba.conf change ($st); stop and report this stage"
  note "reload effective after the last pg_hba.conf change"
}
# The on-disk rules, read by the server: no error line, and rules 1-7 the
# reviewed ones (accept.sql checks 12 and 13).
hba_file_ok() {
  local out
  out=$(psql_su sdr_agent_dev -At -f "$HERE/accept.sql" 2>&1)
  grep -qE '^ACCEPT 12 .*\|ok$' <<<"$out" && grep -qE '^ACCEPT 13 .*\|ok$' <<<"$out"
}

# --- commands -----------------------------------------------------------
check_commit
check_port
check_binaries
case "$CMD" in
  preflight)
    check_pgdata; check_server
    note "listen_addresses '$IDENT_LISTEN'; unix_socket_directories set: $([ -n "$IDENT_SOCKETS" ] && echo yes || echo no)"
    ;;
  backup)
    check_pgdata; check_server
    [ -n "$BPARENT" ] || refuse "--backup-parent is required"
    physical_dir "$BPARENT" "--backup-parent"
    [ "$(stat_um "$BPARENT")" = "$(id -u) 700" ] || refuse "--backup-parent must be yours with mode 700"
    umask 077
    B=$(mktemp -d "$BPARENT/d173-backup.XXXXXXXX") || refuse "cannot create a fresh backup directory"
    incomplete() { printf 'BACKUP-INCOMPLETE %s\n' "$B"; refuse "backup failed: $*; this directory is not a usable backup"; }
    run "$PGBIN/pg_dump" -d "$(ci sdr_agent_dev)" -Fc -f "$B/sdr_agent_dev.dump" || incomplete "pg_dump exited $?"
    run "$PGBIN/pg_dumpall" -d "$(ci postgres)" --globals-only -f "$B/globals.sql" || incomplete "pg_dumpall exited $?"
    hba="$PGD/pg_hba.conf"
    [ -f "$hba" ] && [ ! -L "$hba" ] || incomplete "pg_hba.conf is not a regular file"
    cp -p "$hba" "$B/pg_hba.conf.before" && cmp -s "$hba" "$B/pg_hba.conf.before" || incomplete "pg_hba.conf copy failed"
    run "$PGBIN/pg_restore" --list "$B/sdr_agent_dev.dump" > "$B/toc.txt" || incomplete "pg_restore --list exited $?"
    tables=$(psql_su sdr_agent_dev -At -c "SELECT count(*) FROM pg_catalog.pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'") \
      || incomplete "cannot count tables"
    [ "$tables" -gt 0 ] && [ "$(grep -c ' TABLE DATA public ' "$B/toc.txt")" = "$tables" ] \
      || incomplete "the dump's table data entries are not all $tables public tables"
    tail -3 "$B/globals.sql" | grep -qx -- '-- PostgreSQL database cluster dump complete' || incomplete "globals.sql is not complete"
    manifest "$B" > "$B/MANIFEST" || incomplete "MANIFEST failed"
    printf 'complete\n' > "$B/.BACKUP-COMPLETE.tmp" && mv "$B/.BACKUP-COMPLETE.tmp" "$B/BACKUP-COMPLETE" || incomplete "marker failed"
    echo BACKUP-VERIFIED
    printf 'BACKUP-DIR %s\n' "$B"
    ;;
  install)
    check_backup; check_server
    run_sql install.sql END-OF-SUMMARY-INSTALL
    ;;
  revoke-inventory)
    check_server
    run_sql revoke-public-temp-lo.sql 'END-OF-REVOKE-PUBLIC-TEMP-LO-INVENTORY (nothing changed)' -v mode=inventory
    ;;
  revoke-apply)
    check_backup; check_server
    run_sql revoke-public-temp-lo.sql END-OF-REVOKE-PUBLIC-TEMP-LO-APPLIED -v mode=apply
    ;;
  hba-apply)
    check_pgdata; check_backup; check_server
    grep -q sdr_summary_login "$BACKUP/pg_hba.conf.before" && refuse "the backup's pg_hba.conf already names the summary login"
    WANT=$( (umask 077 && mktemp "${TMPDIR:-/tmp}/d173-hba-want.XXXXXXXX") ) || refuse "cannot create a private temporary file"
    trap '[ -n "$STAGE" ] && [ -f "$STAGE" ] && rm -f -- "$STAGE"; rm -f -- "$WANT"' EXIT
    { HBA_RULES; /bin/cat "$BACKUP/pg_hba.conf.before"; } > "$WANT" || refuse "cannot build the new pg_hba.conf"
    write_hba "$WANT" "$BACKUP/pg_hba.conf.before" "before any change"
    if ! hba_file_ok; then
      write_hba "$BACKUP/pg_hba.conf.before" "$WANT" "PUT-BACK FAILED: the live file holds the NEW rules, not reloaded; stop and report this stage"
      refuse "the new pg_hba.conf did not validate (accept.sql checks 12-13); the backup copy was put back and nothing was reloaded"
    fi
    reload_and_wait "the NEW pg_hba.conf is in place"
    echo HBA-APPLIED-AND-LOADED
    ;;
  hba-reload)
    check_pgdata; check_server
    reload_and_wait "pg_hba.conf was not changed by this command"
    ;;
  accept)
    check_server
    out=$(run ACCEPT_PSQL="$PGBIN/psql" /bin/bash "$HERE/accept.sh" "$PORT" 2>&1); rc=$?
    printf '%s\n' "$out"
    [ "$rc" = 0 ] && [ "$(tail -1 <<<"$out")" = "ACCEPTANCE PASS" ] || refuse "acceptance did not pass"
    ;;
  end-login-sessions)
    check_server
    n=$(psql_su sdr_agent_dev -At -c "SELECT count(pg_terminate_backend(pid)) FROM pg_catalog.pg_stat_activity WHERE usename = 'sdr_summary_login'") \
      || refuse "cannot end login sessions"
    note "login sessions ended: $n"
    ;;
  uninstall)
    check_server
    run_sql uninstall.sql END-OF-SUMMARY-UNINSTALL
    ;;
  revoke-restore)
    check_server
    run_sql revoke-public-temp-lo.sql END-OF-REVOKE-PUBLIC-TEMP-LO-RESTORED -v mode=restore
    ;;
  hba-restore)
    check_pgdata; check_backup; check_server
    WANT=$( (umask 077 && mktemp "${TMPDIR:-/tmp}/d173-hba-applied.XXXXXXXX") ) || refuse "cannot create a private temporary file"
    trap '[ -n "$STAGE" ] && [ -f "$STAGE" ] && rm -f -- "$STAGE"; rm -f -- "$WANT"' EXIT
    { HBA_RULES; /bin/cat "$BACKUP/pg_hba.conf.before"; } > "$WANT" || refuse "cannot build the applied pg_hba.conf"
    cmp -s "$PGD/pg_hba.conf" "$WANT" \
      || refuse "pg_hba.conf is not exactly the applied content (edited since?); remove the seven lines by hand; nothing was changed"
    write_hba "$BACKUP/pg_hba.conf.before" "$WANT" "before any change"
    n=$(psql_su postgres -At -c "SELECT count(*) FROM pg_catalog.pg_hba_file_rules WHERE error IS NOT NULL OR 'sdr_summary_login' = ANY (user_name)") || refuse "cannot read pg_hba_file_rules"
    [ "$n" = 0 ] || refuse "the backup copy is restored on disk but has errors or still names the login (not reloaded); stop and report this stage"
    reload_and_wait "the restored backup copy is in place"
    echo HBA-RESTORED-AND-LOADED
    ;;
esac
note "$CMD OK"
exit 0
