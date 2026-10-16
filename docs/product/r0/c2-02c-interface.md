# C2-02c interface: restart and status

**Status:** draft 1, 2026-10-15, for Codex's interface and entity review.
Slice plan: `c2-02-slices.md` row c. Builds on b2α (merged at `22db5c0`)
and b2β (`c2-02b2b-interface.md`, PASS at `e60943c`; RED in review).
Implementation lands after b2β. Codex's advisory pre-read is
`codex-c202-slice-c-preread-22db5c0.md`.

## 0. Scope, and one narrowing

The slice plan's row c has two parts:
- **Restart:** start at the setting's `desired_profile_id`. A pending
  switch becomes failed (`interrupted_by_restart`), or blocked if the lease
  shows unconfirmed work.
- **Status:** `Runtime.status/0` gains `desired_profile`,
  `effective_profile` and `switch`.

**The narrowing (for the owner, OQ-1).** Drop the "clean pending switch →
failed at boot" branch. **Every pending switch at a coordinator start
stays blocked**, which is what b2α already does (`coordinator_restarted`).
The exit is b2β's attended resolver. Why:
- **No proof.** A restart is never proof that earlier external CLI work
  stopped, and the slice plan says so itself. The lease is local to the
  VM, so its absence after a whole-VM restart proves nothing.
- **No route.** b2α's `fail` needs a ready rollback start with
  `:spawn_preflight` evidence. A new boot's start is a `:boot` or
  `:replacement` start, so there is no honest route to `fail` without
  weakening b2α's guards.
- **No gap.** b2β gives every blocked switch an attended exit. A
  "provably clean" branch would add a second, weaker path to `:failed`
  for no case that b2β doesn't already cover.

So slice c adds **no lifecycle transition and no persisted change**. It
pins the restart behaviour b2α and b2β already have, and builds the
status contract.

## 1. Restart (behaviour pinned, not changed)

