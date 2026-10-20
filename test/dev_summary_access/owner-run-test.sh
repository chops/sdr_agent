#!/usr/bin/env bash
# ADR-0016 hermetic test of priv/dev_summary_access/owner-run.sh. No
# database is involved: psql, pg_dump, pg_dumpall and pg_restore are stubs
# (through the marked test seam, which refuses protected ports) that record
# every call and its environment and answer from fixture files. The package
# runs from a temporary git copy, so the commit binding is real.
#
# It checks that every owner command runs in the fixed context (no inherited
# PG*/PSQL*/GIT_* variable or hostile PATH binary reaches a child; every
# connection is explicit), that backups are fresh, private and fail fast
# (no BACKUP-VERIFIED on any partial backup, earlier backups untouched), and
# that pg_hba writes are staged, validated and atomic (no live-file change
# on any failed stage, original bytes and mode on restore).
#
#   test/dev_summary_access/owner-run-test.sh [LOG]

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/../.." && pwd -P)
LOG=${1:-/dev/null}
PASSES=0 FAILS=0
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
pass() { PASSES=$((PASSES + 1)); log "PASS $*"; }
fail() { FAILS=$((FAILS + 1)); log "FAIL $*"; }
sum() { shasum -a 256 "$1" | cut -d' ' -f1; }
um() { case "$(uname -s)" in Darwin) /usr/bin/stat -f '%Lp' "$1" ;; *) stat -c '%a' "$1" ;; esac; }

T=$(mktemp -d "${TMPDIR:-/tmp}/d168ownerrun.XXXXXX"); T=$(cd -P "$T" && pwd -P); chmod 700 "$T"
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
REPO="$T/repo"; mkdir -p "$REPO/priv" "$REPO/docs/adr"
cp -Rp "$SRC/priv/dev_summary_access" "$REPO/priv/"
cp -p "$SRC/docs/adr/0016-dev-db-summary-access.md" "$REPO/docs/adr/"
g() { env -i PATH=/usr/bin:/bin HOME="$T" /usr/bin/git -C "$REPO" -c user.name=t -c user.email=t@example.invalid "$@"; }
FX="$T/fx"; STUBS="$T/stubs"; CALLS="$T/calls"; HOSTILE="$T/hostile"
mkdir "$FX" "$STUBS" "$HOSTILE"; : > "$STUBS/.d168-owner-run-test-stubs"
# The stub seam exists only in this throwaway repository, committed so that
# the commit binding accepts it; the reviewed package has no such file.
printf '%s' "$STUBS" > "$REPO/priv/dev_summary_access/.d168-owner-run-test-pgbin"
g init -q && g add -A && g commit -q -m fixture || { echo "cannot build the fixture repo"; exit 1; }
C=$(g rev-parse HEAD)
OR="$REPO/priv/dev_summary_access/owner-run.sh"
# shellcheck source=hostile-launch.sh
. "$HERE/hostile-launch.sh"
hostile_setup "$T/hl"
LAUNCH=$(launch_line "$REPO/priv/dev_summary_access/OWNER-STEPS.md")
[ "$(grep -cE '^ *owner_run\(\) \{ .* \}$' "$REPO/priv/dev_summary_access/OWNER-STEPS.md")" = 1 ] || { echo "OWNER-STEPS.md must document exactly one launch line"; exit 1; }
CALLER=zsh
PGD="$T/pgdata"; mkdir -m 700 "$PGD"; BP="$T/backups"; mkdir -m 700 "$BP"
PORT=61999

