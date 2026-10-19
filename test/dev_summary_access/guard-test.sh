#!/usr/bin/env bash
# ADR-0016 hermetic test of the throwaway-cluster guard (guard.sh) through
# the real harness entry point (adversarial.sh). No database is involved:
# psql, pg_controldata and lsof are stubs on PATH that record every call.
# Each refused input must exit 2 with a REFUSED line and make ZERO psql
# calls (so no install, uninstall, seed or other -f script can run). The
# post-connect identity mismatch makes exactly one read-only identity
# query and nothing else.
#
#   test/dev_summary_access/guard-test.sh [LOG]
#
# Exit 0 only if every case passes.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd -P)
LOG=${1:-/dev/null}
PASSES=0 FAILS=0
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
# sedi FILE SED-ARGS...: edit in place, keeping the file's mode (BSD or GNU sed).
sedi() { local f=$1 t; shift; t=$(sed "$@" "$f") && printf '%s\n' "$t" > "$f"; }

base=$(mktemp -d "${TMPDIR:-/tmp}/d168guard.XXXXXX"); base=$(cd -P "$base" && pwd -P); chmod 700 "$base"
nontemp=$(mktemp -d "$REPO/.devenv/d168guard-nontemp.XXXXXX"); chmod 700 "$nontemp"
stubs="$base/stubs"; mkdir "$stubs"
CALLS="$base/psql.calls"
sleep 600 & ALIVE=$!
sleep 600 & OTHER=$!
trap 'kill $ALIVE $OTHER 2>/dev/null; rm -rf "$base" "$nontemp"' EXIT
PORT=61999
SYSID=7123456789012345678

# --- stubs ---
cat > "$stubs/psql" <<'EOF'
#!/usr/bin/env bash
{ printf 'CALL'; printf ' [%s]' "$@"; printf '\n'; printf 'ENV %s\n' "$(env | grep -E '^(PG|PSQLRC)' | cut -d= -f1 | sort | tr '\n' ' ')"; } >> "$STUB_CALLS"
case "$*" in *pg_control_system*) printf '%s\n' "$STUB_IDENTITY" ;; esac
exit 0
EOF
cat > "$stubs/pg_controldata" <<'EOF'
#!/usr/bin/env bash
printf 'pg_control version number:            1800\nDatabase system identifier:           %s\n' "$STUB_SYSID"
EOF
cat > "$stubs/lsof" <<'EOF'
#!/usr/bin/env bash
for p in $STUB_LISTENERS; do printf '%s\n' "$p"; done
EOF
chmod 755 "$stubs"/*

# mkroot DIR: a cluster root exactly as throwaway-cluster.sh lays it out.
mkroot() {
  local r=$1
  mkdir -p "$r/pgdata"; chmod 700 "$r"
  printf '%s' "$r" > "$r/.d168-throwaway-root"
  printf 'd168_throwaway_manifest=1\nroot=%s\npgdata=%s\nport=%s\nsystem_identifier=%s\n' \
    "$r" "$r/pgdata" "${2:-$PORT}" "$SYSID" > "$r/manifest"
  chmod 600 "$r/manifest"
  printf '%s\n%s\n1760000000\n%s\n\n127.0.0.1\n  1   2\nready\n' "$ALIVE" "$r/pgdata" "${3:-${2:-$PORT}}" > "$r/pgdata/postmaster.pid"
}
GOOD="$base/d168-throwaway.good"; mkroot "$GOOD"

# run NAME [VAR=VALUE ...] [-- harness args]: the harness under the stubs.
run() {
  local name=$1; shift
  local args=()
  : > "$CALLS"
  OUT=$(env -i HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" PATH="$stubs:/usr/bin:/bin:/usr/sbin:/sbin" \
    STUB_CALLS="$CALLS" STUB_SYSID="$SYSID" STUB_LISTENERS="$ALIVE" \
    STUB_IDENTITY="$SYSID|$GOOD/pgdata|$PORT|$PORT" \
    ADV_PGBIN="$stubs" ADV_MANIFEST="$GOOD/manifest" ADV_PORT="$PORT" ADV_PGDATA="$GOOD/pgdata" \
    ADV_LOG=/dev/null "$@" "$BASH" "$HERE/adversarial.sh" ${HARNESS_ARGS[@]+"${HARNESS_ARGS[@]}"} 2>&1)
  RC=$?
  NCALLS=$(grep -c '^CALL' "$CALLS")
}

# refused NAME VAR=VALUE...: exit 2, a REFUSED line, zero psql calls.
refused() {
  local name=$1; shift
  HARNESS_ARGS=(); run "$name" "$@"
  if [ "$RC" = 2 ] && grep -q '^REFUSED: ' <<<"$OUT" && [ "$NCALLS" = 0 ]; then
    PASSES=$((PASSES + 1)); log "PASS refused, 0 psql calls: $name ($(grep -m1 '^REFUSED' <<<"$OUT" | cut -c1-110))"
  else
    FAILS=$((FAILS + 1)); log "FAIL $name: exit=$RC psql_calls=$NCALLS out=$(head -2 <<<"$OUT" | tr '\n' ' ' | cut -c1-160)"
  fi
}

log "== ADR-0016 guard hermetic test $(date -u +%Y-%m-%dT%H:%M:%SZ) bash $BASH ($BASH_VERSION) guard.sh sha256 $(shasum -a 256 "$HERE/guard.sh" | cut -d' ' -f1) adversarial.sh sha256 $(shasum -a 256 "$HERE/adversarial.sh" | cut -d' ' -f1)"

# --- positive control, with every libpq override set to a hostile value ---
HARNESS_ARGS=(--guard-only)
run "positive control" PGSERVICE=sdr_dev PGSERVICEFILE=/tmp/evil.conf PGHOST=localhost PGHOSTADDR=127.0.0.1 \
  PGPORT=5520 PGDATABASE=sdr_agent_dev PGUSER=postgres PGPASSFILE=/tmp/pgpass PGOPTIONS='-c search_path=evil' \
  PGSSLMODE=disable PGAPPNAME=x PSQLRC=/tmp/evil.psqlrc
call=$(grep -m1 '^CALL' "$CALLS"); envl=$(grep -m1 '^ENV' "$CALLS")
if [ "$RC" = 0 ] && grep -q '^GUARD OK' <<<"$OUT" && [ "$NCALLS" = 1 ] && [ "$envl" = "ENV " ] \
   && grep -q "\[host=127.0.0.1 hostaddr=127.0.0.1 port=$PORT dbname=postgres user=postgres sslmode=disable" <<<"$call" \
   && grep -q '\[-X\]' <<<"$call"; then
  PASSES=$((PASSES + 1)); log "PASS positive control: guard passes, 1 identity call, no PG*/PSQLRC variable reaches psql, every parameter explicit, -X"
