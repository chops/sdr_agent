#!/usr/bin/env bash
# 5b sink test orchestrator (plan r2 as amended by r3, r4, r5, r6 and R6-1;
# handoff tmp claude-5b-sink-plan-r{2..6}.md, claude-5b-sink-plan-r6-amendment-R6-1.md),
# repaired per claude-5b-harness-repair-plan.md (35a4926f), its amendment (25092856) and A1/A2.
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
# Every wait on a background job is bounded by a monotonic deadline (wait_bounded); a job
# still running at its deadline is HOLD and is never signalled by this script (repair H2,
# A1). A stop is requested at most once per watcher; after a HOLD nothing is stopped again.
#
# Exit: 0 pass; 2 refusal (nothing started); 3 HOLD (uncertainty, retained); 4 FAIL
# (including S5 NOT-EXERCISED).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
STAT=/usr/bin/stat
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

# The self-test IDs, in run order (repair plan + amendment self-test list).
SYNTHETIC_IDS="T9a T9b T10 T11 T12 T15d T16 T17a T17b T17-baseline T18a T18b T18c T18d"
SYNTHETIC_IDS="$SYNTHETIC_IDS T18d-vanish T18d-rebind T19a T19b T19c T19d T20a T20b T20c T20d"
SYNTHETIC_IDS="$SYNTHETIC_IDS T21a T21b T21c T21d T21e T22a T22b T22c T22d T23a T23b T23c T23d T24"
SHELL_IDS="T1 T2 T3 T13 T14 T19e"
INSTANCE_IDS="T4a T4b T5 T6 T7 T8 T15a T15b T15c T25"

# supervise's post-stop bound is TIMEOUTS.barrier (90) + 30 s; the shell allows 30 s more.
WATCH_EXIT_S=150

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
  B  candidate: port only; E1, E2, S5 (forced collector failure; DB b_canary_s5 if accepting)
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
  -> SNAP-0 -> canaries/audits -> drain -> SNAP-pre -> one deliberate stop -> bounded
  watcher exit -> barrier -> SNAP-post -> classify (complete required) -> count -> judge
cross-check: SNAP-0, SNAP-pre and SNAP-post of every required epoch (P E1/E2, A E1,
  B E1/E2, B S5 when accepting)
bounded waits: watcher exit ${WATCH_EXIT_S}s after the stop request; HOLD at the deadline,
  nothing signalled by the shell
selftest ids (stop at the first non-pass):
  synthetic: $SYNTHETIC_IDS
  shell:     $SHELL_IDS
  instance:  $INSTANCE_IDS
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

# ------------------------------------------------------------------ bounded waits (H2, A1)
# wait_bounded PID SECONDS: polls `kill -0` (sends no signal) on this shell's own job
# against a monotonic deadline from sink_watch.py `mono`, with an iteration cap as a second
# bound. Returns 0 with WAIT_RC = the job's own exit status once it has ended and been
# reaped by `wait`; returns 3 (HOLD) if the job is still running at the deadline, or if
# `wait` does not know the job (127: uncertainty, never success). It never signals.
WAIT_RC=""
wait_bounded() {
  local pid=$1 secs=$2 dl n=0 cap
  cap=$((secs * 5 + 25))
  WAIT_RC=""
  dl=$("${W[@]}" mono --plus "$secs") || return 3
  while kill -0 "$pid" 2> /dev/null; do
    n=$((n + 1))
    if [ "$n" -gt "$cap" ] || ! "${W[@]}" mono-before --deadline "$dl"; then
      note "job $pid still running at its ${secs}s deadline: HOLD, nothing signalled"
      return 3
    fi
    sleep 0.2
  done
  if wait "$pid"; then WAIT_RC=0; else WAIT_RC=$?; fi
  if [ "$WAIT_RC" -eq 127 ]; then
    note "job $pid is unknown to this shell: uncertainty"
    return 3
  fi
  return 0
}