| At a coordinator start | Outcome (existing b2α and b2β behaviour) |
|---|---|
| no switch open; the setting says Sonnet | the first start runs Sonnet (adopted or fresh); it is released after the reconciled read |
| no setting row (a read that positively finds none) | the default (`:claude_cli_opus`) |
| the setting read fails | no start; held; the boot is retried (`retry_boot`); **never the default** |
| a pending switch | blocked (`coordinator_restarted`); held |
| a blocked switch | stays blocked; held (b2β's resolver is the exit) |
| a resolved switch (b2β) with a dead lease | held at `:cleanup_unprovable` (b2β section 5) |
| a completed switch | the next start runs its `to` profile (the setting it applied) |

**What counts as a restart.** Each row is tested twice:
- a coordinator-only restart (the coordinator is killed while idle, and
  `:rest_for_one` restarts it);
- a full profile-tree cold start: `ProfileSupervisor` is stopped and
  started again, with no surviving server and no lease, the closest
  hermetic stand-in for a VM restart.

These are different lifecycles. Calling a helper is neither.

## 2. Status

`Runtime.status/0` keeps every existing key with its current meaning,
including `effective` (provider availability), `refusal`, `server` and
`attestation`. For ClaudeCLI it adds:

| Key | Meaning | Source |
|---|---|---|
| `desired_profile` | `%{profile_id, source: :setting \| :default}`; `:unknown` when the coordinator's last setting read failed or it hasn't read yet; nil when no coordinator runs | the coordinator's published status (below) |
| `observed_profile` | the profile the named server runs, or nil when none runs | `ClaudeCLI.profile/1` (the server's own status table) |
| `effective_profile` | the profile a call admitted **now** would run: `observed_profile` when `resolve([])` succeeds, nil otherwise. A held, blocked or staged server never has one | computed |
| `hold` and `stage` | the coordinator's hold (`:held \| :released \| :pending`) and stage (including `:cleanup_unprovable`) | published status |
| `switch` | the open switch: `%{id, from_profile_id, to_profile_id, status: :pending \| :blocked, failure_reason}`, nil when none is open, `:unknown` when not known | published status |
| `as_of` | `%{boot_id, generation, published_at}` of the published status the fields above came from | published status |

**`profile_id` and the model fields** (`model_alias`, `model_id`,
`reviewed_version`) keep the rule "the running server's, else the desired
one", with one change:
- when nothing runs and the desired profile is `:unknown` or nil, they
  are **nil**, never the registry default.

This removes the default-on-unknown fallback in `details/1`.

**The reviewed registry identity and the per-call init attestation stay
separate fields.** Status never claims that the model was attested by a
boot or a no-call preflight.

**The coordinator's published status gains** `desired`, `switch` and
`published_at`:
- **When it publishes:** after every successful setting read (boot,
  `complete`), and on every switch read or write (boot, request, block,
  complete, fail, resolve).
- **On a failed read:** it publishes `:unknown` for that field. It never
  keeps a stale value as current.

**What status may not do.** It reads ETS and the server's own status table
only. It never:
- calls the coordinator, or waits on a queue;
- reads the database;
- initializes a setting, or writes a switch, a start or an event;
- releases a hold, or decides a launch. Status is observational, not
  authority.

**Inconsistent combinations.** Some readings are downgraded rather than
shown as ready:
- `observed_profile` differs from the published start's profile;
- the published `boot_id` doesn't match a live coordinator;
- the ETS table is gone.

In each case `effective_profile` is nil and the inconsistent field is
`:unknown`. A server that is held never looks ready.

**`Runtime.desired_profile/0`** is today a constant default. It becomes
`{:ok, %{profile_id, source}} | {:error, :unknown}`, read from the
published status. When no coordinator runs, it is `{:ok, %{profile_id:
default, source: :default}}` only when the provider is the Fake (no
setting applies). Otherwise it is `{:error, :unknown}`. Its callers are
`runtime.ex` `details/1` and `provider_runtime_test.exs:213`, which is
updated to the new shape.

## 3. ADR evaluation

None needed. This is within ADR-0004: the R0 amendment's status card,
and the C2-02b2 status table. No new dependency, process or authority.

## Entity Model

**Entity Model trigger:** yes, narrowly. Nothing persisted changes: no
attribute, relationship, action or event. A runtime read contract does
change: the published coordinator status, `Runtime.status/0` and
`Runtime.desired_profile/0`.

| Entity | New / Existing | Purpose | Attributes | Relationships | Invariants / Lifecycle | Policy/Actor | Open Questions |
|---|---|---|---|---|---|---|---|
| Coordinator published status (runtime) | Existing (delta) | What operators see | **Added:** `desired` (`%{profile_id, source}` \| `:unknown`), `switch` (projection \| nil \| `:unknown`), `published_at` | — | Republished after every setting or switch read or write. A failed read gives `:unknown`, never a stale value. Never blocks on the coordinator. No raw refs or pids | written only by the coordinator; read by anyone in the node (protected ETS) | none |
| `Runtime.status/0`, `Runtime.desired_profile/0` (runtime read API) | Existing (delta) | The admin card | **Added keys** as in section 2; `desired_profile/0`'s return shape changes | — | No database read, no coordinator call, no write. No default on unknown. `effective_profile` only when calls are admissible now | unchanged (the admin page) | none |

ModelProfileSwitch: existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found.
ModelProfileSetting: existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found.
ModelServerStart: existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found.

## 4. Tests (RED first)

Files: `test/sdr_agent/ai/profile_restart_test.exs` and
`test/sdr_agent/ai/runtime_status_test.exs`. All hermetic, with zero
model calls and no spend. Each restart row in section 1 runs as both a
coordinator-only restart and a profile-tree cold start.

**Restart:**
1. **Desired Sonnet restored**, with no open switch: by adoption on a
   coordinator restart, and by a fresh start on a cold start.
2. **The default only on a positively absent setting.** A failing setting
   read gives no start, held, the boot retried, and recovery once the read
   works (a test-only read fault).
3. **A pending switch → blocked** (`coordinator_restarted`), with the
   request history unchanged. It is never completed or continued, and
   never failed by the restart.
4. **Blocked, and resolved with `:cleanup_unprovable`**, across both
   restarts: still held, with no release and no resolve.
5. **A completed switch:** the next start runs `to`.
6. **Old-boot replies:** a reply or `DOWN` from an old boot's server or
   worker can't reopen the new boot's hold.

**Status:**
7. **Each key** in each state: no provider tree (the Fake), held,
   released, blocked, pending switch, `:cleanup_unprovable`, a failed
   setting read, and the ETS table missing.
8. **No default on unknown:** with nothing running and the desired profile
   `:unknown`, `profile_id` and the model fields are nil.
9. **No side effects:** `status/0` makes zero database queries
   (query-telemetry trace), zero coordinator messages (trace), and zero
   writes (counts of events, starts and switches), with zero launches and
   reservations.
10. **Concurrent changes:** a switch commit, a server death and an ETS
    replacement between observations, with barriers. Every inconsistent
    combination is downgraded, and `effective_profile` is never set while
    the server is held.
11. **Bounded:** `status/0` answers within 50 ms while the coordinator is
    blocked in a ledger call (a test-only pause).
12. **`desired_profile/0`'s shapes:** Fake, coordinator setting, default,
    unknown, and no coordinator.

## Open questions

- **OQ-1 (for the owner):** narrow slice c by dropping the "clean pending
  → failed at boot" branch (section 0)? **Recommendation: yes.** It is
  less code, and needs no new path to `:failed` that a restart can't
  prove. A switch interrupted by a restart then always needs the attended
  resolver, which costs one extra admin step in a rare case.
- **OQ-2 (for Codex):** is a profile-tree cold start an adequate hermetic
  stand-in for a VM restart in the automated suite, given that the lease
  lives in `:persistent_term` and survives the tree but not the VM? A test
  can clear the lease to simulate the VM boundary.
