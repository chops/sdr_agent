# C2-02b2β interface: the attended resolver for a blocked switch

**Status:** draft 4, 2026-10-15, for Codex's interface, entity and ADR
re-review. Slice plan: `c2-02-slices.md` (b2β). Builds on b2α
(`c2-02b2-interface.md`, merged at `22db5c0`). Needs the proposed
ADR-0004 C2-02b2β amendment (section 7), which the owner must accept
before implementation approval.

**Review record:**
- **Draft 3** (`a62a1af`): interface, entity and ADR NEEDS-REVIEW,
  narrowed to three groups (Codex `b217a39e`,
  `codex-c202b2beta-a62a1af-interface-review.md`). Draft 4 answers them:
  - **R3-1, settling an unknown outcome:** a definite negative needs a
    bounded serialization barrier, then an exact re-read (section 1).
    Elapsed time alone is never proof.
  - **R3-2, replay:** repeated in the coordinator before any mutable
    check, and again after the locks. The lease kind is persisted, so the
    semantic identity is recoverable (sections 2 and 4).
  - **R3-3, the lease authority:** **withdrawn.** The cleanup authority R
    and its exception to decision 5 are removed. b2β never calls
    `Reaper.release/1`. A dead lease is a held hard conflict that the
    existing operator path ends (section 5). This is the conservative
    attended path Codex's draft-1 review allowed ("either explicitly model
    resumable authority or choose a conservative attended hard-conflict
    path").
- **Draft 3's closed points are kept:**
  - the current-owner and hold prerequisites;
  - the survivor's work excluded;
  - the pre-dispatch deadline;
  - committed versus ready;
  - the hard conflict;
  - the User and start inverses;
  - α's `block` replay.
- **Earlier rounds:**
  - draft 2 `a559936` (Codex `c42af963`);
  - draft 1 `844a250` (Codex `fc318941`);
  - the pre-read (`codex-c202b2beta-22db5c0-preread.md`).

## 0. Scope

b2α blocks a switch S whenever an outcome can't be proven. A blocked
switch keeps the server **held**, has no exit, and occupies the tenant's
single open-switch slot.

b2β adds **one** exit: **blocked → failed**, attended and fail-closed.
- **Who:** an active human admin decides (the intent). The registered
  coordinator executes it (the authority).
- **Proof:** an explicit owner attestation bound to the switch, the
  tenant, the covered starts, the observed lease kind and the outcome.
- **What it changes:** only S's record. The setting is unchanged. The
  server returns at the desired profile only through b2α's
  reconciliation, and the resolution never releases the hold or a lease.

**Not in b2β:**
- blocked → completed;
- any automatic exit;
- a durable late receipt (OQ-1);
- any call to `Reaper.release/1`;
- UI (R0-05; obligations at the end).

## 1. The entry points, the deadline and settlement

**Read: `Agents.blocked_switch_facts(switch, opts)`.** An active human
admin only. It calls `Coordinator.resolution_facts/2`, which makes no
write and no runtime change. It returns:
- S;
- the coordinator's boot, its latest start and its hold status;
- the covered range (section 3), with each start's recorded pid, node and
  reaper;
- the observed lease kind (section 2, step 5).

A failed observation returns `{:error, :observation_unknown}`.

**Write: `Agents.resolve_blocked_switch(switch, attestation, opts)`.**
- **The deadline.** The caller stamps one monotonic deadline (`now +
  15 s`) **before dispatch**. It runs steps 1–3 of section 2, which have
  no runtime effect, then calls `Coordinator.resolve_blocked(request,
  deadline)` with a call timeout of the time remaining plus 500 ms.
- **On dequeue,** the coordinator refuses an expired request with
  `{:error, :resolve_timeout}` and does nothing else. Every later step
  checks the remaining budget. The `LedgerCall` budget is `min(remaining,
  2 s)`, and `LedgerCall` refuses to commit once that is spent.
- **Busy:** while a switch worker runs, a block is retried or a
  reconciliation is in flight, the reply is `{:error,
  :coordinator_busy}`. Nothing is queued.

**Results:**

