#!/usr/bin/env bash
# 5b sink test orchestrator (plan r2 as amended by r3, r4, r5, r6 and R6-1;
# handoff tmp claude-5b-sink-plan-r{2..6}.md, claude-5b-sink-plan-r6-amendment-R6-1.md),
# repaired per claude-5b-harness-repair-plan.md (35a4926f), its amendment (25092856), A1/A2,
# the ba40b5b dispositions (74d41237) and their binding Q1-Q4.
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
# A1). Long-running observation commands and every self-test run under an independent outer
# controller (run_guarded + sink_watch.py observe-deadline; M1, Q2). The exit path may send
# one stop only after a known FAIL (status 4) with a current clean, unfrozen, kernel-proven
# watcher status (M2); after any HOLD or unknown status nothing is stopped.
#
# Exit: 0 pass; 2 refusal (nothing started); 3 HOLD (uncertainty, retained); 4 FAIL
# (including S5 NOT-EXERCISED).
set -euo pipefail
[ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo "SINK-TEST REFUSE: bash >= 4 required (BASHPID)" >&2; exit 2; }

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
SYNTHETIC_IDS="$SYNTHETIC_IDS T18d-vanish T18d-rebind T19a T19b T19c T19d T19f T19g T19i"
SYNTHETIC_IDS="$SYNTHETIC_IDS T20a T20b T20c T20d T20e T20f T20g T21a T21b T21c T21d T21e"
SYNTHETIC_IDS="$SYNTHETIC_IDS T22a T22b T22c T22d T23a T23b T23c T23d T23e T24 T26a T26b T26c T27"
SHELL_IDS="T1 T2 T3 T13 T14 T19e T19h T26d T28a T28b T28c T29a T29b"
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
outer controller: every self-test and every ready-wait / drain-check / ctl / barrier /
  s5-observe runs gated under observe-deadline (own receipts, own reaps, no signals)
exit path: at most one stop, only after FAIL (4) with a clean unfrozen kernel-proven status
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
GD="$EVID/guard"; mkdir -m 700 "$GD"
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

# ------------------------------------------------------------------ outer controller (M1, Q2)
# run_guarded DEADLINE OUT ERR CMD...: CMD must accept --gate PATH (sink_watch.py and
# sink_selftest.py do, as do the shell subjects below) and does nothing until the gate is
# opened, so its identity is recorded first. Subject and observer intents are registered
# before each spawn and their (pid, birth) identities after; the observer
# (`observe-deadline`) is a separate process with its own receipt and never signals.
# Returns 0 with GUARD_RC = the subject's own reaped status only after the observer's
# receipt says "gone"; otherwise 3 (HOLD): no wait on a live subject, no signal, no
# disposal, and the receipt is retained. "Gone" is not descendant, handle or barrier proof.
GUARD_N=0 GUARD_RC="" GUARD_SP="" GUARD_SB="" GUARD_RECEIPT=""
run_guarded() {
  local dl=$1 out=$2 err=$3 g op
  shift 3
  GUARD_N=$((GUARD_N + 1)); g="g$GUARD_N"
  GUARD_RC="" GUARD_SP="" GUARD_SB="" GUARD_RECEIPT="$GD/$g.observe.json"
  "${ST[@]}" intent --dir "$GD" --test guard --label "$g-subject" --kind proc || return 3
  "$@" --gate "$GD/$g.gate" > "$out" 2> "$err" &
  GUARD_SP=$!
  "${ST[@]}" identity-proc --dir "$GD" --test guard --label "$g-subject" --pid "$GUARD_SP" \
    --ppid "$BASHPID" || return 3
  GUARD_SB=$("${W[@]}" birth --pid "$GUARD_SP") || return 3
  "${ST[@]}" intent --dir "$GD" --test guard --label "$g-observer" --kind proc || return 3
  "${W[@]}" observe-deadline --pid "$GUARD_SP" --birth-us "$GUARD_SB" --deadline "$dl" \
    --out "$GUARD_RECEIPT" > /dev/null 2> "$GD/$g.observer.err" &
  op=$!
  "${ST[@]}" identity-proc --dir "$GD" --test guard --label "$g-observer" --pid "$op" \
    --ppid "$BASHPID" || return 3
  : > "$GD/$g.gate"
  if ! wait_bounded "$op" $((dl + 15)); then
    note "guard $g: observer itself still running: HOLD"
    return 3
  fi
  echo "$WAIT_RC" > "$GD/$g.observer.rc"
  if [ "$WAIT_RC" -ne 0 ] || [ "$(jget "$GUARD_RECEIPT" result)" != gone ]; then
    note "guard $g: subject not proven gone by its ${dl}s deadline (receipt $GUARD_RECEIPT): HOLD"
    return 3
  fi
  wait_bounded "$GUARD_SP" 10 || return 3
  GUARD_RC=$WAIT_RC
  echo "$GUARD_RC" > "$GD/$g.subject.rc"
  return 0
}

# A guarded sink_watch.py command: its own status, or 3 if the guard held.
guarded_w() { # deadline out err W-args...
  local dl=$1 out=$2 err=$3
  shift 3
  run_guarded "$dl" "$out" "$err" "${W[@]}" "$@" || { HOLD_SEEN=1; return 3; }
  return "$GUARD_RC"
}

# Map a W/S/C status to the same class (M2): a HOLD is never re-labelled FAIL.
die_from() { # status label
  case "$1" in
    2) die REFUSE "$2 (status 2)" 2 ;;
    4) die FAIL "$2 (status 4)" 4 ;;
    *) HOLD_SEEN=1; die HOLD "$2 (status $1)" 3 ;;
  esac
}