else
  FAILS=$((FAILS + 1)); log "FAIL positive control: exit=$RC calls=$NCALLS env='$envl' call='$(cut -c1-200 <<<"$call")' out=$(head -2 <<<"$OUT" | tr '\n' ' ')"
fi

# --- ports: every spelling of 5520 and 4120, and other non-canonical forms ---
for p in 5520 05520 005520 +5520 ' 5520' '5520 ' 5520.0 0x15a0 '5520;' 4120 04120 '' 0 65536 1024 49151 -5520; do
  refused "ADV_PORT='$p'" ADV_PORT="$p"
done
R5520="$base/d168-throwaway.p5520"; mkroot "$R5520" 5520
refused "manifest and ADV_PORT both 5520" ADV_MANIFEST="$R5520/manifest" ADV_PGDATA="$R5520/pgdata" ADV_PORT=5520
R0="$base/d168-throwaway.p05520"; mkroot "$R0" 05520
refused "manifest port 05520, ADV_PORT canonical" ADV_MANIFEST="$R0/manifest" ADV_PGDATA="$R0/pgdata" ADV_PORT="$PORT"
refused "ADV_PORT differs from manifest" ADV_PORT=61998

# --- paths: /tmp symlinks, traversal, non-temporary physical roots ---
ln -s "$GOOD/pgdata" "$base/pgdata-link"
refused "ADV_PGDATA via a symlink to the good pgdata" ADV_PGDATA="$base/pgdata-link"
ln -s "$base" /tmp/d168guard-link.$$
refused "ADV_PGDATA spelled through a /tmp symlink" ADV_PGDATA="/tmp/d168guard-link.$$/d168-throwaway.good/pgdata"
refused "ADV_MANIFEST spelled through a /tmp symlink" ADV_MANIFEST="/tmp/d168guard-link.$$/d168-throwaway.good/manifest" \
  ADV_PGDATA="/tmp/d168guard-link.$$/d168-throwaway.good/pgdata"
rm -f /tmp/d168guard-link.$$
NT="$nontemp/d168-throwaway.real"; mkroot "$NT"
ln -s "$NT" "$base/d168-throwaway.tolink"
refused "root is a temp-dir symlink to a non-temporary cluster root" ADV_MANIFEST="$base/d168-throwaway.tolink/manifest" \
  ADV_PGDATA="$base/d168-throwaway.tolink/pgdata"
