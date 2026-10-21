#!/usr/bin/env bash
# 5b sink test orchestrator (plan r2 as amended by r3, r4, r5, r6 and R6-1;
# handoff tmp claude-5b-sink-plan-r{2..6}.md, claude-5b-sink-plan-r6-amendment-R6-1.md).
#
#   bash test/postgres_log_settings/sink-test.sh --dry-plan
#   bash test/postgres_log_settings/sink-test.sh selftest  --scratch DIR --evidence DIR
#   bash test/postgres_log_settings/sink-test.sh discovery --scratch DIR --evidence DIR \
#        --selftest-summary FILE
#   bash test/postgres_log_settings/sink-test.sh campaign  --scratch DIR --evidence DIR \
#        --selftest-summary FILE --discovery-summary FILE
#
# --dry-plan prints the plan constants and the per-instance manifest shape; it builds
# nothing, starts nothing, creates no directory and reads no runtime or log path.
#
# selftest, discovery and campaign start disposable devenv instances under DIR
# (--scratch, a 0700 dir owned by you) and are run by the owner under a DB-slot claim.
# They never connect to 5520/4120 or touch the owner's checkout, runtime dirs or logs.
# On any failure nothing is deleted: evidence and roots are retained privately.
#
# Exit: 0 pass; 2 refusal (nothing started); 3 HOLD (uncertainty, retained); 4 FAIL.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
STAT=/usr/bin/stat
GREP=/usr/bin/grep
TAR=/usr/bin/tar

die() { echo "SINK-TEST $1: $2" >&2; exit "$3"; }
note() { echo "sink-test: $*" >&2; }

MODE="" SCRATCH="" EVIDENCE="" ST_SUMMARY="" DISC_SUMMARY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-plan) MODE=dry-plan; shift ;;
    selftest|discovery|campaign) MODE=$1; shift ;;
    --scratch) SCRATCH=${2:?}; shift 2 ;;
    --evidence) EVIDENCE=${2:?}; shift 2 ;;
    --selftest-summary) ST_SUMMARY=${2:?}; shift 2 ;;
    --discovery-summary) DISC_SUMMARY=${2:?}; shift 2 ;;
    *) die USAGE "unknown argument $1" 64 ;;
  esac
done
[ -n "$MODE" ] || die USAGE "a mode is required" 64

WT=$(git -C "$HERE" rev-parse --show-toplevel)
HEAD=$(git -C "$WT" rev-parse HEAD)
[ -z "$(git -C "$WT" status --porcelain)" ] || die REFUSE "worktree $WT is not clean" 2

INPUTS=(flake.nix flake.lock devenv.nix priv/postgres/log_settings.json
        test/postgres_log_settings/expected-contract.conf)

input_hashes() {
  local f
  for f in "${INPUTS[@]}"; do
    printf '%s  %s\n' "$(git -C "$WT" show "$HEAD:$f" | /usr/bin/shasum -a 256 | cut -d' ' -f1)" "$f"
  done
}

# ------------------------------------------------------------------ dry plan
dry_plan() {
  echo "mode: dry-plan (builds nothing, starts nothing, creates nothing, reads no runtime/log path)"
  echo "worktree: $WT"
  echo "head: $HEAD"
  echo "inputs at head:"
  input_hashes | sed 's/^/  /'
  echo "interpreter: python3 from flake input nixpkgs at git+file://$WT?rev=$HEAD (resolved at run)"
  echo "constants (sink_watch.py plan):"
  /usr/bin/python3 -I "$HERE/sink_watch.py" plan | sed 's/^/  /'
  cat <<EOF
instances (each its own mktemp root under --scratch, 0700, not in a checkout):
  R  reference build: unedited archive, port 5520, built only, NEVER started
  D  discovery: B config, two epochs, no markers (records real exits and socket states)
  P  positive controls: port + 5 channel deltas (r2 6.3); E1, E2
  A  audit controls: port + shared_preload_libraries=auto_explain; E1
  B  candidate: port only; E1, E2, E3 (forced collector failure)
per-instance manifest (sink_watch.py manifest-new):
  root=<scratch>/sink-<runid>/sink-<inst>-XXXX  runtime=/tmp/devenv-<sha256(root/.devenv)[0:7]>
  pgdata=<root>/.devenv/state/postgres  pc_socket=<runtime>/pc.sock
  native_socket=<runtime>/processes/native.sock  pg_socket=<runtime>/postgres/.s.PGSQL.<port>
  port=random 20000-29999 with no listener (never 5520/4120); listen=127.0.0.1
  launch_env keys: PATH HOME TMPDIR USER LOGNAME LANG LC_ALL TZ PGDATA PGHOST PGPORT
                   PC_SOCKET_PATH PC_TUI_ENABLED  (PGHOST=<runtime>/postgres, r3 1.2)
  home=<root>/home tmpdir=<root>/tmp (0700)
timeline per epoch: claim/recheck runtime -> preflight -> supervise launcher -> ready
  (listener proof) -> prepare (identity, then create allowlisted DBs) -> lockout API sockets
  -> SNAP-0 -> canaries/audits -> drain -> SNAP-pre -> deliberate stop -> barrier ->
  SNAP-post -> classify -> count -> judge
selftest ids: T1 T2 T3 T4a T4b T5 T6 T7 T8 T9a T9b T10 T11 T12 T13 T14 T15a T15b T15c T15d
  T16 T17a T17b T18a T18b T18c T18d T18d-vanish T18d-rebind
EOF
}