# --- stubs (paths are baked in: owner-run.sh gives children no environment)
common="FX='$FX'; CALLS='$CALLS'
{ printf 'CALL %s' \"\$(basename \"\$0\")\"; printf ' [%s]' \"\$@\"; printf '\\n'; printf 'ENV %s\\n' \"\$(env | cut -d= -f1 | sort | tr '\\n' ' ')\"; } >> \"\$CALLS\"
a() { [ -f \"\$FX/\$1.out\" ] && /bin/cat \"\$FX/\$1.out\"; exit \"\$(/bin/cat \"\$FX/\$1.rc\" 2>/dev/null || echo 0)\"; }
if [ \"\$1\" = --version ]; then [ -f \"\$FX/version.\$(basename \"\$0\")\" ] && /bin/cat \"\$FX/version.\$(basename \"\$0\")\" || echo \"\$(basename \"\$0\") (PostgreSQL) 18.6\"; exit 0; fi
outfile() { local p=''; for x in \"\$@\"; do [ \"\$p\" = -f ] && echo \"\$x\"; p=\$x; done; }"
cat > "$STUBS/psql" <<EOF
#!/bin/bash
$common
args="\$*"
case "\$args" in
  *"current_setting('server_version'), current_setting('data_directory')"*) a ident ;;
  *"relkind = 'r'"*) a tables ;;
  *"pg_conf_load_time()::text"*) a loadstate ;;
  *"now() >="*) a clock ;;
  *pg_reload_conf*) echo reload >> "\$FX/reloads"; a reload ;;
  *"pg_conf_load_time() >"*) a effective ;;
  *pg_hba_file_rules*) a hbarules ;;
  *pg_terminate_backend*) a terminate ;;
  *uninstall.sql*) a uninstall ;;
  *install.sql*) a install ;;
  *mode=inventory*) a inventory ;;
  *mode=apply*) a apply ;;
  *mode=restore*) a restore ;;
  *accept.sql*) a acceptsql ;;
  *attest.sql*) a attest ;;
  *"-c SELECT current_setting('unix_socket_directories')") a sockets ;;
  *"dbname=postgres user=sdr_summary_login"*|*"dbname=template1 user=sdr_summary_login"*) a reject ;;
  *"dbname=sdr_agent_dev user=sdr_summary_login"*) a login ;;
esac
echo "stub psql: unexpected call" >&2; exit 99
EOF
cat > "$STUBS/pg_dump" <<EOF
#!/bin/bash
$common
f=\$(outfile "\$@"); [ -n "\$f" ] && /bin/cat "\$FX/dump.content" > "\$f"; a dump
EOF
cat > "$STUBS/pg_dumpall" <<EOF
#!/bin/bash
$common
f=\$(outfile "\$@"); [ -n "\$f" ] && /bin/cat "\$FX/globals.content" > "\$f"; a dumpall
EOF
cat > "$STUBS/pg_restore" <<EOF
#!/bin/bash
$common
a toc
EOF
for b in psql pg_dump pg_dumpall pg_restore git; do
  printf '#!/bin/sh\necho HOSTILE >> "%s/hostile.calls"\nexit 1\n' "$T" > "$HOSTILE/$b"
