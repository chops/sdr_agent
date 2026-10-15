# C2-02 (#52) in-app profile switch: proposed slices (draft)

**Status:** draft 1, 2026-10-15, for Codex's review. No code.

**Tripwire 1 (growth):** C2-02 is one backlog story, but it needs three
PRs. The owner is told the same day.

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

## Slices

| Slice | Scope | Main tests | Size |
|---|---|---|---|
| **C2-02a. The records** | `ModelProfileSetting` (a singleton per tenant; `desired_profile_id`, a non-fake registry id; `revision`) and `ModelProfileSwitch` (statuses pending, completed, failed and blocked; `server_generation`; at most one pending or blocked per tenant, a partial unique identity). The `:model_runtime` actor type. Actions: `request` and `resolve_blocked` (human admin, current role re-read); `complete`, `fail` and `block` (`model_runtime` only, idempotent on `(id, server_generation)`, stale generation refused). Audit events `model.profile.switch_*`; the migration; the lock order "setting row → chain head" | Allow and deny for every action and actor. Stale revision; `to` equal to the current desired; a second pending switch. Stale generation; idempotent repeats. Completion updates the setting and revision in the same transaction. History is never relabelled | about 1 day |
| **C2-02b. The switch** | Orchestration: fence admission; drain prepared, reserved, queued and in-flight work within a bounded wait (finished or refused); stop the old server; start the new profile; no-call preflight (pinned binary present, version reported); then complete. On activation failure with clean work, restart the old profile and fail. With unconfirmed work or a held Reaper lease, block, with admission closed. A call never launches under another profile (launch admission's existing refusal) | Queued old-profile calls finish or are refused. Caller, server and Reaper death mid-switch. Failed activation, clean or unconfirmed. No model call during a switch. Concurrent requests. All on independent connections, in both orders where it matters | 1.5 to 2 days |
| **C2-02c. Restart and status** | At boot the server starts with `ModelProfileSetting.desired_profile_id`, replacing `ModelProfiles.default_real()`. A still-pending switch becomes failed (`interrupted_by_restart`), or blocked if the lease shows unconfirmed work. `Runtime.status/0` gains `desired_profile`, `effective_profile` and `switch` | Restart restores the desired profile. An interrupted switch at boot. Status makes no model call | about half a day |
| **R0-05 (#53). The admin page** | Status (configured and effective profile, CLI version, last check) and the switch button with confirmation | LiveView: renders without a model call; confirmation; non-admins denied; the owner tries it | about 1 day |

**Order:** a → b → c → R0-05. Slice b depends on a. Slice c can be
built alongside b once a merges, since its boot path is separate.

## Forecast effect (draft, for the Oct 15 gate review)

- **Build:** about 3.5 to 4.5 days of Claude-lane work for C2-02 plus
  R0-05, with one review round per slice. Starting Oct 15 that gives
  **Oct 19 at the earliest, more likely Oct 20 to 21.** This assumes
  Bandit clears promptly, since every slice needs a merge.
- **The R0-06 proof itself makes no model call** (REQ-R0-11: the owner
  switches Opus → Sonnet → Opus in the app). So G-R0's expiry (Oct 18,
  23:59 MDT) limits only calibration, which is on Oct 15. It doesn't
  limit the switch proof, as long as the calibration evidence stays
  valid for the same tuple.

## Questions for Codex

1. Are three slices the right cut, or should b be split further (fence
   and drain, then activation and rollback)?
2. Does C2-02a need a fresh entity check against the accepted rows, or is
   the existing PASS enough, given no change from the packet?
3. Is the R0-06 reading (the switch proof needs no G-R0 call) right?