| Result | Meaning |
|---|---|
| `{:ok, %{switch: s}}` | The resolution committed, and S is `:failed`. **This doesn't mean the server is ready.** It stays held until b2α's reconciliation releases it, which a dead lease prevents (the hard conflict, section 5) |
| `{:ok, %{switch: s, replay: true}}` | An exact replay: no write and no runtime effect |
| `{:error, :resolve_timeout}` | **Definitely not committed.** Either the request expired on dequeue, `LedgerCall` rolled back on its own pre-commit budget check, or the settlement below proved it |
| `{:error, :resolve_uncertain}` | The outcome is unproven |
| the typed refusals in section 2 | nothing written; each one is a rollback, or a refusal before the transaction |

**Settling an unknown outcome (R3-1).** These cases are **unknown**,
never inferred from elapsed time:
- a caller timeout;
- a lost reply;
- a connection error during the transaction or its commit;
- a `LedgerCall` error that isn't its own pre-commit refusal.

Settlement is one bounded call (a `LedgerCall`, at most 2 s), made by the
caller and, after an unknown commit, by the coordinator before any other
action:
1. **The barrier.** Take the same locks the original write took, in the
   same order: setting → counter `FOR SHARE` → switch `FOR UPDATE`, in a
   read-only `:settle` phase of `ProfileSwitchContext`. Acquiring the
   switch row lock proves the original transaction has finished, because
   it held that row's lock until its commit or rollback.
2. **Read after the barrier.** Re-read S and the tenant's row carrying
   this `attestation_id`:
   - **an exact semantic match** (section 2, step 3) → the replay result;
   - **S still `:blocked` and no row with this id** → `:resolve_timeout`,
     now definite;
   - **a row with this id but other facts** → `:attestation_conflict`;
   - **S resolved under another id** → `:switch_not_blocked`.
3. **No barrier, no answer.** If the barrier can't be acquired within the
   bound, or the read fails, the result is `:resolve_uncertain`. The
   coordinator stays held and retries the same settlement on its tick. No
   other action follows from an unproven outcome.

## 2. The checks, in order

1. **Actor.** An active human admin, with the role and tenant re-read (as
   `request`). This is checked in the caller, again in the coordinator,
   and again after the locks. Refused: reviewer, auditor,
   `model_runtime`, `agent_runtime`, `scheduler`, `seeder`, kernel, and a
   demoted or disabled admin.
2. **Shape.** A closed map, otherwise `{:error, :attestation_invalid}`:

   | Field | Type |
   |---|---|
   | `attestation_id` | uuid, client-generated |
   | `switch_id` | uuid, equal to S's id, in the tenant |
   | `attested_start_id`, `attested_generation` | the latest start in the facts |
   | `attested_lease_kind` | `:none \| :survivor \| :dead_holder` |
   | `outcome` | `:failed` only |
   | `confirmation` | exactly `"STOPPED " <> switch_id` (no trimming or case folding) |

3. **Replay, the first time (in the caller).** One stored read of the
   tenant's switch carrying this `attestation_id`, which is unique per
   tenant.
   - **The semantic identity:** switch, resolver (`resolved_by_id` == the
     actor), `attested_start_id`, `attested_generation`,
     `attested_lease_kind` and outcome. Every field is persisted on the
     switch (section 4), so nothing is inferred from runtime state.
   - **Found, identical:** `{:ok, %{switch: stored, replay: true}}`. No
     write, event, setting revision, start, hold change or other runtime
     effect, even after later starts, boots or switches.
   - **Found, different:** `{:error, :attestation_conflict}`.
   - **Not found:** go on.
4. **Replay, the second time (in the coordinator, R3-2).** On dequeue,
   after the expiry check and **before** busy, binding, state or
   observation, the coordinator repeats step 3's stored read, with the
   same precedence. A competing request with the same id that committed
   in between is therefore returned as a replay, not refused on mutable
   state. Next: S not `:blocked` → `:switch_not_blocked`.
