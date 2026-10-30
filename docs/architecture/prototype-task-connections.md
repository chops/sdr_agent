# Prototype task connection ownership

The source is [prototype-task-connections.mmd](prototype-task-connections.mmd).
It distinguishes setup's conditional maintenance helper and test-only fake from
operator entry's parent-owned Repo. Source wiring is distinct from runtime
proof: the diagram promises neither Repo-stop-on-return nor caller-death time
bounds, and it supplies no new real-connection proof.

The maintenance success deadline covers reply and both DOWN observations;
post-expiry grace acknowledges cleanup only. See accepted ADR-0021 for the
caller-death residual and required implementation evidence.

## Terminal launch (ADR-0022)

`sdr.prototype.import` now wires the terminal `TaskBoundary.launch/3`
route. Mix loads `app.config` through the task's requirement, then `run/1`
attaches SafeLog and calls `launch/3`. The body starts OpenTelemetry, parses
argv, enters Session and runs the import guard before any protected input
reader. Only guard success reaches the existing prepare/import/cap/output
APIs. There is no task-owned import transaction, model call or outreach.

`sdr.prototype.setup` also wires that terminal route. After OpenTelemetry
and strict fresh-mode argv parsing, the real setup guard must pass before
the lazy real effects run. Phase 0 checks the pinned cluster identity
before the fixed maintenance reader. Cluster reads are read-only: owned
ancestor/marker/data/control/socket checks, a bounded marker read, and
fixed `id`/`pg_controldata` commands through ChildEnv with captured output.
This is not an allocation bound on captured child output or a child-kill
deadline. The same-UID filesystem race limit remains explicit.

After preflight, RepoState precedes storage. An existing target refuses
fresh setup; it is never adopted or cleaned. Only an absent target reaches
`storage_up`, then `Ecto.Migrator.with_repo` with temporary application
startup and its existing Repo start/reuse cleanup. Inside the callback,
top-level, target, migration and freshness checks precede bootstrap.
Bootstrap commits phase 2 using the validated configured instance UUID.
Phase 3 verifies boot, resolves the operator and invokes Seed at top level.
Seed's write remains a stub: a later refusal leaves the phase-2 binding
**bound, unseeded**, not a fully successful setup. Import does not require
a seed or model grant. No product tree, model call or outreach is started
by setup, and no stop-on-return or caller-death timing promise is added.

The `op` task's `run/1` remains `not_implemented`; other prototype-task launch
wiring remains planned and dashed. Solid import/setup edges denote installed
source, not real provisioning, successful import or imported rows. The measured A1
harness route is separate: it starts OpenTelemetry **before** launch in a fresh
no-start VM. The setup task's OpenTelemetry-after-prelude ordering still
needs its own fresh-terminal proof. Its focused source/parser and
filesystem-refusal checks do not establish a healthy real cluster or setup.

After the admission, attach and entry checks, the outermost call runs
`LaunchPrelude.run/0` once. Its steps run in order and stop at the first
refusal:

1. E checks that the VM is eligible.
2. P1 handles `Mix.PubSub`. If the child's entry is exactly the expected one,
   the step terminates and deletes it. An absent child is skipped.
3. P2 handles `Mix.Sync.PubSub` the same way.
4. P3 handles the `ssl_handler`. If its formatter is the original one, the
   step replaces the formatter only, then re-reads the handler. An absent or
   already normalized handler is skipped.

Any result other than `:ok` aborts at stage `entry`, and nothing an earlier
step did is rolled back. After that the body process adopts the task's entry
token. In the import body, Session entry precedes the containment guard;
the A1 harness instead calls the guard directly in its body.

Measured pins:

- `Mix.PubSub` appears in `Mix.Supervisor` as
  `{Mix.PubSub, pid, :supervisor, [Supervisor]}`. Its child spec has no
  `:modules`, so OTP lists the start module. `Mix.Sync.PubSub` lists
  `[Mix.Sync.PubSub]`. The A1 r1 STOP fixed this in G2 55f3a4c7.
- The tracer callbacks are `-on_start/1-fun-1-` and `-on_end/1-fun-1-` with
  captured env `[[]]`. The S4 d6 diagnostic measured them on all 134 cached
  tracers, and the fix landed in G3 dfc2e05c.

A1 r3 proved the harness route in one fresh no-start VM at G3. Both children
were removed, the handler was normalized, the launch returned `:ok` and the
guard returned `:ok`. It does not prove actual import-task execution, import
or op behaviour, database rows or delivery. Source presence and a shared-VM
entry refusal are not a substitute for the real task's guarded runtime path.