if [ "$MODE" = dry-plan ]; then dry_plan; exit 0; fi

# ------------------------------------------------------------------ run setup
[ -n "$SCRATCH" ] && [ -n "$EVIDENCE" ] || die USAGE "--scratch and --evidence are required" 64
for d in "$SCRATCH" "$EVIDENCE"; do
  [ -d "$d" ] && [ ! -L "$d" ] || die REFUSE "$d must be a directory" 2
  [ "$(cd "$d" && pwd -P)" = "$d" ] || die REFUSE "$d must be a physical absolute path" 2
  [ "$($STAT -f '%u %Lp' "$d")" = "$(id -u) 700" ] || die REFUSE "$d must be 0700 and owned by you" 2
done
if [ "$MODE" = discovery ] || [ "$MODE" = campaign ]; then
  [ -f "$ST_SUMMARY" ] || die REFUSE "--selftest-summary is required" 2
fi
if [ "$MODE" = campaign ]; then
  [ -f "$DISC_SUMMARY" ] || die REFUSE "--discovery-summary is required" 2
fi

RUNID="$(date -u +%Y%m%dT%H%M%SZ)-${HEAD:0:8}"
RUNROOT="$SCRATCH/sink-$RUNID"
EVID="$EVIDENCE/5b-sink-$MODE-$RUNID"
mkdir -m 700 "$RUNROOT" "$EVID"
input_hashes > "$EVID/inputs.sha256"
git -C "$WT" show "$HEAD:test/postgres_log_settings/expected-contract.conf" > "$EVID/expected-contract.conf"

NIX=$(command -v nix) || die REFUSE "nix not found" 2
NIXBIN=$(dirname "$NIX")
GITBIN=$(dirname "$(command -v git)")
SYS=$("$NIX" eval --impure --raw --expr builtins.currentSystem)
PYOUT=$("$NIX" build --no-link --print-out-paths --impure --expr \
  "(builtins.getFlake \"git+file://$WT?rev=$HEAD\").inputs.nixpkgs.legacyPackages.$SYS.python3")
PY="$PYOUT/bin/python3"
[ -x "$PY" ] || die REFUSE "locked python3 not found" 2
echo "$PY" > "$EVID/python.txt"
W=("$PY" -I "$HERE/sink_watch.py")
ST=("$PY" -I "$HERE/sink_selftest.py")

for s in "$ST_SUMMARY" "$DISC_SUMMARY"; do
  [ -n "$s" ] || continue
  [ "$("${W[@]}" jget --file "$s" --key head)" = "$HEAD" ] || die REFUSE "$s is for another head" 2
  [ "$("${W[@]}" jget --file "$s" --key pass)" = True ] || die REFUSE "$s did not pass" 2
done

# A watcher left running when the script ends is asked to stop (deliberate, verified);
# nothing is deleted on failure.
ACTIVE_CTL="" ACTIVE_WPID=""
on_exit() {
  local rc=$?
  if [ -n "$ACTIVE_CTL" ]; then
    "${W[@]}" ctl --ctl "$ACTIVE_CTL" --cmd stop --timeout 400 > /dev/null 2>&1 || true
    wait "$ACTIVE_WPID" 2> /dev/null || true
  fi
  if [ "$rc" -ne 0 ]; then
    note "exit $rc: evidence retained under $EVID; instance roots retained under $RUNROOT"
  fi
}
trap on_exit EXIT
trap 'exit 130' INT TERM

# ------------------------------------------------------------------ helpers
mf() { "${W[@]}" field --manifest "$1" --key "$2"; }
jget() { "${W[@]}" jget --file "$1" --key "$2"; }
MARKER_FILES=()

marker_list() {
  local out="$EVID/markers-list.json" first=1 f
  { printf '{"files": ['
    for f in "${MARKER_FILES[@]}"; do
      [ $first = 1 ] || printf ', '
      printf '"%s"' "$f"; first=0
    done
    printf ']}\n'; } > "$out.tmp" && mv "$out.tmp" "$out"
}

# Build env: exactly these keys; PWD pins devenv.root (r2 2.3, r3/r4).
build_env() {
  env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" PATH="$NIXBIN:$GITBIN:/usr/bin:/bin" PWD="$1" "${@:2}"
}

new_instance() { # kind inst [extra manifest-new args...]
  "${W[@]}" manifest-new --kind "$1" --inst "$2" --head "$HEAD" --worktree "$WT" \
    --scratch "$RUNROOT" --evidence "$EVID" "${@:3}" > "$EVID/.last-manifest.json"
  M="$EVID/$2/manifest.json"
}

make_copy() { # manifest
  local root; root=$(mf "$1" root)
  git -C "$WT" archive "$HEAD" flake.nix flake.lock devenv.nix priv/postgres/log_settings.json \
    | $TAR -x -C "$root"
  "${W[@]}" edit-copy --manifest "$1" > /dev/null
  git -C "$root" init -q
  git -C "$root" add flake.nix flake.lock devenv.nix priv/postgres/log_settings.json
  git -C "$root" -c user.name=sink-test -c user.email=sink-test@invalid -c commit.gpgsign=false \
    commit -q -m "5b sink test copy of $HEAD"
}