5. **In the coordinator, the mutable prerequisites:**
   - **busy** (section 1);
   - **the binding:** this boot has allocated, and its latest start is
     the attested start. Otherwise `:stale_attestation`;
   - **the hold:** any live named server is the coordinator's exact
     `ServerSupervisor` child, with an **acknowledged** hold. Otherwise
     `:observation_unknown`;
   - **the lease kind** must equal the attested kind:

     | Kind | Observed |
     |---|---|
     | `:survivor` | the live, held server is the bound pid; `admission/1` is `:open`; the lease holder is exactly its published reaper, alive |
     | `:none` | no live named server, and no lease |
     | `:dead_holder` | no live named server, and the lease is held by a **dead** process |

     Anything else (a live holder with no server, a holder that isn't the
     server's own reaper, blocked admission) → `:live_work_observed`. A
     failed observation → `:observation_unknown`. A different kind from
     the attested one → `:stale_attestation`. An observation can only
     refuse. It is never proof of absence, and it grants nothing.
6. **The write.** One `LedgerCall`, with b2α's lock order and no new row:
   setting → counter `FOR SHARE` → switch → latest start `FOR SHARE` →
   head. **After the locks,** in this order:
   1. the actor is still an active admin of the tenant;
   2. **replay, the third time:** if the locked S carries this
      `attestation_id`, an exact match is the replay result. The
      transaction writes nothing, and the coordinator does nothing else.
      A row with this id but other facts → `:attestation_conflict`. A
      unique conflict on `attestation_id` from another switch →
      `:attestation_conflict`;
   3. S is `:blocked`, otherwise `:switch_not_blocked`;
   4. the latest start is the attested start and belongs to the
      coordinator's boot (the b2α fence), otherwise `:stale_attestation`;
   5. no other switch is open.

   Any refusal rolls back.

## 3. What the attestation covers

**The covered range** is every `ModelServerStart` of the tenant with
generation in `[S.server_generation, attested_generation]`: the old
server, the candidate and the rollback when allocated, and any start
allocated after S blocked. A start after the commit is outside the range,
and its own lifecycle proves its cleanup.

**The statement R0-05 shows, which the admin confirms:**
> No Claude CLI process started by any server in this range is still
> running, except work owned by the current held server's own live
> reaper. I checked this myself.

**The attestation is a decision record, not cleanup authority.** It
closes S and frees the slot. It releases no lease and no hold.

**The current server's work is excluded, not attested.** Admission
`:open` doesn't mean no in-flight work (`claude_cli.ex`). Stopping a
`:survivor` later still needs b2α's bound stop protocol with a fresh
receipt.

**Never proof:** an absent lease, a dead holder, a scan, stored pid text,
or a healthy new server.

## 4. The write, and the α finalizers

`ModelProfileSwitch.resolve_blocked`:
- `status` becomes `:failed`. `finished_at` and `resolved_at` are set
  from **one** clock value read once in the action. That is the action's
  time, not the SQL commit instant.
- `failure_reason` keeps the block's reason. The chain shows
  `switch_blocked`, then `switch_resolved`.
- **Kept:** `from_profile_id`, `to_profile_id`, `server_generation`,
  `requested_by_id`, `requested_at`.
- **Set:** `resolution: :owner_attested`, `resolved_by_id`,
  `attestation_id`, `attested_start_id`, `attested_generation`,
  `attested_lease_kind`.
- **The setting** row and revision aren't written. The event reports the
  stored revision.
- **The event `model.profile.switch_resolved`** has closed metadata:
  switch, tenant, `attestation_id`, the covered generations `[first,
  last]`, `attested_lease_kind`, outcome, `resolution` and the block's
  reason. No confirmation text, pids or refs.

**The α finalizers keep their accepted behavior:**
- `complete` and `fail` on a blocked switch: refused (`:switch_blocked`).
- `block` on a blocked switch by the current owner: α's valid no-write
  replay.
- A direct, unphased action: refused.
- **One narrow α delta:** `fail` on a **resolved** switch →
  `:switch_already_finished`, never a `fail` replay. It is checked
  **after** α's existing owner, boot and generation guards, so those
  guards still run first and no actor gains rights. A resolved S is
  `:failed`, which α's `decide/2` would otherwise read as a replay of its
  own `fail`.
- `resolve_blocked` never produces `:ready` evidence, and never counts as
  an adopted or preflighted start.

## 5. After the commit: b2α's reconciliation, or a held hard conflict

The coordinator runs b2α's **no-open-switch** reconciliation (2a), with
no new authority:
- **`:survivor`:** adopt if b2α's conditions hold (the exact child, the
  desired profile, its own live reaper lease). Otherwise use the bound stop
  protocol with a fresh receipt, then a fresh held `:replacement` start.
- **`:none`:** a fresh held `:replacement` start at the desired profile,
  with the no-call preflight and `:ready`.
