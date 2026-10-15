# C2-02b2β interface: the attended resolver for a blocked switch

**Status:** draft 2, 2026-10-15, for Codex's interface and entity review.
Draft 2 folds in Codex's advisory pre-read (`codex-c202b2beta-22db5c0-preread.md`):
the covered runtimes (1c), the deadline (1d), the crash and outcome table
(2a), the unchanged α finalizers (1b), and `Reaper.release/1` as OQ-4.
Slice plan: `c2-02-slices.md` (b2β, about 1 day). Builds on b2α
(`c2-02b2-interface.md`, merged at `22db5c0`).

## 0. Scope

b2α blocks a switch S whenever an outcome can't be proven: an
unconfirmed cleanup, a worker or coordinator death, an uncertain
finalization, or a failed drain or veto. A blocked switch keeps the
server **held**, and has no exit (b2α section 2a: "S `:blocked` → kept,
b2β owns the exit"). It also occupies the tenant's single open-switch
slot, so no further switch can be requested.

b2β adds **one** exit, attended and fail-closed:

- **blocked → failed**, by an active human admin, through the registered
  coordinator, with an explicit owner attestation bound to the switch,
  the tenant, the prior runtime identity and the outcome.
- The setting is unchanged, because a blocked switch never applied it.
  After the resolution, the coordinator's normal reconciliation brings the
  server back at the desired profile (the switch's `from`). The hold is
  released only through that reconciliation, never by the resolution
  itself.

**Not in b2β:**
- **blocked → completed.** The outcome is always `:failed`. Completing a
  blocked switch would need activation proof (a `:ready` `:spawn_preflight`
  activation start for S) that a blocked switch, by construction, doesn't
  have. The admin can request the switch again afterwards.
- **An automatic exit.** Neither a late receipt nor a timer, a restart or
  a process scan resolves S.
- **UI.** R0-05 adds the admin page. b2β is the domain and runtime API
  only.

**Why attestation, not a receipt:** the b2α receipt is in-memory,
single-use and bound to one stop (b2α section 3). Most block reasons
have no stop at all (operation_died, coordinator_restarted,
finalization_uncertain, a drain or veto failure). After a restart, no
receipt can exist for the earlier boot. OQ-3 (b2α) allows "the bound
cleanup receipt, **or** an explicit owner attestation". b2β takes the
attestation as the single proof, and keeps late receipts diagnostic only
(OQ-1 below).

## 1. The attestation

`Agents.resolve_blocked_switch(switch, attestation, opts)`, called with
the admin as actor. It runs **in the coordinator**
(`Coordinator.resolve_blocked/3`, a synchronous call bounded at 15 s),
like every b2 switch write. The coordinator checks the attestation and
performs the write as one bounded `LedgerCall`. The write's actor is the
admin.

`attestation` is a closed map:

| Field | Type | Meaning |
|---|---|---|
| `attestation_id` | uuid | Client-generated; the idempotency key |
| `switch_id` | uuid | Must equal S's id |
| `attested_start_id` | uuid | The latest `ModelServerStart` the admin saw for the tenant (the "prior runtime identity") |
| `attested_generation` | int ≥ 1 | That start's generation |
| `outcome` | `:failed` | The only accepted value |
| `confirmation` | string | Exactly `STOPPED <switch_id>` (the ADR-0005 recovery pattern) |

The attested start must be the tenant's latest start, read under lock in
the write (stale → `{:error, :stale_attestation}`). Pids, node and reaper
are diagnostic identity; the admin sees them, but the binding is the
start's id and generation, which are durable and never reused (b2α
section 1).

**Meaning of the attestation, stated in the confirmation text that R0-05
shows:** "No Claude CLI process from an earlier server of this tenant, or
from this switch's candidate or rollback, is still running. I checked
this myself." Work owned by the **current** server's own live reaper is
not covered. That is confirmed tracking, not orphaned work, and check
1a.4 requires it to be exactly that. The admin attests to stopped work;
they don't attest to success.

### 1a. Checks, in order, all before any write

1. **Actor:** an active human admin, with the role re-read in the
   transaction (as `request`). Reviewers, auditors, `model_runtime`,
   `agent_runtime` and kernel are refused.
2. **Shape:** a closed map; `outcome == :failed`; `confirmation` is
   exactly `"STOPPED " <> switch_id`, with no trimming or case folding.
   Anything else is refused with `{:error, :attestation_invalid}`.
3. **Coordinator stage:** the coordinator is idle for S. That means no
   worker is running and no block retry or reconciliation is in flight;
   otherwise `{:error, :coordinator_busy}`, with no write.
4. **Live presence refuses; absence never permits.** The coordinator
   observes the named server, its published reaper and the named lease:
   - **A live named server:** its `admission/1` must be `:open` (any
     `:blocked` reason means unconfirmed or live CLI work), and the lease
     holder must be **exactly** its own published reaper (`reaper/1`).
     This is b2α's stage-3 veto check.
   - **No live named server:** the lease must be absent, or held by a
     **dead** holder (released after the commit, section 2). A **live**
     holder with no server means a cleanup is still running.
   - **Refusal:** anything else is `{:error, :live_work_observed}`.
   - **Unknown:** a failed or timed-out observation is
     `{:error, :observation_unknown}`.

   Either one refuses, even with the confirmation. This is the ADR-0005
   rule ("live work seen through the probe refuses even with `STOPPED`; a
   probe error is never read as absence"). A scan is never proof of
   absence.
5. **In the write**, with lock order setting → counter `FOR SHARE` →
   switch → latest start `FOR SHARE` → head (b2α 1b, no new lock):
   - S is the tenant's, and `:blocked` (otherwise `:switch_not_blocked`,
     no relabel);
   - the latest start is the attested start id and generation (otherwise
     `:stale_attestation`);
   - an earlier resolution with the same `attestation_id` and identical
     facts is a no-write replay that returns the stored switch. The same
     id with different facts is `{:error, :attestation_conflict}`.

### 1c. What the attestation covers

The attestation covers a **closed range of starts**: every
`ModelServerStart` of the tenant with generation in
`[S.server_generation, attested_generation]`. That range contains every
runtime that can have run CLI work for S:
- the old server (the start current at the request,
  `S.server_generation`);
- the candidate (`:activation` for S), if one was allocated;
- the rollback (`:rollback` for S), if one was allocated;
- any `:replacement` or `:boot` start allocated after S was blocked, for
  example by a coordinator restart while S stayed blocked.

How these starts are bound:
- **Stored with the resolution:** both ends of the range, in the event
  (`covered_generations: [first, last]`).
- **No start after the attestation:** the stale check (1a.5) proves that
  no start was allocated after the attested one, and the write holds the
  latest start `FOR SHARE`.
- **Starts after the commit:** the fresh start the coordinator makes
  later (section 2) is outside the range. It is a new held start with its
  own lifecycle and cleanup, and needs no attestation.
- **Starts the admin never saw:** if a start in the range has `:started`
  identity (pid, node, reaper) that the admin didn't see, the write still
  binds only by id and generation. R0-05 must show every start in the
  range, which is a UI obligation recorded for R0-05.

**What is never proof:** an absent lease, a dead holder, a scan, stored
pid text, or a healthy new server. Each of these can only refuse (1a.4);
none of them permits.

### 1d. The deadline

One monotonic deadline of 15 s, pinned when the coordinator receives the
call, covers:
- the busy check;
- the presence observation;
- the single `LedgerCall`, whose budget is the remaining time, at most
  2 s.

Nothing restarts or extends it. When it is spent before the commit, the
call returns `{:error, :resolve_timeout}` and nothing is written. When the
reply to the admin is lost after the commit, the retry is a replay
(1a.5). The post-commit reconciliation (section 2) keeps b2α's own
bounds, and any failure there leaves the server held.

### 1b. The write: `ModelProfileSwitch.resolve_blocked`

- `status` becomes `:failed`, and `finished_at` is set.
- `failure_reason` keeps the block's reason. History is never
  relabelled: the event chain shows `switch_blocked`, then
  `switch_resolved`.
- New attributes are set: `resolved_by_id`, `resolved_at`,
  `resolution: :owner_attested`, `attestation_id`, `attested_start_id`.
- The event `model.profile.switch_resolved` is appended. Its metadata is
  closed: switch, tenant, `attestation_id`, `attested_start_id`,
  `attested_generation`, outcome `failed`, `resolution: owner_attested`
  and the block's reason. The confirmation text and pids are not stored.
- The one-open index frees the slot, so a new `request` is possible.
- **Kept as recorded:** `from_profile_id`, `to_profile_id`,
  `server_generation`, `requested_by_id` and `requested_at`. The
  resolution's provenance (`resolved_by_id`, `resolved_at`) is separate
  from the request's.
- **The setting:** its row and revision are not written. The event
  reports the stored setting revision, as every switch event does
  (`ProfileSwitchEvent`).
- **The α finalizers are unchanged.** `complete`, `fail` and `block`
  still accept only a pending switch (`ProfileSwitchGuard`), so a blocked
  switch is refused by all three (RED test 6a). `resolve_blocked` is the
  only action that moves a blocked switch. It never produces `:ready`
  evidence, and never counts as an adopted or preflighted start.

## 2. After the commit: reconciliation, then release

The resolution commits first. Every runtime effect follows the commit,
in the coordinator, outside any transaction (b2a: "no `Reaper.release`
side effect inside a transaction that might roll back").

1. **Leases.** A named lease whose holder is **dead** may now be released
   with `Reaper.release/1`. This is that function's documented purpose:
   "operator release of a lease left by a reaper that died without its
   cleanup receipt". The release is covered by this attestation only:
   - **When:** only after the commit, and only for the lease name of the
     attested start's server.
   - **Refusal:** `{:error, :reaper_running}` keeps the server held and is
     retried on the coordinator's tick. A live reaper is never forced.
2. **The server.** With no open switch now, the coordinator runs exactly
   b2α's restart reconciliation for "no open switch" (section 2a):
   - **adopt** the survivor only if it is the exact `ServerSupervisor`
     child, at the desired profile, with its own live reaper lease (hold,
     `:replacement` start, `:adopted`);
   - **otherwise** run the bound stop protocol with its receipt, then a
     fresh held `:replacement` start at the desired profile, the no-call
     preflight, and `:ready`;
   - **an unknown observation** stays held.
3. **The release.** The normal release branch of the reconciliation
   table: no pending or blocked switch, and a ready `:boot` or
   `:replacement` start of this boot at the desired profile, on the held
   pid, with its reaper observed.

**Crashes:**
- **A coordinator death after the commit:** S is `:failed` and no switch
  is open, so the new boot takes the normal path (2a), adopting or
  replacing.
- **A coordinator death before the commit:** the transaction rolls back.
  S stays `:blocked`, and the new boot keeps the hold.
- **A lost reply to the admin:** the retry with the same `attestation_id`
  is a replay (1a.5).

No step makes a model call.

### 2a. Crash and outcome table

| Point | Durable state | Next coordinator or caller | Hold |
|---|---|---|---|
| before the call reaches the coordinator | S `:blocked` | nothing; the admin may retry | kept |
| refused at 1a.1–1a.4 | unchanged | the typed refusal; nothing is written | kept |
| a death or spent deadline inside the `LedgerCall` before commit | unchanged (rolled back) | S is still blocked at the next boot | kept |
| committed; the reply was lost | S `:failed`, with the resolution and its event | an admin retry with the same `attestation_id` is a no-write replay; a different id → `:switch_not_blocked` | kept until 2 below |
| committed; a coordinator death before the lease release | S `:failed` | the new boot takes b2α's no-open-switch path. A dead-holder lease of a covered start is released only if the committed resolution covers that start (OQ-4) | kept until a ready start |
| a lease whose holder is alive after the commit | S `:failed` | `{:error, :reaper_running}`; retried on the tick; never forced | kept |
| the fresh start or its preflight fails | S `:failed`; the start is `:failed` | b2α's replacement retry | kept |
| reconciliation is unknown | S `:failed` | retried on the tick | kept |
| a ready `:replacement` or `:boot` start at the desired profile, with no open switch | S `:failed` | b2α's normal release branch | **released** |

Another attended decision is needed only when a new switch blocks.
Nothing in this table re-blocks S, or moves it again.

## 3. ADR evaluation

The b2α ADR-0004 amendment (accepted 2026-10-15, D-131) already states
that "a blocked switch has no exit until slice b2β's attended resolver".
b2β implements that exit within the accepted coordinator pattern. It
reuses ADR-0005's attended-recovery rules (the typed confirmation; live
work refuses; a probe error is not absence) and ADR-0009's audit coupling
(an audited action and event; no raw write).

**Recommendation: no new ADR.** A one-line wording update in ADR-0004's
b2 amendment would replace "no exit until b2β" with "exit only through
the attended resolver (owner attestation, blocked → failed)". It doesn't
change any decision, so it is a documentation sync, not a new decision.
Codex to confirm.

## Entity Model

**Entity Model trigger:** yes. It covers a new action and lifecycle
transition (blocked → failed) on an existing persisted resource, new
persisted attributes, a new relationship (switch → attested start), a
new event, and a new authorization path (a human admin, executed in the
coordinator).

| Entity | New / Existing | Purpose | Attributes | Relationships | Invariants / Lifecycle | Policy/Actor | Open Questions |
|---|---|---|---|---|---|---|---|
| ModelProfileSwitch | Existing (delta) | One requested change | **Added:** `resolution : :owner_attested, nullable`; `resolved_by_id : uuid, nullable`; `resolved_at : utc_datetime_usec, nullable`; `attestation_id : uuid, nullable`, unique `(tenant_id, attestation_id)` where not null; `attested_start_id : uuid, nullable`. **Check constraint:** these five are all null or all set; when set, `status = 'failed'`. Existing attributes are unchanged | **Added:** belongs_to `resolved_by` (User, optional, `on_delete: :restrict`); belongs_to `attested_start` (ModelServerStart, optional, same tenant, `on_delete: :restrict`) | **New transition:** blocked → failed (`resolve_blocked`), and only from `:blocked`. `failure_reason` is kept, `finished_at` is set, and the event `model.profile.switch_resolved` is appended (closed metadata, 1b). Terminal states are unchanged (completed, failed). No blocked → completed. No other new transition. Replay is by `attestation_id` with identical facts; conflicting facts are an error | `resolve_blocked`: an active human admin (role re-read), executed only by the registered coordinator (`Checks.CoordinatorProcess`) in a new `ProfileSwitchContext` phase `:resolve`. Reads are unchanged | OQ-1, OQ-2 |
| ModelServerStart | Existing (delta: referenced) | One server start attempt | unchanged | **Added inverse:** is referenced by ModelProfileSwitch `attested_start` (0..n switches per start; restrict on delete; starts are never destroyed) | unchanged. The attestation reads the latest start `FOR SHARE` and never writes it | unchanged | none |
| Coordinator (runtime) | Existing (delta) | Owns the server lifecycle | **Added:** `resolve_blocked/3` (synchronous, 15 s bound) | — | It runs the checks 1a.1–4 before the write, and refuses while busy. After the commit: dead-holder lease release, then the 2a "no open switch" reconciliation, then the normal release. It never releases the hold from the resolution itself. No model call | Called with the admin's actor; the write's actor is the admin | none |
| ClaudeCLI.Reaper (runtime) | Existing (usage delta) | Crash-safe owner of CLI work | unchanged | — | `release/1` is called for the first time from the coordinator, only after a committed resolution and only for a dead holder. `{:error, :reaper_running}` → stay held | coordinator only | none |

ModelProfileSetting: existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found.
ModelServerCounter: existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found.

## 4. Tests (RED first)

New files: `test/sdr_agent/agents/profile_switch_resolve_test.exs`
(domain) and `test/sdr_agent/ai/profile_coordinator_resolve_test.exs`
(runtime). Each test sets up a real blocked S through the b2α coordinator
(for example a worker death → `operation_died`, or a missing receipt →
`old_cleanup_unconfirmed`), never by a raw write.

**Domain and policy:**
1. **Happy path:** an admin with a valid attestation moves blocked →
   failed. `failure_reason` is kept; the five resolution fields are set;
   `switch_resolved` follows `switch_blocked` in the chain with closed
   metadata; the setting revision is unchanged.
2. **The confirmation:** wrong text, wrong case, extra whitespace,
   another switch's id, or missing → `:attestation_invalid`, no write, no
   event.
3. **`outcome`** other than `:failed`, or an extra field →
   `:attestation_invalid`.
4. **Actors:** reviewer, auditor, `model_runtime`, `agent_runtime`,
   kernel, and an admin whose role was revoked before the call
   (re-read) → forbidden. Allow and deny pairs.
5. **The process:** a direct Ash `resolve_blocked` outside the registered
   coordinator is forbidden, even for an admin.
6. **The state:** pending, completed and failed switches →
   `:switch_not_blocked`; the history is unchanged.
6a. **The α finalizers refuse blocked:** `complete`, `fail` and `block`
    on a blocked switch are refused through the coordinator and as
    direct actions; nothing is written.
7. **Staleness:** a newer start allocated after the admin's read →
   `:stale_attestation`, no write.
8. **Replay:** the same `attestation_id` with the same facts returns the
   stored switch with no second event. The same id with a different
   start → `:attestation_conflict`.
9. **Concurrency:** two resolutions of S with different ids → exactly
   one commits, and the other gets `:switch_not_blocked`.
10. **Tenancy:** another tenant's switch → not found.
11. **The slot:** after the resolution, a new `request` for the tenant
    succeeds.

**Runtime:**
12. **Live presence refuses**, with the confirmation present: a live
    server whose admission is blocked; a lease held by a live process that
    isn't the server's own reaper; a live holder with no server (cleanup
    still running). Each → `:live_work_observed`; S stays blocked and held.
    **Allowed:** a live idle survivor whose lease is held by its own
    reaper.
13. **An observation fault** (a test-only fault) →
    `:observation_unknown`, with no write.
14. **Busy:** a resolution during a block retry or reconciliation →
    `:coordinator_busy`.
15. **After the commit, a dead-holder lease:** `Reaper.release/1` runs
    once, after the commit. A fresh held `:replacement` start at `from`
    reaches ready through the preflight, and the hold is released; zero
    model launches.
16. **Rollback leaves the lease:** a forced write failure (a test-only
    fault at the pre-commit step) leaves S blocked, the lease intact, the
    server held, and `release/1` uncalled.
17. **A live reaper after the commit:** `{:error, :reaper_running}`
    keeps the server held, and a later tick retries; the hold is never
    released before a ready start.
18. **Adoption after the resolution:** the exact supervised child at the
    desired profile with its own live lease is adopted (`:adopted`);
    otherwise it is stopped with the bound protocol and replaced.
19. **Crashes:** a coordinator kill after the commit → the new boot takes
    the normal path and releases after a ready start. A kill before the
    commit → S is still blocked and the server held.
20. **No model call:** the launch counter stays zero across 12–19.

## Open questions

- **OQ-1, late receipts.** Should a receipt that arrives after the 10 s
  bound be recorded durably, as diagnostic evidence shown to the admin?
  **Recommendation: no, not in b2β.** It would need a new event and the
  receipt kept beyond its single use. It is diagnostic only either way.
  Revisit at R0-05 if the page needs it.
- **OQ-2, who attests.** In the single-owner MVP the admin is the owner.
  Should the resolver require the tenant owner specifically, or any
  active admin? **Recommendation: any active human admin, role re-read**,
  as `request` is today; the attestation names them (`resolved_by_id`).
- **OQ-4, `Reaper.release/1`.** b2α never calls it. b2β calls it only
  after a committed resolution whose covered range includes the lease's
  start, and only for a **dead** holder. This is the function's documented
  operator purpose, and it is attended rather than automatic.
  **Recommendation: allow it, as stated.** The alternative is a separate
  console command for the owner, which adds a manual step that proves
  nothing more. Codex to rule.
- **OQ-3, the 15 s bound.** The same bound as the hold acknowledgement in
  b2α. Codex to confirm that it covers the presence checks plus one
  `LedgerCall` (≤ 2 s).