build_launcher() { # manifest [pwd]
  local root dir; root=$(mf "$1" root); dir=${2:-$root}
  (cd "$dir" && build_env "$dir" "$NIX" build --impure --no-link --print-out-paths "$root#devenv-up")
}

eval_check() { # manifest
  local root ev; root=$(mf "$1" root); ev=$(mf "$1" evidence)
  (cd "$root" && build_env "$root" "$NIX" eval --impure --json \
    "$root#devShells.$SYS.default.config.env" --apply \
    'e: { inherit (e) PGDATA PGHOST PGPORT PC_SOCKET_PATH DEVENV_ROOT DEVENV_DOTFILE DEVENV_STATE DEVENV_RUNTIME; }') \
    > "$ev/eval-env.json"
  "${W[@]}" eval-check --manifest "$1" --eval-json "$ev/eval-env.json" > /dev/null
}

prepare_reference() {
  new_instance R R
  make_copy "$M"
  build_launcher "$M" > "$EVID/R/launcher-path"
  "${W[@]}" artifacts --manifest "$M" --launcher "$(< "$EVID/R/launcher-path")" > /dev/null
}

prepare_instance() { # kind inst -> M
  local kind=$1 inst=$2 ev extra=()
  new_instance "$kind" "$inst"
  ev="$EVID/$inst"
  make_copy "$M"
  build_launcher "$M" > "$ev/launcher-path"
  eval_check "$M"
  case "$kind" in B|D|S) extra=(--expected-contract "$EVID/expected-contract.conf") ;; esac
  "${W[@]}" artifacts --manifest "$M" --launcher "$(< "$ev/launcher-path")" \
    --reference "$EVID/R/artifacts.json" "${extra[@]}" > /dev/null \
    || die REFUSE "provenance check failed for $inst (see $ev/provenance.json)" 2
}

start_epoch() { # manifest epoch first(1|0) -> ED CTL STATE WPID
  local m=$1 ep=$2 ev pf=()
  ev=$(mf "$m" evidence); ED="$ev/$ep"; mkdir -m 700 "$ED"
  if [ "$3" = 1 ]; then
    "${W[@]}" claim-runtime --manifest "$m" > "$ED/claim.json"
    pf=(--first-start)
  else
    "${W[@]}" recheck-runtime --manifest "$m" > "$ED/recheck.json"
  fi
  "${W[@]}" preflight --manifest "$m" "${pf[@]}" > "$ED/preflight.json"
  CTL="$ED/ctl" STATE="$ED/state.json"
  "${W[@]}" supervise --manifest "$m" --ctl "$CTL" --state "$STATE" \
    --launcher "$(< "$ev/launcher-path")" --epoch "$ep" > "$ED/supervise.out" 2> "$ED/supervise.err" &
  WPID=$! ACTIVE_CTL=$CTL ACTIVE_WPID=$WPID
}

wait_ready() { # manifest deadline -> PMPID PMBIRTH (rc of ready-wait)
  local rc=0
  "${W[@]}" ready-wait --manifest "$1" --state "$STATE" --deadline "$2" --out "$ED/ready.json" \
    2> "$ED/ready.err" || rc=$?
  if [ $rc -eq 0 ]; then
    PMPID=$(jget "$ED/ready.json" pid); PMBIRTH=$(jget "$ED/ready.json" birth_us)
  fi
  return $rc
}

CLIENT_N=0
client() { # manifest out-name args... (rc of the client)
  local m=$1 name=$2 ev; ev=$(mf "$m" evidence); CLIENT_N=$((CLIENT_N + 1))
  local out="$ED/client-$CLIENT_N-$name.json"
  (cd "$WT" && "$NIX" develop --impure -c env -u PGHOST -u PGPORT -u PGDATA -u PGUSER \
     -u PGDATABASE -u PGPASSWORD -u PGSERVICE -u PGSERVICEFILE -u PGSYSCONFDIR -u PGPASSFILE \
     -u DATABASE_URL -u PC_SOCKET_PATH MIX_ENV=test \
     mix run --no-start test/postgres_log_settings/sink_canaries.exs \
       --manifest "$m" --out "$out" --postmaster-pid "$PMPID" --postmaster-birth-us "$PMBIRTH" \
       --py "$PY" --watch "$HERE/sink_watch.py" --state "$STATE" --sysid-file "$ev/sysid.txt" \
       "${@:3}") > "$ED/client-$CLIENT_N-$name.out" 2> "$ED/client-$CLIENT_N-$name.err"
}

lock_snap0() { # manifest
  "${W[@]}" lockout --manifest "$1" --out "$ED/lockout.json"
  "${W[@]}" snapshot --manifest "$1" --name SNAP-0 --out "$ED/SNAP-0"
  "${W[@]}" ctl --ctl "$CTL" --cmd mark --label window_start --timeout 30 > /dev/null
}

