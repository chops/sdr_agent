# C2-02b2β interface: the attended resolver for a blocked switch

**Status:** draft 3, 2026-10-15, for Codex's interface and entity
re-review. Slice plan: `c2-02-slices.md` (b2β). Builds on b2α
(`c2-02b2-interface.md`, merged at `22db5c0`). Needs the proposed
ADR-0004 C2-02b2β amendment (section 7), which the owner must accept
before implementation approval.

**Review record:**
- **Draft 2** (`a559936`): interface NEEDS-REVIEW and entity
  NEEDS-REVIEW (Codex `c42af963`,
  `codex-c202b2beta-a559936-interface-review.md`). The six draft-1
  groups remained, plus **MF7** (b2α's `block` replay on a blocked switch
  is valid and stays). OQ-4 was "a narrowly bound attended exception is
  viable", not approval as stated.
- **Draft 1** (`844a250`): interface NEEDS-REVIEW and entity
  NEEDS-REVIEW (Codex `fc318941`,
  `codex-c202b2beta-844a250-interface-review.md`).
- **Pre-read:** `codex-c202b2beta-22db5c0-preread.md`.

**Where draft 3 answers each group:**

| Group | Answer |
|---|---|
| MF1, binding | sections 2.4, 2.5 and 3; the holder binding argument is in section 5 |
| MF2, recovery | the authority R, which can resume (section 5); the hard conflict (section 5); the unknown commit (section 6) |
| MF3, replay first | section 2, step 3 |
| MF4, the deadline | stamped before dispatch (section 1) |
| MF5, the ADR | a substantive amendment (section 7) |
| MF6, the entity delta | the Entity Model, including User |
| MF7, α block replay | section 4 |

## 0. Scope

b2α blocks a switch S whenever an outcome can't be proven. A blocked
switch keeps the server **held**, has no exit, and occupies the tenant's
single open-switch slot.

b2β adds **one** exit: **blocked → failed**, attended and fail-closed.
- **Who:** an active human admin, as their own decision (the intent),
  executed by the registered coordinator (the authority).
- **Proof:** an explicit owner attestation bound to the switch, the
  tenant, the covered starts, the observed lease state and the outcome.
- **The setting** is unchanged, because a blocked switch never applied
  it. The server comes back at the desired profile only through b2α's
  reconciliation. The resolution never releases the hold.

**Not in b2β:**
- blocked → completed;
- any automatic exit (a late receipt, a timer, a restart or a scan);
- a durable late receipt (OQ-1, accepted);
- UI (R0-05; obligations at the end).

## 1. The entry points and the deadline

**Read: `Agents.blocked_switch_facts(switch, opts)`.** An active human
admin only. It calls `Coordinator.resolution_facts/2`, which makes no
write and no runtime change. It returns:
- S;
- the coordinator's boot, its latest start and its hold status;
- the covered range (section 3), with each start's recorded pid, node
  and reaper;
- the observed lease state (section 2, step 4).

A failed observation returns `{:error, :observation_unknown}`.

**Write: `Agents.resolve_blocked_switch(switch, attestation, opts)`.**
- **The deadline.** The caller stamps one monotonic deadline (`now +
  15 s`) **before dispatch**. Steps 1–3 of section 2 run in the caller,
  with no runtime effect.
- **Dispatch.** The caller then calls
  `Coordinator.resolve_blocked(request, deadline)` with a call timeout of
  the time remaining plus 500 ms.
- **Expired requests:** on dequeue, the coordinator refuses an expired
  request with `{:error, :resolve_timeout}`, a definite no-write, and does
  nothing else. A request that waited behind another coordinator action
  is never acted on late.
- **The remaining budget** is checked before each step: observation,
  checkout, locks and the pre-commit check. The `LedgerCall` budget is
  `min(remaining, 2 s)`, and it refuses to commit once that is spent.
- **Busy:** while a switch worker runs, a block is retried, a
  reconciliation is in flight or R (section 5) is running, the reply is
  `{:error, :coordinator_busy}`. Nothing is queued.

**Results:**

