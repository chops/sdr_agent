# C2-02 (#52) in-app profile switch: proposed slices (draft)

**Status:** draft 3, 2026-10-15 (the b2 split and the reforecast), for
Codex's review and the Oct 15 gate. Draft 1 (`95b5cdd`) was NEEDS-REVIEW:
split b; narrow the no-call claim; correct the estimate.

**Tripwire 1 (growth):** C2-02 is one backlog story, but it now needs
five PRs (a, b1, b2α, b2β, c). b2 split at its interface review: b2α is
activation, rollback and ownership; b2β is the attended exit from
`:blocked` (the resolver). The owner is told the same day.

**Where it starts:**
- The entity delta was accepted (C2-01, #51, closed). It is in the R0
  packet section 2, which has an entity PASS at `dc01a65`, and R0 G5
  covers it (D-109).
- **On main (`3b09183`) none of it is built:**
  - there is no `ModelProfileSetting` or `ModelProfileSwitch` resource;
  - there is no `:model_runtime` actor type;
  - `Runtime.desired_profile/0` returns `ModelProfiles.default_real()`.
- **What already exists to build on:**
  - the ClaudeCLI server's admission state (`admission/1`: open or
    blocked);
  - the Reaper lease;
  - launch admission's `profile_mismatch_at_launch` refusal;
  - the `:profile` start option (R0-03).