# Choice 3 as replaced (M2): an exit-path stop only for status 4 with a current, clean,
# unfrozen, kernel-proven watcher status. Pure decision on a status file (T26d).
exit_may_stop() { # rc status-json
  [ "$1" = 4 ] || return 1
  "${ST[@]}" exit-stop-allowed --status "$2" > /dev/null 2>&1
}

# Per-watcher flags: at most one stop request; none after a HOLD.
ACTIVE_CTL="" ACTIVE_WPID="" STOP_ATTEMPTED=0 HOLD_SEEN=0
on_exit() {
  local rc=$? st crc=0
  trap - EXIT
  if [ -n "$ACTIVE_CTL" ]; then
    st="$ACTIVE_CTL.exit-status.json"
    if [ "$rc" = 4 ] && [ "$STOP_ATTEMPTED" = 0 ] && [ "$HOLD_SEEN" = 0 ]; then
      guarded_w 60 "$st" "$ACTIVE_CTL.exit-status.err" ctl --ctl "$ACTIVE_CTL" --cmd status \
        --timeout 30 || crc=$?
    else
      crc=1
    fi
    if [ "$crc" -eq 0 ] && exit_may_stop "$rc" "$st"; then
      STOP_ATTEMPTED=1
      note "FAIL with a clean live watcher: one deliberate stop request (no barrier, no release)"
      if guarded_w 430 "$ACTIVE_CTL.exit-stop.json" "$ACTIVE_CTL.exit-stop.err" ctl \
          --ctl "$ACTIVE_CTL" --cmd stop --timeout 400 \
          && wait_bounded "$ACTIVE_WPID" "$WATCH_EXIT_S" && [ "$WAIT_RC" = 0 ]; then
        note "exit-path stop completed; the instance is retained for disposition"
      else
        note "exit-path stop did not complete: HOLD"
        rc=3
      fi
    else
      note "watcher $ACTIVE_WPID left running for disposition (exit $rc; no automatic stop): HOLD"
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
  reg_intent "root-$2" instance-root
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
    reg_intent "runtime-$inst" instance-runtime
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
  guarded_w $(($2 + 30)) /dev/null "$ED/ready.err" ready-wait --manifest "$1" --state "$STATE" \
    --deadline "$2" --out "$ED/ready.json" || rc=$?
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
  local rc=0
  guarded_w 45 /dev/null "$ED/drain-check.err" drain-check --manifest "$1" --state "$STATE" || rc=$?
  [ "$rc" -eq 0 ] || die_from "$rc" "drain check"
  "${W[@]}" snapshot --manifest "$1" --name SNAP-pre --out "$ED/SNAP-pre" --prev "$ED/SNAP-0" \
    > "$ED/SNAP-pre.violations.json"
}