snap_pre() { # manifest
  "${W[@]}" drain-check --manifest "$1" --state "$STATE"
  "${W[@]}" snapshot --manifest "$1" --name SNAP-pre --out "$ED/SNAP-pre" --prev "$ED/SNAP-0" \
    > "$ED/SNAP-pre.violations.json"
}

stop_and_barrier() { # manifest -> rc 0 ok, 3 hold
  local wrc=0
  "${W[@]}" ctl --ctl "$CTL" --cmd stop --timeout 400 > "$ED/stop.json"
  wait "$WPID" || wrc=$?
  ACTIVE_CTL=""
  echo "$wrc" > "$ED/supervise.rc"
  "${W[@]}" barrier --manifest "$1" --state "$STATE" --out "$ED/barrier.json" 2> "$ED/barrier.err"
}

snap_post_classify() { # manifest -> CLASS_RC
  "${W[@]}" snapshot --manifest "$1" --name SNAP-post --out "$ED/SNAP-post" --prev "$ED/SNAP-pre" \
    > "$ED/SNAP-post.violations.json"
  CLASS_RC=0
  "${W[@]}" classify-epoch --manifest "$1" --epoch-dir "$ED" --state "$STATE" > /dev/null \
    || CLASS_RC=$?
}

count_judge() { # manifest kind markers-file [--q2]
  marker_list
  "${W[@]}" count --markers "$EVID/markers-list.json" --snapshot "$ED/SNAP-post" --out "$ED/counts.json"
  "${W[@]}" judge --kind "$2" --counts "$ED/counts.json" --markers "$3" \
    --classification "$ED/classification.json" --out "$ED/judge.json" "${@:4}" > /dev/null
}

new_markers() { # inst epoch -> MK
  MK="$EVID/markers-$1-$2.json"
  "${W[@]}" markers-new --inst "$1" --epoch "$2" --out "$MK"
  MARKER_FILES+=("$MK")
}

empty_markers() { # inst epoch -> MK
  MK="$EVID/markers-$1-$2.json"
  printf '{"inst": "%s", "epoch": "%s", "markers": {}}\n' "$1" "$2" > "$MK"
}

cleanup_instance() { "${W[@]}" cleanup --manifest "$1" > /dev/null; }

# ------------------------------------------------------------------ one marker epoch
# kind inst epoch first creates canary_db audit_db(-) audit_expect(-)
marker_epoch() {
  local m=$M kind=$1 inst=$2 ep=$3 first=$4 creates=$5 cdb=$6 adb=$7 aexp=$8
  start_epoch "$m" "$ep" "$first"
  wait_ready "$m" "${READY_DEADLINE:-120}" || die FAIL "$inst $ep not ready" 4
  client "$m" prepare --mode prepare --create "$creates" --canary-db "$cdb" \
    || die HOLD "$inst $ep prepare refused" 3
  lock_snap0 "$m"
  new_markers "$inst" "$ep"
  client "$m" canaries --mode canaries --db "$cdb" --markers "$MK" || die FAIL "$inst $ep canaries" 4
  if [ "$adb" != - ]; then
    client "$m" audit --mode audit --db "$adb" --expect "$aexp" || die FAIL "$inst $ep audit" 4
  fi
  if [ "$kind" = P ] && [ "$ep" = E1 ]; then
    client "$m" audit-load --mode audit --db p_load --expect p_load || die FAIL "P p_load" 4
  fi
  snap_pre "$m"
  stop_and_barrier "$m" || die HOLD "$inst $ep barrier" 3
  snap_post_classify "$m"
  local q2=()
  if [ "$kind" = P ] && [ "$ep" = E1 ]; then q2=(--q2); fi
  count_judge "$m" "$kind" "$MK" "${q2[@]}" || die FAIL "$inst $ep judgement (see $ED/judge.json)" 4
}

# ------------------------------------------------------------------ discovery
run_discovery() {
  prepare_reference
  prepare_instance D D
  local m=$M ep first=1 rcs=() pc ns
  for ep in E1 E2; do
    start_epoch "$m" "$ep" "$first"; first=0
    wait_ready "$m" 120 || die FAIL "D $ep not ready" 4
    client "$m" identity --mode identity || die HOLD "D $ep identity" 3
    lock_snap0 "$m"
    pc=$("${W[@]}" check-eacces --path "$(mf "$m" pc_socket)" | "${W[@]}" jget --file - --key result || true)
    ns=$("${W[@]}" check-eacces --path "$(mf "$m" native_socket)" | "${W[@]}" jget --file - --key result || true)
    printf '{"pc_socket": "%s", "native_socket": "%s"}\n' "$pc" "$ns" > "$ED/eacces.json"
    snap_pre "$m"
    stop_and_barrier "$m" || die HOLD "D $ep barrier" 3
    snap_post_classify "$m"
    rcs+=("$ep:$CLASS_RC:$pc:$ns")
  done
  local pass=True r
  for r in "${rcs[@]}"; do
    case "$r" in *:0:errno-13:errno-13) ;; *) pass=False ;; esac
  done
  printf '{"head": "%s", "pass": %s, "epochs": "%s"}\n' "$HEAD" \
    "$([ $pass = True ] && echo true || echo false)" "${rcs[*]}" > "$EVID/discovery-summary.json"
  "${W[@]}" report --evid "$EVID" --head "$HEAD"
  [ $pass = True ] || die FAIL "discovery did not establish the expected graceful epochs" 4
  cleanup_instance "$m"
  cleanup_instance "$EVID/R/manifest.json"
}

