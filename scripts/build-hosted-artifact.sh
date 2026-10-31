#!/usr/bin/env bash
# Build the INACTIVE hosted_prototype release artifact (ADR-0024) on the build host
# (default ch-web-prod), and report where it is. Derived from the deploy-hosted-final
# scripts/deploy.sh build and check steps (plan r1, Codex scoped PASS).
#
# What it does:
# - refuses unless this script passes `bash -n` and shellcheck;
# - ships `git archive` of a clean, pushed commit (never the working tree);
# - builds with nix/build-shell.nix (the flake's locked nixpkgs: OTP 29, Elixir 1.20,
#   Nix Hex and rebar3), with private Mix/Hex/rebar3 homes inside the stage, a refused
#   mix.lock change and an unchanged metadata fingerprint of root's shared tool dirs;
# - unpacks the tarball into the stage's own check/ directory and checks every ELF
#   file's libraries there;
# - prints the stage path, source revision, tool identities and the tarball sha256.
#
# What it never does: install or replace a release, touch a running service or
# its unit, read a secret or env file, change a database, or start the application.
# The artifact stays inert until the separately reviewed runbook installs it.
# This includes migrations: they are the runbook's step. One build at a time
# (a lock directory); refused while a deploy holds its lock.
#
# Usage:
#   scripts/build-hosted-artifact.sh            # build HEAD (clean and pushed)
#   scripts/build-hosted-artifact.sh --check    # check the script and source only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

HOST="${BUILD_HOST:-ch-web-prod}"
LOCK=/run/lock/sdr-agent-artifact-build
DEPLOY_LOCK=/run/lock/sdr-agent-deploy

log() { printf '[%s] %s\n' "$1" "$2"; }
die() { log ERROR "$1"; exit 1; }
SSH_OPTS=(-o ServerAliveInterval=20 -o ServerAliveCountMax=6 -o BatchMode=yes)
# The remote command is built here, on purpose (SC2029): every expansion is ours.
# shellcheck disable=SC2029
remote() { ssh "${SSH_OPTS[@]}" "root@$HOST" "$@"; }

check_script() {
  local self="$SCRIPT_DIR/build-hosted-artifact.sh"
  bash -n "$self" || die "the build script does not parse (bash -n)"
  command -v shellcheck >/dev/null || die "shellcheck is not installed; it must pass first"
  shellcheck "$self" || die "the build script fails shellcheck"
  log INFO "build script passes bash -n and shellcheck"
}

# shared_tooling_fingerprint <home>: a metadata fingerprint (paths, types, sizes, modes,
# mtimes; not file content) of root's shared Mix, Hex and rebar3 directories.
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
  log INFO "building $REV ($(git log -1 --format=%s "$REV"))"
}

acquire_lock() {
  remote "test ! -e $DEPLOY_LOCK" || die "a deploy holds $DEPLOY_LOCK on $HOST"
  remote "mkdir $LOCK" 2>/dev/null || die "another build holds $LOCK on $HOST"
  trap 'remote "rm -rf $LOCK" >/dev/null 2>&1 || true' EXIT
}