# Per-watcher flags (repair H2): at most one stop request; none after a teardown HOLD.
ACTIVE_CTL="" ACTIVE_WPID="" STOP_ATTEMPTED=0 HOLD_SEEN=0
on_exit() {
  local rc=$?
  trap - EXIT
  if [ -n "$ACTIVE_CTL" ]; then
    [ "$rc" -ne 0 ] || rc=3
    if [ "$STOP_ATTEMPTED" = 0 ] && [ "$HOLD_SEEN" = 0 ]; then
      STOP_ATTEMPTED=1
      note "exit $rc with a live watcher: one deliberate stop request (no barrier, no release)"
      if "${W[@]}" ctl --ctl "$ACTIVE_CTL" --cmd stop --timeout 400 > "$ACTIVE_CTL.exit-stop.json" \
          2> "$ACTIVE_CTL.exit-stop.err" && wait_bounded "$ACTIVE_WPID" "$WATCH_EXIT_S" \
          && [ "$WAIT_RC" = 0 ]; then
        note "exit-path stop completed; the instance is retained for disposition"
      else
        note "exit-path stop did not complete: HOLD"
        rc=3
      fi
    else
      note "watcher $ACTIVE_WPID not stopped again (stop_attempted=$STOP_ATTEMPTED hold=$HOLD_SEEN): HOLD"
      rc=3
    fi
  fi
  if [ "$rc" -ne 0 ]; then
    note "exit $rc: evidence retained under $EVID; instance roots retained under $RUNROOT"
  fi
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT TERM

# ------------------------------------------------------------------ helpers
mf() { "${W[@]}" field --manifest "$1" --key "$2"; }
jget() { "${W[@]}" jget --file "$1" --key "$2"; }
MARKER_FILES=()

# Self-test registration hooks (repair H3): intent before creation, identity after.
# Inert outside selftest mode (ST_TEST empty).
ST_TEST="" SD=""
reg_intent() { [ -z "$ST_TEST" ] || "${ST[@]}" intent --dir "$SD" --test "$ST_TEST" --label "$1" --kind "$2"; }
reg_path() { [ -z "$ST_TEST" ] || "${ST[@]}" identity-path --dir "$SD" --test "$ST_TEST" --label "$1" --path "$2"; }

marker_list() {
  local out="$EVID/markers-list.json" first=1 f
  { printf '{"files": ['
    for f in "${MARKER_FILES[@]+"${MARKER_FILES[@]}"}"; do
      [ $first = 1 ] || printf ', '
      printf '"%s"' "$f"; first=0
    done
    printf ']}\n'; } > "$out.tmp" && mv "$out.tmp" "$out"
}

# Build env: exactly these keys; PWD pins devenv.root (r2 2.3, r3/r4).
build_env() {
  env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" PATH="$NIXBIN:$GITBIN:/usr/bin:/bin" PWD="$1" "${@:2}"
}

new_instance() { # kind inst [extra manifest-new args...] -> M
  reg_intent "root-$2" dir
  "${W[@]}" manifest-new --kind "$1" --inst "$2" --head "$HEAD" --worktree "$WT" \
    --scratch "$RUNROOT" --evidence "$EVID" "${@:3}" > "$EVID/.last-manifest.json"
  M="$EVID/$2/manifest.json"
  reg_path "root-$2" "$(mf "$M" root)"
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
    --reference "$EVID/R/artifacts.json" "${extra[@]+"${extra[@]}"}" > /dev/null \
    || die REFUSE "provenance check failed for $inst (see $ev/provenance.json)" 2
}

start_epoch() { # manifest epoch first(1|0) -> ED CTL STATE WPID
  local m=$1 ep=$2 ev pf=() inst
  [ -z "$ACTIVE_CTL" ] || die HOLD "an earlier watcher is still active ($ACTIVE_CTL)" 3
  ev=$(mf "$m" evidence); inst=$(mf "$m" inst); ED="$ev/$ep"; mkdir -m 700 "$ED"
  if [ "$3" = 1 ]; then
    reg_intent "runtime-$inst" dir
    "${W[@]}" claim-runtime --manifest "$m" > "$ED/claim.json"
    reg_path "runtime-$inst" "$(mf "$m" runtime)"
    pf=(--first-start)
  else
    "${W[@]}" recheck-runtime --manifest "$m" > "$ED/recheck.json"
  fi
  "${W[@]}" preflight --manifest "$m" "${pf[@]+"${pf[@]}"}" > "$ED/preflight.json"
  CTL="$ED/ctl" STATE="$ED/state.json"
  "${W[@]}" supervise --manifest "$m" --ctl "$CTL" --state "$STATE" \
    --launcher "$(< "$ev/launcher-path")" --epoch "$ep" > "$ED/supervise.out" 2> "$ED/supervise.err" &
  WPID=$! ACTIVE_CTL=$CTL ACTIVE_WPID=$WPID STOP_ATTEMPTED=0 HOLD_SEEN=0
}

wait_ready() { # manifest deadline -> PMPID PMBIRTH (rc of ready-wait; stderr in $ED/ready.err)
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

# One deliberate stop, a bounded watcher exit, then the barrier (repair H2). Returns 0, or
# the first failing status: 3 for a stop/watcher HOLD, else the barrier's own status. A
# failed stop is never retried and no barrier runs while the watcher may still be live.
stop_and_barrier() { # manifest
  local crc=0 brc=0
  STOP_ATTEMPTED=1
  "${W[@]}" ctl --ctl "$CTL" --cmd stop --timeout 400 > "$ED/stop.json" 2> "$ED/stop.err" || crc=$?
  if ! wait_bounded "$WPID" "$WATCH_EXIT_S"; then
    HOLD_SEEN=1
    echo "running-at-deadline" > "$ED/supervise.rc"
    return 3
  fi
  ACTIVE_CTL="" ACTIVE_WPID=""
  echo "$WAIT_RC" > "$ED/supervise.rc"
  echo "$crc" > "$ED/stop.rc"
  if [ "$crc" -ne 0 ] || [ "$WAIT_RC" -ne 0 ]; then
    HOLD_SEEN=1
    return 3
  fi
  "${W[@]}" barrier --manifest "$1" --state "$STATE" --out "$ED/barrier.json" 2> "$ED/barrier.err" \
    || brc=$?
  echo "$brc" > "$ED/barrier.rc"
  return "$brc"
}

snap_post_classify() { # manifest -> CLASS_RC (0 complete, 4 INCOMPLETE, 3 HOLD)
  "${W[@]}" snapshot --manifest "$1" --name SNAP-post --out "$ED/SNAP-post" --prev "$ED/SNAP-pre" \
    > "$ED/SNAP-post.violations.json"
  CLASS_RC=0
  "${W[@]}" classify-epoch --manifest "$1" --epoch-dir "$ED" --state "$STATE" > /dev/null \
    || CLASS_RC=$?
}

count_judge() { # manifest kind markers-file [--q2]; called in a || list, so checks itself
  marker_list
  "${W[@]}" count --markers "$EVID/markers-list.json" --snapshot "$ED/SNAP-post" \
    --out "$ED/counts.json" || return $?
  "${W[@]}" judge --kind "$2" --counts "$ED/counts.json" --markers "$3" \
    --classification "$ED/classification.json" --out "$ED/judge.json" "${@:4}" > /dev/null || return $?
}

# repair H4: every epoch requires a complete classification and a passing judgement; the
# counts of an INCOMPLETE epoch are still written (partial) and the run stops before any
# later epoch or instance.
epoch_verdict() { # label judge-rc
  case "$CLASS_RC" in
    0) ;;
    4) die FAIL "$1 classification INCOMPLETE (partial counts retained in $ED/counts.json)" 4 ;;
    *) die HOLD "$1 classification status $CLASS_RC" 3 ;;
  esac
  case "$2" in
    0) ;;
    4) die FAIL "$1 judgement (see $ED/judge.json)" 4 ;;
    *) die HOLD "$1 count/judge status $2" 3 ;;
  esac
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

