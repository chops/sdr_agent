#!/usr/bin/env bash
# Deploy the SDR Agent hosted test copy to the shared NixOS Hetzner box (ch-web-prod),
# served at https://sdr.a-z.bot. Adapted from agent_builder's scripts/deploy.sh.
#
# sdr_agent is a co-tenant on ch-web-prod: the service listens on 127.0.0.1:4005 only
# (config/runtime.exs, SDR_BIND_IP default) behind Caddy. The NixOS side (systemd unit
# `sdr-agent`, user/group `sdr_agent`, its own PostgreSQL 18 cluster `sdr-agent-postgresql`
# over the socket /run/sdr-agent-postgresql, sops secret file /run/secrets/sdr-agent/env,
# Caddy vhost, DNS) lives in ~/src/nixos-hetzner-infra and must be applied BEFORE the
# first run.
#
# Safety properties kept from agent_builder:
# - this script passes `bash -n` and shellcheck before anything else runs (--dry-run too);
# - the source is `git archive` of a clean, pushed commit, never the working tree, so
#   untracked files cannot be shipped;
# - one deploy at a time (a lock directory on the host), private staging directories;
# - the build uses the build shell's Nix-pinned Elixir, OTP, Hex and rebar3 (never
#   `mix local.hex`/`local.rebar`) with private Mix, Hex and rebar3 homes inside its
#   staging directory, records each tool's identity in the deploy log, refuses a changed
#   mix.lock, and proves root's shared ~/.mix, ~/.hex and rebar3 directories unchanged;
# - each release keeps its own GC root (its build shell), so rollbacks keep their libs;
# - the staged release is checked before the running one is touched: tarball checksum,
#   every ELF file's libraries (fail closed), a root-owned tree the service user can read
#   and run but not change (it writes only under /var/lib/sdr_agent, RELEASE_TMP
#   included), the env file parsed identically by systemd and the shell (all 10 keys
#   present) and matching the reviewed non-secret expectations (key names and ok/FAIL
#   printed, never a value); migrations, the idempotent hosted seed and the follow-up
#   containment check (D-218 item 9) run from the staged release;
# - after the switch it verifies the *running* process: a new MainPID, local health on
#   127.0.0.1:4005 through the proxy headers, and the installed release's REVISION;
# - prune keeps the active release and the newest 3 backups and fails closed.
#
# What a failure restores, exactly:
# - a failure of install, start or local verification (inside `switch`) restores the
#   previous release FILES and verifies the restored process;
# - migrations and the seed run BEFORE the switch and are never undone: restoring
#   release files (automatically, or with --rollback) leaves the database as the new
#   release migrated and seeded it. Pending migrations must suit the previous release;
# - the public health check runs AFTER the switch and the prune: its failure is
#   reported and restores nothing (the new release stays installed and running);
# - /health is endpoint liveness only, not database or sign-in readiness.
#
# Usage:
#   scripts/deploy.sh              # deploy HEAD
#   scripts/deploy.sh --dry-run    # check the source only
#   scripts/deploy.sh --rollback   # restore the newest /opt backup and verify it

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

HOST="${PROD_HOST:-ch-web-prod}"
PUBLIC_HEALTH_URL="${HEALTH_URL:-https://sdr.a-z.bot/health}"
LOCK=/run/lock/sdr-agent-deploy

log() { printf '[%s] %s\n' "$1" "$2"; }
die() { log ERROR "$1"; exit 1; }
# Keepalives: a long, quiet build must not let a middlebox drop the session.
SSH_OPTS=(-o ServerAliveInterval=20 -o ServerAliveCountMax=6 -o BatchMode=yes)
# The remote command is built here, on purpose (SC2029): every expansion is ours.
# shellcheck disable=SC2029
remote() { ssh "${SSH_OPTS[@]}" "root@$HOST" "$@"; }

# This script must parse and pass shellcheck (all severities) before it does anything.
check_script() {
  local self="$SCRIPT_DIR/deploy.sh"
  bash -n "$self" || die "deploy.sh does not parse (bash -n)"
  command -v shellcheck >/dev/null || die "shellcheck is not installed; it must pass before a deploy"
  shellcheck "$self" || die "deploy.sh fails shellcheck"
  log INFO "deploy.sh passes bash -n and shellcheck"
}

