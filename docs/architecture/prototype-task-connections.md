# Prototype task connection ownership (proposed)

The source is [prototype-task-connections.mmd](prototype-task-connections.mmd).
It distinguishes setup's conditional maintenance helper and test-only fake from
operator entry's parent-owned Repo. It does not claim installed Session startup,
Repo-stop-on-return, caller-death time bounds or a real connection proof.

The maintenance success deadline covers reply and both DOWN observations;
post-expiry grace acknowledges cleanup only. See proposed ADR-0021 for the
caller-death residual and required implementation evidence.

## Terminal launch (ADR-0022)

`TaskBoundary.launch/3` is the terminal entry for prototype Mix tasks. The
product tasks do not use it yet. At G3 dfc2e05c the `op` task's `run/1` is
still `not_implemented` and the import task does not exist, so the diagram
shows that wiring as a dashed, planned edge. The only route measured so far
is the A1 harness. It runs in a fresh no-start VM, attaches SafeLog and calls
`launch/3`.

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
token, and the containment guard runs inside the body.

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
guard returned `:ok`. It does not prove task wiring, import or op behaviour,
database rows or delivery.