# Cross-check inputs (repair H7, D-8): every snapshot of every required epoch.
SNAPS=()
add_snaps() { # inst (for $ED)
  SNAPS+=("$1=$ED/SNAP-0" "$1=$ED/SNAP-pre" "$1=$ED/SNAP-post")
}

# ------------------------------------------------------------------ one marker epoch
# kind inst epoch first creates canary_db audit_db(-) audit_expect(-)
marker_epoch() {
  local m=$M kind=$1 inst=$2 ep=$3 first=$4 creates=$5 cdb=$6 adb=$7 aexp=$8 sb=0 jrc=0
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
  stop_and_barrier "$m" || sb=$?
  [ "$sb" -eq 0 ] || die HOLD "$inst $ep stop/barrier status $sb" 3
  snap_post_classify "$m"
  local q2=()
  if [ "$kind" = P ] && [ "$ep" = E1 ]; then q2=(--q2); fi
  count_judge "$m" "$kind" "$MK" "${q2[@]+"${q2[@]}"}" || jrc=$?
  epoch_verdict "$inst $ep" "$jrc"
  add_snaps "$inst"
}

# ------------------------------------------------------------------ discovery
run_discovery() {
  prepare_reference
  prepare_instance D D
  local m=$M ep first=1 rcs=() pc ns sb r pass=True
  for ep in E1 E2; do
    start_epoch "$m" "$ep" "$first"; first=0
    wait_ready "$m" 120 || die FAIL "D $ep not ready" 4
    client "$m" identity --mode identity || die HOLD "D $ep identity" 3
    lock_snap0 "$m"
    pc=$("${W[@]}" check-eacces --path "$(mf "$m" pc_socket)" | "${W[@]}" jget --file - --key result)
    ns=$("${W[@]}" check-eacces --path "$(mf "$m" native_socket)" | "${W[@]}" jget --file - --key result)
    printf '{"pc_socket": "%s", "native_socket": "%s"}\n' "$pc" "$ns" > "$ED/eacces.json"
    snap_pre "$m"
    sb=0; stop_and_barrier "$m" || sb=$?
    [ "$sb" -eq 0 ] || die HOLD "D $ep stop/barrier status $sb" 3
    snap_post_classify "$m"
    rcs+=("$ep:$CLASS_RC:$pc:$ns")
    case "$CLASS_RC" in
      0) ;;
      4) die FAIL "D $ep classification INCOMPLETE (see $ED/classification.json)" 4 ;;
      *) die HOLD "D $ep classification status $CLASS_RC" 3 ;;
    esac
  done
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
  local sb jrc=0
  # P first: positive controls; any miss (including INCOMPLETE) stops before A or B starts
  prepare_instance P P; local mp=$M
  marker_epoch P P E1 1 p_canary_r1,p_audit,p_load p_canary_r1 p_audit pass
  marker_epoch P P E2 0 p_canary_r2 p_canary_r2 - -
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
  sb=0; stop_and_barrier "$ma" || sb=$?
  [ "$sb" -eq 0 ] || die HOLD "A stop/barrier status $sb" 3
  snap_post_classify "$ma"
  empty_markers A E1
  count_judge "$ma" A "$MK" || jrc=$?
  epoch_verdict "A E1" "$jrc"
  add_snaps A
  # B: candidate
  prepare_instance B B; local mb=$M
  marker_epoch B B E1 1 b_canary_r1,b_audit b_canary_r1 b_audit pass
  marker_epoch B B E2 0 b_canary_r2 b_canary_r2 - -
  run_s5 "$mb" B b_canary_s5 1
  # cross-instance search over every snapshot of every required epoch with every marker
  marker_list
  local entries; entries=$(IFS=,; echo "${SNAPS[*]}")
  "${W[@]}" cross-check --entries "$entries" --markers "$EVID/markers-list.json" \
    --out "$EVID/cross-check.json" || die FAIL "cross-instance check" 4
  "${W[@]}" report --evid "$EVID" --head "$HEAD"
  # success cleanup only after every epoch, the cross-check and an exercised S5 passed
  local mm
  for mm in "$mp" "$ma" "$mb" "$EVID/R/manifest.json"; do cleanup_instance "$mm"; done
  note "campaign complete: $EVID/report.md"
}

