# C2-02a (#52, slice a) the switch records: interface check (draft)

**Status:** draft 2, 2026-10-15, for Codex's interface check before RED.
No code.
- **Draft 1** (`037a1fe`) was NEEDS-REVIEW (Codex, 17604421).
- **What it asked for:** an executable first-row protocol; resolution
  evidence, or deferring resolution fail-closed; plus notes on internal
  writes, generations, reads and idempotency.
- **This draft:**
  - defines the first-row protocol (section "The first setting row");
  - **defers `resolve_blocked` to slice b2,** since no verified "no CLI
    left" proof exists today;
  - adds the internal write path.

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

All reads and writes are scoped to the actor's tenant. A missing actor,
or an actor of another tenant, is refused. Every write re-reads the
stored, current actor and checks the locked rows.

| Function | Actor | Effect |
|---|---|---|
| `get_profile_setting(opts)` | **reads:** admin; auditor (an audited read, as for grants); `agent_runtime` | Read-only. Gives the tenant's setting, or `{:ok, nil}` before the first one exists; nil means "the default: `:claude_cli_opus`, revision 1". **Denied:** a reviewer, `model_runtime` and other system actors |
| `list_profile_switches(opts)` | **reads:** admin; auditor (audited); `agent_runtime` | History, newest first. Never relabelled |
| `request_profile_switch(%{to_profile_id, expected_revision, server_generation}, opts)` | an active human admin, with the role re-read | See "The first setting row" and "Request" below. `server_generation` is a positive integer. In this slice the caller supplies it, as a records-test input only, not proof of live coordinator ownership; b2's coordinator supplies it |
| `complete_profile_switch(switch, %{server_generation}, opts)` | `model_runtime` only | pending → completed. The setting is updated through its internal action (below), in the same transaction |
| `fail_profile_switch(switch, %{server_generation, failure_reason}, opts)` | `model_runtime` only | pending → failed. The setting is unchanged |
| `block_profile_switch(switch, %{server_generation, failure_reason}, opts)` | `model_runtime` only | pending → blocked. The setting is unchanged |

**`resolve_blocked` is deferred to slice b2, fail-closed.**
- **Why:** `ClaudeCLI.Reaper.release/1` takes only a name and returns `:ok`
  or `{:error, :reaper_running}`. It issues no typed receipt and doesn't
  verify that no CLI process is left, so there is no existing proof to
  accept.
- **Until b2:** slice a defines no resolve action. A blocked switch has
  no exit, and nothing in production creates one before b2.
- **In b2:**
  - a typed proof bound to the tenant, the switch, the current
    generation and the runtime target;
  - the completion invariant for `:completed`, so cleanup evidence alone
    isn't treated as a passed preflight;
  - no reopening of admission over unconfirmed work for `:failed`;
  - no `Reaper.release` side effect inside a transaction that might roll
    back.

  b2 brings these as a narrow delta for review.

### The first setting row

The first row is created lazily, inside the request transaction, after
the admin check.
1. **Read** the tenant's setting `FOR UPDATE`.
2. **If it is absent,** create it inside a savepoint through the
   internal `:initialize` action: `desired_profile_id: :claude_cli_opus`,
   `revision: 1`, on the unique `tenant_id` identity.
   - A concurrent first request waits on the unique index until the
     winner commits or rolls back.
   - On a unique conflict, the loser rolls back its savepoint and
     re-reads the winner's row `FOR UPDATE`. It never overwrites the
     winner's desired profile or revision.
   - Before the chain head, no lock is held except this row, so there is
     no cycle.
3. **Then:** the switch rows, then the chain head.
4. **Events:** `:initialize` appends no event of its own, which would
   take the head early. The request appends
   `model.profile.setting_initialized` after taking the head, and only if
   this transaction inserted the row. It then appends
   `model.profile.switch_requested`.
5. **A rejected request leaves nothing:** a refusal rolls back the whole
   transaction, the initialized row included. No setting, switch or
   event remains.
6. **For an uninitialized tenant,** `expected_revision` must be 1;
   anything else is a stale refusal.

**Before RED,** the exact Ash mechanism (a plain create in a savepoint,
with the unique-conflict error classified) is checked by a probe on an
owned partition, rather than assumed.

### Request

These checks run under the setting lock, after initialization. A
refusal writes nothing.
- `to` must be a reviewed real profile; `:fake` and unknown ids are
  refused.