# One deliberate stop, a bounded watcher exit, then the barrier (repair H2). Returns 0, or
# the first failing status: 3 for a stop/watcher HOLD, else the barrier's own status. A
# failed stop is never retried and no barrier runs while the watcher may still be live.
stop_and_barrier() { # manifest
  local crc=0 brc=0
  STOP_ATTEMPTED=1
  guarded_w 430 "$ED/stop.json" "$ED/stop.err" ctl --ctl "$CTL" --cmd stop --timeout 400 || crc=$?
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
  guarded_w 120 /dev/null "$ED/barrier.err" barrier --manifest "$1" --state "$STATE" \
    --out "$ED/barrier.json" || brc=$?
  echo "$brc" > "$ED/barrier.rc"
  [ "$brc" -eq 0 ] || HOLD_SEEN=1
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
  wait_ready "$m" "${READY_DEADLINE:-120}" || die_from $? "$inst $ep not ready"
  client "$m" prepare --mode prepare --create "$creates" --canary-db "$cdb" \
    || die_from $? "$inst $ep prepare"
  lock_snap0 "$m"
  new_markers "$inst" "$ep"
  client "$m" canaries --mode canaries --db "$cdb" --markers "$MK" || die_from $? "$inst $ep canaries"
  if [ "$adb" != - ]; then
    client "$m" audit --mode audit --db "$adb" --expect "$aexp" || die_from $? "$inst $ep audit"
  fi
  if [ "$kind" = P ] && [ "$ep" = E1 ]; then
    client "$m" audit-load --mode audit --db p_load --expect p_load || die_from $? "P p_load"
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
    wait_ready "$m" 120 || die_from $? "D $ep not ready"
    client "$m" identity --mode identity || die_from $? "D $ep identity"
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
  wait_ready "$ma" 120 || die_from $? "A not ready"
  client "$ma" prepare --mode prepare --create a_ext,a_plain || die_from $? "A prepare"
  client "$ma" a-ext-setup --mode a_ext_setup || die_from $? "A a_ext setup"
  lock_snap0 "$ma"
  client "$ma" audit-ext --mode audit --db a_ext --expect a_ext || die_from $? "A a_ext audit"
  client "$ma" audit-plain --mode audit --db a_plain --expect a_plain || die_from $? "A a_plain audit"
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
  guarded_w 330 /dev/null "$ED/s5.err" s5-observe --manifest "$m" --state "$STATE" --deadline 300 \
    --out "$ED/s5.json" || orc=$?
  [ "$orc" -eq 0 ] || die_from "$orc" "$inst S5 observation (see $ED/s5.err)"
  if [ "$(jget "$ED/s5.json" accepting)" != None ]; then
    note "S5: the server accepted connections; running the full S5 marker epoch"
    PMPID=$(jget "$ED/s5.json" accepting.pid); PMBIRTH=$(jget "$ED/s5.json" accepting.birth_us)
    if [ "$fault" = 0 ]; then
      client "$m" s5-disallowed --mode prepare --create b_canary_s5 --canary-db b_canary_s5 || r=$?
      [ "$r" -eq 2 ] || die FAIL "$inst S5: a B database name on an S instance gave status $r, not 2" 4
    fi
    client "$m" s5-prepare --mode prepare --create "$db" --canary-db "$db" \
      || die_from $? "$inst S5 prepare"
    lock_snap0 "$m"
    new_markers "$inst" S5
    client "$m" s5-canaries --mode canaries --db "$db" --markers "$MK" || die_from $? "$inst S5 canaries"
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

# ------------------------------------------------------------------ selftest (r2 9, r3 7; H3, M3)
# Every test ends in `sv`, which asks sink_selftest.py for the verdict: the observed class
# must equal one of the test's fixed expected classes, the test's exact proof contract must
# be satisfied, and an independent reconciliation must find no unauthorized leftover. Then
# its receipt is re-checked before any later test starts (Q2). Anything other than PASS /
# EXPECTED-REFUSAL stops the suite at once with exit 3 (no later test, no cleanup, no
# summary).
sv() { # test expected(comma list) observed teardown-json [retained manifests, comma list]
  local rc=0
  "${ST[@]}" verdict --dir "$SD" --test "$1" --expected "$2" --observed "$3" --teardown "$4" \
    --runroot "$RUNROOT" --retained-manifests "${5:-}" > "$SD/$1.verdict.out" || rc=$?
  [ "$rc" -eq 0 ] || die HOLD "self-test $1 did not give its expected verdict (status $rc; see $SD/$1.json)" 3
  check_receipt "$1"
}
check_receipt() { "${ST[@]}" check-receipt --dir "$SD" --test "$1" || die HOLD "self-test $1: no passing receipt" 3; }
# R2: before any disposal or cleanup, the observed class must be expected and the proof known
# so far acceptable; otherwise everything is retained and the suite stops.
st_pre() { # test expected observed partial-proof-json
  "${ST[@]}" precheck --dir "$SD" --test "$1" --expected "$2" --observed "$3" --partial "$4" \
    || die HOLD "self-test $1: unexpected result or proof before disposal/cleanup; everything retained (see $SD/$1.json)" 3
}
st_intent() { "${ST[@]}" intent --dir "$SD" --test "$1" --label "$2" --kind "$3" --contents "${4:-}"; }
st_idpath() { "${ST[@]}" identity-path --dir "$SD" --test "$1" --label "$2" --path "$3"; }
st_idproc() { "${ST[@]}" identity-proc --dir "$SD" --test "$1" --label "$2" --pid "$3" --ppid "${4:-$BASHPID}"; }
st_retain() { "${ST[@]}" retain --dir "$SD" --test "$1" --labels "$2" --manifests "${3:-}"; }
st_dispose() { "${ST[@]}" dispose --dir "$SD" --test "$1" --label "$2" > "$SD/$1-$2.dispose.out" 2> "$SD/$1-$2.dispose.err"; }
# R2 residual: a validated disposal that does not succeed is actual teardown uncertainty.
# It HOLDs at once, before any later disposal, cleanup or other effect; the status and the
# disposer's own receipt stay visible and everything is retained. Injectable for T29.
ST_DISPOSE=st_dispose ST_CLEANUP=cleanup_instance
dispose_or_hold() { # test label
  local rc=0
  "$ST_DISPOSE" "$1" "$2" || rc=$?
  [ "$rc" -eq 0 ] || die HOLD "self-test $1: disposal of $2 status $rc (see $SD/$1-$2.dispose.err); everything retained, no cleanup" 3
}
obs() { "${ST[@]}" observed-class --file "$1" | "${W[@]}" jget --file - --key class; }
rcword() { if [ "$1" = 0 ]; then echo ok; else echo "status-$1"; fi; }
gate_wait() { local _i; for _i in $(seq 1 200); do [ -e "$1" ] && return 0; sleep 0.05; done; return 3; }

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
  ST_TEST=T1; new_instance S T1; local m=$M rt rc=0 b a cls cl=0
  rt=$(mf "$m" runtime)
  st_intent T1 rtdir dir ""; mkdir -m 700 "$rt"; st_idpath T1 rtdir "$rt"; b=$($STAT -f '%d:%i' "$rt")
  "${W[@]}" claim-runtime --manifest "$m" > /dev/null 2> "$SD/T1.err" || rc=$?
  a=$($STAT -f '%d:%i' "$rt")
  cls=$(obs "$SD/T1.err"); [ "$rc" -eq 2 ] || cls="$cls-STATUS-$rc"
  { [ "$a" = "$b" ] && [ -z "$(ls -A "$rt")" ]; } || cls="RUNTIME-DIR-CHANGED"
  st_pre T1 REFUSE-RUNTIME-EXISTS "$cls" '{}'
  dispose_or_hold T1 rtdir
  "$ST_CLEANUP" "$m" || cl=$?
  ST_TEST=""
  sv T1 REFUSE-RUNTIME-EXISTS "$cls" "{\"fixtures\": \"ok\", \"cleanup\": \"$(rcword $cl)\"}"
}

