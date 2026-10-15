# C2-02b1 (#52, slice b1): the admission fence and the drain (draft 3)

**Status:** draft 3, interface and entity **PASS**, recorded 2026-10-15.
- **Reviewer:** Codex, ai-pair correlated review (`ccf36a4e`, request
  `m_1792054834333758000_45f61327`), at exact `cda8ee5`, about 09:03 UTC.
  Report:
  `~/.local/state/sdr-agent/handoff-20261008/tmp/codex-c2-02b1-cda8ee5-interface-pass.md`.
- **It authorizes scoped RED only:** no GREEN, activation, model calls or
  merge.
- **Binding implementation obligations from the PASS:**
  - The settlement follows the existing outcome rule of
    `AgentWorker.fail_operation/3` through a shared domain-owned helper:
    `SdrAgent.Agents` never calls up into a worker.
  - Idempotency is checked under the actual locks, bound to the stored
    run, cause, request, event, switch and Operation.
  - The full race and crash matrix runs with joined workers on a
    disposable test DB.
  - The final observation is one coherent, bounded read.
- **Draft 2** (`0dd410b`) was NEEDS-REVIEW (Codex, 3db4316e). Its epoch,
  cleanup and consumer fixes were accepted. Two drain lifecycle gaps were
  open, both fixed here:
  - MF1: the stale drain must revalidate in each transaction;
  - MF2: the Operation of a run the drain stopped needs a settlement and
    recovery owner.
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
  switch's outcome. The events are tenant-scoped and read by the kernel.
  - **`:reservation_provenance_missing`:** the invocation's reserved event
    is missing, ambiguous or unreadable. It fails closed: refused, never
    "no later switch".

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
| Launch | inside `Admission.launch_check/6`, after the run-status, generation and profile checks, the exemption check and `Gate.admit_launch`, before `launch_binding`/`launch_terms` | `:switch_pending`, `:switch_blocked`, then `:reservation_provenance_missing` or `:reserved_before_switch` |

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
| `Changes.LinkRefusalAttention` | `"profile_switch_fenced"` joins both the reservation-admission list (`@admission`) and the launch list (`@launch`). So the run stops `failed`/`:model_not_admitted` linking exactly that Failure, even if an admin resolved it meanwhile. There is only one live attention item, and the worker and Operation rules are unchanged |
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
     invocation → charge → head).
   - **Revalidated in that transaction (MF1),** after the head is held,
     by fresh non-locking reads. The switch row is never locked after the
     head:
     - the named switch S is still of the tenant, `pending`, at the input
       `server_generation`;
     - **the cutoff:** the row's `model.invocation.reserved` sequence is
       lower than S's own `model.profile.switch_requested` sequence;
     - the row is still `:reserved`.

     **If S changed** (completed, failed, blocked, or another generation),
     the transaction writes nothing and the drain returns
     `{:error, :switch_not_open}` or `{:error, :stale_server_generation}`.
     A drain therefore never refuses work reserved after S closed, or work
     of a newer switch.

     **A row past the cutoff** can't exist while S is pending (the fence),
     so finding one fails closed: nothing is written, and the drain
     returns `{:error, :drain_observation_failed}`.

     **Missing or ambiguous provenance** (no reserved event, or no unique
     request event for S) also fails closed, the same way.
   - **On success,** that transaction:
     - refuses with reason `:profile_switch_fenced`, check
       `:reserved_before_switch`, recorded exactly as a launch refusal
       (above), with `switch_id` S in the event payload;
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
   - **Operation settlement (MF2).** This is the existing outcome rule
     with a named owner:
     - after each refusal transaction commits and its locks are released,
       the drain settles the stopped run's Operation by the worker's rule
       (`SDR.AgentWorker.fail_operation/3`): it links the run's live
       attention Failure, or opens the resolved-cause Failure if an admin
       resolved it meanwhile;
     - it runs in its own transaction, in the established Operation →
       Failure → head order. It never upgrades the refusal transaction's
       Operation share lock while holding the head;
     - it applies only while the Operation is still `running`. An
       Operation the ordinary worker already settled is left alone, so
       there is exactly one live cause;
     - reply-intake runs (no Operation) are exempt.

     **A retried drain** for S first settles the still-running Operation
     of every run it stopped for S, before it reports success. It finds
     them by its `model.launch.refused` events naming S. So "no reserved
     or sent rows" alone never skips that obligation.

     **The crash backstop** is the stale-run sweeper. Its terminal-run
     heal (today `:witness_mismatch` and `:witness_unreconciled`) is
     extended to runs stopped `:model_not_admitted` whose Operation is
     still `running` and whose job is no longer live, revalidated under
     the run, Operation and job locks. It applies the same worker rule.
     This covers a crash between the run-stop commit and the Operation's
     transaction, whoever stopped the run.
   - **A concurrent ordinary worker** may still hold the job. Its later
     launch of the refused row gets `:invocation_not_reserved` against a
     run already `failed`. The worker's handling of that must neither open
     a second live Failure nor settle the Operation with another cause.
     RED pins this; if the current handling does either, b1 narrows it to
     "run already terminal: halt with no new Failure".