| Result | Meaning |
|---|---|
| `{:ok, %{switch: s, recovery: :lease_bound \| :none}}` | The resolution committed and S is `:failed`. **This doesn't mean the server is ready.** It stays held until b2α's reconciliation releases it. `:lease_bound` means R (section 5) applies |
| `{:ok, %{switch: s, replay: true}}` | An exact replay (step 3): no write and no runtime effect |
| `{:error, :resolve_timeout}` | Definitely not committed: expired on dequeue, or the budget was spent before the commit point |
| `{:error, :resolve_uncertain}` | Unknown. A timeout the caller observes is **never** reported as a definite no-write. **The caller settles it:** after waiting until 1 s past the deadline (beyond `LedgerCall`'s client slack), it makes one stored read by `attestation_id`. Found → the replay result. S still blocked → `:resolve_timeout`. Unreadable → stays `:resolve_uncertain` |
| the typed refusals in section 2 | Nothing written |

## 2. The checks, in order

1. **Actor.** An active human admin, with the role and tenant re-read
   (as `request`), in the caller and again after the locks. Refused:
   reviewer, auditor, `model_runtime`, `agent_runtime`, `scheduler`,
   `seeder`, kernel, and a demoted or disabled admin.
2. **Shape.** A closed map, otherwise `{:error, :attestation_invalid}`:

   | Field | Type |
   |---|---|
   | `attestation_id` | uuid, client-generated |
   | `switch_id` | uuid, equal to S's id, in the tenant |
   | `attested_start_id`, `attested_generation` | the latest start in the facts |
   | `attested_lease` | `:none \| :survivor \| %{name: string, holder: string}` |
   | `outcome` | `:failed` only |
   | `confirmation` | exactly `"STOPPED " <> switch_id` (no trimming or case folding) |

3. **Replay first,** before any check on mutable state (busy, blocked,
   latest start, observation). It is one stored read of the tenant's
   switch carrying this `attestation_id` (unique per tenant). The semantic
   identity is: switch, resolver (`resolved_by_id` == the actor),
   attested start, generation, lease and outcome.
   - **Found, identical:** `{:ok, %{switch: stored, replay: true}}`. No
     write, event, setting revision, lease release, start or hold change.
     This holds even after later starts, boots or switches. A replay
     never re-authorizes R.
   - **Found, anything different** (another switch, another admin,
     another fact): `{:error, :attestation_conflict}`.
   - **Not found and S isn't `:blocked`:** `{:error, :switch_not_blocked}`
     (for example, another id already resolved it).
4. **In the coordinator,** before the transaction:
   - **Busy:** as in section 1.
   - **The binding:** this boot has allocated, and its latest start is
     the attested start. Otherwise `:stale_attestation`.
   - **The hold:** any live named server is the coordinator's exact
     `ServerSupervisor` child, with an **acknowledged** hold. Otherwise
     `:observation_unknown`.
   - **The lease state** must equal the attested one, which is one of:

     | State | Observed |
     |---|---|
     | `:survivor` | the live, held server is the bound pid; `admission/1` is `:open`; the lease holder is exactly its published reaper, alive |
     | `:none` | no live named server, and no lease |
     | `%{name, holder}` | no live named server; the lease is held by a **dead** process; `inspect(pid) == holder`; and some start in the covered range recorded `reaper_pid == holder` and `node == node()` |

   - **Refused:** anything else (a live holder with no server, a holder
     that isn't the server's own reaper, a dead holder no covered start
     recorded, blocked admission) → `:live_work_observed`. A failed
     observation → `:observation_unknown`. A mismatch with the attested
     state → `:stale_attestation`. An observation can only refuse; it is
     never proof of absence.
   - **Kept for the commit:** the coordinator holds this observation
     privately, as the actual holder pid term, for the post-commit check
     (section 5).
5. **In the write,** one `LedgerCall`, using b2α's lock order with no new
   row: setting → counter `FOR SHARE` → switch → latest start `FOR SHARE`
   → head. **After the locks:**
   - the actor is still an active admin of the tenant;
   - S is `:blocked`;
   - the latest start is the attested start, and belongs to the
     coordinator's boot (the b2α fence);
   - no other switch is open;
   - a unique conflict on `attestation_id` re-runs step 3.

   Any failure rolls back with its typed refusal.

## 3. What the attestation covers

**The covered range** is every `ModelServerStart` of the tenant with
generation in `[S.server_generation, attested_generation]`: the old
server, the candidate and the rollback when allocated, and any start
allocated after S blocked. A start allocated after the commit is outside
the range. Its own lifecycle proves its cleanup.

**The statement shown by R0-05, which the admin confirms:**
> No Claude CLI process started by any server in this range is still
> running, except work owned by the current held server's own live
> reaper. I checked this myself.

**The current server's work is excluded, not attested.** A `:survivor`'s
work is owned by its live reaper, which is confirmed tracking. Admission
`:open` doesn't mean no in-flight work (`claude_cli.ex`), which is why
the work is excluded.
- **Stopping it later:** this needs b2α's bound stop protocol with a
  fresh receipt.
- **If it or its reaper dies without a receipt, at any time (including
  during a lock wait):** this attestation grants nothing. The resolution
  records `attested_lease_holder = nil` for `:survivor`, and R needs an
  exact holder. The newly dead lease is a **hard conflict** (section 5).

**Never proof:** an absent lease, a dead holder alone, a scan, stored
pid text alone, or a healthy new server.

## 4. The write, and the α finalizers (MF7)

`ModelProfileSwitch.resolve_blocked`:
- `status` becomes `:failed`. `finished_at` and `resolved_at` are both
  set to the commit-time clock value.
- `failure_reason` keeps the block's reason. The chain shows
  `switch_blocked`, then `switch_resolved`.
- **Kept:** `from_profile_id`, `to_profile_id`, `server_generation`,
  `requested_by_id`, `requested_at`.
- **Set:**
  - `resolution: :owner_attested`;
  - `resolved_by_id`;
  - `attestation_id`;
  - `attested_start_id`;
  - `attested_generation`;
  - `attested_lease_name` and `attested_lease_holder`, set only for a
    dead-holder attestation.
- **The setting** row and revision aren't written. The event reports the
  stored revision.
- **The event `model.profile.switch_resolved`** has closed metadata:
  switch, tenant, `attestation_id`, the covered generations `[first,
  last]`, the lease kind (`none | survivor | dead_holder`), outcome,
  `resolution` and the block's reason. No confirmation text, pids or refs.

**The α finalizers keep their accepted behavior:**
- **`complete`** on a blocked switch is still refused
  (`:switch_blocked`).
- **`fail`** on a blocked switch is still refused (`:switch_blocked`).
  `fail` on a **resolved** switch is refused as
  `:switch_already_finished`, never a `fail` replay. This is a narrow α
  delta. A resolved S is `:failed`, so α's `decide/2` would otherwise
  read it as a replay of its own `fail`.
- **`block`** on a switch already blocked, by the current owner, still
  returns α's valid **no-write replay** (`ProfileSwitches.decide/2`).
- **A direct, unphased action** is still refused.
- `resolve_blocked` never produces `:ready` evidence, and never counts as
  an adopted or preflighted start.

## 5. The cleanup authority R, and the hard conflict

R is the **only** new permission to call `Reaper.release/1`. It is
derived each time from durable rows plus a live observation, never
cached, and never carried by a replay.

**R holds** only when all of these are true, read fresh from the
database and observed live:
1. the tenant's newest switch is a resolved S with
   `attested_lease_holder` set;
2. no switch is open;
3. the tenant's latest start is still `S.attested_start_id`, so nothing
   has been allocated since the resolution;
4. the lease `S.attested_lease_name` is held by a **dead** pid whose
   `inspect/1` equals `S.attested_lease_holder`;
5. no live named server exists.

**Why the pid text binds.** A lease lives in `:persistent_term`, so it
is local to the VM and gone after a VM restart; R is then false (no
lease). Within the VM, every ClaudeCLI server under the coordinator's
name, and so every reaper that can take that lease, is started only by
the coordinator after an allocation (the b2α invariant: "no server is
started except through the allocator"). The calibration console runs its
own VM, with its own `:persistent_term`. So condition 3, no allocation
since the resolution, proves that no new reaper has taken the lease
since the admin's observation, and the same text names the same dead
process. A different holder fails condition 4. A holder that has only
just died has text no attestation recorded, because a `:survivor`
records nil.

**When R is evaluated, and what it does:**
- **When:**
  - right after the commit, in the same coordinator, which also checks
    that the holder is still exactly the private pid it observed before
    the commit;
  - at every boot, **before its first allocation**, because that
    allocation would end R;
  - on the reconcile tick while the server is held.
- **What it does:** when R holds, it calls `Reaper.release(name)` once.
  On `:ok`, the coordinator continues with b2α's no-open-switch path, a
  fresh held `:replacement` start. Anything else keeps the server held.
- **The boot step is new.** α's boot never releases a lease. b2β adds
  this read-only evaluation, plus the single release, before the first
  allocation. It is not ordinary α reconciliation.

**Lifetime and consumption.** R ends at:
- the first start allocated after the resolution (the latest start moves
  on, and generations never go back);
- a new open switch;
- the lease's absence.

An ended R never comes back, because each of those conditions is
monotone: generations only grow, and a switch once opened is newer than
S. R can't clear:
- a later runtime's lease;
- a survivor's lease;
- a lease after a VM restart.

**The hard conflict.** The server is held with no open switch, and the
lease is held by a dead process that R doesn't match. Examples:
- a survivor or its reaper died without a receipt;
- the lease holder changed;
- a crash left a state R can't prove.

In that case:
- the coordinator stays held and publishes `stage: :cleanup_unprovable`
  in `status/0`;
- nothing in b2β releases it;
- its exit is the **existing operator path**: an operator's own
  `Reaper.release/1` from a console after checking the machine, as in
  b2α when a reaper dies without any switch. That path is unchanged.

Whether R0-05 needs an attended action for this state is **OQ-5**, for
the owner. This replaces draft 2's unsupported claim that another
decision is needed only for a new blocked switch.

**A new request during recovery.** The coordinator is busy while R runs,
so it refuses `request_switch/2` in that window. A switch opened by any
other path makes R false (condition 2), and the server stays held. An
old tick re-reads every condition, so it can't act on newer work.

## 6. Crash and outcome table

| Point | Durable state | Next | Hold |
|---|---|---|---|
| expired on dequeue, or refused in section 2 | unchanged | the typed refusal | kept |
| a death or a spent budget before the commit | rolled back | S is still blocked at the next boot | kept |
| **an unknown commit** (`:ledger_timeout`, a connection error) | unknown | Nothing else until one bounded stored read by `attestation_id`. **Resolved:** R. **Blocked:** `:resolve_timeout`. **Unreadable:** `:resolve_uncertain`; the tick re-reads by the same target | kept |
| committed, the admin's reply lost | S `:failed` | the caller settles by stored read (section 1) | kept |
| committed, a coordinator death before R | S `:failed` | the next boot evaluates R before its first allocation | kept |
| R released the lease, then a death before the allocation | S `:failed`, no lease | the next boot finds R false (no lease) and takes b2α's no-open-switch path | kept |
| after the allocation, or a spawn, then a death before the release | the start is `:allocated`, `:started` or `:failed` | R is consumed; b2α's boot and reconciliation | kept |
| the fresh start or its preflight fails | the start is `:failed` | b2α's replacement retry | kept |
| the lease holder changes, comes alive, or a survivor dies without a receipt | S `:failed` | R is false → the hard conflict (section 5) | kept |
| a new switch opens before R runs | a new open switch | R is false; b2α's rules for the new switch | kept |
| reconciliation unknown | S `:failed` | retried on the tick | kept |
| a ready `:replacement` or `:boot` start at the desired profile, with no open switch | S `:failed` | b2α's normal release branch | **released** |

## 7. The proposed ADR-0004 C2-02b2β amendment (substantive)

Decision 5 of the b2α amendment (`Reaper.release/1` is never called) and
decision 6 (a blocked switch has no exit) are changed. The proposed
amendment is in `docs/adr/0004-model-provider.md`, status **proposed**,
and needs the owner's acceptance before implementation approval. No new
ADR number is needed. ADR-0005's calibration recovery is precedent only;
none of its attestations authorize anything here.

Its decisions:
1. **The only exit from blocked** is the attended resolver, to `:failed`.
   An active human admin decides (OQ-2), and the registered coordinator
   executes it with a typed attestation.
2. **The binding:** switch, tenant, the covered start range, the
   observed lease state and the outcome. It is replay-idempotent by id,
   and a replay authorizes nothing new.
3. **A narrow exception to decision 5:** `Reaper.release/1` only under R
   (section 5): a dead holder exactly equal to the attested one, with no
   start allocated since and no switch opened, evaluated after the commit
   or before a boot's first allocation. Otherwise decision 5 stands.
4. **The current server's work** is never attested. Stopping it needs a
   fresh receipt. Unprovable cleanup is a held hard conflict with the
   existing operator path.
5. **Unknown outcomes** stay held. Only b2α's reconciliation releases the
   hold.
6. **Unchanged:** `complete` and `fail` refuse blocked; `block` keeps its
   no-write replay; the lock order, the Fake default and the call grants.
   One narrow α delta: `fail` on a resolved switch is refused, never read
   as a replay.

## Entity Model

**Entity Model trigger:** yes. It covers:
- a new lifecycle transition (blocked → failed);
- new attributes and relationships (to User and to ModelServerStart);
- a new event;
- a new authorization path (a human admin, executed in the
  coordinator);
- a new runtime authority over the Reaper lease (R).

| Entity | New / Existing | Purpose | Attributes | Relationships | Invariants / Lifecycle | Policy/Actor | Open Questions |
|---|---|---|---|---|---|---|---|
| ModelProfileSwitch | Existing (delta) | One requested change | **Added, all nullable:** `resolution : :owner_attested`; `resolved_by_id : uuid`; `resolved_at : utc_datetime_usec`; `attestation_id : uuid`, unique `(tenant_id, attestation_id)` where not null; `attested_start_id : uuid`; `attested_generation : int ≥ 1`; `attested_lease_name : string ≤ 255`; `attested_lease_holder : string ≤ 64`. **Checks:** (a) the first six are all null or all set, and when set, `status = 'failed'`, `resolved_at = finished_at`, and `attested_generation >= server_generation`; (b) the two lease fields are both null or both set, and set only with `resolution`. Existing attributes and the request history are immutable and unchanged | **Added:** belongs_to `resolved_by` (User; set exactly with `resolution`; `on_delete: :restrict`; the same tenant and the current admin role are enforced by the action after the locks, as for `requested_by`); belongs_to `attested_start` (ModelServerStart; composite FK `(tenant_id, attested_start_id)`; `on_delete: :restrict`) | **New transition:** blocked → failed, by `resolve_blocked` only. `complete` and `fail` still refuse blocked. `block`'s no-write replay is kept. `fail` on a resolved switch is refused. `failure_reason` is kept. Replay is by `attestation_id` with an identical semantic identity, anything else being `:attestation_conflict`. R (section 5) is derived from these fields, consumed by the next allocation or the next open switch, and never revived | `resolve_blocked`: a new check `Checks.ResolveContext`, which needs the registered coordinator **process** (the process-only helper factored out of `Checks.CoordinatorProcess`, whose `model_runtime` rule is unchanged) **and** an active human admin re-read, in a new `ProfileSwitchContext` phase `:resolve`. `model_runtime` gains nothing. `blocked_switch_facts` is admin-only. Reads are otherwise unchanged | OQ-5 |
| User | Existing (delta: referenced) | A person | unchanged | **Added inverse:** referenced by 0..n switches as `resolved_by`; each resolution has exactly one resolver; restrict on delete | unchanged. The resolver may be the requester, but the two are recorded separately | unchanged | none |
| ModelServerStart | Existing (delta: referenced) | One start attempt | unchanged | **Added inverse:** referenced by 0..n switches as `attested_start` (composite FK); restrict on delete; starts are never destroyed | unchanged. The resolver reads the latest start `FOR SHARE` and never writes it. A covered start's recorded `reaper_pid` and `node` bind a dead-holder attestation (section 2.4). Its generation order makes R's consumption monotone | unchanged | none |
| Coordinator (runtime) | Existing (delta) | Owns the server lifecycle | **Added:** `resolution_facts/2` (read-only); `resolve_blocked/2` (deadline-stamped); R's evaluation (after the commit, at boot before the first allocation, and on the tick); the `stage: :cleanup_unprovable` status | — | It refuses expired or busy requests. It binds its boot, its latest start, an acknowledged hold and the observed holder. An unknown commit gets a stored read first. It releases the hold only through b2α's reconciliation. No model call | called with the admin's actor; the write's actor is the admin | none |
| ClaudeCLI.Reaper (runtime) | Existing (usage delta) | Crash-safe owner of CLI work | unchanged | — | `release/1` is called by the coordinator **only** when R holds (all five conditions, section 5), once per evaluation. It is invalid after any allocation or open switch since the resolution, or when the holder differs or is alive. The operator path is unchanged | coordinator (under R); operator (existing) | none |

ModelProfileSetting: existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found.
ModelServerCounter: existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found.

## 8. Tests (RED first)

Files: `test/sdr_agent/agents/profile_switch_resolve_test.exs`,
`profile_switch_resolve_race_test.exs` (independent connections, joined
workers) and `test/sdr_agent/ai/profile_coordinator_resolve_test.exs`.
Each sets up a real blocked S through the b2α coordinator, never by a raw
write. Zero model calls, no spend, and never the calibration or dev
database.

**Domain and policy:**
1. **Happy path for each lease state** (`:none`, `:survivor`, dead
   holder): blocked → failed; the reason and request provenance kept; the
   resolution fields set, with `resolved_at = finished_at`;
   `switch_resolved` after `switch_blocked` with closed metadata; the
   setting revision unchanged; the result shape as in section 1.
2. **The shape:** a wrong, mis-cased, padded or missing confirmation;
   another switch's id; a non-`:failed` outcome; an extra field; a bad
   lease shape → `:attestation_invalid`.
3. **Actors:** each refused actor in section 2, step 1. An admin demoted
   or disabled before the call, and between dispatch and commit. Allow
   and deny pairs.
4. **The process:** a direct Ash `resolve_blocked` outside the
   coordinator is forbidden, even for an admin. `model_runtime` gains no
   action.
5. **The state:** pending, completed and failed → `:switch_not_blocked`,
   with the history unchanged.
6. **α finalizers (MF7):**
   - `complete` and `fail` on blocked S are refused (`:switch_blocked`);
   - the current owner's `block` on blocked S is a no-write replay, with
     no second event;
   - `fail` on resolved S → `:switch_already_finished`, never a replay;
   - direct unphased actions are refused.
7. **Replay precedence:**
   - an exact replay right after the resolution;
   - an exact replay after a later start, a later boot and a new switch,
     with no write, event, release, start or hold change;
   - the same id from another admin, on another switch, or with another
     fact → `:attestation_conflict`;
   - a different id on resolved S → `:switch_not_blocked`.
8. **Staleness:**
   - a start allocated after the facts read → `:stale_attestation`;
   - a start allocated while the write waits on the setting lock
     (independent connection) → refused after the locks.
9. **Concurrency:**
   - two different ids → exactly one commits;
   - two identical requests → one commit and one replay;
   - one event either way.
10. **Tenancy:** another tenant's switch → not found.
11. **The slot:** a new `request` succeeds after the resolution.

**Coordinator and runtime:**
12. **Lease states:**
    - a live holder with no server;
    - a holder that isn't the server's own reaper;
    - a dead holder recorded by no covered start;
    - blocked admission.

    Each → `:live_work_observed`, with the confirmation present. An
    attested-state mismatch → `:stale_attestation`.
13. **Observation:** observation faults (test-only) and an
    unacknowledged hold → `:observation_unknown`.
14. **Busy:** during a worker, a block retry, a reconciliation or R →
    `:coordinator_busy`. `request_switch/2` is refused while R runs.
15. **The deadline:**
    - a request expired in a blocked mailbox does nothing;
    - a pool or setting-lock wait that crosses the deadline doesn't
      commit;
    - a caller timeout reports `:resolve_uncertain` and settles by stored
      read;
    - a lost commit reply settles as a replay;
    - held calls are refused throughout.
16. **R after the commit:** `release/1` runs once; a fresh held
    `:replacement` start at `from` reaches ready; then the release; zero
    launches.
17. **R refuses** (`release/1` uncalled, the server held,
    `stage: :cleanup_unprovable` where it applies):
    - the holder changed;
    - the holder alive;
    - a newer start;
    - a new switch open;
    - a survivor whose server and reaper later die without a receipt,
      including during the write's lock wait;
    - the holder replaced between the pre-commit observation and the
      post-commit check.
18. **Crashes:**
    - a kill after the commit and before R → the next boot runs R before
      its first allocation, then readiness;
    - a kill after the release and before the allocation → b2α's path;
    - a kill after the allocation → R consumed;
    - a kill before the commit → S blocked and held;
    - an unknown commit → a stored read before anything else.
19. **Rollback:** a forced failure at the pre-commit step leaves S
    blocked, the lease intact, the server held and `release/1` uncalled.
20. **Held refusals:** ordinary, prepared and direct-pid calls are
    refused throughout.

## Open questions

- **OQ-1 (accepted by Codex):** no durable late receipt and no automatic
  exit from one.
- **OQ-2 (for the owner, in the ADR amendment):** any active human admin
  resolves, named as `resolved_by`.
- **OQ-3 (acceptable with the section 1 semantics):** 15 s is the
  decision and admission budget only. Runtime recovery has b2α's bounds,
  and readiness isn't promised within it.
- **OQ-4 (narrowed, for Codex and the owner):** the `Reaper.release/1`
  exception is bound by R's five conditions.
- **OQ-5 (for the owner):** does R0-05 need an attended action for the
  hard conflict (`:cleanup_unprovable`)? **Recommendation: not for R0.**
  It needs a reaper to die without a receipt and with no switch, which
  b2α already leaves to the operator path.

## R0-05 obligations (recorded, not built)

- Show `blocked_switch_facts`: every covered start with its recorded
  identity, and the observed lease state.
- Show the section 3 statement and collect the typed confirmation.
- Report "committed, not ready" truthfully.
- Show `:cleanup_unprovable`.
