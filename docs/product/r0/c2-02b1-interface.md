# C2-02b1 (#52, slice b1): the admission fence and the drain (draft 1)

**Status:** draft 1, 2026-10-15, for Codex's review. No code. It is
written while slice a (PR #159) is in review, so it counts as preparation
only (`c2-02-slices.md`). It builds on slice a's records as submitted
(`ModelProfileSwitch`, a pending or blocked switch is "open").

**Scope** (`c2-02-slices.md`, row b1):
- the admission fence: committed switch state observed in the reservation
  and launch order, not only an in-memory health check;
- a bounded drain of prepared, reserved, queued and in-flight work. That
  work is finished or refused under the accepted rules, and never moved
  to another profile or grant;
- reserved profile ids stay immutable.

**Safe exit:** the fence closes only while a switch is open. Only
slice a's `request` opens one, and nothing in `lib/` calls it, so
admission stays open in normal use. The drain is a function that nothing
calls before b2.

## The ordering argument (why the chain head is enough)

Every write that can open a switch, and every reservation and launch of a
real-model call, takes the tenant's chain head `FOR UPDATE`:
- **`request`** appends `switch_requested` after taking the head. It
  commits while it still holds the head (slice a: setting → switch →
  chain head);
- **reservation** (`reserve_admitted`) takes the head in step 3 and holds
  it until it commits (`SdrAgent.Agents.Admission`);
- **launch** (`launch_locked`) takes the head last and holds it until the
  row is sent or refused.

So the chain head totally orders a `request` against every reservation
and launch of the same tenant. The fence is a **fresh read of the
tenant's open switch, made after the head is held** (Read Committed: a
statement started after the lock was granted sees every transaction that
committed before it). Then:
- **A reservation or launch ordered after the request** sees the open
  switch and is refused.
- **One ordered before it** committed before the request took the head.
  It is therefore visible to the drain, which starts only after the
  request commits.

No new lock is needed, and no lock is taken in a new order. The setting
row is not locked by reservation or launch.

**Proof obligation (RED):** on independent connections, in both orders:
- a request holds the head while a reservation waits. After the commit,
  the reservation is refused;
- a reservation holds the head while a request waits. After the commit,
  the reservation's row is visible to the drain.

The same two orders are tested for launch.

## The fence

| Where | When | Refusal |
|---|---|---|
| Reservation of a real-profile ClaudeCLI call (`reserve_admitted`) | after `Kernel.lock_head`, before `Admission.admit/5`; the check order becomes: `:no_usage_origin` → admission gate → **fence** → grant checks | `:profile_switch_in_progress`, check `:switch_pending` or `:switch_blocked` |
| Launch (`Admission.launch_check/6`) | after the run status, generation and profile checks, before the admission gate | the same reason and checks; the row moves reserved → failed, never sent, as for every other launch refusal |

- **Recorded like the admission-gate refusals:**
  - reservation: `record_refusal/1`, one deduplicated `provider_error`
    Failure of the run plus `model.reservation.refused`;
  - launch: reserved → failed, one critical `provider_error` Failure plus
    `model.launch.refused`, and the run stops `:model_not_admitted`.
  - **OQ-1** asks whether a fence refusal should stop the run, or leave it
    retryable.
- **What isn't fenced:**
  - the Fake and every non-real-profile path (no grant, no switch);
  - the read paths;
  - settlement of a row that is already `:sent` (`complete`, `fail`,
    `mark_unknown`). In-flight work always settles.
- **The in-memory check stays.** `Runtime.resolve/1` keeps refusing
  `:provider_not_quiescent` while the server's admission is closed. It is
  an early, advisory answer. The database fence is the authority.

## Reserved rows and their profile

- **No change:** a reserved row's `profile_id` is written at reservation
  and never updated. There is no action that rewrites it; RED pins that.
- **During an open switch,** a reserved row of either profile is refused
  at launch by the fence.
- **After `complete`,** a reserved row of the old profile is refused at
  launch by the existing `:profile_mismatch_at_launch`, since the server
  then runs the new profile.
- **After `fail`,** the old profile keeps running and the fence opens, so
  the row launches normally.
- **So reserved work never has to finish before the switch.** It is
  refused or launched by the existing rules. The drain doesn't wait for
  it. The stale-run sweeper still recovers it after `stale_after_seconds`,
  as today.

## The drain

`SdrAgent.Agents.ProfileSwitches.drain(switch, opts)`. It is a function,
not an action: called by b2's coordinator after `request` commits, outside
every transaction.
- **Waits for:**
  - every `:sent` ClaudeCLI invocation of the switch's tenant to settle
    (any profile);
  - the ClaudeCLI server to report no running call and no queued call. A
    queued call reaches launch, where the fence refuses it, so the queue
    empties by refusal.
- **Bounded:** the `timeout:` option. **OQ-2** proposes the server's call
  timeout plus a margin.
  - Polls a count query with no row lock, plus the server's published
    state (ETS, never a `GenServer.call`).
  - Nothing is held under a ledger lock while it waits.