- **`:dead_holder`:** the lease blocks a new server's admission, so no
  start can become ready. The coordinator **stays held**. This is the
  **hard conflict**:
  - `status/0` publishes `stage: :cleanup_unprovable`;
  - b2β releases nothing;
  - the exit is the **existing operator path**: the operator checks the
    machine and runs `Reaper.release/1` themselves from a console. This
    is exactly b2α's situation when a reaper dies without its receipt,
    and it is unchanged.
- **Resuming after the operator.** While `:cleanup_unprovable` and no
  switch is open, the coordinator's tick re-observes the lease. Once there
  is **no lease and no live named server**, it runs the same b2α
  no-open-switch path as at a cold boot: a fresh held allocation,
  preflight and ready. The lease's absence here doesn't prove anything
  about S. It only means the operator has acted, and b2α's cold boot
  already starts a fresh server whenever no lease exists.
- **The release** of the hold, in every case, is b2α's normal branch: no
  open switch, and a ready `:boot` or `:replacement` start of this boot at
  the desired profile, on the held pid, with its reaper observed.

**Honest residual:** a resolution can commit without restoring readiness.
With a dead lease it still needs the operator path. Whether R0-05 needs
its own attended action for that is OQ-5.

## 6. Crash and outcome table

| Point | Durable state | Next | Hold |
|---|---|---|---|
| expired on dequeue, or refused in section 2 | unchanged | the typed refusal | kept |
| `LedgerCall`'s own pre-commit refusal | rolled back | `:resolve_timeout` | kept |
| **an unknown outcome** (a timeout, a lost reply, a connection error) | unknown | the barrier settlement (section 1) by caller and coordinator; no other action until it is proven | kept |
| committed, a coordinator death before reconciliation | S `:failed` | the next boot takes b2α's no-open-switch path (adopt, replace, or the hard conflict) | kept |
| the fresh start or its preflight fails | the start is `:failed` | b2α's replacement retry | kept |
| a dead lease after the commit | S `:failed` | the hard conflict; the operator path; the tick resumes once no lease and no server exist | kept |
| a survivor or its reaper dies without a receipt, at any time | S `:failed` or still blocked | b2α's rules; with no open switch, the hard conflict | kept |
| a new switch opens after the commit | a new open switch | b2α's rules for that switch | kept |
| reconciliation unknown | S `:failed` | retried on the tick | kept |
| a ready `:replacement` or `:boot` start at the desired profile, with no open switch | S `:failed` | b2α's normal release branch | **released** |

## 7. The proposed ADR-0004 C2-02b2β amendment (substantive)

It changes C2-02b2 decision 6 (a blocked switch had no exit). **Decision
5 is unchanged:** `Reaper.release/1` is never called by this code. The
amendment is in `docs/adr/0004-model-provider.md`, status **proposed**,
and needs the owner's acceptance before implementation approval. No new
ADR number. ADR-0005's calibration recovery is precedent only.

Its decisions:
1. **The only exit from blocked** is the attended resolution to
   `:failed`. An active human admin decides (OQ-2). The registered
   coordinator executes it with a typed attestation.
