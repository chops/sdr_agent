#!/usr/bin/env bash
# CI216 seed replay (NEVER MERGE): the hermetic gate, but `mix test --seed
# 376743` (run 39801163524) in place of bin/verify, ash.codegen and credo.
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
  echo "::group::mix test --seed 376743 (CI216 replay of run 39801163524)"
  mix test --seed 376743 || status=$?
  echo "::endgroup::"

  pg_ctl -D "$PGDATA" -m fast stop >/dev/null || true
  exit "$status"
' hermetic "$work"