# S5 (r2 10, r3 5.5, r4 3.2; repair H7). fault=1: B's forced collector-start failure; both
# branches must end with s5-verdict exercised=true, else NOT-EXERCISED (exit 4, retained).
# fault=0: T25 plumbing on a self-test instance (accepting branch required; proves the
# branch's code path only, never the forced failure).
run_s5() { # manifest inst db fault(1|0)
  local m=$1 inst=$2 db=$3 fault=$4 ev orc=0 sb=0 jrc=0 vrc=0 r=0 first=0
  ev=$(mf "$m" evidence)
  if [ "$fault" = 1 ]; then
    "${W[@]}" move-collector --manifest "$m" --dest "$ev/collector-pre-s5" --out "$ev/s5-move.json"
  else
    first=1
  fi
  start_epoch "$m" S5 "$first"
  "${W[@]}" s5-observe --manifest "$m" --state "$STATE" --deadline 300 --out "$ED/s5.json" \
    2> "$ED/s5.err" || orc=$?
  [ "$orc" -eq 0 ] || die HOLD "$inst S5 observation status $orc (see $ED/s5.err)" 3
  if [ "$(jget "$ED/s5.json" accepting)" != None ]; then
    note "S5: the server accepted connections; running the full S5 marker epoch"
    PMPID=$(jget "$ED/s5.json" accepting.pid); PMBIRTH=$(jget "$ED/s5.json" accepting.birth_us)
    if [ "$fault" = 0 ]; then
      client "$m" s5-disallowed --mode prepare --create b_canary_s5 --canary-db b_canary_s5 || r=$?
      [ "$r" -eq 2 ] || die FAIL "$inst S5: a B database name on an S instance gave status $r, not 2" 4
    fi
    client "$m" s5-prepare --mode prepare --create "$db" --canary-db "$db" \
      || die HOLD "$inst S5 prepare refused" 3
    lock_snap0 "$m"
    new_markers "$inst" S5
    client "$m" s5-canaries --mode canaries --db "$db" --markers "$MK" || die FAIL "$inst S5 canaries" 4
    snap_pre "$m"
    stop_and_barrier "$m" || sb=$?
    [ "$sb" -eq 0 ] || die HOLD "$inst S5 stop/barrier status $sb" 3
    if [ "$fault" = 1 ]; then
      "${W[@]}" restore-collector --manifest "$m" --out "$ED/restore.json"
    fi
    snap_post_classify "$m"
    count_judge "$m" B "$MK" || jrc=$?
    epoch_verdict "$inst S5" "$jrc"
    add_snaps "$inst"
  else
    [ "$fault" = 1 ] || die FAIL "$inst S5 (T25) did not reach the accepting branch" 4
    "${W[@]}" snapshot --manifest "$m" --name SNAP-0 --out "$ED/SNAP-0" > /dev/null
    stop_and_barrier "$m" || sb=$?
    [ "$sb" -eq 0 ] || die HOLD "$inst S5 stop/barrier status $sb" 3
    "${W[@]}" restore-collector --manifest "$m" --out "$ED/restore.json"
    "${W[@]}" snapshot --manifest "$m" --name SNAP-post --out "$ED/SNAP-post" --prev "$ED/SNAP-0" \
      > /dev/null
  fi
  if [ "$fault" = 1 ]; then
    printf '{"inst": "B", "epoch": "S5diag", "markers": {"collector_open_fail": "could not open log file"}}\n' \
      > "$EVID/s5-diag-markers.json"
    printf '{"files": ["%s"]}\n' "$EVID/s5-diag-markers.json" > "$ED/s5-diag-list.json"
    "${W[@]}" count --markers "$ED/s5-diag-list.json" --snapshot "$ED/SNAP-post" \
      --out "$ED/s5-diag-counts.json"
    "${W[@]}" s5-verdict --epoch-dir "$ED" --out "$ED/s5-verdict.json" > /dev/null || vrc=$?
    case "$vrc" in
      0) ;;
      4) die FAIL "S5 NOT-EXERCISED: the forced collector failure was not shown (B retained; see $ED/s5-verdict.json)" 4 ;;
      *) die HOLD "S5 verdict status $vrc" 3 ;;
    esac
  fi
}

# ------------------------------------------------------------------ selftest (r2 9, r3 7; H3)
# Every test ends in `sv`, which asks sink_selftest.py for the verdict: the observed class
# must equal one of the test's fixed expected classes, the teardown proof must be complete
# and the independent reconciliation must find no unauthorized leftover. Anything other
# than PASS / EXPECTED-REFUSAL stops the suite at once with exit 3 (no later test, no
# cleanup, no summary).
sv() { # test expected(comma list) observed teardown-json [retained manifests, comma list]
  local rc=0
  "${ST[@]}" verdict --dir "$SD" --test "$1" --expected "$2" --observed "$3" --teardown "$4" \
    --runroot "$RUNROOT" --retained-manifests "${5:-}" > "$SD/$1.verdict.out" || rc=$?
  [ "$rc" -eq 0 ] || die HOLD "self-test $1 did not give its expected verdict (status $rc; see $SD/$1.json)" 3
}
st_intent() { "${ST[@]}" intent --dir "$SD" --test "$1" --label "$2" --kind "$3"; }
st_idpath() { "${ST[@]}" identity-path --dir "$SD" --test "$1" --label "$2" --path "$3"; }
st_idproc() { "${ST[@]}" identity-proc --dir "$SD" --test "$1" --label "$2" --pid "$3" --ppid "$$"; }
st_retain() { "${ST[@]}" retain --dir "$SD" --test "$1" --labels "$2"; }
obs() { "${ST[@]}" observed-class --file "$1" | "${W[@]}" jget --file - --key class; }
rcword() { if [ "$1" = 0 ]; then echo ok; else echo "status-$1"; fi; }

# Identity-bound fixture stop (SIGTERM, 10 s), then a bounded reap of this shell's own job.
st_kill() { # test label pid -> 0, or 3
  "${ST[@]}" kill-fixture --dir "$SD" --test "$1" --label "$2" > /dev/null || return 3
  wait_bounded "$3" 20 || return 3
  return 0
}