2. **Wait for every `:sent` ClaudeCLI row of the tenant to settle**
   (completed, failed or unknown).
   - This polls a count query with no row lock. Nothing is held under a
     ledger lock while waiting.
   - **A caller that dies after `:sent`:** its row is settled by its own
     facade path, if that is still running, or else only by the stale-run
     recovery (`stale_after_seconds`, 1800 s by default). That is longer
     than the drain's bound, so the drain times out, and b2 blocks.
   - **A server that dies:** its `:sent` rows behave the same way.
3. **Prepared callers** (health check passed, not reserved) leave nothing
   to drain: no reservation exists.
   - **While the switch is open,** their reservation is refused by the
     fence.
   - **A caller paused until after the switch closed** has no pre-fence
     reservation event, so the epoch rule doesn't concern it. Its later
     reservation and launch pass the fresh ordinary checks, against the
     server and profile then running.
   - **b2 owns** whether a new server generation admits it at all (its
     ingress and generation obligation).

### Result

- **`{:ok, %{refused: n}}`:** in one final transaction:
  - S is still of the tenant, `pending`, at the generation;
  - no `:reserved` or `:sent` real-profile row of the tenant remains;
  - no run the drain stopped for S has a `running` Operation.

  If S changed by then, the result is `{:error, :switch_not_open}` or
  `{:error, :stale_server_generation}`, never an unqualified success.
- **`{:error, :drain_timeout, %{reserved: n, sent: n}}`:** the deadline
  passed.
- **`{:error, :drain_observation_failed}`:** any query error. It fails
  closed.
- **The deadline is one monotonic budget.** It is never reset, and it
  covers validation, every refusal and settlement transaction, the
  polling, and the final observation. No wait happens under a ledger lock.
  A failed observation is never read as zero outstanding work.
- **Errors don't themselves reopen the fence.** The drain unlocks and
  refunds nothing. A concurrent `complete`, `fail` or `block` by another
  actor may still close the switch: that is the switch's own lifecycle,
  and MF1's revalidation keeps the drain from acting on it.

### Observability (stage events)

The drain emits `[:sdr_agent, :profile_switch, :drain]` telemetry events
(agreed in the RED review, Codex 36cc598a).
- **Contents:** empty measurements; metadata
  `%{stage: stage, switch_id: id}` only. No prompts, outputs, rows,
  credentials or caller-controlled values.
- **Stages:**
  - `:validated`: the initial validation of S passed;
  - `:refused`: after each refusal transaction has committed and
    released its locks, before that run's Operation transaction;
  - `:polling`: each poll of the sent count, outside any transaction.