done
chmod 700 "$STUBS"/* "$HOSTILE"/*

ORIG_HBA='# initdb default
local   all all              trust
host    all all 127.0.0.1/32 trust
host    all all ::1/128      trust'
fixtures() {
  rm -rf "$FX"; mkdir "$FX"
  printf '18.6|%s|%s/pg_hba.conf|t|127.0.0.1|\n' "$PGD" "$PGD" > "$FX/ident.out"
  echo 3 > "$FX/tables.out"
  printf '2026-10-20 00:00:00.5+00|2026-10-20 00:00:00+00\n' > "$FX/loadstate.out"
  echo t > "$FX/clock.out"; echo t > "$FX/reload.out"; echo t > "$FX/effective.out"; echo 0 > "$FX/hbarules.out"
  echo 0 > "$FX/terminate.out"
  for f in install:END-OF-SUMMARY-INSTALL uninstall:END-OF-SUMMARY-UNINSTALL apply:END-OF-REVOKE-PUBLIC-TEMP-LO-APPLIED \
           restore:END-OF-REVOKE-PUBLIC-TEMP-LO-RESTORED 'inventory:END-OF-REVOKE-PUBLIC-TEMP-LO-INVENTORY (nothing changed)'; do
    printf '%s\n' "${f#*:}" > "$FX/${f%%:*}.out"
  done
  { for n in 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do printf 'ACCEPT %s check (must be x)|x|ok\n' "$n"; done; echo 'ACCEPT-SQL PASS'; } > "$FX/acceptsql.out"
  printf 'ATTEST PASS: 36 of 36 checks hold\nEND-OF-SUMMARY-ATTEST\n' > "$FX/attest.out"
  : > "$FX/sockets.out"
  echo 'FATAL:  pg_hba.conf rejects connection for host "127.0.0.1"' > "$FX/reject.out"; echo 2 > "$FX/reject.rc"
  echo t > "$FX/login.out"
  echo PGDMP-fixture > "$FX/dump.content"
  printf -- '--\n-- PostgreSQL database cluster dump\n--\n\n--\n-- PostgreSQL database cluster dump complete\n--\n\n' > "$FX/globals.content"
  printf '1; 0 0 TABLE DATA public t1 postgres\n2; 0 0 TABLE DATA public t2 postgres\n3; 0 0 TABLE DATA public t3 postgres\n' > "$FX/toc.out"
  printf '%s\n' "$ORIG_HBA" > "$PGD/pg_hba.conf"; chmod 600 "$PGD/pg_hba.conf"
}

# orun NAME ok|refused COMMAND ARGS...: runs owner-run.sh with a hostile
# environment and PATH; checks the result and the context of every call.
OUT="$T/out"
orun() {
  local name=$1 want=$2 rc why=""; shift 2
  : > "$CALLS"; rm -f "$T/hostile.calls"; : > "$HL_SENT"
  HOSTILE_EXTRA=(PGHOST=/evil PGHOSTADDR=10.9.9.9 PGPORT=5520 PGSERVICE=evil PGSERVICEFILE="$T/evil.service"
                 "PGOPTIONS=-c default_transaction_read_only=on" PGPASSFILE="$T/evil.pass" PGDATA=/evil PGDATABASE=evil
                 PGUSER=evil PSQLRC="$T/evil.psqlrc" GIT_DIR=/evil GIT_WORK_TREE=/evil)
  hostile_call "$CALLER" "$LAUNCH" "$OR" "$OUT" "$@"; rc=$?
  if [ "$want" = ok ]; then
    [ "$rc" = 0 ] && [ "$(tail -1 "$OUT")" = "OWNER-RUN $1 OK" ] || why="$why exit=$rc last='$(tail -1 "$OUT")'"
  else
    [ "$rc" = 3 ] && tail -1 "$OUT" | grep -q '^OWNER-RUN REFUSED: ' || why="$why exit=$rc last='$(tail -1 "$OUT")'"
    grep -qE '^(BACKUP-VERIFIED|HBA-APPLIED-AND-LOADED|HBA-RESTORED-AND-LOADED|ACCEPTANCE PASS)$' "$OUT" && why="$why success-marker"
  fi
  [ -f "$T/hostile.calls" ] && why="$why hostile-PATH-binary-ran"
  [ -s "$HL_SENT" ] && why="$why sentinel-or-decoy-ran($(tr '\n' ';' < "$HL_SENT"))"
  grep '^ENV ' "$CALLS" | grep -qE ' (PG[A-Z]*|PSQL[A-Z]*|GIT_[A-Z_]*|D168_[A-Z_]*) ' && why="$why inherited-variable-reached-a-child"
  if grep '^CALL ' "$CALLS" | grep -v '\[--version\]' | grep 'application_name=d168-owner-run' \
       | grep -v 'host=127.0.0.1 hostaddr=127.0.0.1 port=61999 dbname=[a-z_0-9]* user=postgres sslmode=disable gssencmode=disable passfile=/nonexistent/d168-no-pgpass' | grep -q .; then
    why="$why implicit-connection"
  fi
  [ -z "$why" ] && pass "$name" || fail "$name:$why"
}
ncalls() { grep '^CALL ' "$CALLS" | grep -vc '\[--version\]'; }
hba_sum() { sum "$PGD/pg_hba.conf"; }
stages() { find "$PGD" -name '.pg_hba.conf.d173.*' | wc -l | tr -d ' '; }
A=(--commit "$C" --port "$PORT")

log "== ADR-0016 owner-run.sh hermetic test $(date -u +%Y-%m-%dT%H:%M:%SZ) bash $BASH_VERSION owner-run.sh sha256 $(sum "$SRC/priv/dev_summary_access/owner-run.sh")"
log "   documented launch: $LAUNCH"

# --- 0. the launch (Codex R5-1) ---
# Every orun below uses the exact documented launch from a hostile zsh
# caller and requires that no sentinel or decoy ran. Positive controls: the
# same hostile environment with any other launch runs the sentinels, and
# owner-run.sh refuses to continue.
fixtures
naive() {
  local name=$1 want_sent=$2; shift 2
  : > "$HL_SENT"
  /usr/bin/env -i PATH="$HL_DIR/decoy:/usr/bin:/bin" HOME="$HL_DIR/home" BASH_ENV="$HL_DIR/startup.sh" \
    "BASH_FUNC_echo%%=() { builtin echo \"exported function echo ran\" >> \"$HL_SENT\"; builtin echo \"\$@\"; }" "$@" > "$OUT" 2>&1; rc=$?
  if [ "$rc" != 0 ] && ! grep -q 'OWNER-RUN preflight OK' "$OUT" && grep -q "$want_sent" "$HL_SENT"; then
    pass "control: $name: '$want_sent' ran and owner-run.sh did not continue (exit $rc: $(tail -1 "$OUT" | cut -c1-90))"
  else fail "control: $name: exit=$rc sentinels=$(tr '\n' ';' < "$HL_SENT")"; fi
}
naive "launch with /bin/bash but the caller's environment" "startup file ran" /bin/bash "$OR" preflight "${A[@]}" --pgdata "$PGD"
grep -q 'not started by the documented clean launch' "$OUT" && pass "  ... and owner-run.sh refused it as not the documented clean launch" || fail "  ... refusal: $(tail -1 "$OUT")"
naive "launch with a Nix bash and the caller's environment" "exported function echo ran" /nix/var/nix/profiles/system/sw/bin/bash "$OR" preflight "${A[@]}" --pgdata "$PGD"
naive "launch through PATH lookup of bash (#!/usr/bin/env bash style)" "decoy bash ran" bash "$OR" preflight "${A[@]}" --pgdata "$PGD"
out=$(/usr/bin/env -i PATH=/usr/bin:/bin HOME=/var/empty "$OR" preflight "${A[@]}" --pgdata "$PGD" 2>&1); rc=$?
[ "$rc" = 126 ] && pass "control: direct execution of owner-run.sh is impossible (not executable, exit 126)" || fail "direct execution: exit=$rc"
out=$(cd "$REPO" && /usr/bin/env -i PATH=/usr/bin:/bin HOME=/var/empty /bin/bash --noprofile --norc priv/dev_summary_access/owner-run.sh preflight "${A[@]}" --pgdata "$PGD" 2>&1); rc=$?
[ "$rc" = 3 ] && grep -q 'not started by the documented clean launch (relative path)' <<<"$out" && pass "control: a relative owner-run.sh path is refused" || fail "relative path: exit=$rc"
out=$(/usr/bin/env -i PATH=/usr/bin:/bin HOME=/var/empty EXTRA=1 /bin/bash --noprofile --norc "$OR" preflight "${A[@]}" --pgdata "$PGD" 2>&1); rc=$?
[ "$rc" = 3 ] && grep -q 'not started by the documented clean launch (inherited environment)' <<<"$out" && pass "control: one extra environment variable is refused" || fail "extra variable: exit=$rc"
out=$(/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin HOME=/var/empty /bin/bash --noprofile --norc "$OR" preflight "${A[@]}" --pgdata "$PGD" 2>&1); rc=$?
[ "$rc" = 3 ] && grep -q 'not started by the documented clean launch' <<<"$out" && pass "control: a different PATH is refused" || fail "different PATH: exit=$rc"
orun "the documented launch from a hostile zsh caller (decoy bash/env/psql/git, BASH_ENV, ENV, SHELLOPTS+PS4, BASHOPTS, exported functions, PG*, GIT_*)" ok preflight "${A[@]}" --pgdata "$PGD"
CALLER=bash
orun "the documented launch from a hostile bash caller (exported functions, decoy PATH, PG*, GIT_*)" ok preflight "${A[@]}" --pgdata "$PGD"
CALLER=zsh

# --- 1. the happy path, in OWNER-STEPS.md order ---
fixtures
orun "preflight" ok preflight "${A[@]}" --pgdata "$PGD"
orun "backup" ok backup "${A[@]}" --pgdata "$PGD" --backup-parent "$BP"
B1=$(sed -n 's/^BACKUP-DIR //p' "$OUT")
[ -n "$B1" ] && grep -qx BACKUP-VERIFIED "$OUT" && [ "$(um "$B1")" = 700 ] && [ -f "$B1/BACKUP-COMPLETE" ] \
  && [ "$(find "$B1" -type f ! -perm 600 | wc -l | tr -d ' ')" = 0 ] && cmp -s "$B1/pg_hba.conf.before" "$PGD/pg_hba.conf" \
  && pass "backup: fresh mode-700 directory, every file mode 600, BACKUP-COMPLETE, exact pg_hba copy" || fail "backup layout"
before=$(cd "$B1" && shasum -a 256 * | shasum -a 256)
orun "a second backup" ok backup "${A[@]}" --pgdata "$PGD" --backup-parent "$BP"
B2=$(sed -n 's/^BACKUP-DIR //p' "$OUT")
[ -n "$B2" ] && [ "$B2" != "$B1" ] && [ "$(cd "$B1" && shasum -a 256 * | shasum -a 256)" = "$before" ] \
  && pass "a second backup gets a new directory and leaves the first untouched" || fail "second backup reused or changed the first"
orun "install" ok install "${A[@]}" --backup "$B1"
orun "revoke-inventory" ok revoke-inventory "${A[@]}"
orun "revoke-apply" ok revoke-apply "${A[@]}" --backup "$B1"
chmod 640 "$PGD/pg_hba.conf"
orun "hba-apply (pg_hba.conf mode 640 differs from the backup copy's 600 only in mode)" ok hba-apply "${A[@]}" --pgdata "$PGD" --backup "$B1"
want="$T/want"; { grep -vE '^[[:space:]]*(#|$)' "$REPO/priv/dev_summary_access/pg_hba-summary.conf"; /bin/cat "$B1/pg_hba.conf.before"; } > "$want"
cmp -s "$PGD/pg_hba.conf" "$want" && [ "$(um "$PGD/pg_hba.conf")" = 640 ] && [ "$(stages)" = 0 ] && grep -qx HBA-APPLIED-AND-LOADED "$OUT" \
  && [ "$(wc -l < "$FX/reloads" | tr -d ' ')" = 1 ] \
  && pass "hba-apply: live file is exactly the seven rules + the backup copy, mode 640 kept, no staging file left, one reload" || fail "hba-apply result"
orun "hba-reload" ok hba-reload "${A[@]}" --pgdata "$PGD"
orun "accept (accept.sh through the pinned psql, under no environment)" ok accept "${A[@]}"
grep -qx 'ACCEPTANCE PASS' "$OUT" && pass "  ... accept.sh printed ACCEPTANCE PASS" || fail "accept output"
orun "end-login-sessions" ok end-login-sessions "${A[@]}"
orun "uninstall" ok uninstall "${A[@]}"
orun "revoke-restore" ok revoke-restore "${A[@]}"
orun "hba-restore" ok hba-restore "${A[@]}" --pgdata "$PGD" --backup "$B1"
cmp -s "$PGD/pg_hba.conf" "$B1/pg_hba.conf.before" && [ "$(um "$PGD/pg_hba.conf")" = 640 ] && [ "$(stages)" = 0 ] \
  && pass "hba-restore: original bytes, mode kept, no staging file" || fail "hba-restore result"

# --- 2. context and binding refusals ---
fixtures
orun "no --commit" refused preflight --port "$PORT" --pgdata "$PGD"
[ "$(ncalls)" = 0 ] && pass "  ... with zero database calls" || fail "  ... calls: $(ncalls)"
orun "a short commit" refused preflight --commit "${C:0:12}" --port "$PORT" --pgdata "$PGD"
orun "an unknown commit" refused preflight --commit 0000000000000000000000000000000000000000 --port "$PORT" --pgdata "$PGD"
echo x > "$REPO/README"; g add README; g commit -q -m later
orun "a checkout one commit past the reviewed one (package unchanged)" refused preflight "${A[@]}" --pgdata "$PGD"
grep -q 'not at the reviewed commit' "$OUT" && pass "  ... refused because HEAD is not the reviewed commit" || fail "  ... HEAD binding"
g reset -q --hard "$C"
echo '-- edited' >> "$REPO/priv/dev_summary_access/install.sql"
orun "a modified package file" refused install "${A[@]}" --backup "$B1"
g checkout -q -- priv/dev_summary_access/install.sql
echo x > "$REPO/priv/dev_summary_access/extra.sql"
orun "an untracked file in the package" refused install "${A[@]}" --backup "$B1"
rm "$REPO/priv/dev_summary_access/extra.sql"
echo '-- edited' >> "$REPO/docs/adr/0016-dev-db-summary-access.md"
orun "a modified ADR-0016" refused preflight "${A[@]}" --pgdata "$PGD"
g checkout -q -- docs/adr/0016-dev-db-summary-access.md
orun "port 5520 with test binaries" refused preflight --commit "$C" --port 5520 --pgdata "$PGD"
[ "$(ncalls)" = 0 ] && pass "  ... with zero database calls" || fail "  ... calls: $(ncalls)"
orun "a non-canonical port" refused preflight --commit "$C" --port 061999 --pgdata "$PGD"
rm "$STUBS/.d168-owner-run-test-stubs"
orun "test binaries without the stub marker" refused preflight "${A[@]}" --pgdata "$PGD"
[ ! -s "$CALLS" ] && pass "  ... no stub was even asked its version" || fail "  ... stubs called"
: > "$STUBS/.d168-owner-run-test-stubs"
echo 'psql (PostgreSQL) 18.5' > "$FX/version.psql"
orun "a psql that is not 18.6" refused preflight "${A[@]}" --pgdata "$PGD"
rm "$FX/version.psql"
orun "an unknown command" refused frobnicate "${A[@]}"
printf '18.6|/elsewhere|%s/pg_hba.conf|t|127.0.0.1|\n' "$PGD" > "$FX/ident.out"
orun "--pgdata is not the server's data_directory" refused preflight "${A[@]}" --pgdata "$PGD"
printf '18.6|%s|/elsewhere/pg_hba.conf|t|127.0.0.1|\n' "$PGD" > "$FX/ident.out"
orun "hba_file is not <pgdata>/pg_hba.conf" refused hba-apply "${A[@]}" --pgdata "$PGD" --backup "$B1"
printf '18.5|%s|%s/pg_hba.conf|t|127.0.0.1|\n' "$PGD" "$PGD" > "$FX/ident.out"
orun "a server that is not 18.6" refused preflight "${A[@]}" --pgdata "$PGD"
fixtures
ln -s "$PGD" "$T/pgdata-link"
orun "a symlinked --pgdata" refused preflight "${A[@]}" --pgdata "$T/pgdata-link"

# --- 3. backup failures: never BACKUP-VERIFIED, never usable ---
fixtures
chmod 755 "$BP"; orun "a backup parent with mode 755" refused backup "${A[@]}" --pgdata "$PGD" --backup-parent "$BP"; chmod 700 "$BP"
ln -s "$BP" "$T/bp-link"; orun "a symlinked backup parent" refused backup "${A[@]}" --pgdata "$PGD" --backup-parent "$T/bp-link"
orun "a missing backup parent" refused backup "${A[@]}" --pgdata "$PGD" --backup-parent "$T/nope"
partial() {
  local name=$1; shift
  fixtures; "$@"
  orun "backup with $name" refused backup "${A[@]}" --pgdata "$PGD" --backup-parent "$BP"
  local d; d=$(sed -n 's/^BACKUP-INCOMPLETE //p' "$OUT")
  if [ -n "$d" ] && [ ! -e "$d/BACKUP-COMPLETE" ]; then pass "  ... marked BACKUP-INCOMPLETE, no BACKUP-COMPLETE marker"
  else fail "  ... partial backup state ($d)"; fi
  orun "install with that partial backup" refused install "${A[@]}" --backup "$d"
  [ "$(ncalls)" = 0 ] && pass "  ... refused before any database call" || fail "  ... calls: $(ncalls)"
}
partial "pg_dump exiting 1" eval 'echo 1 > "$FX/dump.rc"'
partial "pg_dumpall exiting 1" eval 'echo 1 > "$FX/dumpall.rc"'
partial "an unreadable archive (pg_restore --list exits 1)" eval 'echo 1 > "$FX/toc.rc"'
partial "a dump missing table data (2 of 3 tables)" eval 'sed -i.bak 3d "$FX/toc.out"'
partial "globals without the completion trailer" eval 'printf -- "--\n-- PostgreSQL database cluster dump\n" > "$FX/globals.content"'
fixtures
orun "a good backup for the tamper case" ok backup "${A[@]}" --pgdata "$PGD" --backup-parent "$BP"
B3=$(sed -n 's/^BACKUP-DIR //p' "$OUT"); echo tampered >> "$B3/sdr_agent_dev.dump"
orun "install with a backup that no longer matches its MANIFEST" refused install "${A[@]}" --backup "$B3"
orun "revoke-apply without --backup" refused revoke-apply "${A[@]}"

# --- 4. pg_hba writes: no live change on any failed stage ---
hba_refused() {
  local name=$1 h0; shift
  h0=$(hba_sum)
  orun "hba-apply with $name" refused hba-apply "${A[@]}" --pgdata "$PGD" --backup "$B1"
  [ "$(hba_sum)" = "$h0" ] && [ "$(stages)" = 0 ] && pass "  ... live pg_hba.conf unchanged, no staging file left" || fail "  ... live file changed or staging left"
}
fixtures; echo '# drift' >> "$PGD/pg_hba.conf"; hba_refused "a live file that differs from the backup copy"
fixtures; mv "$PGD/pg_hba.conf" "$PGD/real.conf"; ln -s real.conf "$PGD/pg_hba.conf"
h0=$(sum "$PGD/real.conf"); orun "hba-apply on a symlinked pg_hba.conf" refused hba-apply "${A[@]}" --pgdata "$PGD" --backup "$B1"
[ "$(sum "$PGD/real.conf")" = "$h0" ] && [ -L "$PGD/pg_hba.conf" ] && pass "  ... symlink and its target unchanged" || fail "  ... symlink case changed files"
rm "$PGD/pg_hba.conf"; mv "$PGD/real.conf" "$PGD/pg_hba.conf"
fixtures; chmod 500 "$PGD"; hba_refused "a data directory where no staging file can be created"; chmod 700 "$PGD"
fixtures; sed -i.bak 's/^ACCEPT 13 \(.*\)|ok$/ACCEPT 13 \1|STOP/' "$FX/acceptsql.out"; rm -f "$FX/reloads"
hba_refused "staged rules the server does not read back as the reviewed seven (reverted)"
[ ! -e "$FX/reloads" ] && pass "  ... and nothing was reloaded" || fail "  ... a reload happened"
fixtures; echo f > "$FX/effective.out"
orun "hba-apply whose reload never becomes effective" refused hba-apply "${A[@]}" --pgdata "$PGD" --backup "$B1"
grep -q 'reload did not take effect' "$OUT" && pass "  ... refused: the reload did not take effect (no HBA-APPLIED marker)" || fail "  ... reload refusal"
fixtures; echo f > "$FX/clock.out"
orun "hba-reload whose server clock never passes the file's mtime" refused hba-reload "${A[@]}" --pgdata "$PGD"
fixtures; h0=$(hba_sum)
orun "hba-restore of a file that is not the applied content" refused hba-restore "${A[@]}" --pgdata "$PGD" --backup "$B1"
[ "$(hba_sum)" = "$h0" ] && pass "  ... live pg_hba.conf unchanged" || fail "  ... restore changed the file"
fixtures; echo 1 > "$FX/attest.rc"
orun "accept when acceptance STOPs" refused accept "${A[@]}"
grep -qx 'ACCEPTANCE STOP' "$OUT" && pass "  ... accept.sh's ACCEPTANCE STOP is shown" || fail "  ... accept STOP output"

log "== owner-run: $PASSES passed, $FAILS failed"
[ "$FAILS" = 0 ]