# Start a selftest fixture as this shell's own job, registered intent-then-identity.
FX=""
st_fixture() { # test label ready-path fixture-args...
  local t=$1 l=$2 ready=$3 _i
  shift 3
  st_intent "$t" "$l" proc
  "${ST[@]}" "$@" & FX=$!
  for _i in $(seq 1 50); do [ -e "$ready" ] && break; sleep 0.1; done
  [ -e "$ready" ] || die HOLD "fixture $t/$l not ready" 3
  st_idproc "$t" "$l" "$FX"
}

st_T1() {
  ST_TEST=T1; new_instance S T1; local m=$M rt rc=0 b a cls cl
  rt=$(mf "$m" runtime)
  st_intent T1 rtdir dir; mkdir -m 700 "$rt"; st_idpath T1 rtdir "$rt"; b=$($STAT -f '%d:%i' "$rt")
  "${W[@]}" claim-runtime --manifest "$m" > /dev/null 2> "$SD/T1.err" || rc=$?
  a=$($STAT -f '%d:%i' "$rt")
  cls=$(obs "$SD/T1.err"); [ "$rc" -eq 2 ] || cls="$cls-STATUS-$rc"
  { [ "$a" = "$b" ] && [ -z "$(ls -A "$rt")" ]; } || cls="RUNTIME-DIR-CHANGED"
  rmdir "$rt"
  cl=0; cleanup_instance "$m" || cl=$?
  ST_TEST=""
  sv T1 REFUSE-RUNTIME-EXISTS "$cls" "{\"fixtures\": \"ok\", \"cleanup\": \"$(rcword $cl)\"}"
}

st_T2() {
  ST_TEST=T2; new_instance S T2; local m=$M rt rc=0 cls k=0 cl=0
  rt=$(mf "$m" runtime)
  st_intent T2 rtdir dir; mkdir -m 700 "$rt"; st_idpath T2 rtdir "$rt"
  st_fixture T2 unix-decoy "$rt/pc.sock" fixture-unix-listener --path "$rt/pc.sock"
  "${W[@]}" claim-runtime --manifest "$m" > /dev/null 2> "$SD/T2.err" || rc=$?
  cls=$(obs "$SD/T2.err"); [ "$rc" -eq 2 ] || cls="$cls-STATUS-$rc"
  st_kill T2 unix-decoy "$FX" || k=$?
  [ "$k" -eq 0 ] || die HOLD "T2 fixture teardown: REAL-UNCERTAINTY" 3
  rm -f "$rt/pc.sock"; rmdir "$rt"
  cleanup_instance "$m" || cl=$?
  ST_TEST=""
  sv T2 REFUSE-RUNTIME-EXISTS "$cls" "{\"fixtures\": \"ok\", \"cleanup\": \"$(rcword $cl)\"}"
}

st_T3() {
  local real="$RUNROOT/t3-real" link="$RUNROOT/t3-link" d755="$RUNROOT/t3-755" repo="$RUNROOT/t3-repo"
  local ca cb cc cls ra=0 rb=0 rc=0
  st_intent T3 real dir; mkdir -m 700 "$real"; st_idpath T3 real "$real"
  st_intent T3 link symlink; ln -s "$real" "$link"; st_idpath T3 link "$link"
  st_intent T3 d755 dir; mkdir -m 755 "$d755"; st_idpath T3 d755 "$d755"
  st_intent T3 repo dir; mkdir -m 700 "$repo"; st_idpath T3 repo "$repo"
  git -C "$repo" init -q; mkdir -m 700 "$repo/root"
  "${W[@]}" manifest-new --kind S --inst T3a --head "$HEAD" --worktree "$WT" --scratch "$RUNROOT" \
    --evidence "$EVID" --root "$link" > /dev/null 2> "$SD/T3a.err" || ra=$?
  "${W[@]}" manifest-new --kind S --inst T3b --head "$HEAD" --worktree "$WT" --scratch "$RUNROOT" \
    --evidence "$EVID" --root "$d755" > /dev/null 2> "$SD/T3b.err" || rb=$?
  "${W[@]}" manifest-new --kind S --inst T3c --head "$HEAD" --worktree "$WT" --scratch "$RUNROOT" \
    --evidence "$EVID" --root "$repo/root" > /dev/null 2> "$SD/T3c.err" || rc=$?
  ca=$(obs "$SD/T3a.err"); cb=$(obs "$SD/T3b.err"); cc=$(obs "$SD/T3c.err")
  cls="symlink=$ca/$ra,mode755=$cb/$rb,in-checkout=$cc/$rc"
  [ "$cls" != "symlink=REFUSE-ROOT/2,mode755=REFUSE-ROOT/2,in-checkout=REFUSE-ROOT/2" ] || cls=REFUSE-ROOT
  rm -f "$link"; rmdir "$real" "$d755"; rm -rf "$repo"
  sv T3 REFUSE-ROOT "$cls" '{"fixtures": "ok"}'
}

st_T13() {
  ST_TEST=T13; prepare_instance S T13; local m=$M ev cls cl=0 rc=0
  ev=$(mf "$m" evidence)
  "${W[@]}" perturb --manifest "$m" --out "$ev/manifest-attach.json" \
    --set "launch_env.PC_SOCKET_PATH=/tmp/sink-t13-elsewhere.sock" > /dev/null
  "${W[@]}" preflight --manifest "$ev/manifest-attach.json" --first-start > /dev/null 2> "$SD/T13.err" \
    || rc=$?
  cls=$(obs "$SD/T13.err"); [ "$rc" -eq 2 ] || cls="$cls-STATUS-$rc"
  cleanup_instance "$m" || cl=$?
  ST_TEST=""
  sv T13 REFUSE-ENV "$cls" "{\"cleanup\": \"$(rcword $cl)\"}"
}