# ------------------------------------------------------------------ campaign (r3 6)
run_campaign() {
  prepare_reference
  local snaps=()
  # P first: positive controls; any miss stops before B is ever started
  prepare_instance P P; local mp=$M
  marker_epoch P P E1 1 p_canary_r1,p_audit,p_load p_canary_r1 p_audit pass
  snaps+=("P=$ED/SNAP-post")
  marker_epoch P P E2 0 p_canary_r2 p_canary_r2 - -
  snaps+=("P=$ED/SNAP-post")
  # A: audit controls
  prepare_instance A A; local ma=$M
  start_epoch "$ma" E1 1
  wait_ready "$ma" 120 || die FAIL "A not ready" 4
  client "$ma" prepare --mode prepare --create a_ext,a_plain || die HOLD "A prepare" 3
  client "$ma" a-ext-setup --mode a_ext_setup || die HOLD "A a_ext setup" 3
  lock_snap0 "$ma"
  client "$ma" audit-ext --mode audit --db a_ext --expect a_ext || die FAIL "A a_ext audit" 4
  client "$ma" audit-plain --mode audit --db a_plain --expect a_plain || die FAIL "A a_plain audit" 4
  snap_pre "$ma"
  stop_and_barrier "$ma" || die HOLD "A barrier" 3
  snap_post_classify "$ma"
  empty_markers A E1
  count_judge "$ma" A "$MK" || die FAIL "A judgement" 4
  snaps+=("A=$ED/SNAP-post")
  # B: candidate
  prepare_instance B B; local mb=$M
  marker_epoch B B E1 1 b_canary_r1,b_audit b_canary_r1 b_audit pass
  snaps+=("B=$ED/SNAP-post")
  marker_epoch B B E2 0 b_canary_r2 b_canary_r2 - -
  snaps+=("B=$ED/SNAP-post")
  run_s5 "$mb"
  # cross-instance search over every SNAP-post with every marker (r2 7.1)
  marker_list
  local entries; entries=$(IFS=,; echo "${snaps[*]}")
  "${W[@]}" cross-check --entries "$entries" --markers "$EVID/markers-list.json" \
    --out "$EVID/cross-check.json" || die FAIL "cross-instance check" 4
  "${W[@]}" report --evid "$EVID" --head "$HEAD"
  local mm
  for mm in "$mp" "$ma" "$mb" "$EVID/R/manifest.json"; do cleanup_instance "$mm"; done
  note "campaign complete: $EVID/report.md"
}

run_s5() { # B E3: forced collector-start failure (r2 10, r3 5.5, r4 3.2)
  local m=$1 ev rc=0
  ev=$(mf "$m" evidence)
  "${W[@]}" move-collector --manifest "$m" --dest "$ev/collector-pre-s5" --out "$ev/s5-move.json"
  start_epoch "$m" E3 0
  "${W[@]}" s5-observe --manifest "$m" --state "$STATE" --deadline 300 --out "$ED/s5.json" || rc=$?
  if [ "$(jget "$ED/s5.json" accepting)" != None ]; then
    note "S5: the server accepted connections; running an s5 marker epoch"
    PMPID=$(jget "$ED/s5.json" accepting.pid); PMBIRTH=$(jget "$ED/s5.json" accepting.birth_us)
    client "$m" s5-prepare --mode prepare --create b_canary_s5 --canary-db b_canary_s5 || true
    lock_snap0 "$m"
    new_markers B S5
    client "$m" s5-canaries --mode canaries --db b_canary_s5 --markers "$MK" || true
    snap_pre "$m" || true
  else
    "${W[@]}" snapshot --manifest "$m" --name SNAP-0 --out "$ED/SNAP-0" > /dev/null || true
  fi
  stop_and_barrier "$m" || die HOLD "S5 barrier" 3
  "${W[@]}" restore-collector --manifest "$m" --out "$ED/restore.json"
  "${W[@]}" snapshot --manifest "$m" --name SNAP-post --out "$ED/SNAP-post" > /dev/null
  printf '{"inst": "B", "epoch": "S5diag", "markers": {"collector_open_fail": "could not open log file"}}\n' \
    > "$EVID/s5-diag-markers.json"
  printf '{"files": ["%s"]}\n' "$EVID/s5-diag-markers.json" > "$ED/s5-diag-list.json"
  "${W[@]}" count --markers "$ED/s5-diag-list.json" --snapshot "$ED/SNAP-post" --out "$ED/s5-diag-counts.json"
  "${W[@]}" s5-verdict --epoch-dir "$ED" --out "$ED/s5-verdict.json" > /dev/null || true
}

# ------------------------------------------------------------------ selftest (r2 9, r3 7)
SD=""
sv() { # id expected observed ok [retained-json]
  "${ST[@]}" verdict --dir "$SD" --test "$1" --expected "$2" --observed "$3" --ok "$4" \
    --retained "${5:-[]}" > /dev/null || true
}
reg() { "${ST[@]}" register --dir "$SD" --test "$1" --kind "$2" --what "$3"; }
birth() { "${ST[@]}" identity --pid "$1" | "${W[@]}" jget --file - --key birth_us; }
kill_fx() { "${ST[@]}" kill-fixture --pid "$1" --birth-us "$2" > /dev/null || true; wait "$1" 2> /dev/null || true; }