2. **The binding:** switch, tenant, the covered start range (the latest
   being the coordinator's current start, re-checked after the locks),
   the observed lease kind and the outcome. Replay is idempotent by id, a
   replay authorizes nothing, and replay is checked in the caller, in the
   coordinator and after the locks.
3. **An unknown outcome** is settled only through a serialization barrier
   and an exact re-read. Until then the server stays held and nothing
   acts.
4. **No new cleanup authority.** The resolution releases no lease and no
   hold. A dead lease is a held hard conflict (`:cleanup_unprovable`),
   whose exit is the existing operator path. The coordinator resumes
   b2α's cold-boot path once no lease and no server exist.
5. **Unchanged:**
   - `complete` and `fail` refuse blocked;
   - `block` keeps its no-write replay;
   - the lock order, the Fake default and the call grants.

   Plus one narrow change: `fail` on a resolved switch is refused after
   the existing guards.

## Entity Model

**Entity Model trigger:** yes. It covers a new lifecycle transition
(blocked → failed), new attributes and relationships (to User and to
ModelServerStart), a new event, and a new authorization path (a human
admin, executed in the coordinator, plus a read-only settle phase).

| Entity | New / Existing | Purpose | Attributes | Relationships | Invariants / Lifecycle | Policy/Actor | Open Questions |
|---|---|---|---|---|---|---|---|
| ModelProfileSwitch | Existing (delta) | One requested change | **Added, all nullable:** `resolution : :owner_attested`; `resolved_by_id : uuid`; `resolved_at : utc_datetime_usec`; `attestation_id : uuid`, unique `(tenant_id, attestation_id)` where not null; `attested_start_id : uuid`; `attested_generation : int ≥ 1`; `attested_lease_kind : :none \| :survivor \| :dead_holder`. **Check:** all seven null or all set; when set, `status = 'failed'`, `resolved_at = finished_at` and `attested_generation >= server_generation`. Existing attributes and request history are immutable and unchanged | **Added:** belongs_to `resolved_by` (User; set exactly with `resolution`; `on_delete: :restrict`; the same tenant and the current admin role are enforced by the action after the locks, as for `requested_by`); belongs_to `attested_start` (ModelServerStart; composite FK `(tenant_id, attested_start_id)`; `on_delete: :restrict`) | **New transition:** blocked → failed, by `resolve_blocked` only. `complete` and `fail` refuse blocked. `block`'s no-write replay is kept. `fail` on a resolved switch is refused after α's guards. `failure_reason` is kept. Replay is by `attestation_id` with the persisted semantic identity (section 2.3), checked in the caller, in the coordinator and after the locks. A resolution grants no cleanup authority | `resolve_blocked`: a new `Checks.ResolveContext` needs the registered coordinator **process** (the process-only helper factored out of `Checks.CoordinatorProcess`, whose `model_runtime` rule is unchanged) **and** an active human admin re-read, in a new `ProfileSwitchContext` phase `:resolve`. **Settle:** a read-only lock in a `:settle` phase, for that admin or the coordinator. `model_runtime` gains no write. `blocked_switch_facts` is admin-only. Other reads are unchanged | OQ-5 |
| User | Existing (delta: referenced) | A person | unchanged | **Added inverse:** referenced by 0..n switches as `resolved_by`; each resolution has exactly one resolver; restrict on delete | unchanged. The resolver may be the requester, recorded separately | unchanged | none |
| ModelServerStart | Existing (delta: referenced) | One start attempt | unchanged | **Added inverse:** referenced by 0..n switches as `attested_start` (composite FK); restrict on delete; never destroyed | unchanged. The resolver reads the latest start `FOR SHARE` and never writes it | unchanged | none |
| Coordinator (runtime) | Existing (delta) | Owns the server lifecycle | **Added:** `resolution_facts/2` (read-only); `resolve_blocked/2` (deadline-stamped, with replay checked before mutable state); settlement after an unknown outcome; the `stage: :cleanup_unprovable` status and its resume on the tick | — | It refuses expired or busy requests. It binds its boot, its latest start, an acknowledged hold and the observed lease kind. Nothing acts before an unknown outcome is settled. It never calls `Reaper.release/1`. It releases the hold only through b2α's reconciliation. No model call | called with the admin's actor; the write's actor is the admin | none |

ClaudeCLI.Reaper: existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found.
ModelProfileSetting: existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found.
ModelServerCounter: existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found.

## 8. Tests (RED first)

Files: `test/sdr_agent/agents/profile_switch_resolve_test.exs`,
`profile_switch_resolve_race_test.exs` (independent connections, joined
workers, explicit barriers) and
`test/sdr_agent/ai/profile_coordinator_resolve_test.exs`. Each sets up a
real blocked S through the b2α coordinator, never by a raw write. Zero
model calls, no spend, and never the calibration or dev database.

**Domain and policy:**
1. **Happy path for each lease kind:** blocked → failed; the reason and
   request provenance kept; the seven resolution fields set from one
   clock value; `switch_resolved` after `switch_blocked` with closed
   metadata; the setting revision unchanged; `{:ok, %{switch: s}}`.
2. **The shape:** a bad confirmation (wrong, mis-cased, padded, missing,
   or another switch's id), a non-`:failed` outcome, an extra field or an
   unknown lease kind → `:attestation_invalid`.
3. **Actors:** each refused actor; an admin demoted or disabled before
   the call, and between dispatch and the locks. Allow and deny pairs.
4. **The process:** a direct Ash `resolve_blocked` outside the
   coordinator is forbidden, even for an admin. `model_runtime` gains no
   write.
5. **The state:** pending, completed and failed → `:switch_not_blocked`,
   with the history unchanged.
6. **α finalizers:**
   - `complete` and `fail` on blocked S → `:switch_blocked`;
   - the current owner's `block` on blocked S is a no-write replay;
   - `fail` on resolved S → `:switch_already_finished`, after the
     existing guards (a stale-generation `fail` still gets α's stale
     error first);
   - direct unphased actions are refused.
7. **Replay precedence:**
   - an exact replay right after the resolution;
   - after a later start, a later boot and a new switch, still a replay
     with no effect;
   - the same id from another admin, on another switch, or with another
     start, generation or lease kind (`:none` versus `:survivor`, both
     ways) → `:attestation_conflict`;
   - a different id on resolved S → `:switch_not_blocked`.
8. **Concurrent replay (R3-2):** two same-id callers are barriered after
   their caller-side reads both see nothing. One completes, and the
   resolution advances the runtime start, before the other is dequeued.
   The result: one event, one resolution, and one exact replay.
9. **Concurrent different ids:** exactly one commits; the other gets
   `:switch_not_blocked`.
10. **Staleness:**
    - a start allocated after the facts read → `:stale_attestation`;
    - a start allocated while the write waits on the setting lock
      (independent connection) → refused after the locks.
11. **Tenancy and the slot:** another tenant's switch → not found; a new
    `request` succeeds after the resolution.

**Settlement (R3-1):**
12. **The open transaction:** the original transaction is held
    uncommitted, with its row locks, past the caller's settle point. An
    independent read sees S blocked, but settlement stays
    `:resolve_uncertain`. When the original commits, settlement converges
    to the replay; when it rolls back, to a definite `:resolve_timeout`.
    Nothing acts in between.
13. **The pre-commit refusal:** `LedgerCall`'s own budget refusal is a
    definite `:resolve_timeout` without settlement.
14. **The coordinator after an unknown commit:** it runs the settlement
    before any reconciliation, and an unproven outcome stays held and
    retries.

**Coordinator and runtime:**
15. **Lease kinds:** a live holder with no server, a holder that isn't
    the server's own reaper, and blocked admission → `:live_work_observed`
    (with the confirmation present). A kind mismatch →
    `:stale_attestation`. Observation faults (test-only) and an
    unacknowledged hold → `:observation_unknown`.
16. **Busy:** during a worker, a block retry or a reconciliation →
    `:coordinator_busy`.
17. **The deadline:** a request expired in a blocked mailbox does
    nothing; a pool or lock wait crossing the deadline doesn't commit;
    held calls are refused throughout.
18. **After the commit:**
    - `:none` → a fresh held start at `from`, then ready, then the
      release;
    - `:survivor` → adopted, or stopped with a fresh receipt and
      replaced;
    - `:dead_holder` → held at `:cleanup_unprovable`, with `release/1`
      never called by the coordinator. After a test-side operator
      release, the tick resumes to ready and the release.
    - Zero launches throughout.
19. **No authority from absence or death:** a survivor whose server and
    reaper die without a receipt, including during the write's lock wait,
    leaves the coordinator held. The coordinator never calls `release/1`
    in any test.
20. **Crashes:**
    - a kill after the commit → the next boot takes b2α's no-open-switch
      path;
    - a kill before the commit → S blocked and held;
    - a forced failure at the pre-commit step → S blocked, the server
      held.
21. **Held refusals:** ordinary, prepared and direct-pid calls are
    refused while held.

## Open questions

- **OQ-1 (accepted):** no durable late receipt.
- **OQ-2 (for the owner, in the ADR amendment):** any active human admin
  resolves, named as `resolved_by`.
- **OQ-3 (accepted in principle):** the 15 s pre-dispatch budget, with
  settlement by barrier. Recovery has b2α's bounds and isn't promised
  within it.
- **OQ-4: withdrawn.** There is no `Reaper.release/1` exception.
- **OQ-5 (for the owner):** does R0-05 need its own attended action for
  the hard conflict? **Recommendation: not for R0.** The operator path
  exists. It needs a reaper to die without a receipt, which b2α already
  leaves to that path. The page shows the state honestly.

## R0-05 obligations (recorded, not built)

- Show `blocked_switch_facts`: the covered starts with their recorded
  identity, and the lease kind.
- Show the section 3 statement and collect the typed confirmation.
- Report "committed, not ready" truthfully.
- Show `:cleanup_unprovable` and that it needs the operator.