st_T2() {
  ST_TEST=T2; new_instance S T2; local m=$M rt rc=0 cls k=0 cl=0
  rt=$(mf "$m" runtime)
  st_intent T2 rtdir dir "pc.sock"; mkdir -m 700 "$rt"; st_idpath T2 rtdir "$rt"
  st_fixture T2 unix-decoy "$rt/pc.sock" fixture-unix-listener --path "$rt/pc.sock"
  "${W[@]}" claim-runtime --manifest "$m" > /dev/null 2> "$SD/T2.err" || rc=$?
  cls=$(obs "$SD/T2.err"); [ "$rc" -eq 2 ] || cls="$cls-STATUS-$rc"
  st_kill T2 unix-decoy "$FX" || k=$?
  [ "$k" -eq 0 ] || die HOLD "T2 fixture teardown: REAL-UNCERTAINTY" 3
  st_pre T2 REFUSE-RUNTIME-EXISTS "$cls" '{}'
  dispose_or_hold T2 rtdir
  "$ST_CLEANUP" "$m" || cl=$?
  ST_TEST=""
  sv T2 REFUSE-RUNTIME-EXISTS "$cls" "{\"fixtures\": \"ok\", \"cleanup\": \"$(rcword $cl)\"}"
}

st_T3() {
  local real="$RUNROOT/t3-real" link="$RUNROOT/t3-link" d755="$RUNROOT/t3-755" repo="$RUNROOT/t3-repo"
  local ca cb cc cls ra=0 rb=0 rc=0
  st_intent T3 real dir ""; mkdir -m 700 "$real"; st_idpath T3 real "$real"
  st_intent T3 link symlink; ln -s "$real" "$link"; st_idpath T3 link "$link"
  st_intent T3 d755 dir ""; mkdir -m 755 "$d755"; st_idpath T3 d755 "$d755"
  st_intent T3 repo dir ".git/**,root"; mkdir -m 700 "$repo"; st_idpath T3 repo "$repo"
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
  st_pre T3 REFUSE-ROOT "$cls" '{}'
  dispose_or_hold T3 link; dispose_or_hold T3 real; dispose_or_hold T3 d755; dispose_or_hold T3 repo
  sv T3 REFUSE-ROOT "$cls" "{\"fixtures\": \"ok\"}"
}

st_T13() {
  ST_TEST=T13; prepare_instance S T13; local m=$M ev cls cl=0 rc=0
  ev=$(mf "$m" evidence)
  "${W[@]}" perturb --manifest "$m" --out "$ev/manifest-attach.json" \
    --set "launch_env.PC_SOCKET_PATH=/tmp/sink-t13-elsewhere.sock" > /dev/null
  "${W[@]}" preflight --manifest "$ev/manifest-attach.json" --first-start > /dev/null 2> "$SD/T13.err" \
    || rc=$?
  cls=$(obs "$SD/T13.err"); [ "$rc" -eq 2 ] || cls="$cls-STATUS-$rc"
  st_pre T13 REFUSE-ENV "$cls" '{}'
  cleanup_instance "$m" || cl=$?
  ST_TEST=""
  sv T13 REFUSE-ENV "$cls" "{\"cleanup\": \"$(rcword $cl)\"}"
}

st_T14() {
  ST_TEST=T14; new_instance S T14; local m=$M other="$RUNROOT/t14-other" ev cls cl=0 rc=0
  ev=$(mf "$m" evidence)
  st_intent T14 other dir ""; mkdir -m 700 "$other"; st_idpath T14 other "$other"
  make_copy "$m"
  build_launcher "$m" "$other" > "$ev/launcher-path"
  "${W[@]}" artifacts --manifest "$m" --launcher "$(< "$ev/launcher-path")" \
    --reference "$EVID/R/artifacts.json" > /dev/null 2> "$SD/T14.err" || rc=$?
  cls=$(obs "$SD/T14.err"); [ "$rc" -eq 2 ] || cls="$cls-STATUS-$rc"
  st_pre T14 REFUSE-PROVENANCE "$cls" '{}'
  dispose_or_hold T14 other
  "$ST_CLEANUP" "$m" || cl=$?
  ST_TEST=""
  sv T14 REFUSE-PROVENANCE "$cls" "{\"fixtures\": \"ok\", \"cleanup\": \"$(rcword $cl)\"}"
}