# env_semantic_check <env file>: the hosted env file against its reviewed, non-secret
# expectations (Codex I3). Prints key names and ok/FAIL only, never a value; returns 1 on
# any failure. Runs on the host as root (shipped with `declare -f`); bash 3.2 compatible
# and builtins only, so no value reaches another process's arguments. The file is read by
# sourcing it in a subshell, as the systemd/sh equality check does, and only after every
# line is a KEY=value of a known key.
env_semantic_check() {
  (
    file=$1
    fail=0
    n=0
    seen=' '
    required='DATABASE_URL SECRET_KEY_BASE TOKEN_SIGNING_SECRET PHX_HOST POOL_SIZE SDR_ANCHOR_SINKS POSTMARK_API_KEY SDR_MAIL_FROM SDR_LOGIN_ALLOWLIST SDR_OWNER_EMAIL'
    optional='SDR_MODEL_PROVIDER SDR_BIND_IP'
    [ -r "$file" ] || { printf 'env keys: FAIL (file not readable)\n'; exit 1; }

    # 1. Key names: every line blank, a comment, or KEY=value of a known key.
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      case "$line" in '' | '#'*) continue ;; esac
      if [[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]]; then
        name=${BASH_REMATCH[1]}
        case " $required $optional " in
          *" $name "*) seen="$seen$name " ;;
          *) printf 'env keys: FAIL unexpected %s\n' "$name"; fail=2 ;;
        esac
      else
        printf 'env keys: FAIL unparsable line %s\n' "$n"; fail=2
      fi
    done < "$file"
    # Unknown names or lines are never sourced.
    [ "$fail" = 0 ] || exit 1
    for name in $required; do
      case "$seen" in *" $name "*) ;; *) printf 'env keys: FAIL missing %s\n' "$name"; fail=1 ;; esac
    done
    [ "$fail" = 0 ] && printf 'env keys: ok\n'

    # 2. Values, from the file alone (never inherited).
    for name in $required $optional; do unset "$name"; done
    set -a
    # shellcheck disable=SC1090
    . "$file" 2>/dev/null || { printf 'env file: FAIL (sh cannot read it)\n'; exit 1; }
    set +a

    check() {
      local label=$1
      shift
      if "$@"; then printf 'env %s: ok\n' "$label"; else printf 'env %s: FAIL\n' "$label"; fail=1; fi
    }
    # The helpers below run through check (SC2329: invoked indirectly).
    # Exactly one socket_dir query parameter, with the dedicated cluster's directory.
    # shellcheck disable=SC2329
    socket_dir_is() {
      local url=$1 want=$2 rest param found=0
      case "$url" in *'?'*) rest=${url#*\?} ;; *) return 1 ;; esac
      rest=${rest%%#*}
      while [ -n "$rest" ]; do
        param=${rest%%&*}
        if [ "$param" = "$rest" ]; then rest=''; else rest=${rest#*&}; fi
        case "$param" in
          socket_dir=*) found=$((found + 1)); [ "${param#socket_dir=}" = "$want" ] || return 1 ;;
        esac
      done
      [ "$found" = 1 ]
    }
    # At least one entry once spaces and commas are removed.
    # shellcheck disable=SC2329
    non_empty_list() { local v=${1//[[:space:],]/}; [ -n "$v" ]; }
    # Unset, or exactly the one allowed value.
    # shellcheck disable=SC2329
    unset_or() { [ "$1" != set ] || [ "$2" = "$3" ]; }
    # A small pool: 1..20 (the dedicated cluster allows 40 connections in all).
    # shellcheck disable=SC2329
    small_pool() { [[ $1 =~ ^[1-9][0-9]?$ ]] && [ "$1" -le 20 ]; }

    check PHX_HOST test "${PHX_HOST-}" = sdr.a-z.bot
    check SDR_ANCHOR_SINKS test "${SDR_ANCHOR_SINKS-}" = none
    check 'DATABASE_URL socket_dir' socket_dir_is "${DATABASE_URL-}" /run/sdr-agent-postgresql
    check SDR_LOGIN_ALLOWLIST non_empty_list "${SDR_LOGIN_ALLOWLIST-}"
    check SDR_MODEL_PROVIDER unset_or "${SDR_MODEL_PROVIDER+set}" "${SDR_MODEL_PROVIDER-}" fake
    check SDR_BIND_IP unset_or "${SDR_BIND_IP+set}" "${SDR_BIND_IP-}" 127.0.0.1
    check POOL_SIZE small_pool "${POOL_SIZE-}"
    [ "$fail" = 0 ] || exit 1
    printf 'env semantics ok\n'
  )
}

# shared_tooling_fingerprint <home>: one hash over root's shared Mix, Hex and rebar3
# directories (paths, types, sizes, modes, mtimes); an absent directory hashes as absent.
shared_tooling_fingerprint() {
  local d
  for d in "$1/.mix" "$1/.hex" "$1/.cache/rebar3" "$1/.config/rebar3"; do
    if [ -e "$d" ]; then find "$d" -printf '%p %y %s %m %T@\n'; else printf '%s absent\n' "$d"; fi
  done | LC_ALL=C sort | sha256sum | cut -d" " -f1
}

check_source() {
  cd "$PROJECT_ROOT"
  [ -z "$(git status --porcelain --untracked-files=no)" ] || die "tracked changes are uncommitted"
  git fetch -q origin
  REV="$(git rev-parse HEAD)"
  git branch -r --contains "$REV" | grep -q . || die "HEAD $REV is not pushed"
  log INFO "deploying $REV ($(git log -1 --format=%s "$REV"))"
}

acquire_lock() {
  remote "mkdir $LOCK" 2>/dev/null || die "another deploy holds $LOCK on $HOST"
  trap 'remote "rm -rf $LOCK" >/dev/null 2>&1 || true' EXIT
}

build() {
  STAGE="$(remote 'mktemp -d /root/sdr_agent-build.XXXXXXXX')"
  log INFO "shipping $REV to $HOST:$STAGE"
  git -C "$PROJECT_ROOT" archive --format=tar "$REV" | remote "tar -x -C $STAGE"
  remote "echo $REV > $STAGE/REVISION"

  log INFO "building release on $HOST"
  # The fingerprint helper runs on the host, before and after the build.
  SUM="$( { declare -f shared_tooling_fingerprint; /bin/cat <<'BUILDEOF'; } | remote "STAGE=$STAGE REV=$REV bash -s"
    set -euo pipefail
    cd "$STAGE"
    # I2: the build must not touch root's shared Mix/Hex/rebar3 state (other deployments
    # use it); fingerprinted here and compared after the build.
    shared_before="$(shared_tooling_fingerprint "$HOME")"
    # Flakes only see tracked files: stage the archive in a throwaway repo (owned by
    # root, like the build, so no safe.directory exception is needed). `git add -A` is
    # confined to this freshly archived throwaway copy, never a working repository.
    git init -q && git add -A
    # One GC root per release revision: rollback targets keep their libraries.
    mkdir -p /root/.cache/sdr_agent
    # The build shell lives in nix/build-shell.nix (flake.nix is workflow-managed),
    # instantiated with the flake's locked nixpkgs; --impure only for getFlake.
    nix develop --impure --expr "import $STAGE/nix/build-shell.nix { pkgs = (builtins.getFlake \"git+file://$STAGE\").inputs.nixpkgs.legacyPackages.\${builtins.currentSystem}; }" \
      --profile "/root/.cache/sdr_agent/build-shell-${REV:0:12}" --command bash -c '
      set -euo pipefail
      : "${STAGE:?}"
      export MIX_ENV=prod
      # I2: private, per-stage Mix/Hex/rebar3 state, removed with the stage by prune.
      export MIX_HOME="$STAGE/.build-home/mix" HEX_HOME="$STAGE/.build-home/hex"
      export MIX_DEPS_PATH="$STAGE/deps" MIX_BUILD_ROOT="$STAGE/_build"
      export REBAR_CACHE_DIR="$STAGE/.build-home/rebar3-cache"
      export REBAR_GLOBAL_CONFIG_DIR="$STAGE/.build-home/rebar3-config"
      unset MIX_XDG MIX_ARCHIVES MIX_PATH
      mkdir -p "$MIX_HOME" "$HEX_HOME" "$REBAR_CACHE_DIR" "$REBAR_GLOBAL_CONFIG_DIR"
      # Build output goes to stderr (the deploy log); only the checksum is stdout.
      # The Nix-pinned tools only: Hex from the build shell (bp.hex on ERL_LIBS) and
      # rebar3 from MIX_REBAR3 (nix/build-shell.nix); no mix local.hex/local.rebar.
      case "${MIX_REBAR3:-}" in /nix/store/*/bin/rebar3) ;; *) echo "MIX_REBAR3 is not the pinned rebar3" >&2; exit 1 ;; esac
      [ -x "$MIX_REBAR3" ] || { echo "the pinned rebar3 is not executable" >&2; exit 1; }
      hex_dir="$(elixir -e "IO.write(:code.lib_dir(:hex))")"
      case "$hex_dir" in /nix/store/*) ;; *) echo "Hex is not the pinned one" >&2; exit 1 ;; esac
      [ -z "$(ls -A "$MIX_HOME")" ] || { echo "the private MIX_HOME is not empty" >&2; exit 1; }
      echo "tool elixir: $(elixir --version | tail -1) at $(command -v elixir)"
      echo "tool otp: $(erl -noshell -eval "{ok, V} = file:read_file(filename:join([code:root_dir(), \"releases\", erlang:system_info(otp_release), \"OTP_VERSION\"])), io:put_chars(string:trim(V)), halt().") at $(command -v erl)"
      echo "tool hex: $(elixir -e "Application.load(:hex); IO.write(Application.spec(:hex, :vsn))") at $hex_dir"
      echo "tool rebar3: $("$MIX_REBAR3" version) at $MIX_REBAR3"
      lock_before="$(sha256sum mix.lock | cut -d" " -f1)"
      mix deps.get --only prod --check-locked
      [ "$(sha256sum mix.lock | cut -d" " -f1)" = "$lock_before" ] && git diff --quiet -- mix.lock \
        || { echo "mix.lock changed during deps.get" >&2; exit 1; }
      echo "mix.lock sha256 $lock_before unchanged by deps.get"
      # NixOS: patch the downloaded tailwind/esbuild binaries to a real interpreter.
      mix tailwind.install --if-missing
      mix esbuild.install --if-missing
      INTERP="${NIX_CC:+$(cat "$NIX_CC/nix-support/dynamic-linker" 2>/dev/null)}"
      if [ -z "$INTERP" ] || [ ! -f "$INTERP" ]; then
        INTERP="$(nix build --no-link --print-out-paths --inputs-from . nixpkgs#glibc)/lib/ld-linux-x86-64.so.2"
      fi
      # Only dynamically linked binaries have an interpreter to patch (tailwind/Bun);
      # esbuild is static Go. A failed patch of a dynamic binary still stops the build.
      for bin in _build/tailwind-* _build/esbuild-*; do
        [ -f "$bin" ] || continue
        if patchelf --print-interpreter "$bin" >/dev/null 2>&1; then
          patchelf --set-interpreter "$INTERP" "$bin"
        fi
      done
      # The pinned nixpkgs (this flake input), so the library matches the build shell.
      export LD_LIBRARY_PATH="$(nix build --no-link --print-out-paths --inputs-from . nixpkgs#stdenv.cc.cc.lib)/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      mix compile
      mix assets.deploy
      mix release --overwrite
      git diff --quiet -- mix.lock || { echo "mix.lock changed during the build" >&2; exit 1; }
      cp REVISION _build/prod/rel/sdr_agent/REVISION
      tar -C _build/prod/rel -czf "$PWD/release.tar.gz" sdr_agent
    ' >&2
    shared_after="$(shared_tooling_fingerprint "$HOME")"
    [ "$shared_before" = "$shared_after" ] \
      || { echo "the build changed root's shared Mix/Hex/rebar3 directories" >&2; exit 1; }
    echo "root's shared Mix/Hex/rebar3 directories unchanged (fingerprint $shared_after)" >&2
    sha256sum release.tar.gz | cut -d" " -f1
BUILDEOF
)"
  log INFO "release sha256 $SUM"
}

stage_and_check() {
  log INFO "staging and checking the release (running release untouched)"
  remote "STAGE=$STAGE SUM=$SUM bash -s" <<'STAGEEOF'
    set -euo pipefail
    echo "$SUM  $STAGE/release.tar.gz" | sha256sum -c --quiet
    new=/opt/sdr_agent.new
    rm -rf "$new" && mkdir -p "$new"
    tar -xzf "$STAGE/release.tar.gz" -C "$new" --strip-components=1
    find "$new" -type f \( -executable -o -name '*.sh' \) -print0 \
      | xargs -0 grep -l '^#!' 2>/dev/null | while read -r f; do
        sed -i '1s|^#!/nix/store/[^/]*/bin/.*|#!/bin/sh|' "$f"
        sed -i '1s|^#!/usr/bin/env sh$|#!/bin/sh|' "$f"
        sed -i '1s|^#!/usr/bin/env bash$|#!/bin/sh|' "$f"
      done
    # The release tree is root's: the service user reads and runs it but cannot change it
    # (links themselves, never their targets). It writes only under /var/lib/sdr_agent:
    # the unit's RELEASE_TMP (checked below) and its working directory.
    chown -R -h root:root "$new"
    chmod -R u=rwX,go=rX "$new"
    bad="$(find "$new" \( ! -user root -o ! -group root -o \( ! -type l -perm /022 \) \) -print -quit)"
    [ -z "$bad" ] || { echo "release tree: not root-owned or group/other-writable"; exit 1; }
    sudo -u sdr_agent test -x "$new/bin/sdr_agent" -a -r "$new/releases/COOKIE" \
      || { echo "release tree: the service user cannot read or run it"; exit 1; }
    if sudo -u sdr_agent test -w "$new" || sudo -u sdr_agent test -w "$new/bin/sdr_agent" \
      || sudo -u sdr_agent test -w "$new/releases"; then
      echo "release tree: the service user can write it"; exit 1
    fi
    echo "release tree: root:root, readable and runnable by sdr_agent, not writable by it"
    systemctl show -p Environment --value sdr-agent | tr ' ' '\n' \
      | grep -qx 'RELEASE_TMP=/var/lib/sdr_agent/tmp' \
      || { echo "the sdr-agent unit does not set RELEASE_TMP=/var/lib/sdr_agent/tmp"; exit 1; }
    sudo -u sdr_agent test -w /var/lib/sdr_agent \
      || { echo "/var/lib/sdr_agent is not writable by sdr_agent (RELEASE_TMP)"; exit 1; }
    echo "RELEASE_TMP: the unit's /var/lib/sdr_agent/tmp, under the service user's writable home"

    # Every ELF file (ERTS binaries and NIF .so files) must resolve all libraries.
    command -v ldd >/dev/null || { echo "ldd unavailable"; exit 1; }
    n=0
    while IFS= read -r -d '' f; do
      if head -c 4 "$f" | grep -q $'\x7fELF'; then
        out="$(ldd "$f" 2>&1)" || { case "$out" in *"not a dynamic"*) continue ;; *) echo "ldd failed: $f"; exit 1 ;; esac; }
        if grep -q 'not found' <<<"$out"; then echo "missing libraries: $f"; exit 1; fi
        n=$((n + 1))
      fi
    done < <(find "$new" -type f -print0)
    [ "$n" -gt 0 ] || { echo "no ELF files checked"; exit 1; }
    echo "libraries ok for $n ELF files"

    # systemd and the shell must read the secret env file identically (no values shown),
    # the 10 required keys and the two optional ones the semantic check reads.
    required='^(DATABASE_URL|SECRET_KEY_BASE|TOKEN_SIGNING_SECRET|PHX_HOST|POOL_SIZE|SDR_ANCHOR_SINKS|POSTMARK_API_KEY|SDR_MAIL_FROM|SDR_LOGIN_ALLOWLIST|SDR_OWNER_EMAIL)='
    keys='^(DATABASE_URL|SECRET_KEY_BASE|TOKEN_SIGNING_SECRET|PHX_HOST|POOL_SIZE|SDR_ANCHOR_SINKS|POSTMARK_API_KEY|SDR_MAIL_FROM|SDR_LOGIN_ALLOWLIST|SDR_OWNER_EMAIL|SDR_MODEL_PROVIDER|SDR_BIND_IP)='
    # The transient unit gets the system PATH (NixOS has no coreutils in systemd's default).
    a="$(systemd-run --quiet --wait --pipe --collect -p Environment=PATH=/run/current-system/sw/bin \
          -p EnvironmentFile=/run/secrets/sdr-agent/env \
          /bin/sh -c "env | grep -E '$keys' | sort | sha256sum")"
    b="$(env -i PATH="$PATH" sh -c "set -a; . /run/secrets/sdr-agent/env; set +a; env" | grep -E "$keys" | sort | sha256sum)"
    [ "$a" = "$b" ] || { echo "env file parses differently under systemd and sh"; exit 1; }
    [ "$(env -i PATH="$PATH" sh -c "set -a; . /run/secrets/sdr-agent/env; env" | grep -cE "$required")" = 10 ] \
      || { echo "env file is missing keys"; exit 1; }
    echo "env file parses identically under systemd and sh"