st_T1() {
  new_instance S T1; local rt rc=0 b a; rt=$(mf "$M" runtime)
  reg T1 dir "\"$rt\""; mkdir -m 700 "$rt"; b=$($STAT -f '%d:%i' "$rt")
  "${W[@]}" claim-runtime --manifest "$M" > /dev/null 2> "$SD/T1.err" || rc=$?
  a=$($STAT -f '%d:%i' "$rt")
  local ok=0
  [ $rc -eq 2 ] && $GREP -q REFUSE-RUNTIME-EXISTS "$SD/T1.err" && [ "$a" = "$b" ] \
    && [ -z "$(ls -A "$rt")" ] && ok=1
  rmdir "$rt"; sv T1 REFUSE-RUNTIME-EXISTS "rc=$rc" $ok
}

st_T2() {
  new_instance S T2; local rt rc=0 dp db _i; rt=$(mf "$M" runtime)
  reg T2 dir "\"$rt\""; mkdir -m 700 "$rt"
  reg T2 proc '"T2-unix-decoy"'
  "${ST[@]}" fixture-unix-listener --path "$rt/pc.sock" & dp=$!
  for _i in $(seq 1 50); do [ -S "$rt/pc.sock" ] && break; sleep 0.1; done
  db=$(birth "$dp")
  "${W[@]}" claim-runtime --manifest "$M" > /dev/null 2> "$SD/T2.err" || rc=$?
  kill_fx "$dp" "$db"; rm -f "$rt/pc.sock"; rmdir "$rt"
  local ok=0; [ $rc -eq 2 ] && $GREP -q REFUSE-RUNTIME-EXISTS "$SD/T2.err" && ok=1
  sv T2 REFUSE-RUNTIME-EXISTS "rc=$rc; launcher never spawned" $ok
}

st_T3() {
  local real="$RUNROOT/t3-real" link="$RUNROOT/t3-link" d755="$RUNROOT/t3-755" repo="$RUNROOT/t3-repo"
  local ra=0 rb=0 rc=0
  reg T3 dir "\"$real\""; reg T3 symlink "\"$link\""; reg T3 dir "\"$d755\""; reg T3 dir "\"$repo\""
  mkdir -m 700 "$real"; ln -s "$real" "$link"; mkdir -m 755 "$d755"
  mkdir -m 700 "$repo"; git -C "$repo" init -q; mkdir -m 700 "$repo/root"
  "${W[@]}" manifest-new --kind S --inst T3a --head "$HEAD" --worktree "$WT" --scratch "$RUNROOT" \
    --evidence "$EVID" --root "$link" > /dev/null 2>&1 || ra=$?
  "${W[@]}" manifest-new --kind S --inst T3b --head "$HEAD" --worktree "$WT" --scratch "$RUNROOT" \
    --evidence "$EVID" --root "$d755" > /dev/null 2>&1 || rb=$?
  "${W[@]}" manifest-new --kind S --inst T3c --head "$HEAD" --worktree "$WT" --scratch "$RUNROOT" \
    --evidence "$EVID" --root "$repo/root" > /dev/null 2>&1 || rc=$?
  rm -f "$link"; rmdir "$real" "$d755"; rm -rf "$repo"
  local ok=0; [ $ra -eq 2 ] && [ $rb -eq 2 ] && [ $rc -eq 2 ] && ok=1
  sv T3 REFUSE-ROOT "symlink=$ra mode755=$rb in-checkout=$rc" $ok
}

st_T4() { # a|b
  local v=$1 addr; [ "$v" = a ] && addr=127.0.0.1 || addr=0.0.0.0
  prepare_instance S "T4$v"; local m=$M port dp db rc=0 acc
  port=$(mf "$m" port); ED="$(mf "$m" evidence)/E1"; mkdir -m 700 "$ED"
  "${W[@]}" claim-runtime --manifest "$m" > "$ED/claim.json"
  "${W[@]}" preflight --manifest "$m" --first-start > "$ED/preflight.json"
  reg "T4$v" proc "\"T4$v-tcp-decoy\""
  "${ST[@]}" fixture-tcp-decoy --addr "$addr" --port "$port" --count-file "$SD/T4$v-count.json" & dp=$!
  local _i; for _i in $(seq 1 50); do [ -f "$SD/T4$v-count.json" ] && break; sleep 0.1; done
  db=$(birth "$dp")
  CTL="$ED/ctl" STATE="$ED/state.json"
  "${W[@]}" supervise --manifest "$m" --ctl "$CTL" --state "$STATE" \
    --launcher "$(< "$(mf "$m" evidence)/launcher-path")" --epoch E1 > /dev/null 2>&1 &
  WPID=$! ACTIVE_CTL=$CTL ACTIVE_WPID=$WPID
  wait_ready "$m" 60 || rc=$?
  stop_and_barrier "$m" || true
  kill_fx "$dp" "$db"
  acc=$(jget "$SD/T4$v-count.json" accepts)
  local ok=0; [ $rc -ne 0 ] && [ "$acc" = 0 ] && ok=1
  reg "T4$v" dir "\"$(mf "$m" root)\""; reg "T4$v" dir "\"$(mf "$m" runtime)\""
  sv "T4$v" HOLD-or-FAIL-START "ready_rc=$rc decoy_accepts=$acc" $ok \
    "[\"$(mf "$m" root)\", \"$(mf "$m" runtime)\"]"
}