# T19e (A1): the subject is wait_bounded on its own 8 s fixture with a 2 s deadline; it must
# return HOLD (3) promptly. It runs under the independent outer controller, and the fixture
# is reaped by the subject's own bounded wait; its identity is then checked gone.
t19e_subject() { # --gate PATH
  gate_wait "$2" || exit 3
  local fx sub=0
  st_intent T19e sleeper proc
  "${ST[@]}" fixture-sleeper --seconds 8 & fx=$!
  st_idproc T19e sleeper "$fx" "$BASHPID" || exit 3
  wait_bounded "$fx" 2 || sub=$?
  echo "$sub" > "$SD/T19e.subject.rc"
  "${W[@]}" mono > "$SD/T19e.subject.t"
  wait_bounded "$fx" 20 || exit 3
  echo "$WAIT_RC" > "$SD/T19e.fixture.rc"
  exit 0
}
st_T19e() {
  local t0 g=0 cls sub t1 fxr
  t0=$("${W[@]}" mono)
  run_guarded 40 "$SD/T19e.subject.out" "$SD/T19e.subject.err" t19e_subject || g=$?
  [ "$g" -eq 0 ] && [ "$GUARD_RC" = 0 ] \
    || die HOLD "T19e: the guarded subject did not end cleanly (receipt $GUARD_RECEIPT): REAL-UNCERTAINTY" 3
  sub=$(< "$SD/T19e.subject.rc"); t1=$(< "$SD/T19e.subject.t"); fxr=$(< "$SD/T19e.fixture.rc")
  cls=HOLD-WAIT-BOUNDED
  [ "$sub" = 3 ] || cls="SUBJECT-STATUS-$sub"
  awk -v a="$t1" -v b="$t0" 'BEGIN { exit !(a - b <= 6) }' || cls="SUBJECT-OVERRAN"
  "${ST[@]}" wait-gone --dir "$SD" --test T19e --label sleeper --deadline 1 > /dev/null \
    || die HOLD "T19e: fixture identity still present after its reap: REAL-UNCERTAINTY" 3
  sv T19e HOLD-WAIT-BOUNDED "$cls" "{\"subject_receipt\": \"ok\", \"outer_reap\": \"$(rcword "$fxr")\"}"
}

# T19h (M1, Q2): a stuck subject (an unbounded wait on its own 8 s fixture) under a 2 s
# guard. The observer must return HOLD with a live-at-deadline receipt (retained); then a
# second independent observer proves it gone, the subject is reaped, and the fixture's
# registered identity is checked gone (gone-ness of the subject is not descendant proof).
t19h_subject() { # --gate PATH
  gate_wait "$2" || exit 3
  local sl
  st_intent T19h sleeper proc
  "${ST[@]}" fixture-sleeper --seconds 8 & sl=$!
  st_idproc T19h sleeper "$sl" "$BASHPID" || exit 3
  wait "$sl"
  exit 0
}
st_T19h() {
  local g=0 sp sb op res cls outer
  run_guarded 2 "$SD/T19h.subject.out" "$SD/T19h.subject.err" t19h_subject || g=$?
  sp=$GUARD_SP sb=$GUARD_SB
  res=$(jget "$GUARD_RECEIPT" result)
  cls="GUARD-$g-$res"
  [ "$g" != 3 ] || [ "$res" != live-at-deadline ] || cls=HOLD-SUBJECT-LIVE
  echo "$GUARD_RECEIPT" > "$SD/T19h.retained-receipt"
  "${ST[@]}" intent --dir "$GD" --test T19h --label observer2 --kind proc
  "${W[@]}" observe-deadline --pid "$sp" --birth-us "$sb" --deadline 20 \
    --out "$SD/T19h.observe2.json" > /dev/null 2>&1 &
  op=$!
  "${ST[@]}" identity-proc --dir "$GD" --test T19h --label observer2 --pid "$op" --ppid "$BASHPID"
  wait_bounded "$op" 35 || die HOLD "T19h: the outer observer is still running: REAL-UNCERTAINTY" 3
  [ "$WAIT_RC" -eq 0 ] && [ "$(jget "$SD/T19h.observe2.json" result)" = gone ] \
    || die HOLD "T19h: subject not gone at the outer deadline: REAL-UNCERTAINTY" 3
  wait_bounded "$sp" 10 || die HOLD "T19h: subject not reaped: REAL-UNCERTAINTY" 3
  outer=$WAIT_RC
  "${ST[@]}" wait-gone --dir "$SD" --test T19h --label sleeper --deadline 1 > /dev/null \
    || die HOLD "T19h: descendant fixture still present: REAL-UNCERTAINTY" 3
  sv T19h HOLD-SUBJECT-LIVE "$cls" \
    "{\"observer_receipt\": \"ok\", \"outer_reap\": \"$(rcword "$outer")\", \"descendants\": \"ok\"}"
}

# T26d (M2, choice 3 replaced): the exit-path decision on fabricated status files. Only a
# FAIL (4) with a clean, unfrozen, kernel-proven status may stop; nothing else.
st_T26d() {
  local dir="$SD/T26d" got="" want case rc file
  mkdir -m 700 "$dir"
  printf '%s\n' '{"ok": true, "state": {"signals_frozen": false, "violations": [], "launcher_identity": {"identity": "kernel"}}}' > "$dir/clean.json"
  printf '%s\n' '{"ok": true, "state": {"signals_frozen": true, "violations": [], "launcher_identity": {"identity": "kernel"}}}' > "$dir/frozen.json"
  printf '%s\n' '{"ok": true, "state": {"signals_frozen": false, "violations": [{"kind": "x"}], "launcher_identity": {"identity": "kernel"}}}' > "$dir/violation.json"
  printf '%s\n' '{"ok": true, "state": {"signals_frozen": false, "violations": [], "launcher_identity": {"identity": "unknown"}}}' > "$dir/unknown.json"
  printf '%s\n' '{"ok": false, "state": {"signals_frozen": false, "violations": [], "launcher_identity": {"identity": "kernel"}}}' > "$dir/notok.json"
  for case in 3:clean 1:clean 2:clean 4:frozen 4:violation 4:unknown 4:notok 4:absent 4:clean; do
    rc=${case%%:*} file="$dir/${case#*:}.json"
    if exit_may_stop "$rc" "$file"; then got="$got $case=stop"; else got="$got $case=no"; fi
  done
  want=" 3:clean=no 1:clean=no 2:clean=no 4:frozen=no 4:violation=no 4:unknown=no 4:notok=no 4:absent=no 4:clean=stop"
  local cls="DECISIONS:$got"
  [ "$got" != "$want" ] || cls=DECISIONS-AS-REQUIRED
  sv T26d DECISIONS-AS-REQUIRED "$cls" '{"fixtures": "not-applicable:decision function on fabricated status files"}'
}

