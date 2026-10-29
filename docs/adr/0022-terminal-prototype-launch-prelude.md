---
status: accepted
date: 2026-10-29
supersedes: null
---

# ADR-0022: Terminal prototype launch prelude removes VM tooling that the containment guard refuses

## Status

Accepted by the owner on 2026-10-29T22:26:08Z (exact instruction "Approve ADR-0022"), binding the reviewed
draft sha256 `244c357fdc4c47468b45b9133e47cb01315ba4af85ca97b0fa063f55dba581b9`. Independent plan and
entity review: Codex, `0a2891ea`, SCOPED PLAN PASS + ENTITY PASS. Acceptance record sha256
`debf72c2c646454f590708d03afcaae7a2bd79872110885d4147d756235fce00`. Acceptance is not a claim of a working
guard proof, live CLI or import. Related: ADR-0021 (unchanged), D-237 S4 containment guard.

## Context
The S4 containment guard (unchanged) refuses task entry when the VM has a listening socket or a logger handler outside the
kept projection. Measured in a fresh no-start test VM: one listener owned by Mix.Sync.PubSub (a core Mix.Supervisor child in Elixir 1.20.4) holds a
loopback listening socket once any Mix task subscribes (deps.loadpaths), and one standard-stream handler with a non-default id and a foreign
formatter. Its identity is NOT measured; the pinned source candidate is OTP ssl 11.7.4 `ssl_handler` ({ssl_logger, #{}}),
which the prelude verifies exactly before acting. The normalized handler remains a logging sink. Both are tooling, not product behaviour.

## Decision
Prototype Mix tasks enter only through `TaskBoundary.launch/3`, which after the existing input/attach/Repo/snapshot checks and
before the entry token runs a prelude: terminate and delete the fixed Mix.Supervisor children Mix.PubSub and Mix.Sync.PubSub,
and, for the exact-shape `ssl_handler` (pinned OTP ssl 11.7.4), replace only its formatter with the kept
`Logger.default_formatter()` form, preserving destination, filters, level and filter_default. Pinned to Elixir 1.20.4 / kernel 11.0.3; refused under ExUnit or when any product runtime (app, SdrAgent.Supervisor,
Endpoint, model Coordinator) is present; nested launch raises with no inner presentation; fail-closed, no rollback.
`TaskBoundary.run/3` is unchanged. The guard is unchanged; it re-checks when called (token adoption checks nothing).

## Alternatives
- No-Mix boot (release or `elixir -pa` with runtime config): cleanest, larger; deferred.
- Exempt Mix sockets / accept ssl_logger formatter in the guard: rejected (weakens containment).
- Remove `ssl_handler` or stop ssl: rejected (drops a handler / TLS behaviour merely to pass containment).
- `--no-listeners` flags: do not prevent the socket (source).

## Consequences
Depends on private, @moduledoc false Mix internals (pinned; upgrade requires re-review). A launch VM cannot use Mix build
sync and ssl debug logs are formatted by Logger.Formatter (behind SafeLog). Recreation by explicit start is possible and is refused by the guard.