STAGEEOF
  # The reviewed non-secret expectations (key names and ok/FAIL only).
  { declare -f env_semantic_check; printf 'env_semantic_check /run/secrets/sdr-agent/env\n'; } \
    | remote 'bash -s' || die "the env file does not match the reviewed expectations; nothing changed"
}

# Runs `bin/sdr_agent eval <expr>` from the staged release as the service user, with
# the service's env file (pseudo-tty, like agent_builder's migrate step).
eval_staged() {
  ssh -tt "${SSH_OPTS[@]}" "root@$HOST" "
    set -a; . /run/secrets/sdr-agent/env; set +a
    cd /var/lib/sdr_agent
    sudo -u sdr_agent -E env RELEASE_TMP=/var/lib/sdr_agent/tmp HOME=/var/lib/sdr_agent \
      /opt/sdr_agent.new/bin/sdr_agent eval '$1'
  "
}

migrate_staged() {
  log INFO "migrating from the staged release (never undone: a later restore of release files leaves the database migrated)"
  eval_staged "SdrAgent.Release.migrate()"
}

# Idempotent: the tenant, exactly one operator (the SDR_OWNER_EMAIL owner; a new one signs
# in by magic link only) and the synthetic demo content with no follow-up step; never the
# fixture operators. An unexpected identity state fails before any content write.
seed_staged() {
  log INFO "seeding the hosted copy from the staged release (idempotent; never undone by a restore)"
  eval_staged "SdrAgent.Release.seed_hosted()"
}