- **Returns:**
  - `{:ok, :drained}`;
  - or `{:error, :drain_timeout, %{sent: n, server: state}}`, which b2
    turns into `block`.
- **The server state.** The server already serves calls one at a time
  (`handle_call` runs the call itself), so queued calls are messages in
  its mailbox. The drain reads:
  - a new published `activity` (`:idle` or `:running`, set around
    `run/4`, in the status table as `admission/1` is);
  - the server's `message_queue_len` (`Process.info/2`, which never
    blocks).

  "Drained" requires no `:sent` row, `:idle`, and an empty mailbox. An
  unrelated message only delays "drained", up to the bound and then
  `block`; it never makes it early.
- **Why late callers are still safe:** a caller whose reservation
  committed before the request can enqueue after "drained". Its launch is
  refused by the fence while the switch is open. After `complete` it is
  refused by `:profile_mismatch_at_launch`. Every queued call also carries
  its enqueue deadline (`:provider_queue_timeout`), as today. **OQ-3**
  asks whether this is enough, or whether the server should count calls
  it has accepted.
- **Caller death:** a caller that dies with its row `:reserved` leaves a
  row the drain ignores (see above). A caller that dies after `:sent`
  leaves the server's own settlement path (`unknown`) to settle it. The
  drain waits for that, within its bound.
- **Server death:** the server state reads `:not_running`, and the `:sent`
  rows are settled `unknown` by the existing paths. If they aren't
  settled within the bound, the drain times out and b2 blocks.

## Entity Model

**Entity Model trigger:** yes, narrowly: a backend action contract.
- reservation and launch gain a refusal reason (`:profile_switch_in_progress`);
- the ClaudeCLI server publishes a new read-only state.

No persisted field, relationship, identity or lifecycle changes, and
there is no new actor authority.

| Entity | New / Existing | Purpose | Attributes | Relationships | Invariants / Lifecycle | Policy/Actor | Open Questions |
|---|---|---|---|---|---|---|---|
| ModelInvocation | Existing (action contract delta) | One model call | unchanged; `profile_id` stays immutable after reservation | unchanged | **reserve:** refused while the tenant has an open switch (read under the chain head). **launch:** reserved → failed with `:profile_switch_in_progress` under the same read. Sent rows settle unchanged | unchanged (`agent_runtime`) | OQ-1 |
| ModelProfileSwitch | Existing (slice a) | — | unchanged | unchanged | Read, not written, by reservation and launch: a fresh tenant read under the chain head (kernel read) | unchanged | none |
| ClaudeCLI server state | Existing (runtime, not persisted) | Published status | adds `activity: :idle \| :running` (`:not_running` when absent), read with the mailbox length | n/a | read-only, never blocks | n/a | OQ-3 |

existing dependency: ModelProfileSetting unchanged — relationship/policy/lifecycle impact checked, none found.

## Tests (RED first)

1. **Ordering, on independent connections** (as the C2-02a race file):
   - request holds the head, then a reservation: the reservation is
     refused;
   - a reservation holds the head, then the request: the reservation's
     row is visible to the drain afterwards;
   - the same two orders for launch.
2. **The fence:**
   - a pending switch and a blocked switch each refuse reservation and
     launch, with the reason and the check;
   - a completed or failed switch doesn't;
   - another tenant's open switch doesn't;
   - the Fake is never fenced;
   - a `:sent` row settles during an open switch.
3. **Recording:**
   - each refusal writes exactly the Failure and the event of its stage,
     and nothing else;
   - a refused reservation leaves no invocation.
4. **Immutability:** no action changes a reserved row's `profile_id`, and
   the profile is unchanged across the switch.
5. **The drain:**
   - it returns drained with no sent row and an idle server;
   - with a sent row it waits, and returns drained once the row settles;
   - with a row that never settles, it times out within the bound;
   - queued calls are refused at launch and the queue empties;
   - caller death after sent, and server death, are each covered;
   - it holds no lock while waiting (`pg_locks` probe, as for C2-02a).
6. **Safe exit:** with no open switch, admission is unchanged. The
   existing admission and launch suites pass unchanged.

## Open questions

- **OQ-1:** should a fence refusal stop the run (as the admission-gate
  refusals do: `provider_error`, run `:model_not_admitted`), or leave it
  retryable?
  - **Recommended:** stop it, as today's gate does. A switch is a rare,
    attended action, and silently queueing SDR work across it would hide
    the switch from the run's record.
- **OQ-2:** the drain bound. **Recommended:** the ClaudeCLI call timeout
  plus 30 s, passed by b2.
- **OQ-3:** the "queued" signal.
  - **Recommended:** the mailbox length plus `activity`, as above. It can
    only delay "drained", and every late launch is refused by the fence or
    the profile check.
  - **The alternative:** a caller-side counter in `complete/2`, which
    needs crash handling for every caller.
