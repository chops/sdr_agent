#!/usr/bin/env bash
# Deploy the SDR Agent hosted test copy to the shared NixOS Hetzner box (ch-web-prod),
# served at https://sdr.a-z.bot. Adapted from agent_builder's scripts/deploy.sh.
#
# sdr_agent is a co-tenant on ch-web-prod: the service listens on 127.0.0.1:4005 only
# (config/runtime.exs, SDR_BIND_IP default) behind Caddy. The NixOS side (systemd unit
# `sdr-agent`, user/group `sdr_agent`, Postgres co-tenant DB over /run/postgresql, sops
# secret file /run/secrets/sdr-agent/env, Caddy vhost, DNS) lives in
# ~/src/nixos-hetzner-infra and must be applied BEFORE the first run.
#
# Safety properties kept from agent_builder:
# - the source is `git archive` of a clean, pushed commit, never the working tree, so
#   untracked files cannot be shipped;
# - one deploy at a time (a lock directory on the host), private staging directories;
# - each release keeps its own GC root (its build shell), so rollbacks keep their libs;
# - the staged release is checked before the running one is touched: tarball checksum,
#   every ELF file's libraries (fail closed), and the env file parsed identically by
#   systemd and the shell (all 10 keys present, no values shown); migrations (additive)
#   and the idempotent hosted seed run from the staged release;
# - after the switch it verifies the *running* process: a new MainPID, local health on
#   127.0.0.1:4005 through the proxy headers, and the installed release's REVISION; any
#   failure restores the previous release automatically;
# - prune keeps the active release and the newest 3 backups and fails closed.
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
remote() { ssh "${SSH_OPTS[@]}" "root@$HOST" "$@"; }

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
  SUM="$(remote "STAGE=$STAGE REV=$REV bash -s" <<'BUILDEOF'
    set -euo pipefail
    cd "$STAGE"
    # Flakes only see tracked files: stage the archive in a throwaway repo (owned by
    # root, like the build, so no safe.directory exception is needed).
    git init -q && git add -A
    # One GC root per release revision: rollback targets keep their libraries.
    mkdir -p /root/.cache/sdr_agent
    # The build shell lives in nix/build-shell.nix (flake.nix is workflow-managed),
    # instantiated with the flake's locked nixpkgs; --impure only for getFlake.
    nix develop --impure --expr "import $STAGE/nix/build-shell.nix { pkgs = (builtins.getFlake \"git+file://$STAGE\").inputs.nixpkgs.legacyPackages.\${builtins.currentSystem}; }" \
      --profile "/root/.cache/sdr_agent/build-shell-${REV:0:12}" --command bash -c '
      set -euo pipefail
      export MIX_ENV=prod
      # Build output goes to stderr (the deploy log); only the checksum is stdout.
      mix local.hex --force
      mix local.rebar --force
      mix deps.get --only prod
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
      cp REVISION _build/prod/rel/sdr_agent/REVISION
      tar -C _build/prod/rel -czf "$PWD/release.tar.gz" sdr_agent
    ' >&2
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
    chown -R sdr_agent:sdr_agent "$new"

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

    # systemd and the shell must read the secret env file identically (no values shown).
    keys='^(DATABASE_URL|SECRET_KEY_BASE|TOKEN_SIGNING_SECRET|PHX_HOST|POOL_SIZE|SDR_ANCHOR_SINKS|POSTMARK_API_KEY|SDR_MAIL_FROM|SDR_LOGIN_ALLOWLIST|SDR_OWNER_EMAIL)='
    # The transient unit gets the system PATH (NixOS has no coreutils in systemd's default).
    a="$(systemd-run --quiet --wait --pipe --collect -p Environment=PATH=/run/current-system/sw/bin \
          -p EnvironmentFile=/run/secrets/sdr-agent/env \
          /bin/sh -c "env | grep -E '$keys' | sort | sha256sum")"
    b="$(set -a; . /run/secrets/sdr-agent/env; set +a; env | grep -E "$keys" | sort | sha256sum)"
    [ "$a" = "$b" ] || { echo "env file parses differently under systemd and sh"; exit 1; }
    [ "$(env -i PATH="$PATH" sh -c "set -a; . /run/secrets/sdr-agent/env; env" | grep -cE "$keys")" = 10 ] \
      || { echo "env file is missing keys"; exit 1; }
    echo "env file ok"
STAGEEOF
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
  log INFO "migrating from the staged release (migrations are additive)"
  eval_staged "SdrAgent.Release.migrate()"
}

# Idempotent: the tenant, exactly one operator (the SDR_OWNER_EMAIL owner, magic-link
# sign-in only) and the synthetic demo content; never the fixture operators.
seed_staged() {
  log INFO "seeding the hosted copy from the staged release (idempotent)"
  eval_staged "SdrAgent.Release.seed_hosted()"
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

# One transaction: displace the running release (recording exactly which backup this
# deploy created), install the staged one, start and verify it. Every step's status is
# checked explicitly (no reliance on errexit inside conditionals); any failure after
# displacement restores *this* transaction's backup and verifies the restored process.
switch() {
  OLD_PID="$(remote 'systemctl show -p MainPID --value sdr-agent')"
  log INFO "switching releases (old pid $OLD_PID)"
  remote 'systemctl stop sdr-agent' || true

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
    die "deploy of $REV failed ($1); restored and verified $PREV_REV"
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
  die "public health failed (DNS, TLS or Caddy): $PUBLIC_HEALTH_URL"
}

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
      check_source; log INFO "dry run: no changes" ;;
    --rollback)
      acquire_lock
      OLD_PID="$(remote 'systemctl show -p MainPID --value sdr-agent')"
      rollback_remote
      verify_running "$(remote 'cat /opt/sdr_agent/REVISION')" "$OLD_PID" \
        || die "rollback did not verify; ssh root@$HOST journalctl -u sdr-agent -e"
      public_check ;;
    "")
      check_source; acquire_lock; build; stage_and_check; migrate_staged; seed_staged; switch
      # The switch is verified by now; a refused prune keeps every GC root and is reported.
      prune || log ERROR "prune refused (GC roots kept); inspect /opt/sdr_agent*/REVISION"
      public_check ;;
    *) die "unknown option $1" ;;
  esac
}

# Sourceable with remote operations stubbed (like agent_builder's scripts/test-deploy.sh).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