**Acceptance (#52):**

> Admin-only; fences admission, drains prepared/reserved/queued/in-flight,
> bounded wait; frozen per-call profile; guarded rollback; restart
> restores.

**Required evidence:** role-deny, concurrency, queued work, caller,
server and Reaper death, restart, and failed-activation tests
(REQ-R0-5, 6 and 7; packet section 4 "Switch").

## Entity coverage

**Entity Model trigger:** yes. It is covered by the existing independent
PASS for the accepted C2 rows at `dc01a65`, subject to exact scope
mapping (Codex, 560c37bc).
- **The rows covered,** in R0 readiness section 2: ModelProfileSetting,
  ModelProfileSwitch and Actor (`:model_runtime`), with their
  qualifications. Slice a implements them as written.
- **When a narrow delta is needed first:** any new field or marker,
  changed generation identity, transition, lock or authorization
  semantics, or wider runtime authority. Only that change is reviewed,
  not the whole domain.

## Slices

Each slice has a **safe exit:** when it merges alone, no switch is
advertised, no real provider is activated, and behavior on main stays
correct. The final integration matrix is required before R0-05.

| Slice | Scope | Main tests | Safe exit | Author size |
|---|---|---|---|---|
| **a. The records** | ModelProfileSetting and ModelProfileSwitch, exactly the accepted rows; the `:model_runtime` actor; the actions (`request` and `resolve_blocked` for a human admin with the role re-read; `complete`, `fail` and `block` for `model_runtime` only, idempotent on `(id, server_generation)`, stale generation refused); `model.profile.switch_*` events; the migration; the lock order "setting row → chain head" | Allow and deny for every action and actor; stale revision; `to` equal to the current desired; a second pending switch; stale generation; idempotent repeats; completion updates the setting and revision atomically; history never relabelled | Records and actions only. Nothing calls `request`, there is no orchestrator and no UI. `desired_profile/0` is unchanged | about 1 day |
| **b1. Fence and drain** | The admission fence: committed switch state observed in the reservation and launch order, not only an in-memory health check, so an old prepared caller can't race a later reservation. Then a bounded drain of prepared, reserved, queued and in-flight work: finished or refused under the accepted rules, never moved to another profile or grant. Reserved profile ids stay immutable | Concurrent reservations versus a committed fence, on independent connections in both orders; queued old-profile work finishes or is refused within the bound; caller and server death during the drain; nothing is held under a ledger lock while waiting | The fence can only be closed by a switch request, which slice a's actions alone don't start, so admission stays open in normal use | about 1 to 1.5 days |
| **b2. Activation and rollback** | Coordinator and server generation ownership and handoff. Stop the old server, start the new profile, and run the no-call preflight (pinned binary, version), all outside the setting and chain-head transactions. Then short, generation-guarded `complete`. On failure with clean work, restart the old profile and `fail`. With unconfirmed work or a held Reaper lease, `block`, keep admission closed, and use the accepted attended resolution, never an automatic unlock or a rollback over a held lease | Stale-generation replies; clean failed activation; unconfirmed candidate or old work; Reaper death; no model call during a switch; concurrent requests | Integrated with b1; still no UI. Reachable only through the domain API in tests | **Split (Oct 15):** b2α (interface `c2-02b2-interface.md`, draft 3) about 1.5 to 2 days; b2β, the attended resolution of `:blocked`, about 1 day |
| **c. Restart and status** | At boot, start with the setting's `desired_profile_id`. ~~A pending switch becomes failed (`interrupted_by_restart`), or blocked if the lease shows unconfirmed work~~ **Narrowed (D-139, owner, 2026-10-15; C2-02c OQ-1):** every pending switch at a coordinator start stays blocked (b2α's `coordinator_restarted`), and its exit is b2β's attended resolver; a restart is not proof that earlier external work stopped (`c2-02c-interface.md` section 0). `Runtime.status/0` gains `desired_profile`, `effective_profile` and `switch` | Restart restores the desired profile; an interrupted switch at boot, clean and unconfirmed; status makes no model call | Depends on b2's generation and coordinator interface. Preparation while b2 is in review counts as preparation only, integrated in order | about half a day to 1 day |
| **R0-05 (#53). The admin page** | Status and the switch button with confirmation | LiveView: no model call; confirmation; non-admins denied; the owner tries it | Last, after the integrated switch and status | about 1 day |

**Order:** a → b1 → b2α → b2β → c → R0-05. It is serial for one author. Work on
c while b2 is in review is preparation, not extra capacity.

## Forecast effect (provisional, low confidence, for the Oct 15 gate)

- **Author time:** 4.5 to 6 days for C2-02 plus R0-05, with a = 1, b1 =
  1 to 1.5, b2 = 1 to 1.5, c = 0.5 to 1 and R0-05 = 1.
- **Reforecast (Oct 15, 05:30 MDT, before calibration):**
  - **Done:** a (#159) and b1 (#160) are Codex-approved, unmerged
    (owner acceptance and Bandit). b1 took about 2 days with two
    CHANGES REQUESTED rounds (tripwire 2).
  - **Remaining author time:** b2α 1.5 to 2, b2β 1, c 0.5 to 1, R0-05 1,
    and R0-04 1 to 1.5: **5 to 6.5 days** from Oct 15 after calibration. Review rounds
    (b1 needed two) add to that, which is why the earliest R0-06 is Oct 22.
- **Plus time not counted in that sum:** each slice's review,
  correction and CI round, so this doesn't overlap with review capacity.
- **Also still ahead of R0-06:**
  - R0-04 (contract in review, then about 1 to 1.5 days);
  - C9-04 and C9-06 evidence (C9-06's Home test waits for C1-02 to
    merge);
  - the Bandit decision and fix;
  - integration;
  - the owner's try.
- **Window:** ~~starting Oct 15, R0-06 is Oct 20 at the earliest, more
  plausibly Oct 21 to 22~~. **Reforecast: Thu Oct 22 at the earliest, more
  plausibly Fri Oct 23, or Mon Oct 26 if no weekend work.** This is a conditional planning window, not a
  promise. While Bandit is unresolved there is no dependable date.
  Protected S6 is not spent silently.
- **What G-R0's expiry does and doesn't gate:**
  - **R0-06 isn't a no-call story overall.** It includes calibration (one
    reviewed PASS per profile under G-R0, D-142), Codex's independent review of the
    captured exchanges, and the exact tuple promotion.
  - **Calibration is scheduled for Oct 15, not done.** It is gated, and
    its evidence must be valid for each exact tuple.
  - **The rest can come after expiry.** Once valid evidence exists, the
    remaining switch demonstration (Opus → Sonnet → Opus in the app) and
    its preflight and UI checks make no model call. They can finish
    after G-R0 expires (Oct 18, 23:59 MDT) without an extra call.
  - **Any real attempt still needed after expiry** requires an
    owner-authorized grant change or a new grant. There is no automatic
    renewal, borrowing or rerun.

## Answers recorded (Codex, 560c37bc)

1. Split b into b1 (fence and drain) and b2 (activation and rollback).
   Keep each slice's death and generation tests with the behavior they
   protect.
2. Don't repeat an unchanged entity review. The `dc01a65` PASS covers
   the accepted rows; a narrow delta is needed only if the contract
   changes.
3. The remaining switch demonstration can be no-call after valid
   pre-expiry calibration, review and promotion. R0-06 as a whole is not
   no-call.

The implementation obligations from that review bind slices b1, b2 and
c. They cover:
- the fence's linearization;
- no external waiting under ledger locks;
- generation ownership and recovery;
- never rolling back over a held lease;
- safe staging.
