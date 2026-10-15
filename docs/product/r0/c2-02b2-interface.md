# C2-02b2 (#52, slice b2): activation, rollback and the blocked-switch resolver (draft 1)

**Status:** draft 1, 2026-10-15, for Codex's review. No code.
- **Builds on:** slice a (`2590693`, PR #159) and slice b1 (`5a234cf`,
  PR #160), both approved.
- **The b1 handoff it must honour** (`c2-02b1-interface.md`, "What
  drained means"):
  - a drained ledger is necessary, never sufficient;
  - b2 binds the exact server instance, its cleanup state and the Reaper
    lease outside every ledger lock, and treats any doubt as `block`;
  - nullable timeout counts are unknown, never clean.

**Scope** (`c2-02-slices.md`, row b2):
- coordinator and server-generation ownership and handoff;
- stopping the old server, starting the new profile, and the no-call
  preflight, all outside the setting and chain-head transactions;
- a short, generation-guarded `complete`;
- on a failure with clean work, restart the old profile and `fail`;
- with unconfirmed work or a held Reaper lease, `block`. Admission stays
  closed, and only the attended resolution leaves it: never an automatic
  unlock, and never a rollback over a held lease;
- `resolve_blocked`, deferred here by slice a.

**Safe exit:** still no UI. The coordinator is reachable only through its
own API in tests, and R0-05 adds the admin page. Nothing in production
requests a switch before R0-05. With no switch, the coordinator only owns
the one server it starts at boot, as `Runtime.children/0` does today.

## What exists today (facts this draft relies on)

- **One named ClaudeCLI server** (`ClaudeCLI.server/0`) is started by
  `Runtime.children/0` under the app supervisor (`:one_for_one`), with
  `profile: Runtime.desired_profile/0`. The profile is fixed for the
  server's life.
- **The Reaper lease** (`{Reaper, name}` in `:persistent_term`):
  - it is held by the running server's reaper;
  - on server death the reaper kills every tracked tree, then releases
    it;
  - a tree it can't confirm stopped, or an unidentified launch, keeps
    the lease held, and a dead reaper's lease stays held until an
    operator's `Reaper.release/1`;
  - a new server whose name's lease is held by another reaper starts with
    admission closed (`:previous_cli_not_quiescent` or
    `:previous_cleanup_unconfirmed`).
- **The CLI has no no-call probe** for its init attestation: model,
  version and tools are reported only by a session that also sends a
  request. Boot records the attestation `:pending`, checked at the first
  call.
- **The pinned CLI** is checked by `PinnedExecutable.check/1` (the exact
  recorded store path).

## The coordinator

`SdrAgent.AI.ModelProvider.ProfileCoordinator`: one GenServer, started by
`Runtime.children/0` in place of the bare server. It supervises the named
ClaudeCLI server itself, as a `DynamicSupervisor` child, and serializes
every switch: one at a time, with no switch work under a ledger lock.

- **Server generation.** The coordinator holds the current generation `G`:
  a positive integer, bumped on every server start it makes.
  - **At boot:** `G` = the tenant's highest stored
    `ModelProfileSwitch.server_generation` + 1, or 1 with none. **OQ-1**
    asks whether this is enough, or whether a persisted counter is needed
    before slice c.
  - **Each server start** records `{G, pid, profile}`. That is the bound
    instance the b1 handoff requires.
- **API** (proposed names):
  - `request_switch(to_profile_id, expected_revision, actor: admin)`:
    calls `Agents.request_profile_switch/2` with `server_generation: G`,
    then runs the switch below, asynchronously. It returns the pending
    switch, or the request's refusal;
  - `status/0`: the current `G`, the bound pid and profile, the open
    switch (if any), and the stage. Metadata only.
- **Actors:** the request is the admin's (role re-read, slice a). The
  drain runs as `agent_runtime`, and `complete`, `fail` and `block` as
  `model_runtime`, both of the tenant (the coordinator holds both, as the
  ClaudeCLI server holds `agent_runtime` for `admit_launch` today).

## The switch, step by step

Every step is outside the setting and chain-head transactions. Each
ledger write is one short slice-a or b1 action.

1. **Request** (admin). The fence closes on commit (b1).
2. **Drain** (`agent_runtime`): `drain_profile_switch(S, %{server_generation: G, timeout_ms: cli_timeout + 30_000})`.
   - `{:error, :drain_timeout, counts}` (counts possibly `nil`), or
     `:drain_observation_failed` or `:drain_settlement_failed`: go to
     **block** with that reason.
   - `:switch_not_open` or `:stale_server_generation`: stop. S was closed
     by someone else, or this coordinator is stale. Nothing is touched.
3. **Cleanup veto, part 1:** the old instance, before it is stopped, read
   outside any lock:
   - the bound pid is still the named server, alive, at generation `G`;
   - `ClaudeCLI.admission(pid)` is `:open`: no stuck or unconfirmed work
     of its own;
   - the lease is held by that server's own reaper.

   Any other answer (absent, a replaced pid, closed, unreadable,
   malformed): go to **block** with the observation as its reason.
4. **Stop the old server** (the coordinator terminates its child), then
   wait, bounded by **OQ-2**, for the old reaper's lease release.
   - **Released:** the old trees are confirmed gone (the reaper's own
     receipt).
   - **Still held** when the bound passes, or held by a dead reaper:
     **block** (`:old_cleanup_unconfirmed`). The old profile is **not**
     restarted, and nothing calls `Reaper.release/1`.
5. **Start the new server** (generation `G+1`, profile `to`). The no-call
   preflight then requires:
   - `PinnedExecutable.check/1` passes for the configured pin;
   - `ClaudeCLI.profile(pid) == to`;
   - `admission(pid)` is `:open`: it took the lease;
   - the attestation is `:pending` with the shim found (`command?`
     true).

   No model call is made. The first real call attests the model, version
   and tools, as today.
6. **Preflight passes:** `complete_profile_switch(S, %{server_generation: G})`
   (`model_runtime`). The setting is applied in the same transaction (slice
   a). The fence opens, and `G := G+1` is bound to the new pid.
7. **Preflight fails** (or the start fails):
   - stop the new server, wait for its lease release (as in step 4), and
     restart the old profile (generation `G+2`) with the same preflight;
   - **old preflight passes:** `fail_profile_switch(S, %{server_generation: G, failure_reason})`.
     The setting is unchanged and the fence opens;
   - **anything else** (the new server's cleanup unconfirmed, or the old
     profile's preflight failing): **block**.
8. **Block:** `block_profile_switch(S, %{server_generation: G, failure_reason})`.
   - Admission stays closed: the fence holds while S is blocked (b1).
   - No server is restarted over a held lease.
   - The coordinator stays in `:blocked` until the resolver runs.

**Generation guard.** Every `complete`, `fail` and `block` carries S's own
`server_generation` (`G` at request time). Slice a refuses any other value
before any replay check. A coordinator restarted mid-switch has a new `G`
and can't finish an older switch. That is slice c's boot rule: a still
pending switch becomes failed or blocked.

## The blocked-switch resolver (`resolve_blocked`, deferred from slice a)

`ProfileCoordinator.resolve_blocked(switch, outcome, proof, actor: admin)`,
with `outcome` `:completed` or `:failed`. It is attended: a current human
admin, role re-read.

- **The proof** is typed. It is gathered by the coordinator **before** any
  transaction, never inside one that might roll back:
  - `%{tenant_id, switch_id, server_generation, target_profile, reaper_lease: :released | {:held_by_live, pid}, cli_processes: :none_found}`.
  - `cli_processes: :none_found` is the coordinator's own process-table
    check: no `claude` process of a previous server under the app's tree.
  - **OQ-3** asks whether that check is acceptable evidence, or whether
    only the reaper's receipt may count.
- **Rules:**
  - **`:completed`** only when the target profile's server is running at
    the current generation and passed the step 5 preflight. Cleanup
    evidence alone never counts as a passed preflight.
  - **`:failed`** only when the old profile is running and passed the
    preflight, and no unconfirmed work remains. Admission never reopens
    over unconfirmed work.
  - **A dead reaper's held lease** stays the operator's own
    `Reaper.release/1` step, done before the resolver and outside it. The
    resolver never calls `release/1`.
- **Entity delta** (ModelProfileSwitch): a new `:resolve_blocked` update,
  blocked → completed or failed.
  - `:completed` applies the setting in the same transaction (as
    `complete`);
  - it records `resolved_by_id` and `resolution` (a metadata-only map of
    the proof);
  - it appends `model.profile.switch_resolved`.

## Entity Model

**Entity Model trigger:** yes:
- a new switch action and its lifecycle edge (blocked → completed or
  failed);
- two new nullable switch attributes;
- a new event;
- the runtime ownership of the server (the coordinator and the
  generation).

| Entity | New / Existing | Purpose | Attributes | Relationships | Invariants / Lifecycle | Policy/Actor | Open Questions |
|---|---|---|---|---|---|---|---|
| ModelProfileSwitch | Existing (action and attribute delta) | One requested change | adds `resolved_by_id : uuid, nullable` (a human admin) and `resolution : map, nullable` (the metadata-only proof: lease state, process check, generation, target, profile) | adds belongs_to User (`resolved_by`, optional) | **`:resolve_blocked`:** blocked → completed (applies the setting, revision + 1, same transaction) or blocked → failed (setting unchanged), only with the typed proof and its rules; no other exit from blocked; terminal states unchanged | **resolve:** a current human admin (role re-read); `complete`, `fail` and `block` unchanged (`model_runtime`) | OQ-3 |
| ModelProfileSetting | Existing | — | unchanged | unchanged | changed only by `complete` or by `resolve_blocked` as `:completed` | unchanged | none |
| AuditEvent | Existing (new event type) | Ledger | `model.profile.switch_resolved`: from, to, `server_generation`, outcome, `setting_revision`, `resolution` (metadata only), `resolved_by` | unchanged | same transaction as the resolve | unchanged | none |
| ProfileCoordinator (runtime, not persisted) | New | Owns the server lifecycle and the generation | `G`, the bound `{G, pid, profile}`, the stage | supervises the named ClaudeCLI server | one switch at a time; no step under a ledger lock; a generation from a past boot can't act | runs the drain as `agent_runtime` and `complete`, `fail`, `block` as `model_runtime`; the request and resolve are the admin's | OQ-1, OQ-2 |

## Tests (RED first)

1. **The happy path:** request → drain → veto → stop → start → preflight →
   complete.
   - The setting is applied; the new pid is bound at `G+1`; no model call
     is made (a fake launcher counts zero calls).
2. **Activation fails cleanly:** the new preflight fails, the old is
   restarted, and `fail` follows; the setting is unchanged and the fence
   opens.
3. **Block paths:**
   - drain timeout, with nil counts and with real counts;
   - veto failures: absent, replaced pid, admission closed, lease not the
     server's own;
   - an old lease not released within the bound;
   - a dead reaper's lease;
   - the new cleanup unconfirmed;
   - the old preflight failing on rollback.

   Each gives block with its reason, the fence stays closed, nothing is
   restarted over a held lease, and `Reaper.release/1` is never called.
4. **Generation:**
   - a stale coordinator (another `G`) can't complete, fail or block;
   - a restart mid-switch can't finish an older switch.
5. **The resolver:**
   - completed and failed each succeed only with their rules;
   - cleanup evidence alone can't complete;
   - unconfirmed work can't fail-and-reopen;
   - a non-admin and a stale admin are refused;
   - the proof is gathered outside the transaction;
   - the event and the setting are written in one transaction.
6. **Serialization:** a second request while one switch runs is refused by
   slice a's one-open rule; the coordinator never runs two.
7. **No model call** in any switch path: the fake launcher's call count is
   zero throughout.

## Open questions

- **OQ-1, the generation source.**
  - **Recommended:** derive it at boot from the highest stored switch
    generation + 1, in memory afterwards. That is enough because every
    switch row records its own generation, and slice c's boot rule closes
    any pending switch from an earlier boot.
  - **The alternative:** a persisted counter row, which is a new entity.
- **OQ-2, the lease-release bound** after a stop. **Recommended:** the
  reaper's own kill timeline (TERM grace + KILL + exit wait, about 2 s)
  plus a margin, so 10 s, then block.
- **OQ-3, the resolver's process evidence.**
  - **Recommended:** accept the coordinator's process-table check
    (`pgrep` under the app's process tree, on the same host) as
    `cli_processes: :none_found`, plus the lease state.
  - **The alternative:** only a live reaper's release counts. A dead
    reaper's lease then always needs the operator's `release/1` first.