refused "root physically outside the temporary prefixes" ADV_MANIFEST="$NT/manifest" ADV_PGDATA="$NT/pgdata"
RL="$base/d168-throwaway.pglink"; mkroot "$RL"; rm -rf "$RL/pgdata"; ln -s "$NT/pgdata" "$RL/pgdata"
refused "pgdata inside a good root is a symlink to a non-temporary directory" ADV_MANIFEST="$RL/manifest" ADV_PGDATA="$RL/pgdata"
refused "ADV_PGDATA with ../ traversal" ADV_PGDATA="$GOOD/pgdata/../pgdata"
refused "ADV_PGDATA with ./ segment" ADV_PGDATA="$GOOD/./pgdata"
refused "ADV_MANIFEST with ../ traversal" ADV_MANIFEST="$GOOD/../d168-throwaway.good/manifest"
refused "ADV_MANIFEST traversing out of the temp prefix" ADV_MANIFEST="$base/../../../..$NT/manifest" ADV_PGDATA="$NT/pgdata"
refused "relative ADV_PGDATA" ADV_PGDATA="pgdata"

# --- the root, marker and manifest themselves ---
RM="$base/d168-throwaway.mode"; mkroot "$RM"; chmod 755 "$RM"
refused "root mode 755" ADV_MANIFEST="$RM/manifest" ADV_PGDATA="$RM/pgdata"
RK="$base/d168-throwaway.nomark"; mkroot "$RK"; rm "$RK/.d168-throwaway-root"
refused "no creation marker" ADV_MANIFEST="$RK/manifest" ADV_PGDATA="$RK/pgdata"
RF="$base/d168-throwaway.mfmode"; mkroot "$RF"; chmod 644 "$RF/manifest"
refused "manifest mode 644" ADV_MANIFEST="$RF/manifest" ADV_PGDATA="$RF/pgdata"
RD="$base/d168-throwaway.dup"; mkroot "$RD"; printf 'port=5520\n' >> "$RD/manifest"
refused "manifest with a second port line" ADV_MANIFEST="$RD/manifest" ADV_PGDATA="$RD/pgdata"
RO="$base/d168-throwaway.other"; mkroot "$RO"; sedi "$RO/manifest" "s|^pgdata=.*|pgdata=$NT/pgdata|"
refused "manifest pgdata outside its root" ADV_MANIFEST="$RO/manifest" ADV_PGDATA="$NT/pgdata"
refused "manifest path inside pgdata" ADV_MANIFEST="$GOOD/pgdata/postmaster.pid"
refused "ADV_MANIFEST unset" ADV_MANIFEST=

# --- identity before connecting: control file, postmaster.pid, listener ---
refused "pg_controldata system identifier differs" STUB_SYSID=7000000000000000001
RP="$base/d168-throwaway.pidport"; mkroot "$RP" "$PORT" 5520
refused "postmaster.pid port is 5520" ADV_MANIFEST="$RP/manifest" ADV_PGDATA="$RP/pgdata"
RX="$base/d168-throwaway.piddir"; mkroot "$RX"; sedi "$RX/pgdata/postmaster.pid" "2s|.*|$NT/pgdata|"
refused "postmaster.pid names another data directory" ADV_MANIFEST="$RX/manifest" ADV_PGDATA="$RX/pgdata"
RY="$base/d168-throwaway.nopid"; mkroot "$RY"; rm "$RY/pgdata/postmaster.pid"
refused "no postmaster.pid" ADV_MANIFEST="$RY/manifest" ADV_PGDATA="$RY/pgdata"
RZ="$base/d168-throwaway.dead"; mkroot "$RZ"; sedi "$RZ/pgdata/postmaster.pid" "1s|.*|999999|"
refused "postmaster PID not alive" ADV_MANIFEST="$RZ/manifest" ADV_PGDATA="$RZ/pgdata"
refused "another process also listens on the port" STUB_LISTENERS="$ALIVE $OTHER"
refused "the listener is not the postmaster" STUB_LISTENERS="$OTHER"
refused "nothing listens on the port" STUB_LISTENERS=

# --- identity after connecting: one read-only identity query, then stop ---
for ident in "7000000000000000001|$GOOD/pgdata|$PORT|$PORT" "$SYSID|$NT/pgdata|$PORT|$PORT" "$SYSID|$GOOD/pgdata|5520|5520" ""; do
  HARNESS_ARGS=(); run "server identity" STUB_IDENTITY="$ident"
  only=$(grep '^CALL' "$CALLS")
  if [ "$RC" = 2 ] && grep -q '^REFUSED: server identity' <<<"$OUT" && [ "$NCALLS" = 1 ] \
     && grep -q 'pg_control_system' <<<"$only" && ! grep -q '\[-f\]' <<<"$only"; then
    PASSES=$((PASSES + 1)); log "PASS server identity '$(cut -c1-40 <<<"$ident")...' refused after 1 identity query, 0 scripts"
  else
    FAILS=$((FAILS + 1)); log "FAIL server identity '$ident': exit=$RC calls=$NCALLS"
  fi
done

log "== guard: $PASSES passed, $FAILS failed"
[ "$FAILS" = 0 ]