- `to` must differ from the current desired profile.
- The revision must not be stale.
- No pending or blocked switch may exist (checked, and backed by the
  partial unique index).

The new switch is `pending`, with `from`, `requested_by_id`,
`requested_at` and `server_generation`.

### The internal setting write path

The setting has two internal actions:
- **`:initialize`** (create);
- **`:apply_switch`**, an update of `desired_profile_id` to the switch's
  `to` with `revision + 1`.

**Who can call them:** they are authorized only by a context marker,
`ProfileSwitchContext`, the same pattern as `GrantContext`. Only the
switch's own `request` and `complete` changes set it, after locking the
setting row.
- A direct call to either action is refused before any lock, even for an
  admin or `model_runtime`.
- `model_runtime` gets no general setting write.
- There is no raw Repo mutation and no `authorize?: false` on these
  paths.
- **If anything fails,** the setting, the switch and their events roll
  back together.

### Idempotency and conflicts

- **A replay** of the same action with the same generation on a switch
  already in that action's result status returns that switch unchanged.
  No event is appended and the revision doesn't move.
- **A stale generation** (not the switch's `server_generation`) is
  refused.
- **A conflicting terminal action** is refused with
  `{:error, :switch_already_finished}`, never reported as a success. That
  covers fail after complete, complete after fail, and any `model_runtime`
  action on a blocked switch.

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
- **Lock order:** setting row `FOR UPDATE` (or its initializing insert)
  → switch rows → chain head, for request, complete, fail and block.
- **No model call** and no waiting under these locks; orchestration
  comes in b1 and b2.
- **`model_runtime` authority:** only the switch's complete, fail and
  block. It is denied every grant, allocation, invocation and setting
  write (policy tests).

## RED tests

The resources don't exist on main. Each test first asserts that the
module and function exist (`Code.ensure_loaded?/1`, then
`function_exported?/3`), after its fixtures, so it fails with an explicit
assertion message, not an `UndefinedFunctionError` setup crash. Codex
verifies the intended reason against the draft once the resources exist.
There is no production behavior during RED.

1. **Authorization.**
   - **Request** (`request_profile_switch`): allowed for an active admin.
     Denied for a reviewer, an auditor, a disabled admin, a stale demoted
     admin struct, a missing actor, another tenant's admin, `model_runtime`
     and every other system actor.
   - **Complete, fail and block:** allowed for `model_runtime` only;
     everyone else is denied, including an admin.
   - **Reads:** as in the table (an audited auditor read; reviewer
     denied).
   - **`model_runtime` beyond its three actions:** denied every grant,
     allocation, invocation and setting write.
   - **Direct calls** to the setting's `:initialize` and `:apply_switch`
     actions are refused, even for an admin and `model_runtime`.
2. **The first row, on independent connections:**
   - two concurrent first requests give one setting at revision 1, one
     `setting_initialized` event and one pending switch; the loser is
     refused as having an existing pending switch;
   - a first request that is invalid or stale leaves no setting, switch
     or event;
   - a request against an existing row doesn't re-initialize it.
3. **Request refusals,** with nothing written:
   - a stale revision;
   - `to` equal to the current desired profile;
   - `to: :fake` and an unknown id;
   - a second pending switch;
   - an existing blocked switch.
4. **Complete:**
   - the setting's desired profile and revision change in the same
     transaction, through `:apply_switch`;
   - the events come in order;
   - a forced failure rolls back the setting, the switch and the events
     together.
5. **Fail and block** leave the setting unchanged.
6. **Idempotency and conflicts:**
   - a same-generation replay is a no-op, with no event and no revision
     change;
   - a stale generation is refused;
   - fail after complete, complete after fail, and `model_runtime`
     actions on a blocked switch are refused with
     `:switch_already_finished`.
7. **History** is never relabelled.
8. **Direct-SQL negatives,** one rule each: the `from = to` check, the
   status check, the partial unique index, the setting's fake-profile
   check, and the one-setting-per-tenant uniqueness.
9. **Lock order:** a request waits on the setting row, or on the
   initializing insert, before the chain head (independent connections).

**Not in slice a:** resolving a blocked switch (b2), the orchestrator, and
reading the setting at boot (c).

**Gate:** the full gate on an owned partition. No model calls. The
domain diagrams are regenerated for the new resources.