st_T4() { # a|b
  local v=$1 addr; [ "$v" = a ] && addr=127.0.0.1 || addr=0.0.0.0
  local T="T4$v"
  ST_TEST=$T; prepare_instance S "$T"; local m=$M port rc=0 sb=0 k=0 acc cls
  port=$(mf "$m" port)
  ED="$(mf "$m" evidence)/E1"; mkdir -m 700 "$ED"
  reg_intent "runtime-$T" instance-runtime
  "${W[@]}" claim-runtime --manifest "$m" > "$ED/claim.json"
  reg_path "runtime-$T" "$(mf "$m" runtime)"
  "${W[@]}" preflight --manifest "$m" --first-start > "$ED/preflight.json"
  st_fixture "$T" tcp-decoy "$SD/$T-count.json" fixture-tcp-decoy --addr "$addr" --port "$port" \
    --count-file "$SD/$T-count.json"
  local dp=$FX
  CTL="$ED/ctl" STATE="$ED/state.json"
  "${W[@]}" supervise --manifest "$m" --ctl "$CTL" --state "$STATE" \
    --launcher "$(< "$(mf "$m" evidence)/launcher-path")" --epoch E1 > "$ED/supervise.out" \
    2> "$ED/supervise.err" &
  WPID=$! ACTIVE_CTL=$CTL ACTIVE_WPID=$WPID STOP_ATTEMPTED=0 HOLD_SEEN=0
  wait_ready "$m" 60 || rc=$?
  cls=$(obs "$ED/ready.err")
  [ "$rc" -ne 0 ] || cls="READY"
  stop_and_barrier "$m" || sb=$?
  st_kill "$T" tcp-decoy "$dp" || k=$?
  [ "$k" -eq 0 ] || die HOLD "$T fixture teardown: REAL-UNCERTAINTY" 3
  acc=$(jget "$SD/$T-count.json" accepts)
  [ "$acc" = 0 ] || cls="DECOY-ACCEPTED-$acc"
  st_retain "$T" "root-$T,runtime-$T" "$m"
  ST_TEST=""
  sv "$T" HOLD-FOREIGN-LISTENER,FAIL-START "$cls" \
    "{\"stop_barrier\": \"$(rcword $sb)\", \"fixtures\": \"ok\", \"cleanup\": \"not-applicable:retained by design (H3)\"}" "$m"
}

# R1: each T5 client's actual exit status and exact receipt are gated before the next
# client or any other effect. Only the specified status-2/halt refusals and the db-exists
# positive pass; anything else HOLDs at once: statuses recorded, everything retained, no
# further client, stop or cleanup (the exit trap never stops after a HOLD).
T5_CLIENT=client T5_STATUS=""
t5_gate() { # case actual-status
  T5_STATUS="$T5_STATUS $1=$2"
  printf '%s\n' "$T5_STATUS" > "$ED/T5-client-status.txt"
  "${ST[@]}" client-gate --file "$ED/client-$CLIENT_N-$1.json" --actual "$2" --case "$1" \
    > "$ED/T5-gate-$1.json" \
    || { HOLD_SEEN=1; die HOLD "T5: client $1 (status $2) did not give its exact expected receipt; retained, no further client, stop or cleanup" 3; }
}
t5_clients() { # manifest evidence-dir
  local r
  r=0; "$T5_CLIENT" "$2/manifest-bad-pgdata.json" bad-pgdata --mode prepare --create s_probe || r=$?
  t5_gate bad-pgdata "$r"
  r=0; "$T5_CLIENT" "$2/manifest-bad-port.json" bad-port --mode prepare --create s_probe || r=$?
  t5_gate bad-port "$r"
  r=0; "$T5_CLIENT" "$1" db-exists --mode db_exists --name s_probe || r=$?
  t5_gate db-exists "$r"
}

st_T5() { # choice 5 / Q4: exact receipts, see sink_selftest.py t5_class / client_gate
  ST_TEST=T5; prepare_instance S T5; local m=$M ev sb=0 cl=0 cls n0
  ev=$(mf "$m" evidence)
  start_epoch "$m" E1 1
  wait_ready "$m" 120 || die HOLD "T5: instance not ready (setup failure)" 3
  "${W[@]}" perturb --manifest "$m" --out "$ev/manifest-bad-pgdata.json" --set "pgdata=/nonexistent/pgdata" > /dev/null
  "${W[@]}" perturb --manifest "$m" --out "$ev/manifest-bad-port.json" --set "port=$(( $(mf "$m" port) + 1 ))" > /dev/null
  T5_STATUS="" n0=$CLIENT_N
  t5_clients "$m" "$ev"
  cls=$("${ST[@]}" t5-class --pgdata "$ED/client-$((n0 + 1))-bad-pgdata.json" \
    --port "$ED/client-$((n0 + 2))-bad-port.json" --exists "$ED/client-$((n0 + 3))-db-exists.json" \
    | "${W[@]}" jget --file - --key class)
  stop_and_barrier "$m" || sb=$?
  st_pre T5 REFUSE-CLIENT-TARGET "$cls" "{\"db_exists_client\": \"ok\", \"stop_barrier\": \"$(rcword $sb)\"}"
  cleanup_instance "$m" || cl=$?
  ST_TEST=""
  sv T5 REFUSE-CLIENT-TARGET "$cls" \
    "{\"db_exists_client\": \"ok\", \"stop_barrier\": \"ok\", \"cleanup\": \"$(rcword "$cl")\"}"
}