# D-218 item 9: the staged release's follow-up switch is off, no active follow-up step,
# open campaign using one or incomplete follow-up job exists, and the suppressed seed
# contact has no enrollment, draft or delivery. Read-only; a failure stops before the
# switch (the migrations and seed above stay in the database).
containment_staged() {
  log INFO "checking the hosted follow-up containment from the staged release"
  eval_staged "SdrAgent.Release.verify_hosted_containment()" \
    || die "hosted follow-up containment failed; nothing switched (the migrations and seed above remain in the database)"
}

# Verify the running process: a new MainPID, local health on 127.0.0.1:4005 through the
# proxy headers, and the installed release's REVISION. Prints nothing secret.
verify_running() {
  local want="$1" old_pid="$2"
  remote "WANT=$want OLD_PID=$old_pid bash -s" <<'VERIFYEOF'
    set -uo pipefail
    for _ in $(seq 1 45); do
      pid="$(systemctl show -p MainPID --value sdr-agent)"
      if [ "$pid" != 0 ] && [ "$pid" != "$OLD_PID" ] \
        && [ "$(curl -sf --max-time 5 -H 'Host: sdr.a-z.bot' -H 'X-Forwarded-Proto: https' \
             http://127.0.0.1:4005/health)" = ok ]; then
        got="$(cat /opt/sdr_agent/REVISION 2>/dev/null)"
        [ "$got" = "$WANT" ] && { echo "running $got as pid $pid"; exit 0; }
        echo "installed release is $got, expected $WANT"; exit 1
      fi
      sleep 2
    done
    echo "service did not become healthy"; exit 1
VERIFYEOF
}

