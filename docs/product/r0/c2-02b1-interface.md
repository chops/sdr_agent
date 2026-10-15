# C2-02b1 (#52, slice b1): the admission fence and the drain (draft 2)

**Status:** draft 2, 2026-10-15, for Codex's recheck. No code.
- **Draft 1** (`90d622c`) was NEEDS-REVIEW (Codex, 1fd883a5). The
  chain-head ordering was accepted. There were three gaps:
  - reserved and prepared work, and an ABA gap;
  - samples are not a quiescence or cleanup proof;
  - the refusal consumers and the drain authority.
- **This draft:**
  - closes the ABA gap with a chain-sequence epoch;
  - keeps the accepted bounded finish-or-refuse contract (no acceptance
    change);
  - makes "drained" a ledger fact, with an explicit handoff to b2;
  - maps the reason through every consumer.

It builds on slice a as approved (`2590693`, PR #159).

**Scope** (`c2-02-slices.md`, row b1):
- the admission fence: committed switch state observed in the
  reservation and launch order;
- a bounded drain of prepared, reserved, queued and in-flight work. That
  work is finished or refused, and never moved to another profile or
  grant, nor refunded;
- reserved profile ids stay immutable.

**Safe exit:** nothing in `lib/` opens a switch (slice a), so the fence
never closes in normal use, and the drain has no caller before b2. With
no switch ever requested, the epoch rule below refuses nothing.

## The ordering (accepted in draft 1)

- **Who takes the head:**
  - `request` takes the tenant's chain head `FOR UPDATE` and commits
    holding it;
  - reservation (`reserve_admitted`, step 3) and launch (`launch_locked`,
    last) each take the same head and hold it to commit.
- **So the head totally orders them.** Each fence read is a new, ordinary,
  non-locking statement, in the same Read Committed transaction, issued
  after `Kernel.lock_head/1` returns. There is no earlier cached
  observation and no snapshot isolation.
- **The reader never locks the switch row while holding the head.** That
  would reverse `request`'s setting → switch → head order.
- **A rolled-back request** leaves no switch row and no event, so it
  leaves no fence.
- **The chain sequence materializes the order.** A request's
  `model.profile.switch_requested` event and a reservation's
  `model.invocation.reserved` event each get the tenant's next sequence
  under the same head. So "this reservation is older than that switch" is
  exactly "its reserved event has the lower sequence".

## The fence rules

The reason is `:profile_switch_fenced`. Its checks:
- **`:switch_pending` / `:switch_blocked`:** the tenant has an open
  switch;
- **`:reserved_before_switch`:** at launch, the invocation's
  `model.invocation.reserved` event has a lower sequence than some
  `model.profile.switch_requested` event of the tenant, whatever that
  switch's outcome.

The second check is the **epoch rule**, and it closes the ABA gap:
- the case is reserve Opus, then switch to Sonnet, then switch back to
  Opus, then a delayed launch. Profile equality alone would admit it;
- an invocation may be sent only if no switch was requested after it was
  reserved;
- so a reservation never outlives a switch request. It is refused at
  launch, or earlier by the drain.

| Stage | Exact placement | Checks |
|---|---|---|
| Reservation | inside `Admission.admit/5`, which already runs after `Kernel.lock_head/1`: after `:no_usage_origin` and the admission gate (`Gate`), before grant eligibility | `:switch_pending`, `:switch_blocked` |
| Launch | inside `Admission.launch_check/6`, after the run-status, generation and profile checks, the exemption check and `Gate.admit_launch`, before `launch_binding`/`launch_terms` | `:switch_pending`, `:switch_blocked`, then `:reserved_before_switch` |

- **Unchanged:** the budget and run checks before admission
  (`reserve_model_call`, the daily limit), and the calibration identity
  and exemption safeguards. The fence only adds a refusal.
- **Not fenced:**
  - the Fake and non-real profiles;
  - reads;
  - settlement of a `:sent` row.
- **The in-memory check stays.** `Runtime.resolve/1`'s
  `:provider_not_quiescent` is advisory; the database fence is the
  authority.

## Recording the refusal: every consumer (MF3)

A fence refusal reuses the existing admission-gate stop contract
end-to-end. There is no new status, enum or column.

| Consumer | Change |
|---|---|
| `Admission` | **New `fence_reasons/0`** = `[:profile_switch_fenced]`. **`admission_reason?/1`:** true for `Gate.reasons()` and `fence_reasons()`, so `failure_class/1` gives `:provider_error` (not `:budget_exhausted`). **`reason_name/1`:** `"profile_switch_fenced"`. **Reservation:** the transaction rolls back, then `record_refusal/1` commits one deduplicated `provider_error` Failure of the run plus `model.reservation.refused` (`reason`, `check`, `failure_id`, the request's `idempotency_key`). The receipt is `%Refused{stage: :reservation, reason: :profile_switch_fenced, check, failure_id, event_id, agent_run_id, request_id}` |
| Launch (`Agents.admit_launch/3`, `refuse_launch`) | reserved → failed, never sent, with `error = %{"kind" => "launch_refused", "reason" => "profile_switch_fenced", ...}`, plus one critical `provider_error` Failure of the run and `model.launch.refused`, in one transaction. The receipt is `%Refused{stage: :launch, ...}`, as for every launch refusal |
| `SDR.Model.stop_reason/1` | **Launch:** `:model_not_admitted` (unchanged). **Reservation:** `:model_not_admitted`, through `admission_reason?/1`. No new branch |
| `Changes.LinkRefusalAttention` | `"profile_switch_fenced"` joins both the reservation-admission list (`@admission`) and the launch list (`@launch`). So the run stops `failed`/`:model_not_admitted` linking exactly that Failure, even if an admin resolved it meanwhile. There is no second live attention item, and the worker and Operation rules are unchanged |
| Operations.Failure | class `provider_error`, detail reason `profile_switch_fenced`. Unchanged schema |
| AuditEvent | `model.reservation.refused` and `model.launch.refused` gain the reason and checks above. They are read (not written) for the epoch rule: the invocation's `model.invocation.reserved` and the tenant's `model.profile.switch_requested` sequences, by kernel read, in the admission path only |

**OQ-1 (resolved):** a fence refusal stops the run (`failed`,
`:model_not_admitted`), as Codex recommended. b1 adds no retry mechanism.

## The drain (MF1, MF2)

### Authority and inputs

`SdrAgent.Agents.drain_profile_switch(switch, %{server_generation, timeout_ms}, opts)`
- **Actor:** `agent_runtime` of the switch's tenant. That is the ledger
  actor that already admits launches, fails invocations and stops runs.
  No new authority is granted, and `model_runtime` gets no invocation or
  history read. Any other actor is `Forbidden`.
- **Validation,** before anything else, by a kernel read of the stored
  switch: the actor's tenant, `status == :pending`, and `server_generation`
  equal to the input. Otherwise `{:error, :switch_not_open}` or
  `{:error, :stale_server_generation}`. Nothing is written and nothing is
  waited for.
- **`timeout_ms`:** a positive integer, required, with no default in b1.
  **OQ-2 (resolved):** b2 passes the CLI call timeout + 30 s.
  - It is one end-to-end monotonic deadline, never reset on progress or
    on a server change.
  - Every wait and query is capped by the remaining budget.
- **Results are counts only.** No rows are returned.

### Steps

1. **Refuse every reserved row (bounded finish-or-refuse; no acceptance
   change).**
   - While the switch is open, every `:reserved` real-profile ClaudeCLI
     row of the tenant is pre-fence: the fence refuses reservations after
     the request.
   - Each one is refused in its own transaction through the launch
     refusal path, with launch's lock order (run → Operation share →
     invocation → charge → head):
     - reason `:profile_switch_fenced`, check `:reserved_before_switch`,
       recorded exactly as a launch refusal (above);
     - the run is then stopped `failed`/`:model_not_admitted`, linking
       that Failure, in the same transaction;
     - a run that is no longer `:running` gets the existing
       `:run_not_running_at_launch` treatment instead: the row is failed,
       with no Failure.
   - **If a live caller is launching that row at the same moment,** the
     invocation lock serializes the two:
     - launch first: launch, under the head, refuses it by the fence;
     - drain first: the row is no longer reserved, so the caller's launch
       gets the existing `:invocation_not_reserved` identity refusal.

     Either way it is never sent.
   - **Dead callers and queued calls** are refused the same way. A queued
     call's row is still `:reserved` until the server dequeues it, so it
     is refused here. When the server reaches it, launch refuses it as
     not reserved.
   - **Nothing is rewritten or refunded:** not the reserved profile, not
     the grant or allocation, not the charge.
2. **Wait for every `:sent` ClaudeCLI row of the tenant to settle**
   (completed, failed or unknown).
   - This polls a count query with no row lock. Nothing is held under a
     ledger lock while waiting.
   - **A caller that dies after `:sent`:** its row is settled by its own
     facade path, if that is still running, or else only by the stale-run
     recovery (`stale_after_seconds`, 1800 s by default). That is longer
     than the drain's bound, so the drain times out, and b2 blocks.
   - **A server that dies:** its `:sent` rows behave the same way.
3. **Prepared callers** (health check passed, not reserved) need nothing:
   their reservation is refused by the fence.

### Result

- **`{:ok, %{refused: n}}`:** after step 1, no `:reserved` real-profile
  row of the tenant remains, and after step 2 none is `:sent`. Both are
  read in one final count query.
- **`{:error, :drain_timeout, %{reserved: n, sent: n}}`:** the deadline
  passed.
- **`{:error, :drain_observation_failed}`:** any query error. It fails
  closed.
- **Either error leaves the fence closed.** Nothing is unlocked or
  refunded.

### What "drained" means, and the b2 handoff (MF2)

**"Drained" is a ledger fact:**
- no admitted real-model spend of the tenant is outstanding;
- none can start while the switch is open (the fence);
- no row reserved before the switch can ever be sent (the epoch rule).

**It is not a quiescence or cleanup proof:**
- a settled or `unknown` row doesn't prove its CLI process tree stopped;
- the server can keep stuck or unconfirmed work, with admission blocked;
- b1 reads no server state.

b1 therefore adds no server activity signal. Mailbox length and an
activity flag would be advisory telemetry at best (Codex OQ-3), and b1
makes no claim from them.

**b2 must, outside every ledger lock, before it stops, activates, rolls
back or reopens anything:**
- bind the exact server instance (pid) of the switch's generation;
- read that server's own cleanup state (no stuck or unconfirmed work) and
  the Reaper lease;
- treat absence, a replaced pid, an unavailable or malformed observation,
  or a read error as **not clean**, which means `block`.

A `{:ok, _}` drain is necessary for b2's `complete` or `fail`, never
sufficient. This handoff is b2's contract, recorded here so it isn't
implicit.

## Entity Model

**Entity Model trigger:** yes. The changes are:
- backend action contracts: the reservation and launch refusal, the drain
  function and its authority;
- event-consumer contracts: Failure class, run stop and attention link.

No persisted field, relationship, identity or lifecycle state is added.

| Entity | New / Existing | Purpose | Attributes | Relationships | Invariants / Lifecycle | Policy/Actor | Open Questions |
|---|---|---|---|---|---|---|---|
| ModelInvocation | Existing (action contract delta) | One model call | unchanged; `profile_id`, grant and allocation are immutable after reservation; charges are never refunded | unchanged | **reserve:** refused (`:profile_switch_fenced`, `:switch_pending`/`:switch_blocked`) while the tenant has an open switch, read after the head. **launch:** the same checks, then `:reserved_before_switch` (the epoch rule: its reserved event's sequence is lower than a `switch_requested` event's); reserved → failed, never sent. **drain:** every reserved row of the tenant → failed through the launch refusal path. Sent rows settle unchanged | unchanged: `agent_runtime` (the drain runs as `agent_runtime`) | none |
| AgentRun | Existing (action-cause delta) | One agent run | unchanged | unchanged | `:fail` with `:model_not_admitted` accepts a `profile_switch_fenced` refusal Failure as its cause, at either stage, through `LinkRefusalAttention`'s lists. It links the same Failure even when resolved; no second attention item | unchanged (`agent_runtime`) | none |
| Operations.Failure | Existing (recording delta) | Operator attention | unchanged | unchanged | a fence refusal opens one `provider_error` Failure with detail reason `profile_switch_fenced`: deduplicated per run at reservation; one per refused row at launch or drain | unchanged | none |
| AuditEvent | Existing (event-contract delta) | Ledger | unchanged | unchanged | `model.reservation.refused` and `model.launch.refused` record `reason: "profile_switch_fenced"` and the check. The epoch rule reads `model.invocation.reserved` and `model.profile.switch_requested` sequences, kernel read, inside the admission and drain paths only | unchanged | none |
| ModelProfileSwitch | Existing (slice a) | One requested change | unchanged | unchanged | read, never written or locked, by the fence (fresh read after the head) and by the drain's validation (stored, by the kernel: pending at the generation) | unchanged | none |

ModelProfileSetting: existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found.

## Tests (RED first)

1. **Ordering, on independent connections** (each task joined or
   cancelled before cleanup; the disposable test DB only):
   - request holds the head, then a reservation: the reservation waits on
     the head (proved by `pg_blocking_pids`) and is refused;
   - a reservation holds the head, then the request: the reservation's row
     is visible afterwards and is refused by the drain;
   - the same two orders for launch;
   - a request that rolls back while a reservation waits leaves no fence:
     the reservation is admitted;
   - no fence reader locks the switch row (a `pg_locks` probe).
2. **The fence:**
   - pending and blocked each refuse reservation and launch, with the
     reason and check;
   - completed and failed switches don't fence new reservations;
   - another tenant's switch doesn't;
   - the Fake is never fenced;
   - a `:sent` row settles while the switch is open.
3. **The epoch rule (ABA):** reserve Opus, complete Opus→Sonnet, complete
   Sonnet→Opus, then launch the old row. It is refused
   `:reserved_before_switch`, never sent. A row reserved after both
   switches launches normally.
4. **Consumers, at both stages:**
   - the exact `Refused` receipt;
   - one `provider_error` Failure;
   - the event payload;
   - the run `failed`/`:model_not_admitted` linking exactly that Failure,
     also after the Failure was resolved;
   - no budget-class Failure;
   - no second attention item.
5. **The drain:**
   - a dead reserved caller's row is refused within the bound, its run is
     stopped, and the charge is unchanged;
   - a queued call's row is refused, and the later dequeue is refused
     `:invocation_not_reserved`;
   - drain versus a live launch of the same row, in both orders: never
     sent;
   - `:sent` settles, then drained;
   - a row that never settles: `:drain_timeout` at the deadline, the
     deadline not reset by progress, the fence still closed;
   - a query error gives `:drain_observation_failed`;
   - caller death with a durable `:sent` row times out (no false drained);
   - no lock held while waiting.
6. **Drain authority:**
   - `model_runtime`, an admin and a foreign-tenant `agent_runtime` are
     each refused;
   - a completed, failed or blocked switch gives `:switch_not_open`;
   - a stale generation gives `:stale_server_generation`;
   - the result carries counts only.
7. **Immutability:** the profile, grant, allocation and charge of a
   refused row are unchanged; no action rewrites a reserved profile.
8. **Safe exit:** with no switch ever requested, the existing admission,
   launch and SDR suites pass unchanged.

## Open questions

None open. OQ-1 and OQ-2 are resolved above, as Codex recommended, and
OQ-3 is dropped: b1 adds no server signal.
