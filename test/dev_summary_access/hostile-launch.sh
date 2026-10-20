# shellcheck shell=bash
# ADR-0016 test helper (sourced): run owner-run.sh through the EXACT launch
# line documented in OWNER-STEPS.md, from a caller shell whose environment
# is hostile (Codex R5-1). Bash only.
#
#   hostile_setup DIR          decoys and sentinel scripts under DIR
#   launch_line OWNER-STEPS    prints the documented `owner_run() { ... }` line
#   hostile_call CALLER LAUNCH R OUT ARGS...
#       CALLER: zsh (the owner's shell, `zsh -f`) or bash (`bash --norc`).
#       Runs `owner_run ARGS...` in that caller, with R set, and with:
#         PATH with decoy bash, env, psql, pg_dump, pg_dumpall, pg_restore
#         and git first; BASH_ENV and ENV startup sentinels; SHELLOPTS=xtrace
#         with a marker PS4 (detected in the output; a command-substitution
#         PS4 would fork without end under xtrace); BASHOPTS, BASH_XTRACEFD, CDPATH, GLOBIGNORE,
#         TMPDIR; exported shell functions (BASH_FUNC_*%%) shadowing the
#         commands and builtins owner-run.sh uses; plus HOSTILE_EXTRA
#         (an array of NAME=VALUE, e.g. PG* aimed at a decoy).
#   sentinels                  every sentinel or decoy that ran ("" = none)

hostile_setup() {
  HL_DIR=$1; HL_SENT="$HL_DIR/sentinels"
  mkdir -p "$HL_DIR/decoy" "$HL_DIR/home"; : > "$HL_SENT"
  printf 'echo "startup file ran in ${0##*/}" >> "%s"\n' "$HL_SENT" > "$HL_DIR/startup.sh"
  local b
  for b in bash env psql pg_dump pg_dumpall pg_restore git sh; do
    printf '#!/bin/sh\necho "decoy %s ran" >> "%s"\nexit 1\n' "$b" "$HL_SENT" > "$HL_DIR/decoy/$b"
  done
  chmod 700 "$HL_DIR"/decoy/*
}
launch_line() { grep -E '^ *owner_run\(\) \{ .* \}$' "$1" | sed 's/^ *//'; }
sentinels() { /bin/cat "$HL_SENT"; }

hostile_call() {
  local caller=$1 launch=$2 r=$3 out=$4 f; shift 4
  local fns=()
  for f in cmp grep sed cut mktemp seq sleep id uname shasum chmod mv cat env git tail sort tr wc find \
           echo printf cd pwd read test command; do
    fns+=("BASH_FUNC_${f}%%=() { builtin echo \"exported function $f ran\" >> \"$HL_SENT\"; builtin command $f \"\$@\"; }")
  done
  local envs=(PATH="$HL_DIR/decoy:/usr/bin:/bin" HOME="$HL_DIR/home" BASH_ENV="$HL_DIR/startup.sh" ENV="$HL_DIR/startup.sh"
              SHELLOPTS=xtrace BASHOPTS=extdebug "PS4=D168-XTRACE-SENTINEL+ " BASH_XTRACEFD=2 CDPATH=/nonexistent GLOBIGNORE='*'
              TMPDIR=/nonexistent/tmp "${fns[@]}" ${HOSTILE_EXTRA[@]+"${HOSTILE_EXTRA[@]}"})
  case "$caller" in
    zsh) /usr/bin/env -i "${envs[@]}" /bin/zsh -f -c 'R=$1; L=$2; shift 2; eval "$L"; owner_run "$@"' zsh "$r" "$launch" "$@" > "$out" 2>&1 ;;
    bash) /usr/bin/env -i "${envs[@]}" BASH_ENV= ENV= SHELLOPTS= /bin/bash --norc --noprofile -c 'R=$1; L=$2; shift 2; eval "$L"; owner_run "$@"' bash "$r" "$launch" "$@" > "$out" 2>&1 ;;
    *) echo "hostile_call: unknown caller $caller" > "$out"; return 99 ;;
  esac
  local rc=$?
  grep -q 'D168-XTRACE-SENTINEL' "$out" && echo "xtrace (SHELLOPTS/PS4) ran" >> "$HL_SENT"
  return $rc
}