# One transaction over release FILES: displace the running release (recording exactly
# which backup this deploy created), install the staged one, start and verify it. Every
# step's status is checked explicitly (no reliance on errexit inside conditionals); a
# failure of install, start or local verification restores *this* transaction's backup
# and verifies the restored process. The database is not restored (see the header).
switch() {
  OLD_PID="$(remote 'systemctl show -p MainPID --value sdr-agent')"
  log INFO "switching releases (old pid $OLD_PID)"
  remote 'systemctl stop sdr-agent' || true

  # The single quotes are deliberate (SC2016): the date and $b expand on the host.
  # shellcheck disable=SC2016
  BACKUP="$(remote 'if [ -d /opt/sdr_agent ]; then b="/opt/sdr_agent.backup.$(date +%Y%m%d_%H%M%S)"; mv /opt/sdr_agent "$b" && echo "$b"; fi')" \
    || { remote 'systemctl start sdr-agent' || true; die "could not displace the running release; nothing changed"; }
  PREV_REV=""
  [ -n "$BACKUP" ] && PREV_REV="$(remote "cat $BACKUP/REVISION" || true)"

  if ! remote 'mv /opt/sdr_agent.new /opt/sdr_agent'; then
    recover "install failed"
  elif ! remote 'systemctl start sdr-agent'; then
    recover "start failed"
  elif ! verify_running "$REV" "$OLD_PID"; then
    recover "verification failed"
  else
    log OK "local verification passed"
  fi
}