st_T14() {
  ST_TEST=T14; new_instance S T14; local m=$M other="$RUNROOT/t14-other" ev cls cl=0 rc=0
  ev=$(mf "$m" evidence)
  st_intent T14 other dir; mkdir -m 700 "$other"; st_idpath T14 other "$other"
  make_copy "$m"
  build_launcher "$m" "$other" > "$ev/launcher-path"
  "${W[@]}" artifacts --manifest "$m" --launcher "$(< "$ev/launcher-path")" \
    --reference "$EVID/R/artifacts.json" > /dev/null 2> "$SD/T14.err" || rc=$?
  cls=$(obs "$SD/T14.err"); [ "$rc" -eq 2 ] || cls="$cls-STATUS-$rc"
  rmdir "$other"; cleanup_instance "$m" || cl=$?
  ST_TEST=""
  sv T14 REFUSE-PROVENANCE "$cls" "{\"fixtures\": \"ok\", \"cleanup\": \"$(rcword $cl)\"}"
}

st_T19e() { # A1: the subject (wait_bounded, 2 s) must HOLD on a live 8 s job without hanging
  local rc=0 t_lim cls outer
  st_intent T19e sleeper proc
  "${ST[@]}" fixture-sleeper --seconds 8 & FX=$!
  st_idproc T19e sleeper "$FX"
  t_lim=$("${W[@]}" mono --plus 5)
  wait_bounded "$FX" 2 || rc=$?
  cls=HOLD-WAIT-BOUNDED
  [ "$rc" -eq 3 ] || cls="SUBJECT-STATUS-$rc"
  "${W[@]}" mono-before --deadline "$t_lim" || cls="SUBJECT-OVERRAN"
  # outer teardown: no signal; its own job, under an independent monotonic 20 s deadline
  wait_bounded "$FX" 20 || die HOLD "T19e: fixture still alive at the outer deadline: REAL-UNCERTAINTY" 3
  outer=$WAIT_RC
  "${ST[@]}" wait-gone --dir "$SD" --test T19e --label sleeper --deadline 1 > /dev/null \
    || die HOLD "T19e: fixture identity still present after its reap: REAL-UNCERTAINTY" 3
  sv T19e HOLD-WAIT-BOUNDED "$cls" "{\"outer_reap\": \"$(rcword "$outer")\"}"
}

st_T4() { # a|b
  local v=$1 addr; [ "$v" = a ] && addr=127.0.0.1 || addr=0.0.0.0
  local T="T4$v"
  ST_TEST=$T; prepare_instance S "$T"; local m=$M port rc=0 sb=0 k=0 acc cls
  port=$(mf "$m" port)
  ED="$(mf "$m" evidence)/E1"; mkdir -m 700 "$ED"
  reg_intent "runtime-$T" dir
  "${W[@]}" claim-runtime --manifest "$m" > "$ED/claim.json"
  reg_path "runtime-$T" "$(mf "$m" runtime)"
  "${W[@]}" preflight --manifest "$m" --first-start > "$ED/preflight.json"
  st_fixture "$T" tcp-decoy "$SD/$T-count.json" fixture-tcp-decoy --addr "$addr" --port "$port" \
    --count-file "$SD/$T-count.json"
  CTL="$ED/ctl" STATE="$ED/state.json"
  "${W[@]}" supervise --manifest "$m" --ctl "$CTL" --state "$STATE" \
    --launcher "$(< "$(mf "$m" evidence)/launcher-path")" --epoch E1 > "$ED/supervise.out" \
    2> "$ED/supervise.err" &
  WPID=$! ACTIVE_CTL=$CTL ACTIVE_WPID=$WPID STOP_ATTEMPTED=0 HOLD_SEEN=0
  local dp=$FX
  wait_ready "$m" 60 || rc=$?
  cls=$(obs "$ED/ready.err")
  [ "$rc" -ne 0 ] || cls="READY"
  stop_and_barrier "$m" || sb=$?
  st_kill "$T" tcp-decoy "$dp" || k=$?
  [ "$k" -eq 0 ] || die HOLD "$T fixture teardown: REAL-UNCERTAINTY" 3
  acc=$(jget "$SD/$T-count.json" accepts)
  [ "$acc" = 0 ] || cls="DECOY-ACCEPTED-$acc"
  st_retain "$T" "root-$T,runtime-$T"
  ST_TEST=""
  sv "$T" HOLD-FOREIGN-LISTENER,FAIL-START "$cls" \
    "{\"stop_barrier\": \"$(rcword $sb)\", \"fixtures\": \"ok\", \"cleanup\": \"not-applicable:retained by design (H3)\"}" "$m"
}