# T28 (R1 controls): the T5 gate sequence with a fabricated client in a subshell (its own
# exit; traps are not inherited). a: a client HOLD at the first client; b: a missing
# receipt at the second; c: the paired all-expected sequence. The call log proves which
# later clients and effects ran.
t28_client() { # fabricated client: logs the call, writes the scenario's receipt
  local name=$2 f
  CLIENT_N=$((CLIENT_N + 1)); f="$ED/client-$CLIENT_N-$name.json"
  echo "$name" >> "$ED/calls.log"
  case "$T28_SCENARIO:$name" in
    hold:bad-pgdata) printf '%s\n' '{"status": 3, "halt": "identity query failed"}' > "$f"; return 3 ;;
    noreceipt:bad-port) return 2 ;;
    *:bad-pgdata) printf '%s\n' '{"status": 2, "halt": "identity mismatch: data_directory,config_file"}' > "$f"; return 2 ;;
    *:bad-port) printf '%s\n' '{"status": 2, "halt": "target socket mismatch"}' > "$f"; return 2 ;;
    *:db-exists) printf '%s\n' '{"status": 0, "exists": false}' > "$f"; return 0 ;;
  esac
}
# T29 (R2 residual control): the real dispose_or_hold -> cleanup sequence in a subshell with
# an injected disposer and cleanup. a: an expected functional result whose disposal returns
# 3; cleanup must NOT be called and the evidence must remain. b: the paired successful
# disposal reaches cleanup and the evidence is gone.
t29_dispose() { echo "dispose" >> "$T29_DIR/calls.log"; [ "$T29_SCENARIO" = ok ] || return 3; rm -f "$T29_DIR/evidence"; }
t29_cleanup() { echo "cleanup" >> "$T29_DIR/calls.log"; }
st_T29() { # a|b
  local v=$1 T sc rc=0 calls want wrc ev cls
  T="T29$v"
  T29_DIR="$SD/$T"; mkdir -m 700 "$T29_DIR"; : > "$T29_DIR/calls.log"; : > "$T29_DIR/evidence"
  case "$v" in
    a) sc=fail want="dispose " wrc=3 ev=present ;;
    *) sc=ok want="dispose cleanup " wrc=0 ev=absent ;;
  esac
  ( T29_SCENARIO=$sc; ST_DISPOSE=t29_dispose; ST_CLEANUP=t29_cleanup
    dispose_or_hold "$T" evidence; "$ST_CLEANUP" /fabricated ) > "$T29_DIR/sub.out" 2> "$T29_DIR/sub.err" || rc=$?
  calls=$(tr '\n' ' ' < "$T29_DIR/calls.log")
  local now=absent; [ ! -e "$T29_DIR/evidence" ] || now=present
  cls="CALLS:${calls}RC:$rc:EVIDENCE:$now"
  [ "$calls" != "$want" ] || [ "$rc" != "$wrc" ] || [ "$now" != "$ev" ] || cls=DISPOSAL-GATE-AS-REQUIRED
  sv "$T" DISPOSAL-GATE-AS-REQUIRED "$cls" '{"fixtures": "not-applicable:fabricated disposer and cleanup"}'
}

st_T28() { # a|b|c
  local v=$1 T sc rc=0 calls want wrc cls
  T="T28$v"
  ED="$SD/$T"; mkdir -m 700 "$ED"; : > "$ED/calls.log"
  case "$v" in
    a) sc=hold want="bad-pgdata " wrc=3 ;;
    b) sc=noreceipt want="bad-pgdata bad-port " wrc=3 ;;
    *) sc=good want="bad-pgdata bad-port db-exists after-effects " wrc=0 ;;
  esac
  ( T28_SCENARIO=$sc; T5_CLIENT=t28_client; T5_STATUS=""; t5_clients /fabricated "$ED"
    echo after-effects >> "$ED/calls.log" ) > "$ED/sub.out" 2> "$ED/sub.err" || rc=$?
  calls=$(tr '\n' ' ' < "$ED/calls.log")
  cls="CALLS:${calls}RC:$rc"
  [ "$calls" != "$want" ] || [ "$rc" != "$wrc" ] || cls=GATE-AS-REQUIRED
  sv "$T" GATE-AS-REQUIRED "$cls" '{"fixtures": "not-applicable:fabricated client receipts"}'
}

st_T6() {
  ST_TEST=T6; prepare_instance S-T6 T6; local m=$M rc=0 sb=0 cls
  start_epoch "$m" E1 1
  wait_ready "$m" 60 || rc=$?
  cls=$(obs "$ED/ready.err"); [ "$rc" -ne 0 ] || cls=READY
  stop_and_barrier "$m" || sb=$?
  st_retain T6 "root-T6,runtime-T6" "$m"
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
  st_retain T7 "root-T7,runtime-T7,standby-signal" "$m"
  ST_TEST=""
  sv T7 FAIL-TIMEOUT "$cls" \
    "{\"stop_barrier\": \"$(rcword $sb)\", \"fixtures\": \"ok\", \"cleanup\": \"not-applicable:retained by design (H3)\"}" "$m"
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
  guarded_w 120 /dev/null "$ED/barrier-after-fixture.err" barrier --manifest "$m" --state "$STATE" \
    --out "$ED/barrier-after-fixture.json" || b2=$?
  st_pre T8 FAIL-UNCERTAIN "$cls" "{\"fixtures\": \"ok\", \"second_barrier\": \"$(rcword $b2)\"}"
  cleanup_instance "$m" || cl=$?
  ST_TEST=""
  sv T8 FAIL-UNCERTAIN "$cls" \
    "{\"fixtures\": \"ok\", \"second_barrier\": \"$(rcword $b2)\", \"cleanup\": \"$(rcword "$cl")\"}"
}