build() {
  STAGE="$(remote 'mktemp -d /root/sdr_agent-build.XXXXXXXX')"
  log INFO "shipping $REV to $HOST:$STAGE"
  git -C "$PROJECT_ROOT" archive --format=tar "$REV" | remote "tar -x -C $STAGE"
  remote "echo $REV > $STAGE/REVISION"

  log INFO "building the hosted_prototype release on $HOST"
  SUM="$( { declare -f shared_tooling_fingerprint; /bin/cat <<'BUILDEOF'; } | remote "STAGE=$STAGE REV=$REV bash -s"
    set -euo pipefail
    cd "$STAGE"
    shared_before="$(shared_tooling_fingerprint "$HOME")"
    # Flakes only see tracked files: a throwaway repo of this freshly archived copy only.
    git init -q && git add -A
    mkdir -p /root/.cache/sdr_agent
    nix develop --impure --expr "import $STAGE/nix/build-shell.nix { pkgs = (builtins.getFlake \"git+file://$STAGE\").inputs.nixpkgs.legacyPackages.\${builtins.currentSystem}; }" \
      --profile "/root/.cache/sdr_agent/hosted-build-shell-${REV:0:12}" --command bash -c '
      set -euo pipefail
      : "${STAGE:?}"
      export MIX_ENV=hosted_prototype
      export MIX_HOME="$STAGE/.build-home/mix" HEX_HOME="$STAGE/.build-home/hex"
      export MIX_DEPS_PATH="$STAGE/deps" MIX_BUILD_ROOT="$STAGE/_build"
      export REBAR_CACHE_DIR="$STAGE/.build-home/rebar3-cache"
      export REBAR_GLOBAL_CONFIG_DIR="$STAGE/.build-home/rebar3-config"
      unset MIX_XDG MIX_ARCHIVES MIX_PATH
      mkdir -p "$MIX_HOME" "$HEX_HOME" "$REBAR_CACHE_DIR" "$REBAR_GLOBAL_CONFIG_DIR"
      case "${MIX_REBAR3:-}" in /nix/store/*/bin/rebar3) ;; *) echo "MIX_REBAR3 is not the pinned rebar3" >&2; exit 1 ;; esac
      [ -x "$MIX_REBAR3" ] || { echo "the pinned rebar3 is not executable" >&2; exit 1; }
      hex_dir="$(elixir -e "IO.write(:code.lib_dir(:hex))")"
      case "$hex_dir" in /nix/store/*) ;; *) echo "Hex is not the pinned one" >&2; exit 1 ;; esac
      [ -z "$(ls -A "$MIX_HOME")" ] || { echo "the private MIX_HOME is not empty" >&2; exit 1; }
      echo "tool elixir: $(elixir --version | tail -1) at $(command -v elixir)"
      echo "tool otp: $(elixir -e "IO.write(File.read!(Path.join([:code.root_dir(), \"releases\", :erlang.system_info(:otp_release), \"OTP_VERSION\"])) |> String.trim())") at $(command -v erl)"
      echo "tool hex: $(elixir -e "Application.load(:hex); IO.write(Application.spec(:hex, :vsn))") at $hex_dir"
      echo "tool rebar3: $("$MIX_REBAR3" version) at $MIX_REBAR3"
      lock_before="$(sha256sum mix.lock | cut -d" " -f1)"
      mix deps.get --only hosted_prototype --check-locked
      [ "$(sha256sum mix.lock | cut -d" " -f1)" = "$lock_before" ] && git diff --quiet -- mix.lock \
        || { echo "mix.lock changed during deps.get" >&2; exit 1; }
      echo "mix.lock sha256 $lock_before unchanged by deps.get"
      # NixOS: patch the downloaded tailwind binary to a real interpreter.
      mix tailwind.install --if-missing
      mix esbuild.install --if-missing
      INTERP="${NIX_CC:+$(cat "$NIX_CC/nix-support/dynamic-linker" 2>/dev/null)}"
      if [ -z "$INTERP" ] || [ ! -f "$INTERP" ]; then
        INTERP="$(nix build --no-link --print-out-paths --inputs-from . nixpkgs#glibc)/lib/ld-linux-x86-64.so.2"
      fi
      for bin in _build/tailwind-* _build/esbuild-*; do
        [ -f "$bin" ] || continue
        if patchelf --print-interpreter "$bin" >/dev/null 2>&1; then
          patchelf --set-interpreter "$INTERP" "$bin"
        fi
      done
      export LD_LIBRARY_PATH="$(nix build --no-link --print-out-paths --inputs-from . nixpkgs#stdenv.cc.cc.lib)/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      mix compile --warnings-as-errors
      mix assets.deploy
      mix release --overwrite
      git diff --quiet -- mix.lock || { echo "mix.lock changed during the build" >&2; exit 1; }
      cp REVISION _build/hosted_prototype/rel/sdr_agent/REVISION
      tar -C _build/hosted_prototype/rel -czf "$PWD/release.tar.gz" sdr_agent
    ' >&2
    shared_after="$(shared_tooling_fingerprint "$HOME")"
    [ "$shared_before" = "$shared_after" ] \
      || { echo "the build changed the metadata of root's shared Mix/Hex/rebar3 directories" >&2; exit 1; }
    echo "root's shared Mix/Hex/rebar3 directories: metadata fingerprint unchanged ($shared_after)" >&2
    sha256sum release.tar.gz | cut -d" " -f1
BUILDEOF
)"
  log INFO "release.tar.gz sha256 $SUM"
}

# The artifact unpacked inside its own stage (check/), never an install path.
check_artifact() {
  remote "STAGE=$STAGE SUM=$SUM REV=$REV bash -s" <<'CHECKEOF'
    set -euo pipefail
    echo "$SUM  $STAGE/release.tar.gz" | sha256sum -c --quiet
    dir="$STAGE/check"
    rm -rf "$dir" && mkdir -p "$dir"
    tar -xzf "$STAGE/release.tar.gz" -C "$dir" --strip-components=1
    [ "$(cat "$dir/REVISION")" = "$REV" ] || { echo "artifact REVISION mismatch"; exit 1; }
    [ -x "$dir/bin/sdr_agent" ] && [ -x "$dir/bin/server" ] \
      || { echo "artifact is missing bin/sdr_agent or bin/server"; exit 1; }
    grep -qx 'export RELEASE_DISTRIBUTION=none' "$dir/releases/"*/env.sh \
      || { echo "artifact env.sh does not disable distribution"; exit 1; }
    command -v ldd >/dev/null || { echo "ldd unavailable"; exit 1; }
    n=0
    while IFS= read -r -d '' f; do
      if head -c 4 "$f" | grep -q $'\x7fELF'; then
        out="$(ldd "$f" 2>&1)" || { case "$out" in *"not a dynamic"*) continue ;; *) echo "ldd failed: $f"; exit 1 ;; esac; }
        if grep -q 'not found' <<<"$out"; then echo "missing libraries: $f"; exit 1; fi
        n=$((n + 1))
      fi
    done < <(find "$dir" -type f -print0)
    [ "$n" -gt 0 ] || { echo "no ELF files checked"; exit 1; }
    echo "libraries ok for $n ELF files"
CHECKEOF
}

main() {
  check_script
  check_source
  if [ "${1:-}" = "--check" ]; then log INFO "check only: nothing built"; exit 0; fi
  acquire_lock
  build
  check_artifact
  log INFO "INACTIVE artifact: $HOST:$STAGE/release.tar.gz sha256 $SUM rev $REV"
}

main "$@"