st_T5() {
  ST_TEST=T5; prepare_instance S T5; local m=$M ev r1=0 r2=0 ex dx=0 sb=0 cl=0 cls
  ev=$(mf "$m" evidence)
  start_epoch "$m" E1 1
  wait_ready "$m" 120 || die HOLD "T5: instance not ready (setup failure)" 3
  "${W[@]}" perturb --manifest "$m" --out "$ev/manifest-bad-pgdata.json" --set "pgdata=/nonexistent/pgdata" > /dev/null
  "${W[@]}" perturb --manifest "$m" --out "$ev/manifest-bad-port.json" --set "port=$(( $(mf "$m" port) + 1 ))" > /dev/null
  client "$ev/manifest-bad-pgdata.json" bad-pgdata --mode prepare --create s_probe || r1=$?
  client "$ev/manifest-bad-port.json" bad-port --mode prepare --create s_probe || r2=$?
  client "$m" db-exists --mode db_exists --name s_probe || dx=$?
  ex=$(jget "$ED/client-$CLIENT_N-db-exists.json" exists)
  stop_and_barrier "$m" || sb=$?
  if [ "$sb" -eq 0 ]; then cleanup_instance "$m" || cl=$?; else cl=not-run; fi
  # [A] the client's status for a wrong pgdata is 2 (identity) and for a port with no
  # server 2 or 3 (connect refused before any statement); both refuse before mutation.
  cls="bad_pgdata=$r1,bad_port=$r2,s_probe_exists=$ex"
  case "$r1:$r2:$ex" in 2:2:False|2:3:False) cls=REFUSE-CLIENT-TARGET ;; esac
  ST_TEST=""
  sv T5 REFUSE-CLIENT-TARGET "$cls" \
    "{\"db_exists_client\": \"$(rcword $dx)\", \"stop_barrier\": \"$(rcword $sb)\", \"cleanup\": \"$(rcword "$cl")\"}"
}

st_T6() {
  ST_TEST=T6; prepare_instance S-T6 T6; local m=$M rc=0 sb=0 cls
  start_epoch "$m" E1 1
  wait_ready "$m" 60 || rc=$?
  cls=$(obs "$ED/ready.err"); [ "$rc" -ne 0 ] || cls=READY
  stop_and_barrier "$m" || sb=$?
  st_retain T6 "root-T6,runtime-T6"
  ST_TEST=""
  sv T6 FAIL-START "$cls" \
    "{\"stop_barrier\": \"$(rcword $sb)\", \"cleanup\": \"not-applicable:retained by design (H3)\"}" "$m"
}

st_T7() {
  ST_TEST=T7; prepare_instance S-T7 T7; local m=$M rc=0 sb=0 pg cls live
  pg=$(mf "$m" pgdata)
  start_epoch "$m" E1 1
  wait_ready "$m" 120 || die HOLD "T7: first start not ready (setup failure)" 3
  stop_and_barrier "$m" || sb=$?
  [ "$sb" -eq 0 ] || die HOLD "T7: first stop/barrier status $sb" 3
  st_intent T7 standby-signal file; : > "$pg/standby.signal"; st_idpath T7 standby-signal "$pg/standby.signal"
  start_epoch "$m" E2 0
  wait_ready "$m" 60 || rc=$?
  cls=$(obs "$ED/ready.err"); [ "$rc" -ne 0 ] || cls=READY
  live=$("${ST[@]}" state-live-role --state "$STATE" --role postmaster-final | "${W[@]}" jget --file - --key live)
  [ "$live" = True ] || cls="$cls-WITHOUT-LIVE-POSTMASTER"
  sb=0; stop_and_barrier "$m" || sb=$?
  st_retain T7 "root-T7,runtime-T7,standby-signal"
  ST_TEST=""
  sv T7 FAIL-TIMEOUT "$cls" \
    "{\"stop_barrier\": \"$(rcword $sb)\", \"cleanup\": \"not-applicable:retained by design (H3)\"}" "$m"
}

st_T8() {
  ST_TEST=T8; prepare_instance S T8; local m=$M sb=0 adm alive gr k=0 b2=0 cl=0 cls dp
  start_epoch "$m" E1 1
  wait_ready "$m" 120 || die HOLD "T8: instance not ready (setup failure)" 3
  st_intent T8 cwd-holder proc
  "${ST[@]}" fixture-cwd-holder --cwd "$(mf "$m" root)" & dp=$!
  sleep 0.5; st_idproc T8 cwd-holder "$dp"
  stop_and_barrier "$m" || sb=$?
  # the class is read from the barrier's own stderr, only if the barrier ran
  cls=STOP-OR-WATCHER-HOLD
  [ ! -f "$ED/barrier.rc" ] || cls=$(obs "$ED/barrier.err")
  [ "$sb" -ne 0 ] || cls=BARRIER-PASSED
  adm=$("${ST[@]}" state-has-pid --state "$STATE" --pid "$dp" | "${W[@]}" jget --file - --key admitted)
  [ "$adm" = False ] || cls="$cls-FIXTURE-ADMITTED"
  gr=0
  "${ST[@]}" wait-gone --dir "$SD" --test T8 --label cwd-holder --deadline 0 > "$ED/T8-gone.json" || gr=$?
  alive=$(jget "$ED/T8-gone.json" gone)
  [ "$alive" = False ] && [ "$gr" -eq 3 ] || cls="$cls-FIXTURE-GONE-EARLY"
  st_kill T8 cwd-holder "$dp" || k=$?
  [ "$k" -eq 0 ] || die HOLD "T8 fixture teardown: REAL-UNCERTAINTY" 3
  "${W[@]}" barrier --manifest "$m" --state "$STATE" --out "$ED/barrier-after-fixture.json" \
    > /dev/null 2> "$ED/barrier-after-fixture.err" || b2=$?
  if [ "$b2" -eq 0 ]; then cleanup_instance "$m" || cl=$?; else cl=not-run; fi
  ST_TEST=""
  sv T8 FAIL-UNCERTAIN "$cls" \
    "{\"fixtures\": \"ok\", \"second_barrier\": \"$(rcword $b2)\", \"cleanup\": \"$(rcword "$cl")\"}"
}