st_T15() { # a|b|c: injection after the stop began, before SNAP-post (r4 2.6)
  local v=$1
  local T="T15$v"
  ST_TEST=$T; prepare_instance S "$T"; local m=$M rt pg dp="" crc=0 brc=0 sc=0 k=0 cls subs root fxw=ok
  rt=$(mf "$m" runtime); pg=$(mf "$m" pgdata); root=$(mf "$m" root)
  start_epoch "$m" E1 1
  wait_ready "$m" 120 || die HOLD "$T: instance not ready (setup failure)" 3
  client "$m" identity --mode identity || die HOLD "$T: identity (setup failure)" 3
  lock_snap0 "$m"; snap_pre "$m"
  STOP_ATTEMPTED=1
  guarded_w 430 "$ED/stop.json" "$ED/stop.err" ctl --ctl "$CTL" --cmd stop --timeout 400 || sc=$?
  wait_bounded "$WPID" "$WATCH_EXIT_S" || die HOLD "$T: watcher running at its deadline" 3
  ACTIVE_CTL="" ACTIVE_WPID=""
  { [ "$sc" -eq 0 ] && [ "$WAIT_RC" -eq 0 ]; } || die HOLD "$T: stop status $sc, watcher status $WAIT_RC" 3
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
  guarded_w 120 /dev/null "$ED/barrier.err" barrier --manifest "$m" --state "$STATE" \
    --out "$ED/barrier.json" || brc=$?
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
  st_retain "$T" "root-$T,runtime-$T" "$m"
  ST_TEST=""
  local exp td
  td="\"stop\": \"ok\", \"barrier\": \"$(rcword $brc)\", \"cleanup\": \"not-applicable:retained by design (H3)\""
  case "$v" in
    c) exp="INCOMPLETE:postmaster.pid,INCOMPLETE:capture-new-in-window"
       td="$td, \"fixtures\": \"$fxw\"" ;;
    *) exp="INCOMPLETE:$subs" ;;
  esac
  sv "$T" "$exp" "$cls" "{$td}" "$m"
}

st_T25() { # H7: the S5 accepting branch end to end on an S instance (plumbing only)
  ST_TEST=T25; prepare_instance S T25; local m=$M cl=0 xc=0
  run_s5 "$m" T25 s_canary_s5 0
  marker_list
  local entries; entries=$(IFS=,; echo "${SNAPS[*]}")
  "${W[@]}" cross-check --entries "$entries" --markers "$EVID/markers-list.json" \
    --out "$SD/T25-cross-check.json" > /dev/null || xc=$?
  [ "$xc" -eq 0 ] || die FAIL "T25 cross-check status $xc" 4
  st_pre T25 PASS PASS '{"stop_barrier": "ok"}'
  cleanup_instance "$m" || cl=$?
  ST_TEST=""
  sv T25 PASS PASS "{\"stop_barrier\": \"ok\", \"cleanup\": \"$(rcword $cl)\"}"
}

run_selftest() {
  SD="$EVID/selftest"; mkdir -m 700 "$SD"
  local id dl ids="" r=0 g
  for id in $SYNTHETIC_IDS; do
    case "$id" in T16|T18*) dl=180 ;; *) dl=120 ;; esac
    g=0
    run_guarded "$dl" /dev/null "$SD/$id.err" "${ST[@]}" synthetic --dir "$SD" --scratch "$RUNROOT" \
      --runroot "$RUNROOT" --id "$id" || g=$?
    [ "$g" -eq 0 ] || die HOLD "self-test $id: guarded run held (receipt $GUARD_RECEIPT)" 3
    [ "$GUARD_RC" = 0 ] \
      || die HOLD "self-test $id did not give its expected verdict (status $GUARD_RC; see $SD/$id.json)" 3
    check_receipt "$id"
  done
  ST_TEST=R; prepare_reference; ST_TEST=""
  st_T1; st_T2; st_T3; st_T13; st_T14; st_T19e; st_T19h; st_T26d; st_T28 a; st_T28 b; st_T28 c; st_T29 a; st_T29 b
  st_T4 a; st_T4 b; st_T5; st_T6; st_T7; st_T8; st_T15 a; st_T15 b; st_T15 c; st_T25
  for id in $SYNTHETIC_IDS $SHELL_IDS $INSTANCE_IDS; do ids="$ids${ids:+,}$id"; done
  "${ST[@]}" summary --dir "$SD" --head "$HEAD" --ids "$ids" --runroot "$RUNROOT" \
    > "$EVID/selftest-summary.out" || r=$?
  [ "$r" -eq 0 ] || die HOLD "self-test summary or final audit did not pass (see $SD/selftest-summary.json)" 3
  cleanup_instance "$EVID/R/manifest.json"
  note "selftest summary: $SD/selftest-summary.json"
}

case "$MODE" in
  selftest) run_selftest ;;
  discovery) run_discovery ;;
  campaign) run_campaign ;;
esac
