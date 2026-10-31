# Remote model transport (hosted side)

S-B4 and S-B6 source implementation (ADR-0024), not a deployed topology. See
[the Mermaid source](remote-model-transport.mmd).

Under the trusted `:model_transport :remote`, the hosted runtime starts no
local ClaudeCLI tree and never launches a CLI. `ModelProvider.Runtime`
resolves ClaudeCLI to `ClaudeCLI.Remote`, whose `prepare/2` checks the
current binding's worker (`availability/1`: presence, open intake and a
heartbeat at most 60 s old by the server clock; then pins naming exactly
one compiled real profile) and the worst-case launch size before any
reservation. The reservation creates the RemoteModelCall in the same
transaction. The facade then waits, bounded and monotonic, holding no
transaction, lock or connection, woken by audit events or a 5 s poll.

S-B6 offline queueing: before START, `AgentWorker` (run queued, Operation
enqueued) and `ReplyWorker` (run queued) ask `SDR.OfflineGate`, which uses
the same `availability/1`. While the worker is absent, paused or stale
(`last_seen_at` nil, older than 60 s or later than now) the job snoozes
60 s: Oban reschedules the same job with its attempt restored; no run or
Operation transition, reservation, charge or Failure. The wait is
unbounded. Residuals: a disconnect inside the 60 s window still reserves
(charged, then expires at the 120 s claim deadline); a worker going stale
between the gate and `prepare/2` is refused `:provider_offline` before
reservation and the run fails `provider_error`, uncharged. No refunds or
automatic retries. The gate is a lock-free read, never admission
evidence; the claim rechecks under its locks.

The owner's Mac runs `mix sdr.mac_agent` in an ordinary VM and makes only
outbound requests to `/worker/heartbeat`, `/worker/claim` and
`/worker/complete`. `WorkerIntake` admits POST JSON objects up to 13 MiB
before the global parser; `WorkerController` maps the bearer token and
every domain refusal to fixed codes. A paused intake or no live hosted owner
is `200 {"call": null}`; an undeliverable launch is 500 and rolls back.

`RemoteSettler` (every minute, kernel actor with the `:remote_settler`
marker) expires unclaimed and overdue calls and settles completed ones from
the stored transcript through the unchanged ClaudeCLI fold and schema
validation. For a running run, settlement counts the call on the run budget.
For a run already terminal (for example after the caller's wait timed out),
the invocation is finished ledger-only under a private, scope-bound settler
capability: no run, Operation or counter write, the charge stays one, and no
release. Business output reaches the caller only through `ResultGate`.

`Runtime.status/0` under `:remote` reports the singleton tenant's worker
view. It is observational: it can report `effective: Remote` before
`prepare/2`'s freshness and pin checks, and is never admission evidence.

Conditional supervision: the local ProfileSupervisor/server/reaper/shim tree
exists only under `:local`. A production build without prototype authority
refuses remote calls (`:provider_not_running`), has no worker view, no
settler and no terminal-settle path.
