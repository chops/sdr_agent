# C2-02a (#52, slice a) the switch records: interface check (draft)

**Status:** draft 1, 2026-10-15, for Codex's interface check before RED.
No code.

**Scope:** exactly the accepted rows in R0 readiness section 2:
ModelProfileSetting, ModelProfileSwitch and Actor `:model_runtime`. These
are covered by the `dc01a65` entity PASS. Plan PASS: c8f77ac9.

**Safe exit:** records and actions only. There is no orchestrator, no UI,
and nothing in `lib/` calls `request`. `Runtime.desired_profile/0` is
unchanged; it switches to the setting in slice c.

## Placement

- **Domain:** `SdrAgent.Agents`, next to the grant resources, which share
  the admin-authority pattern (`Checks.CurrentAdmin`) and the audit chain.
- **New:**
  - `lib/sdr_agent/agents/model_profile_setting.ex`;
  - `lib/sdr_agent/agents/model_profile_switch.ex`;
  - `lib/sdr_agent/agents/checks/model_runtime.ex`, if the existing
    `Checks.ActorType` is not enough;
  - one migration.
- **Changed:**
  - `lib/sdr_agent/actor.ex`: add `:model_runtime` to the system types;
  - `lib/sdr_agent/agents.ex`: add the resources and the functions below.

## Domain functions (proposed names)

| Function | Actor | Effect |
|---|---|---|
| `get_profile_setting(opts)` | admin, auditor (audited read, as for grants), `agent_runtime` | The tenant's setting, or `{:ok, nil}` before the first one exists |
| `request_profile_switch(%{to_profile_id, expected_revision}, opts)` | an active human admin, role re-read | Locks the setting row, then the chain head. Refused if: <br>• `to` is not a reviewed real profile, or is `:fake`; <br>• `to` equals the current desired profile; <br>• the revision is stale; <br>• a pending or blocked switch exists (partial unique identity). <br>Creates the switch as `pending`, with `from`, `requested_by_id`, `requested_at` and `server_generation` (given by the caller in this slice; the orchestrator supplies it in b2). Event `model.profile.switch_requested` |
| `complete_profile_switch(switch, %{server_generation}, opts)` | `model_runtime` only | pending → completed. In the same transaction: setting `desired_profile_id := to` and revision + 1. Idempotent on `(id, server_generation)`; a stale generation is refused. Event `model.profile.switch_completed` |
| `fail_profile_switch(switch, %{server_generation, failure_reason}, opts)` | `model_runtime` only | pending → failed; the setting is unchanged. Idempotent, with stale generations refused. Event `model.profile.switch_failed` |
| `block_profile_switch(switch, %{server_generation, failure_reason}, opts)` | `model_runtime` only | pending → blocked. Idempotent, with stale generations refused. Event `model.profile.switch_blocked` |
| `resolve_blocked_profile_switch(switch, %{outcome: :completed or :failed, attestation}, opts)` | an active human admin | blocked → completed or failed. It reuses the Reaper release attestation that no CLI process is left: the accepted attended boundary, not an automatic unlock. Event `model.profile.switch_resolved` |
| `list_profile_switches(opts)` | admin, auditor (audited) | History, newest first. Never relabelled |

**The setting's first row:** `request` creates the setting at revision 1
(`desired_profile_id: :claude_cli_opus`, the registry default) if it is
absent, under the same lock, before checking the request. There is no
separate write action, matching "No direct write action".

**Open question for Codex:** is the lazy first row acceptable, or must
it be created at tenant bootstrap or in the migration?

## Invariants and locks

- **Setting:** one row per tenant (unique `tenant_id`). `desired_profile_id`
  is a non-fake registry id (a DB check against the registry's real ids).
  `revision` is at least 1.
- **Switch:**
  - `from_profile_id` differs from `to_profile_id` (DB check);
  - status is one of pending, completed, failed or blocked (DB check);
  - at most one pending or blocked switch per tenant (partial unique
    index);
  - `finished_at` is set exactly when the status is terminal;
  - rows are append-only apart from the status transitions above.
- **Lock order:** setting row `FOR UPDATE` → chain head, for request,
  complete, fail, block and resolve. The switch row is locked after the
  setting and before the head.
- **No model call** and no waiting under these locks; orchestration
  comes in b1 and b2.
- **`model_runtime` authority:** only the switch's complete, fail and
  block. It is denied every grant, allocation, invocation and setting
  write (policy tests).

## RED tests (all fail on main: the resources don't exist)

1. **Allow and deny for every action.** Allowed: an active admin, or
   `model_runtime` for its three actions. Denied:
   - a reviewer, an auditor, a disabled admin, a stale demoted admin
     struct;
   - every other system actor;
   - `model_runtime` on request, resolve and every grant, allocation,
     invocation and setting write.
2. **Request refusals:** a stale revision; `to` equal to the current
   desired; `to: :fake` and an unknown id; a second pending switch; a
   blocked switch blocking a new request.
3. **Complete:** the setting's desired profile and revision change in
   the same transaction as the switch, with events in order.
4. **Fail and block:** the setting is unchanged.
5. **Idempotency and generations:** each transition repeated with the
   same generation is a no-op success; a stale generation is refused;
   completed and failed are final; blocked leaves only through the admin's `resolve_blocked`, never through `model_runtime`.
6. **History** is never relabelled: earlier switches keep their values.
7. **Direct-SQL negatives,** one rule each: the `from = to` check, the
   status check, the partial unique index, the setting's fake-profile
   check.
8. **The lock order:** a test on independent connections shows that a
   request waits on the setting row before the chain head. This follows
   the pattern of the grant edit tests.

**Gate:** the full gate on an owned partition. No model calls.