recover() {
  log ERROR "$1: recovering"
  if [ -z "$BACKUP" ]; then
    remote 'systemctl stop sdr-agent' || true
    die "$1 and there was no previous release to restore; the service is stopped"
  fi
  local failed_pid
  failed_pid="$(remote 'systemctl show -p MainPID --value sdr-agent' || echo 0)"
  if remote "BACKUP=$BACKUP bash -s" <<'RECOVEREOF' && verify_running "$PREV_REV" "$failed_pid"; then
    set -euo pipefail
    systemctl stop sdr-agent || true
    if [ -d /opt/sdr_agent ]; then
      mv /opt/sdr_agent "/opt/sdr_agent.failed.$(date +%Y%m%d_%H%M%S)"
    fi
    mv "$BACKUP" /opt/sdr_agent
    systemctl start sdr-agent
RECOVEREOF
    die "deploy of $REV failed ($1); restored and verified release files of $PREV_REV (the database keeps $REV's migrations and seed)"
  fi
  die "ROLLBACK FAILED after: $1. The service may be down. ssh root@$HOST journalctl -u sdr-agent -e"
}

# Keep the last 3 backups; keep the build-shell GC root of every retained release.
# Fail closed: the active release and every backup must carry a valid 40-hex REVISION
# before anything (old backups or GC roots) is deleted. OPT_ROOT, CACHE_DIR and
# BUILD_PARENT exist only so the prune can be exercised against temp dirs.
prune() {
  remote "OPT_ROOT=${OPT_ROOT:-/opt} CACHE_DIR=${CACHE_DIR:-/root/.cache/sdr_agent} BUILD_PARENT=${BUILD_PARENT:-/root} bash -s" <<'PRUNEEOF'
    set -euo pipefail
    shopt -s nullglob
    # A release's identity: its REVISION must read as exactly one 40-hex commit.
    rev_of() {
      local v
      v="$(cat "$1/REVISION" 2>/dev/null)" || return 1
      [[ "$v" =~ ^[0-9a-f]{40}$ ]] || return 1
      printf '%s' "$v"
    }
    # Validate every release (active and all backups) before deleting anything. A failed
    # or incomplete newest-first listing stops the prune instead of reading as "no backups".
    backups=()
    found=("$OPT_ROOT"/sdr_agent.backup.*)
    if [ "${#found[@]}" -gt 0 ]; then
      listing="$(ls -dt -- "${found[@]}")" || { echo "prune: cannot list backups; nothing deleted"; exit 1; }
      mapfile -t backups <<<"$listing"
      [ "${#backups[@]}" -eq "${#found[@]}" ] ||
        { echo "prune: backup listing incomplete; nothing deleted"; exit 1; }
    fi
    for d in "$OPT_ROOT/sdr_agent" "${backups[@]}"; do
      rev_of "$d" >/dev/null || { echo "prune: $d has no valid REVISION; nothing deleted"; exit 1; }
    done
    # Keep the active release and the newest 3 backups, and the GC roots of exactly those.
    keep=("$(rev_of "$OPT_ROOT/sdr_agent" | cut -c1-12)")
    for d in "${backups[@]:0:3}"; do keep+=("$(rev_of "$d" | cut -c1-12)"); done
    if [ "${#backups[@]}" -gt 3 ]; then rm -rf "${backups[@]:3}"; fi
    for p in "$CACHE_DIR"/build-shell-*; do
      rev="${p##*/build-shell-}"; rev="${rev%%-*}"
      printf '%s\n' "${keep[@]}" | grep -qx "$rev" || rm -f "$p"
    done
    rm -rf "$BUILD_PARENT"/sdr_agent-build.*
PRUNEEOF
}