st_T15() { # a|b|c: injection after the stop began, before SNAP-post (r4 2.6)
  local v=$1
  local T="T15$v"
  ST_TEST=$T; prepare_instance S "$T"; local m=$M rt pg dp="" crc=0 brc=0 sc=0 k=0 cls subs root
  rt=$(mf "$m" runtime); pg=$(mf "$m" pgdata); root=$(mf "$m" root)
  start_epoch "$m" E1 1
  wait_ready "$m" 120 || die HOLD "$T: instance not ready (setup failure)" 3
  client "$m" identity --mode identity || die HOLD "$T: identity (setup failure)" 3
  lock_snap0 "$m"; snap_pre "$m"
  STOP_ATTEMPTED=1
  "${W[@]}" ctl --ctl "$CTL" --cmd stop --timeout 400 > "$ED/stop.json" 2> "$ED/stop.err" || sc=$?
  wait_bounded "$WPID" "$WATCH_EXIT_S" || die HOLD "$T: watcher running at its deadline" 3
  ACTIVE_CTL="" ACTIVE_WPID=""
  [ "$sc" -eq 0 ] && [ "$WAIT_RC" -eq 0 ] || die HOLD "$T: stop status $sc, watcher status $WAIT_RC" 3
  case "$v" in
    a) "${ST[@]}" inject --kind truncate --path "$rt/processes/logs/postgres.stderr.log" > /dev/null
       subs="capture-prefix-changed" ;;
    b) "${ST[@]}" inject --kind rename-over \
         --path "$root/.devenv/state/process-compose/process-compose.log" > /dev/null
       subs="capture-replaced" ;;
    c) st_intent T15c decoy proc
       "${ST[@]}" fixture-sleeper --seconds 600 & dp=$!
       sleep 0.3; st_idproc T15c decoy "$dp"
       "${ST[@]}" inject --kind new-collector --path "$pg/log" > /dev/null
       "${ST[@]}" inject --kind postmaster-pid --path "$pg/postmaster.pid" --pid "$dp" > /dev/null
       subs="postmaster.pid,capture-new-in-window" ;;
  esac
  "${W[@]}" barrier --manifest "$m" --state "$STATE" --out "$ED/barrier.json" 2> "$ED/barrier.err" \
    || brc=$?
  "${W[@]}" snapshot --manifest "$m" --name SNAP-post --out "$ED/SNAP-post" --prev "$ED/SNAP-pre" \
    > /dev/null
  "${W[@]}" classify-epoch --manifest "$m" --epoch-dir "$ED" --state "$STATE" > /dev/null || crc=$?
  cls=$("${ST[@]}" incomplete-class --file "$ED/classification.json" --subs "$subs" \
    | "${W[@]}" jget --file - --key class)
  [ "$crc" -eq 4 ] || cls="$cls-STATUS-$crc"
  if [ -n "$dp" ]; then
    st_kill T15c decoy "$dp" || k=$?
    [ "$k" -eq 0 ] || die HOLD "T15c fixture teardown: REAL-UNCERTAINTY" 3
  fi
  st_retain "$T" "root-$T,runtime-$T"
  ST_TEST=""
  local exp
  case "$v" in
    c) exp="INCOMPLETE:postmaster.pid,INCOMPLETE:capture-new-in-window" ;;
    *) exp="INCOMPLETE:$subs" ;;
  esac
  sv "$T" "$exp" "$cls" \
    "{\"stop\": \"ok\", \"barrier\": \"$(rcword $brc)\", \"fixtures\": \"ok\", \"cleanup\": \"not-applicable:retained by design (H3)\"}" "$m"
}

st_T25() { # H7: the S5 accepting branch end to end on an S instance (plumbing only)
  ST_TEST=T25; prepare_instance S T25; local m=$M cl=0 xc=0
  run_s5 "$m" T25 s_canary_s5 0
  marker_list
  local entries; entries=$(IFS=,; echo "${SNAPS[*]}")
  "${W[@]}" cross-check --entries "$entries" --markers "$EVID/markers-list.json" \
    --out "$SD/T25-cross-check.json" > /dev/null || xc=$?
  [ "$xc" -eq 0 ] || die FAIL "T25 cross-check status $xc" 4
  cleanup_instance "$m" || cl=$?
  ST_TEST=""
  sv T25 PASS PASS "{\"stop_barrier\": \"ok\", \"cleanup\": \"$(rcword $cl)\"}"
}

run_selftest() {
  SD="$EVID/selftest"; mkdir -m 700 "$SD"
  local id rc ids="" r=0
  for id in $SYNTHETIC_IDS; do
    rc=0
    "${ST[@]}" synthetic --dir "$SD" --scratch "$RUNROOT" --runroot "$RUNROOT" --id "$id" \
      > /dev/null 2> "$SD/$id.err" || rc=$?
    [ "$rc" -eq 0 ] || die HOLD "self-test $id did not give its expected verdict (status $rc; see $SD/$id.json)" 3
  done
  ST_TEST=R; prepare_reference; ST_TEST=""
  st_T1; st_T2; st_T3; st_T13; st_T14; st_T19e
  st_T4 a; st_T4 b; st_T5; st_T6; st_T7; st_T8; st_T15 a; st_T15 b; st_T15 c; st_T25
  for id in $SYNTHETIC_IDS $SHELL_IDS $INSTANCE_IDS; do ids="$ids${ids:+,}$id"; done
  "${ST[@]}" summary --dir "$SD" --head "$HEAD" --ids "$ids" > "$EVID/selftest-summary.out" || r=$?
  [ "$r" -eq 0 ] || die HOLD "self-test summary did not pass (see $SD/selftest-summary.json)" 3
  cleanup_instance "$EVID/R/manifest.json"
  note "selftest summary: $SD/selftest-summary.json"
}

case "$MODE" in
  selftest) run_selftest ;;
  discovery) run_discovery ;;
  campaign) run_campaign ;;
esac