st_T5() {
  prepare_instance S T5; local m=$M ev r1=0 r2=0 ex
  ev=$(mf "$m" evidence)
  start_epoch "$m" E1 1
  wait_ready "$m" 120 || { sv T5 REFUSE "not ready" 0; stop_and_barrier "$m" || true; return; }
  "${W[@]}" perturb --manifest "$m" --out "$ev/manifest-bad-pgdata.json" --set "pgdata=/nonexistent/pgdata" > /dev/null
  "${W[@]}" perturb --manifest "$m" --out "$ev/manifest-bad-port.json" --set "port=$(( $(mf "$m" port) + 1 ))" > /dev/null
  client "$ev/manifest-bad-pgdata.json" bad-pgdata --mode prepare --create s_probe || r1=$?
  client "$ev/manifest-bad-port.json" bad-port --mode prepare --create s_probe || r2=$?
  client "$m" db-exists --mode db_exists --name s_probe || true
  ex=$(jget "$ED/client-$CLIENT_N-db-exists.json" exists)
  stop_and_barrier "$m" || true
  local ok=0; [ $r1 -ne 0 ] && [ $r2 -ne 0 ] && [ "$ex" = False ] && ok=1
  [ $ok = 1 ] && cleanup_instance "$m"
  sv T5 REFUSE "bad_pgdata_rc=$r1 bad_port_rc=$r2 s_probe_exists=$ex" $ok
}

st_T6() {
  prepare_instance S-T6 T6; local m=$M rc=0
  start_epoch "$m" E1 1
  wait_ready "$m" 60 || rc=$?
  stop_and_barrier "$m" || true
  reg T6 dir "\"$(mf "$m" root)\""; reg T6 dir "\"$(mf "$m" runtime)\""
  local ok=0; [ $rc -ne 0 ] && ok=1
  sv T6 FAIL-START "ready_rc=$rc" $ok "[\"$(mf "$m" root)\", \"$(mf "$m" runtime)\"]"
}

st_T7() {
  prepare_instance S-T7 T7; local m=$M rc=0 pg
  pg=$(mf "$m" pgdata)
  start_epoch "$m" E1 1
  wait_ready "$m" 120 || { sv T7 FAIL-TIMEOUT "first start not ready" 0; stop_and_barrier "$m" || true; return; }
  stop_and_barrier "$m" || { sv T7 FAIL-TIMEOUT "first stop barrier" 0; return; }
  reg T7 file "\"$pg/standby.signal\""; : > "$pg/standby.signal"
  start_epoch "$m" E2 0
  wait_ready "$m" 60 || rc=$?
  stop_and_barrier "$m" || true
  reg T7 dir "\"$(mf "$m" root)\""; reg T7 dir "\"$(mf "$m" runtime)\""
  if [ $rc -eq 0 ]; then
    sv T7 FAIL-TIMEOUT "INCONCLUSIVE: the standby fixture became ready" 0
  else
    sv T7 FAIL-TIMEOUT "ready_rc=$rc" 1 "[\"$(mf "$m" root)\", \"$(mf "$m" runtime)\"]"
  fi
}

st_T8() {
  prepare_instance S T8; local m=$M dp db brc=0 adm alive
  start_epoch "$m" E1 1
  wait_ready "$m" 120 || { sv T8 FAIL-UNCERTAIN "not ready" 0; stop_and_barrier "$m" || true; return; }
  reg T8 proc '"T8-cwd-holder"'
  "${ST[@]}" fixture-cwd-holder --cwd "$(mf "$m" root)" & dp=$!
  sleep 0.5; db=$(birth "$dp")
  stop_and_barrier "$m" || brc=$?
  adm=$("${ST[@]}" state-has-pid --state "$STATE" --pid "$dp" | "${W[@]}" jget --file - --key admitted)
  alive=$("${ST[@]}" identity --pid "$dp" | "${W[@]}" jget --file - --key birth_us 2> /dev/null || echo gone)
  kill_fx "$dp" "$db"
  "${W[@]}" barrier --manifest "$m" --state "$STATE" --out "$ED/barrier-after-fixture.json" > /dev/null 2>&1 \
    && cleanup_instance "$m"
  local ok=0; [ $brc -eq 3 ] && [ "$adm" = False ] && [ "$alive" = "$db" ] && ok=1
  sv T8 FAIL-UNCERTAIN "barrier_rc=$brc admitted=$adm decoy_alive_until_fixture_cleanup=$([ "$alive" = "$db" ] && echo yes || echo no)" $ok
}

