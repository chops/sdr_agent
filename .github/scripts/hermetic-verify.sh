#!/usr/bin/env bash
# CI gate run inside a network namespace that has only loopback (see ci.yml).
# Proves outbound network is unavailable, starts a throwaway Postgres on
# 127.0.0.1:5520 inside the namespace, then runs the full verification gate.
set -euo pipefail

work="${RUNNER_TEMP:?RUNNER_TEMP must be set}/hermetic"
rm -rf "$work"
mkdir -p "$work"

echo "::group::Prove outbound network is unavailable"
ip -o link show
if ip -o link show | grep -v ': lo:' | grep -q .; then
  echo "unexpected non-loopback interface in namespace" >&2
  exit 1
fi
for target in https://hex.pm https://github.com https://api.telegram.org; do
  if curl -sS --max-time 5 -o /dev/null "$target" 2>/dev/null; then
    echo "outbound request to $target succeeded; network is NOT blocked" >&2
    exit 1
  fi
  echo "blocked: $target"
done
echo "::endgroup::"

# shellcheck disable=SC2016 # expanded inside the dev shell
nix develop --impure -c bash -euo pipefail -c '
  work="$1"
  export PGDATA="$work/pgdata"
  echo "::group::Start throwaway Postgres on 127.0.0.1:5520"
  initdb -U postgres --auth=trust -D "$PGDATA" >/dev/null
  pg_ctl -D "$PGDATA" -l "$work/postgres.log" -w \
    -o "-h 127.0.0.1 -p 5520 -k $work" start
  pg_isready -h 127.0.0.1 -p 5520
  echo "::endgroup::"

  status=0
  echo "::group::bin/verify (workflow receipt, format, compile --warnings-as-errors, mix test)"
  bin/verify || status=$?
  echo "::endgroup::"
  if [ "$status" -eq 0 ]; then
    echo "::group::mix ash.codegen --check"
    mix ash.codegen --check || status=$?
    echo "::endgroup::"
  fi
  if [ "$status" -eq 0 ]; then
    echo "::group::mix credo"
    mix credo || status=$?
    echo "::endgroup::"
  fi

  pg_ctl -D "$PGDATA" -m fast stop >/dev/null || true
  exit "$status"
' hermetic "$work"