- **They observe lifecycle points and authorize nothing.** No safety
  check depends on them. Tests attach handlers to them as barriers.

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
| ModelInvocation | Existing (action contract delta) | One model call | unchanged; `profile_id`, grant and allocation are immutable after reservation; charges are never refunded | unchanged | **reserve:** refused (`:profile_switch_fenced`, `:switch_pending`/`:switch_blocked`) while the tenant has an open switch, read after the head. **launch:** the same checks, then `:reservation_provenance_missing` (fails closed) or `:reserved_before_switch` (the epoch rule: its reserved event's sequence is lower than a `switch_requested` event's); reserved → failed, never sent. **drain:** every reserved row of the tenant → failed through the launch refusal path. Sent rows settle unchanged | unchanged: `agent_runtime` (the drain runs as `agent_runtime`) | none |
| AgentRun | Existing (action-cause delta) | One agent run | unchanged | unchanged | `:fail` with `:model_not_admitted` accepts a `profile_switch_fenced` refusal Failure as its cause, at either stage, through `LinkRefusalAttention`'s lists. It links the same Failure even when resolved; only one live attention item | unchanged (`agent_runtime`) | none |
| Operations.Failure | Existing (recording delta) | Operator attention | unchanged | unchanged | a fence refusal opens one `provider_error` Failure with detail reason `profile_switch_fenced`: deduplicated per run at reservation; one per refused row at launch or drain | unchanged | none |
| AuditEvent | Existing (event-contract delta) | Ledger | unchanged | unchanged | `model.reservation.refused` and `model.launch.refused` record `reason: "profile_switch_fenced"` and the check. A drain refusal also records `switch_id` (read back by a retried drain). The epoch rule reads `model.invocation.reserved` and `model.profile.switch_requested` sequences, kernel read, inside the admission and drain paths only | unchanged | none |
| Operations.Operation | Existing (consumer and recovery delta) | One business operation | unchanged | unchanged | **A run the drain stopped `:model_not_admitted`:** the drain fails its still-running Operation by the worker's rule (`AgentWorker.fail_operation/3`), in its own Operation → Failure → head transaction after the refusal commits, linking the live cause or a resolved-cause Failure. A retried drain finishes that obligation for S's runs. The stale-run sweeper's terminal heal also takes `:model_not_admitted` runs with a running Operation and a dead job. Exactly one live attention item. Reply-intake runs have no Operation | unchanged: `agent_runtime` (drain); the sweeper's existing actor | none |
| ModelProfileSwitch | Existing (slice a) | One requested change | unchanged | unchanged | read, never written or locked, by the fence and by the drain. Both use a fresh read after the head, in every destructive drain transaction and in the final observation: pending at the generation, plus its `switch_requested` sequence as the cutoff | unchanged | none |

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
   - only one live attention item.
5. **The drain:**
   - a dead reserved caller's row is refused within the bound, its run is
     stopped, and the charge is unchanged;
   - the launch-time epoch with missing provenance is refused
     `:reservation_provenance_missing`;
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
6. **Drain revalidation (MF1),** on independent connections:
   - the drain validates S; another actor fails S and commits; a new
     reservation V commits. The drain's next transaction writes nothing
     and returns `:switch_not_open`, and V is never refused;
   - the same with S completed, and with a newer pending switch at
     another generation (`:stale_server_generation`);
   - S changes between the last refusal and the final observation: no
     success;
   - a missing reserved event or request event fails closed.
7. **Operation settlement (MF2):**
   - a dead worker: the drain stops the run and fails its Operation by
     the worker's rule, with one live attention item;
   - a crash after the run-stop commit, before the Operation transaction:
     a retried drain settles it before reporting success, and,
     separately, the sweeper heals it once the job is dead;
   - a concurrent ordinary worker: the Operation is settled once, by the
     same cause, leaving only one live attention item;
   - the resolved-cause race: an admin resolves the Failure before the
     Operation transaction, and the worker's resolved-cause Failure is
     used;
   - a reply-intake run is left with no Operation.
8. **Drain authority:**
   - `model_runtime`, an admin and a foreign-tenant `agent_runtime` are
     each refused;
   - a completed, failed or blocked switch gives `:switch_not_open`;
   - a stale generation gives `:stale_server_generation`;
   - the result carries counts only.
9. **Immutability:** the profile, grant, allocation and charge of a
   refused row are unchanged; no action rewrites a reserved profile.
10. **Safe exit:** with no switch ever requested, the existing admission,
   launch and SDR suites pass unchanged.

## Open questions

None open. OQ-1 and OQ-2 are resolved above, as Codex recommended, and
OQ-3 is dropped: b1 adds no server signal.