public_check() {
  for _ in $(seq 1 30); do
    if [ "$(curl -sf --max-time 10 "$PUBLIC_HEALTH_URL")" = ok ]; then
      log OK "public health ok: $PUBLIC_HEALTH_URL"; return 0
    fi
    sleep 2
  done
  die "public health failed (DNS, TLS or Caddy): $PUBLIC_HEALTH_URL; nothing was restored: the new release stays installed after the switch and prune (--rollback restores release files only, not the database)"
}

# Release files only: the database keeps every migration and seed already applied.
rollback_remote() {
  remote 'bash -s' <<'ROLLBACKEOF'
    set -euo pipefail
    prev="$(ls -dt /opt/sdr_agent.backup.* 2>/dev/null | head -1)"
    [ -n "$prev" ] || { echo "no backup to roll back to"; exit 1; }
    systemctl stop sdr-agent || true
    [ -d /opt/sdr_agent ] && mv /opt/sdr_agent "/opt/sdr_agent.failed.$(date +%Y%m%d_%H%M%S)"
    mv "$prev" /opt/sdr_agent
    systemctl start sdr-agent
    echo "restored $(cat /opt/sdr_agent/REVISION)"
ROLLBACKEOF
}

main() {
  case "${1:-}" in
    --dry-run)
      check_script; check_source; log INFO "dry run: no changes" ;;
    --rollback)
      check_script; acquire_lock
      OLD_PID="$(remote 'systemctl show -p MainPID --value sdr-agent')"
      rollback_remote
      verify_running "$(remote 'cat /opt/sdr_agent/REVISION')" "$OLD_PID" \
        || die "rollback did not verify; ssh root@$HOST journalctl -u sdr-agent -e"
      log INFO "rollback restored release files only; the database is unchanged by it"
      public_check ;;
    "")
      check_script; check_source; acquire_lock; build; stage_and_check
      migrate_staged; seed_staged; containment_staged; switch
      # The switch is verified by now; a refused prune keeps every GC root and is reported.
      prune || log ERROR "prune refused (GC roots kept); inspect /opt/sdr_agent*/REVISION"
      # After the switch and prune: a failure here is reported, never restored.
      public_check ;;
    *) die "unknown option $1" ;;
  esac
}

# Sourceable with remote operations stubbed (like agent_builder's scripts/test-deploy.sh).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