st_T13() {
  prepare_instance S T13; local m=$M ev rc=0
  ev=$(mf "$m" evidence)
  "${W[@]}" perturb --manifest "$m" --out "$ev/manifest-attach.json" \
    --set "launch_env.PC_SOCKET_PATH=/tmp/sink-t13-elsewhere.sock" > /dev/null
  "${W[@]}" preflight --manifest "$ev/manifest-attach.json" --first-start > /dev/null 2> "$SD/T13.err" || rc=$?
  local ok=0; [ $rc -eq 2 ] && $GREP -q REFUSE-ENV "$SD/T13.err" && ok=1
  cleanup_instance "$m"
  sv T13 REFUSE-ENV "rc=$rc" $ok
}

st_T14() {
  new_instance S T14; local m=$M other="$RUNROOT/t14-other" rc=0 ev
  ev=$(mf "$m" evidence)
  reg T14 dir "\"$other\""; mkdir -m 700 "$other"
  make_copy "$m"
  build_launcher "$m" "$other" > "$ev/launcher-path"
  "${W[@]}" artifacts --manifest "$m" --launcher "$(< "$ev/launcher-path")" \
    --reference "$EVID/R/artifacts.json" > /dev/null 2>&1 || rc=$?
  rmdir "$other"; cleanup_instance "$m"
  local ok=0; [ $rc -eq 2 ] && ok=1
  sv T14 REFUSE-PROVENANCE "rc=$rc" $ok
}

st_T15() { # a|b|c: injection after the stop began, before SNAP-post (r4 2.6)
  local v=$1
  prepare_instance S "T15$v"; local m=$M rt pg dp="" db="" crc=0
  rt=$(mf "$m" runtime); pg=$(mf "$m" pgdata)
  start_epoch "$m" E1 1
  wait_ready "$m" 120 || { sv "T15$v" INCOMPLETE "not ready" 0; stop_and_barrier "$m" || true; return; }
  client "$m" identity --mode identity || true
  lock_snap0 "$m"; snap_pre "$m"
  "${W[@]}" ctl --ctl "$CTL" --cmd stop --timeout 400 > "$ED/stop.json"
  wait "$WPID" || true; ACTIVE_CTL=""
  case "$v" in
    a) reg T15a file "\"$rt/processes/logs/postgres.stderr.log\""
       "${ST[@]}" inject --kind truncate --path "$rt/processes/logs/postgres.stderr.log" > /dev/null ;;
    b) reg T15b file "\"$(mf "$m" root)/.devenv/state/process-compose/process-compose.log\""
       "${ST[@]}" inject --kind rename-over \
         --path "$(mf "$m" root)/.devenv/state/process-compose/process-compose.log" > /dev/null ;;
    c) reg T15c proc '"T15c-decoy"'
       "${ST[@]}" fixture-sleeper --seconds 600 & dp=$!; sleep 0.3; db=$(birth "$dp")
       reg T15c file "\"$pg/log/new-collector\""; reg T15c file "\"$pg/postmaster.pid\""
       "${ST[@]}" inject --kind new-collector --path "$pg/log" > /dev/null
       "${ST[@]}" inject --kind postmaster-pid --path "$pg/postmaster.pid" --pid "$dp" > /dev/null ;;
  esac
  "${W[@]}" barrier --manifest "$m" --state "$STATE" --out "$ED/barrier.json" 2> "$ED/barrier.err" || true
  "${W[@]}" snapshot --manifest "$m" --name SNAP-post --out "$ED/SNAP-post" --prev "$ED/SNAP-pre" > /dev/null || true
  "${W[@]}" classify-epoch --manifest "$m" --epoch-dir "$ED" --state "$STATE" > /dev/null || crc=$?
  [ -n "$dp" ] && kill_fx "$dp" "$db"
  reg "T15$v" dir "\"$(mf "$m" root)\""; reg "T15$v" dir "\"$(mf "$m" runtime)\""
  local ok=0; [ $crc -eq 4 ] && ok=1
  sv "T15$v" INCOMPLETE "classify_rc=$crc" $ok "[\"$(mf "$m" root)\", \"$(mf "$m" runtime)\"]"
}

run_selftest() {
  SD="$EVID/selftest"; mkdir -m 700 "$SD"
  local id
  for id in T9a T9b T10 T11 T12 T15d T16 T17a T17b T18a T18b T18c T18d T18d-vanish T18d-rebind; do
    "${ST[@]}" synthetic --dir "$SD" --scratch "$RUNROOT" --id "$id" > /dev/null 2> "$SD/$id.err" || true
  done
  prepare_reference
  st_T1; st_T2; st_T3; st_T13; st_T14
  st_T4 a; st_T4 b; st_T5; st_T6; st_T7; st_T8; st_T15 a; st_T15 b; st_T15 c
  local ids="T1,T2,T3,T4a,T4b,T5,T6,T7,T8,T9a,T9b,T10,T11,T12,T13,T14,T15a,T15b,T15c,T15d,T16"
  ids="$ids,T17a,T17b,T18a,T18b,T18c,T18d,T18d-vanish,T18d-rebind"
  "${ST[@]}" summary --dir "$SD" --head "$HEAD" --ids "$ids" > "$EVID/selftest-summary.out" \
    || die FAIL "self-tests did not all give their expected verdicts (see $SD/selftest-summary.json)" 4
  note "selftest summary: $SD/selftest-summary.json"
}

case "$MODE" in
  selftest) run_selftest ;;
  discovery) run_discovery ;;
  campaign) run_campaign ;;
esac
