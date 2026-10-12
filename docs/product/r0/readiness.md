# R0 readiness packet: model runtime, profiles, switch, call grants

Status: **G5 approved by the owner on 2026-10-12** (section 7), with the
owner's answers in section 6. Original status line kept below for history.

Status (draft): **for independent review and owner G5.** Nothing here starts
implementation until (1) Codex records an entity-model verdict of PASS on the
table below, and (2) the owner approves G5 for the scope in "Next authorized
scope". Real-model budget stays 0 until C9 is merged and the owner has created
a grant in the app.

Sources: [build plan](https://github.com/chops/sdr_agent/blob/owner-decisions/docs/product/build-plan.md)
(epic R0, contracts C2 and C9), ADR-0004 R0 amendment (PR #39, accepted
2026-10-12), walkthrough rows 14-19d, 21b, 22-25 (D-087, D-088, D-096,
D-098, D-099, D-104). Code facts are from `main` at 56ae378.

Stories in scope: R0-02..R0-06, C2-01..C2-02, C9-01..C9-06
(issues #48-#54, #41-#46). R0-01 (the ADR amendment) is done.

## 1. Requirements (observable behavior)

| ID | Requirement |
|---|---|
| REQ-R0-1 | The app launches the Claude CLI only from its own pinned build, by absolute path. Updating the system or agent CLI does not change what the app runs. If the pinned build is missing, real calls are refused with a typed reason; there is no fallback to the system CLI or to the Fake. The active pinned build and the previous one (for rollback) are each kept alive by their own Nix GC root. |
| REQ-R0-2 | Two reviewed profiles exist: `claude_cli_opus` (alias `opus`, resolved `claude-opus-5-5`) and `claude_cli_sonnet` (alias `sonnet`, resolved `claude-sonnet-5-5`), both on the one pinned CLI version. No other model can be selected; there is no free-text model input. |
| REQ-R0-3 | Every new real-model invocation records its profile, grant and allocation (Fake invocations record their profile only). Rows written before R0 keep their original values and are never relabelled, and their legal lifecycle transitions keep working. |
| REQ-R0-4 | The admin page shows the desired profile, the effective (running) profile, any pending or blocked switch with its reason, the pinned CLI version and the last attestation, without making a model call. |
| REQ-R0-5 | An admin can switch profiles on the admin page, with a confirmation step. The switch is recorded in the audit trail. The app does not restart; only the model server does. Switching makes no model call: the new server passes a no-call preflight (pinned binary present, version reported), and the model itself is attested on its first real call. |
| REQ-R0-6 | During a switch, no new call is admitted. Calls already reserved or queued under the old profile finish or are refused, within a bounded wait. A call never launches under a profile other than the one it was reserved for. |
| REQ-R0-7 | If the new profile fails to activate, the old profile keeps running when nothing from the attempt is unconfirmed; otherwise the provider shows blocked with the reason until an admin acts. A restart restores the persisted desired profile; a switch interrupted by a restart is recorded as failed (or blocked if work is unconfirmed) and never resumed silently. |
| REQ-R0-8 | Every real-model attempt is charged to exactly one allocation of one owner-created grant when it is reserved, and admitted again just before launch. Attempts count whatever their outcome and are never refunded. With no eligible grant and allocation, no real call is made and nothing is charged. Fake calls need no grant. |
| REQ-R0-9 | Only a human admin (an active, persisted user with the admin role, re-read at the time of the action) creates or edits a grant or its allocations, revokes it, or releases a held allocation early, through an admin form with a confirmation step; each change is audited with the previous values and revision. No system or agent actor can change a grant. |
| REQ-R0-10 | When a reservation is refused (no eligible grant, allocation or day room) or a reserved call is refused at launch, the refusal is committed durably as an operator-attention item and an audit event, even though the reservation itself is rolled back. |
| REQ-R0-11 | Calibration and proof (OQ-3 = (b)): the four G-R0 attempts (two per profile) are **calibration** calls under an owner-accepted exception: synthetic input, an isolated test database with test-only exact overrides, never a business flow, results quarantined as unreviewed evidence and never presented as reconciled. Codex independently reviews the captured exchanges against candidate projections built hermetically beforehand; only then is each exact tuple (pinned CLI version, profile, resolved model, prompt builder, method) promoted to reconciled. The owner then switches Opus → Sonnet → Opus in the app. If calibration needs more than four attempts (for example, a changed wire grammar), that is a new owner grant request; nothing is spent silently. |
| REQ-R0-12 | Per-invocation result gate (OQ-3 = (b)): once a tuple is promoted, the result of every ordinary real call may be used downstream (validation, decisions, drafts) only after **that** invocation reconciles with the witness. Mismatch, missing capture or reconciliation timeout fails closed. The evidence and the charged attempt are kept, and no new call is made automatically. A tuple that is not promoted cannot make ordinary real calls. Reconciled proves the wire projection, not the factual accuracy of research. |

## 2. Entity model

Entity Model trigger: **yes**. New persisted resources (grant, allocation,
profile setting, switch record), new attributes and invariants on
ModelInvocation and AgentRun, a new admin-only authorization boundary, a new
lifecycle (switch), and changed backend action contracts (reservation
admission, launch admission, the facade's sent boundary).

| Entity | New / Existing | Purpose | Attributes | Relationships | Invariants / Lifecycle | Policy/Actor | Open Questions |
|---|---|---|---|---|---|---|---|
| ModelProfile (code registry, not persisted) | New | The closed set of reviewed model configurations | `id : atom` one of `:fake`, `:claude_cli_opus`, `:claude_cli_sonnet`; `adapter`; `cli_alias`; `resolved_model`; `cli_version`; `witness_disposition : :reconciled \| :captured_inferred` | Referenced by id from ModelInvocation, ModelProfileSetting, ModelProfileSwitch, ModelCallGrant, ModelCallAllocation | Changes only by reviewed code. `:fake` is never grant-checked and never a desired real profile. | n/a (code) | OQ-3 |
| ModelInvocation | Existing (delta) | Ledger row per model attempt | add `ledger_generation : int, not nil, default 1` (migration leaves every existing row at 1; R0 reservations write 2); add `profile_id : atom, nullable`; add `grant_id : uuid, nullable`; add `allocation_id : uuid, nullable`. All four written only by `:reserve` and immutable afterwards (excluded from the terminal-immutable trigger's mutable set and guarded by a new column-immutability check for non-terminal rows). `:reserve` accepts no grant, allocation or generation: the admitted charge reaches it only through the trusted admission context set by `Agents` after admission, and a cast `claude_cli` reservation without it (or any other provider with it) is refused. For an admitted call `reserved_at` is the admission instant (read after every reservation lock is held, see contracts), not the attribute default. | belongs_to ModelCallGrant (optional, restrict); belongs_to ModelCallAllocation (optional, restrict); composite FK `(allocation_id, grant_id)` → allocation `(id, grant_id)` so the allocation belongs to the recorded grant; grant, allocation, run and invocation share `tenant_id` (validated in `:reserve` and by composite FKs on `(grant_id, tenant_id)`) | Check constraint (applies to every insert and update, so it is a cutover predicate, not NOT VALID): `ledger_generation = 1 OR provider <> 'claude_cli' OR (profile_id, grant_id, allocation_id all not null)`. Generation-1 rows keep every existing transition (reserved/sent → failed/unknown/completed); a generation-1 `claude_cli` row is refused at launch (`legacy_invocation_without_grant`) and failed, never launched. **Sent boundary (changed):** for `claude_cli` the facade no longer marks sent before the provider call; the row stays `reserved` through queueing and becomes `sent` only inside `admit_launch/2` (below). Fake keeps today's order. | Unchanged: lifecycle actions by `agent_runtime`; reads by any present actor | none |
| AgentRun | Existing (delta) | Agent run with per-run budget | add `usage_origin : atom, nullable` (null only for runs created before R0), one of `:assignment, :referral, :reply, :followup, :discovery, :channel, :proof`. `status_reason` gains `:grant_exhausted` and `:grant_unavailable`. `:fail` and `:exhaust_budget` gain arguments `refusal_failure_id : uuid` and `refusal_request_id : string` (the refusal receipt), required with, and refused without, those two reasons. | `attention_failure_id` may now reference the reservation refusal's Failure (existing relationship, new source) | `usage_origin`: set at `:create` by trusted server code from the entry point (never from job args a caller can forge, never from model output); immutable; `:retry` copies it. A real reservation for a run with null `usage_origin` is refused (`no_usage_origin`), fail-closed. **Stop on a refused reservation:** a grant cap (`grant_exhausted`, `grant_day_exhausted`, `allocation_exhausted`) → `:exhaust_budget`, `budget_exhausted` / `:grant_exhausted`; `no_eligible_grant`, `no_allocation`, `ambiguous_allocation`, `no_usage_origin` → `:fail`, `failed` / `:grant_unavailable` (`failure_reason` names the exact reason). Neither opens a Failure: the run links the receipt's exact Failure as `attention_failure_id`, read `FOR UPDATE` after the run row, and only if it is this refusal's: same tenant, class `budget_exhausted`, subject this run, `operation_id` = the run's Operation (or none), and named with the same request id by a `model.reservation.refused` event of this run whose recorded reason is of the stop reason's category. The stop event records both arguments. **Resolution race:** the link does not require the Failure to be live; if an admin resolved the refusal before the stop, the run still stops with the grant reason and records that Failure as its cause (no new Failure, no `crash`). | Unchanged (`agent_runtime` / `scheduler` create; `agent_runtime` stops; admin retry) | none |
| ModelCallGrant | New | An owner-granted budget of real-model attempts | `id : uuid_v7`; `tenant_id`; `name : string, not nil` (e.g. "G-R0"); `purpose : string, not nil`; `status : :active \| :revoked, default :active`; `profile_ids : {:array, atom}, not nil, non-empty, non-fake registry ids`; `total_attempts : int > 0`; `per_utc_day_attempts : int > 0, nullable` (null: only the global 200/day applies); `starts_at`, `expires_at : utc_datetime, not nil, expires_at > starts_at`; `revision : int ≥ 1`; `created_by_id`, `updated_by_id`; timestamps | belongs_to Tenant; has_many ModelCallAllocation; has_many ModelInvocation; belongs_to User (created_by, updated_by) | Consumed = count of ModelInvocations with this `grant_id` (derived, never stored, never refunded). Invariant: sum of its allocations' `attempts` ≤ `total_attempts` (checked on every terms edit under the grant row lock). Revocation is terminal. Edits carry `expected_revision` and are refused if stale. Lowering a total, day limit or allocation below what is consumed is allowed; it only stops new reservations. | `create`, `update_terms`, `revoke`: human admin only (active persisted `Accounts.User`, role re-read in the action); every system actor forbidden. Each action is guarded and appends `model.grant.created \| terms_changed \| revoked` with previous values and revision. Reads: admin, auditor, `agent_runtime`. | OQ-2 |
| ModelCallAllocation | New | One spendable slice of a grant | `id`; `tenant_id`; `grant_id`; `key : atom, not nil` (`:b1`..`:b5`, `:proof`, `:rehearsal`, `:daily_use`, `:workshop`); `applies_to : {:array, atom}, not nil` (usage buckets it may fund); `profile_id : atom, nullable` (restricts to one profile, e.g. G-R0's two per profile); `attempts : int > 0`; `available_from`, `available_until : utc_datetime, nullable`; `released_at : utc_datetime, nullable`; `grant_revision : int ≥ 1, not nil` (added in implementation, PR #130: the grant revision that last wrote this allocation; set only by the grant's own action) | belongs_to ModelCallGrant (not nil, restrict); identity unique on `[grant_id, key, profile_id]`; unique `(id, grant_id)` for the invocation composite FK | The **workshop reserve is an ordinary allocation** (`key :workshop`, `available_from` = workshop day start), so there is one balance and no double counting. Available at t iff (`released_at` set or `available_from` null or t ≥ `available_from`) and (`available_until` null or t < `available_until`). Consumed = invocations with this `allocation_id`. Owner "release" sets `released_at` (early availability); owner "redistribute" is a terms edit moving attempts between allocations within the grant total; history is never rewritten because consumption is derived from immutable invocation rows. Never borrows from another allocation. | Created and changed only through its grant's own actions (`create`, `update_terms`, `release_allocation`), which lock the grant row, then its allocations, validate the complete final state and set the `GrantContext` marker; a direct allocation action is refused by policy before any lock (PR #130). Audited `model.grant.allocation_created \| allocation_changed`, `model.allocation.released`, each carrying `grant_revision` | none |
| ModelProfileSetting | New (singleton per tenant) | The persisted desired real profile | `tenant_id` (unique); `desired_profile_id : atom, not nil, default :claude_cli_opus`, non-fake registry id; `revision : int ≥ 1` | belongs_to Tenant (unique) | Changes only when a switch completes. On boot the model server starts with `desired_profile_id`. | Read: admin, auditor, `agent_runtime`. No direct write action. | none |
| ModelProfileSwitch | New | One requested profile change and its outcome | `id`; `tenant_id`; `from_profile_id`, `to_profile_id : atom, not nil, different`; `status : :pending \| :completed \| :failed \| :blocked`; `requested_by_id`; `requested_at`; `finished_at : nullable`; `failure_reason : string, nullable`; `server_generation : int` (the server start the switch belongs to) | belongs_to Tenant; belongs_to User (requester) | pending → completed (new server passed no-call preflight; setting.desired := to, revision +1, same transaction); pending → failed (activation failed and old work confirmed clean; old profile keeps running; desired unchanged); pending → blocked (unconfirmed work or Reaper lease held; admission closed); blocked → completed or failed after an admin action. At boot a still-pending switch is set failed (`interrupted_by_restart`), or blocked if the Reaper lease shows unconfirmed work; the server starts with `desired_profile_id`. Completion/failure actions are idempotent on `(id, server_generation)` and refuse a stale generation. At most one pending or blocked switch per tenant (partial unique identity). `request` refused if setting revision is stale or `to` = current desired. | `request`, `resolve_blocked`: human admin (resolve reuses the Reaper release attestation that no CLI process is left). `complete` / `fail` / `block`: system actor `model_runtime` only. All append `model.profile.switch_*`. | none |
| Actor | Existing (delta) | System actor types | add type `:model_runtime` | n/a | Authorized only for ModelProfileSwitch `complete` / `fail` / `block`. No invocation, grant, allocation or setting write authority. `admit_launch/2` runs as `agent_runtime`, like `mark_sent` today. | n/a | none |
| Operations.Failure | Existing (delta) | Operator attention items | no new attributes; new `detail.reason` values: class `budget_exhausted`: `no_eligible_grant`, `no_allocation`, `ambiguous_allocation`, `grant_exhausted`, `allocation_exhausted`, `grant_day_exhausted`, `no_usage_origin`; class `provider_error`: `grant_ineligible_at_launch`, `profile_mismatch_at_launch`, `legacy_invocation_without_grant`, `profile_switch_blocked` | unchanged | Reservation refusal: opened in its **own** committed transaction after the reservation transaction rolls back (see contracts). Deduplicated atomically: that transaction takes the chain-head lock before checking for an open Failure with the same `(class, reason, grant or none, run)` key, so concurrent and sequential repeats add no second item. Launch refusal: opened in the same transaction that fails the invocation. **Provenance and binding (PR-B):** the refusal Failure has subject = the run, `operation_id` = the run's Operation, and its detail is the dedupe key; its immutable `model.reservation.refused` event (run, request id as `idempotency_key`, `failure_id`, exact `reason`) is the provenance a run stop checks. The caller receives the exact receipt `{:error, %Refused{reason, failure_id, event_id, agent_run_id, request_id}}`; nothing looks up "the newest" Failure. A resolved refusal Failure is never reused by dedupe (a later refusal opens a new one) but may still be linked as the cause of the run it stopped. | `:open` by `agent_runtime` (existing system-actor permission) | none |
| Operations.Operation | Existing (behaviour delta) | Durable background work | — | unchanged | Unchanged invariant: a failed Operation links only a **live** Failure of its condition (or opens its own). For a run stopped by a refused reservation, the worker locks the Operation, then the run's linked refusal Failure (`FOR UPDATE`, order Operation → Failure → head) and links it while it is live. **Resolution race outcome:** if an admin resolved it first, the Operation fails opening its own `budget_exhausted` Failure (subject the Operation, naming the resolved refusal), so the failed Operation keeps a live queue entry; the run keeps the refusal as its cause and nothing is recorded as a crash. | Unchanged (kind actor) | none |
| Tenant | Existing | Singleton tenant | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found | — | — |
| Accounts.User | Existing | Human operators | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found (new resources reference it as creator/updater/requester only; role values and role-change rules unchanged) | — | OQ-2 |

### Changed backend action contracts

- **Usage bucket (trusted).** Code maps `(run.usage_origin,
  invocation.purpose)` to a usage bucket, following the owner-approved
  mapping (D-104): `:assignment` → `:b1` for every purpose (imported and
  referred-in leads are assigned like any other); `:referral` (the referred
  person's run) → `:b1` for research and qualification, `:b5` for
  `:outreach_proposal` (referral-specific drafting); `:reply` → `:b5`;
  `:followup` → `:b4`; `:discovery` → `:b2`; `:channel` → `:b3`; `:proof` →
  `:proof`. Callers cannot supply a bucket.
- **`Agents.reserve_model_invocation/3`** (for `provider: :claude_cli`).
  - **Locks and selection (as implemented, PR-B).** In one transaction:
    1. the run row `FOR UPDATE`;
    2. the candidate grants (run's tenant, `active`, profile in
       `profile_ids`), read under MVCC and then locked `FOR SHARE` by id;
    3. all their allocations `FOR SHARE` by id;
    4. the chain head, explicitly; only then is the admission instant t read
       from the clock;
    5. the run counter and daily limit (for t's UTC day), then the eligibility
       and room of the locked candidates from fresh reads, then the payload
       and the row, with `reserved_at` = t.

    The share locks match the editors' order (grant `FOR UPDATE` → its
    allocations `FOR UPDATE` → head): a reservation never waits for a grant or
    allocation row (including the invocation FKs' `FOR KEY SHARE`) while it
    holds the head, and no editor commits a change to a candidate during the
    reservation. A grant committed after step 2 is not a candidate (the
    reservation is ordered before it). Eligibility: the grant is active,
    `starts_at ≤ t < expires_at`, the profile is in the grant's `profile_ids`
    and matches the allocation's `profile_id` if set, the bucket is in
    `applies_to`, and the allocation is available at t. The Fake keeps run →
    head.
  - **Room check.** Grant consumed < total, grant today's (UTC, by
    `reserved_at`) consumed < day limit, and allocation consumed < attempts.
  - **Allocation choice.** Exactly one allocation must match. Zero matches
    refuses with `no_allocation` or `no_eligible_grant`. Two or more refuses
    with `ambiguous_allocation`. Owners configure non-overlapping windows
    (e.g. G-DEMO: `:b1`..`:b5` until Oct 26; `:rehearsal` Oct 27-29 for all
    buckets; `:daily_use` Oct 30-Nov 5; `:workshop` from Nov 6 or on
    release).
  - **Refusal path.** The transaction returns the error and rolls back, so
    there is no payload, no invocation and no counter change. The caller then,
    in a separate guarded transaction as `agent_runtime`, locks the run's
    Operation `FOR SHARE` (Operation lifecycle writers take Operation `FOR
    UPDATE` → head), then the chain head, opens or reuses the deduplicated
    Failure and appends `model.reservation.refused`, and returns the exact
    receipt `{:error, %Refused{reason, failure_id, event_id, agent_run_id,
    request_id}}`.
  - **Run stop (PR-B).** `SDR.Model` stops the run from the receipt (see the
    AgentRun row): `:grant_exhausted` or `:grant_unavailable`, linking that
    exact Failure; the worker then fails the Operation (see the Operation
    row for the resolution race).
  - **Duplicates.** A duplicate `idempotency_key` still fails on the
    existing identity, so a request never consumes twice.
- **`Agents.admit_launch(invocation_id, effective_profile)`** (new, actor
  `agent_runtime`).
  - **When it runs.** The ClaudeCLI server calls it once per dispatch: after
    dequeue, the deadline check and workspace preparation, and before it asks
    the Reaper to open the port.
  - **Transaction.** One transaction: lock the run row, then the invocation
    row; re-read both fresh and tenant-scoped; then take the chain-head lock
    **explicitly** (`Kernel.lock_head/1`, as the reservation's daily check
    already does) **before** reading any grant, allocation or switch state,
    and hold it until the sent or failed transition commits. The event
    append's own after-action lock is too late to order the eligibility
    read.
  - **As implemented (C9-03).** Between the invocation row and the chain
    head, the charged grant and then its allocation are locked `FOR SHARE`
    (the reservation's order, `Admission.lock_charge/1`); `now` is read
    after the head. An editor holding the grant therefore commits first and
    is seen (launch refused); an admission holding the share locks commits
    first (launch proceeds) and the editor waits for it. Identity and state
    refusals roll back and are then recorded as a `model.launch.refused`
    event of the actor's tenant (reason `invocation_not_found`,
    `invocation_not_claude_cli` or `invocation_not_reserved`); a non
    `agent_runtime` actor is `Forbidden`, audited as `authz.denied`.
    The locked run must still be `running` (the only status that reserves
    and settles model calls); a run stopped while its call was queued
    (`succeeded`, `failed`, `budget_exhausted`, `cancelled`) is refused as
    `run_not_running_at_launch` (check = the run status): the call is
    failed and never sent, and no launch Failure is opened, because the
    stop already has its own cause.
    The ClaudeCLI server monitors the caller before admission and re-checks
    it after admission, before the Reaper handoff: a caller that died while
    admission waited for its locks is never launched for. If admission had
    already committed `sent`, the row stays `sent` (never reset to
    `reserved`). The existing crash path recovers it only while its run is
    still `running` and abandoned (`StaleRunSweeper`: sent → unknown, never
    re-sent). A `sent` row of an already terminal run is not recovered
    (settling it also needs a running run); this is tracked below as an
    enablement prerequisite.
    Eligibility refusals record the failed check (`grant_revoked`,
    `grant_expired`, `grant_not_started`, `profile_not_in_grant`,
    `allocation_not_in_grant`, `allocation_profile_restricted`,
    `bucket_not_applicable`, `allocation_unavailable`, `profile_mismatch`,
    `legacy_generation`) on the failed row and the Failure detail; the
    Failure's subject is the invocation.
  - **Identity and state refusals (no mutation).** It refuses if the
    invocation is missing, belongs to another tenant, is not `reserved` (a
    replay of a sent, in-flight or terminal row), or is not `claude_cli`.
    Such a refusal changes nothing on that invocation or any other row. A
    sent call keeps running and settling normally. The refusal is returned
    as `{:error, reason}` and logged as `authz.denied` or a refusal event
    for the current tenant only.
  - **Eligibility refusals (owned reserved row).** Only for an invocation
    that is owned, tenant-matched and currently `reserved`, it re-checks the
    **complete non-room predicate** against current terms:
    - generation 2;
    - `profile_id` = the effective profile;
    - grant `active` (not revoked), with `starts_at ≤ t < expires_at`;
    - `profile_id` still in the grant's `profile_ids`;
    - the allocation still belongs to that grant and tenant;
    - the allocation's `profile_id` restriction, if any, still matches;
    - the trusted usage bucket is still in the allocation's `applies_to`;
    - the allocation is available at t (window and release).

    If any check fails, it moves that invocation to `failed` (never sent) and
    opens the Failure in the same committed transaction, then returns
    `{:error, reason}`.
  - **Room is grandfathered.** Room (grant total, grant day limit,
    allocation attempts) is not re-checked, because the attempt was already
    charged at reservation. A lowered cap never strands an already reserved
    call, including the last slot. Every other edit (revocation, expiry, a
    later start, a profile or bucket restriction, a closed window) does stop
    it.
  - **Success.** It marks the invocation `sent` and commits.
  - **Linearization.** Grant, allocation and setting mutators lock their own
    row, then take the chain head; they never lock a run or invocation
    afterwards. Because admission reads terms only while holding the chain
    head, either an edit commits first (launch refused) or admission commits
    first (launch proceeds; a later revocation does not kill a launched
    call). Admission never moves an invocation to another grant or profile.
  - **After admission.** A deterministic spawn failure before any process
    exists becomes `failed`. An uncertain spawn or receipt becomes `unknown`,
    with admission closed and no relaunch, as today.
- **`ModelProvider` facade.** For `claude_cli` it reserves, then hands the
  provider the reserved invocation id. It does not call `mark_sent`, and it
  re-reads the invocation before settling. The Fake path is unchanged.
- **`Runtime.status/0`** gains `desired_profile`, `effective_profile`,
  `switch: nil | %{status, to, reason}`. `ClaudeCLI` gains a `:profile`
  start option replacing the hard-coded alias, model and version constants,
  and an `:executable` option (absolute pinned path) used only by the app's
  runtime. Agent CLIs are untouched.
- **Lock order summary.** Reservation: run → candidate grants `FOR SHARE`
  → their allocations `FOR SHARE` → chain head (explicit), then the clock.
  Launch admission: run → invocation → its grant `FOR SHARE` → its
  allocation `FOR SHARE` → chain head (explicit, before the term reads; as
  implemented in C9-03). Grant and allocation edits: grant row → its
  allocations → chain head. Switch request: setting row → chain head. Refusal reporting: the
  run's Operation `FOR SHARE` → chain head (explicit, before the dedupe
  check). Run stop on a refusal: run → refusal Failure `FOR UPDATE` → chain
  head. Operation failure: Operation → Failure `FOR UPDATE` → chain head.
  Launch admission takes only share locks on grant rows, in the editors'
  order and before the head, and reads the terms under the chain head.
  Mutators never take run or invocation locks after the chain head. No
  cycles.

### C9-03 recovery delta: abandoned reserved invocations

Status: **entity PASS; implemented in C9-03** (`SDR.StaleRunSweeper`).
- Reviewer: Codex via ai-pair, 2026-10-12. Answer correlation
  m_1791841877000009253_7afb24e6 → codex-pr136-10e7eba-answer. Report:
  `~/.local/state/sdr-agent/handoff-20261008/tmp/codex-pr136-10e7eba-rereview.md`
  (entity verdict PASS at 10e7eba; code verdict then REQUEST_CHANGES until
  this was implemented and tested).
- Answers to the open questions:
  1. Both (a) and (b) are in scope. Case (b) covers explicitly terminal
     runs only; queued and live runs are left alone.
  2. The strict `reserved_at < now − stale_after_seconds` cutoff is
     acceptable as a grace period. Age is not the proof.
  3. The proof is the locked terminal run plus the locked, freshly re-read
     `reserved` state, together with the atomic sent-before-spawn contract.
     Status and age are re-checked under the locks; rows exactly at the
     cutoff and recent rows are untouched.
- The PASS covers this reserved-only delta, not tuple promotion,
  calibration, deployment or real-call enablement.

Origin: Codex PR #136 review (REQUEST_CHANGES at 543846b, must-fix 2). Moving the ClaudeCLI queue wait from `sent` to
`reserved` lets a reservation outlive its caller: a facade caller killed
while its call is queued never settles it, the server drops the dead
caller's request unlaunched, and crash recovery (`SDR.StaleRunSweeper`)
selects only `sent` rows, so the row stays `reserved` forever, even after
its run is failed. This delta makes such rows terminal.

| Entity | New / Existing | Purpose | Attributes | Relationships | Invariants / Lifecycle | Policy/Actor | Open Questions |
|---|---|---|---|---|---|---|---|
| ModelInvocation | Existing (lifecycle delta) | Close reservations proven abandoned and unlaunched | no new attributes; `error` = `%{"kind" => "abandoned_before_launch", "reason" => "run_abandoned" \| "run_stopped"}`; `sent_at` stays nil; `profile_id`, `grant_id`, `allocation_id`, `ledger_generation` unchanged | unchanged (still charged to its grant and allocation) | **Proof of "abandoned, unlaunched".** A row is `reserved` when read under its own `FOR UPDATE` lock, taken after its run's `FOR UPDATE` lock. It was never launched: `sent` is committed by launch admission before any port opens, and admission needs the run lock and a `running` run (MF1). It can never launch later: either (a) the same transaction proves the run abandoned and fails it (stale and its Oban job not live, decided again under the run, Operation and job locks, exactly as today), so later admissions see a non-running run and are refused; or (b) the run is already terminal (MF1: never launchable again) and the row was reserved before the stale cutoff (`reserved_at` < now − `stale_after_seconds`), which leaves time for a live facade to settle it itself. **Transition:** reserved → failed through the existing `:fail` action (`Agents.fail_model_invocation/3`), never `unknown` (the call provably never ran) and never back to `sent`. **No refund, no invented use:** the charged attempt is kept (grant and allocation consumption counts the row by `grant_id` / `allocation_id`, which stay); `model_calls_reserved` stays; `model_calls_used` and tokens are not settled, because `sent_at` is nil. **Idempotent:** only `reserved` rows are selected, so a failed row is never touched again; a recovered run is `failed`, so later sweeps skip it. **Never sweeps live work:** case (a) only for runs whose job is not live under its lock; case (b) only for terminal runs, whose rows launch admission already refuses. A live facade that later reaches admission gets `invocation_not_reserved`, and its re-read returns the failure without another write. | `agent_runtime` (as the sweeper today); the existing `:fail` action and policy; no new action | Answered (see the status above): (a) and (b) both in scope; the cutoff is a grace period |
| AgentRun | Existing (behaviour only) | — | none | unchanged | Case (a): unchanged; the run is failed `:crash`, opening its one attention Failure as today. Case (b): the run is not written. | unchanged | none |
| Operations.Failure | Existing (behaviour only) | — | none | unchanged | No Failure for a recovered reservation: case (a) has the run's crash Failure; case (b)'s run stop is already its cause. | unchanged | none |

**Lock order.**
- Case (a), inside the existing recovery transaction: run → Operation → Oban job → the run's `sent` **and** `reserved` invocations, `FOR UPDATE`, in sequence order → appends (chain head). This extends today's step 1, which locks only `sent` rows.
- Case (b), one transaction per run: run `FOR UPDATE` → its `reserved` invocations older than the cutoff, `FOR UPDATE` → appends.
- Both take the run first, as launch admission does (run → invocation → grant `FOR SHARE` → allocation `FOR SHARE` → head), so a recovery and a launch are serialized on the run row. No grant or allocation lock is taken (the `:fail` update does not change their key columns). No cycles.

**Tests** (`test/sdr_agent/sdr/reserved_recovery_test.exs`, real-connection orderings in `test/sdr_agent/agents/launch_admission_race_test.exs`).
- Regression: a facade caller killed while its call is queued leaves a `reserved` row.
- After recovery, case (a) leaves the run `failed` and the row `failed` with `sent_at` nil; consumption is unchanged.
- Idempotent re-sweep.
- A run whose job is live is untouched (its `reserved` row too).
- Case (b): a recent reserved row is untouched; an old one is failed.
- A launch racing recovery: either order, real connections.
- Never `unknown`.

### Tracked prerequisites before ordinary real calls

| Item | Source | Status | Required before |
|---|---|---|---|
| **Launch refusal opens two live Failures.** `Agents.admit_launch/3` opens a `provider_error` Failure about the invocation. Then `SDR.Model` treats the refusal as a generic provider error, and `AgentRun :fail` opens a second run-stopped Failure for the same cause. Fix: follow the reservation refusal's exact-cause pattern. Admission returns a receipt (reason, Failure, event, run, request id), and the run stop (and its Operation) links that exact Failure instead of opening one. This needs a reviewed AgentRun/Operation action delta, plus a worker/Operation attention test through the full SDR path. Never look up "the newest" Failure, and never take an Operation lock after the chain head. | Codex PR #136 review, important | Open. Not tiny (new AgentRun stop arguments and link provenance), so not in C9-03. | Real-call enablement (R0-07 promotion / lifting `:real_model_staged`) |
| Abandoned reserved invocations (the delta above) | Codex PR #136 review, must-fix 2 | Entity PASS; implemented | Merge of #136 |
| **`sent` rows of an already terminal run stay `sent`.** The sweeper recovers `sent` rows only for runs that are still `running` and abandoned. Settling a `sent` row also needs a running run (BudgetCounter). So a `sent` row whose run became terminal first (e.g. a dead caller after admission committed, then the run was stopped) is never settled or marked `unknown`. It is distinct from the reserved delta: a `sent` row is not proven unlaunched and must never be failed as such. It needs its own reviewed delta and tests. | Codex PR #136 re-review (10e7eba), important | Open, not implemented | Real-call enablement (lifting `:real_model_staged`) |

## 3. Out of scope

API-key providers (Anthropic API, OpenAI, Gemini, OpenRouter); concurrent
model calls (D-069); a grant editor beyond the admin form (B8 reuses it
later); real prospect data (needs the constraint-7 amendment, PR #125).
App-side Telegram: none (OQ-4, owner decision). The witness work for the
new tuples is in scope (OQ-3 = (b)), requires an ADR-0005 amendment and its
own entity/action review before that part is implemented, and is tracked as
story R0-07.

## 4. Test plan (RED first, synthetic only)

- **Pin.** Pinned binary by absolute path; missing binary refused without
  fallback; GC roots for active and rollback builds; `Runtime` → shim → pin
  wiring; the agents' own CLI selection unchanged.
- **Profiles.** Registry closed; unknown or `:fake` desired profile refused;
  per-profile `--model` and attestation; drift fails closed.
- **Legacy (migration).**
  - Terminal and non-terminal generation-1 `claude_cli` rows still complete
    every legal transition.
  - A generation-1 reserved row is refused at launch and failed.
  - A new generation-2 `claude_cli` row without profile, grant or allocation
    is rejected by the constraint.
  - New columns cannot be changed after reserve.
  - A legacy run with null `usage_origin` is refused for real calls.
- **Grants and allocations.**
  - Each action: human admin allowed; reviewer, auditor, disabled user, a
    stale role-bearing struct and every system actor denied.
  - Audit events carry previous values and revision.
  - Stale revision refused; allocation sum ≤ total.
  - Eligibility at `starts_at`, at `expires_at`, at UTC day rollover and at
    the day limit.
  - Workshop allocation unavailable before its time and available after
    release.
  - Ambiguous, missing and cross-grant allocations; cross-tenant
    references refused.
- **Reservation.**
  - Concurrent reservations for the last unit: exactly one wins.
  - Duplicate idempotency key consumes once.
  - A refusal leaves no payload, invocation or counter change, and leaves a
    persisted Failure and event (assert the stored rows, not only the
    returned tuple).
  - Concurrent and sequential repeated refusals produce one Failure.
- **Launch admission.**
  - Queued call after expiry, revocation, profile removal, a later grant
    `starts_at`, an allocation profile restriction, removal of its bucket
    from `applies_to`, or an allocation window close is refused, failed and
    never sent, with a Failure.
  - A revocation that commits after admission locked the run and invocation
    but before it read the terms is seen (launch refused).
  - Replay of a sent id while its process is running: refused, the row and
    the process are untouched and it settles normally. Terminal, foreign
    and missing ids: refused, with unchanged rows asserted.
  - Queued call after a lowered cap still launches (already charged).
  - Last-slot launch succeeds.
  - Replayed or terminal id refused; forged and cross-tenant ids refused.
  - Held revocation racing a launch: exactly one order.
  - `model_runtime` cannot call it or touch grants.
- **Switch.**
  - Admin allowed, others denied; stale revision; concurrent requests.
  - Queued old-profile calls finish or are refused.
  - Caller, server and Reaper death mid-switch.
  - Interrupted switch at boot becomes failed or blocked.
  - Stale-generation completion refused.
  - Failed activation with clean work → failed; with unconfirmed work →
    blocked.
  - Restart restores desired; history never relabelled; no model call during
    a switch.
- **Admin LiveView.** Status renders without a model call; switch and grant
  forms with confirmation; denial for non-admins.
- **Gate.** Full gate `bin/verify` on an isolated test partition, never the
  owner demo database.

## 5. Risks

| Risk | Mitigation |
|---|---|
| The pinned CLI cannot be built from the project flake (unfree licence, npm source) or the shim cannot exec an absolute path | R0-02 starts with a spike; fallback is a reviewed wrapper that still never uses `PATH`. Escalate the same day. |
| The `sonnet` alias resolves to a different model id than expected | Attestation refuses it; registry updated by reviewed change after evidence. |
| Moving the sent boundary into the server touches the reviewed lifecycle | Dedicated tests for every existing lifecycle path (queue timeout, caller death, reaper loss) plus the new admission; Fake path unchanged. |
| Scope is large for one sprint | Order: C9 (grants, allocations, admission) → profiles and pin → switch → admin UI → proof. If late, the B1 prototype moves to early S2 (owner-approved slip order). |

## 6. Questions for the owner (G5)

**Owner answers (2026-10-12):** OQ-2 "(a)"; OQ-3 "(b) with the calibration
exception", after Claude's and Codex's explanation of the bootstrap
constraint and the per-invocation gate; OQ-4 "no telegram in the app" (no
revisit story).

- **OQ-1 (resolved by mapping).** Calls are charged by where the run
  started plus what the call does, using the mapping you approved (D-104).
  Rehearsal, daily-use and workshop budgets apply by date window, which you
  set when you create G-DEMO. No job or model can choose a budget.
- **OQ-2 Who may change budgets.** Today any human admin account could.
  Proposal: accept "every human admin may change budgets" for this personal
  deployment, where your login is the only admin; adding another admin is
  itself an admin-only, audited action. Alternative: name you as the single
  budget owner in the app (a little more work).
- **OQ-3 Wire witness for the new CLI version and Sonnet.** The witness
  reconciliation was reviewed for exactly CLI 2.1.291 + Opus. Proposal: R0
  captures raw traffic for both new profiles and labels their calls
  "inferred"; reviewed reconciliation for the new pairs becomes a new story
  (R0-07, target S2-S3, not core, with its own small proof budget if G-R0
  is spent). This changes R0-06's acceptance from "witness reconciled" to
  "witness captured". Alternative: include it in R0, which likely pushes R0
  into sprint 2.
- **OQ-4 Telegram for budget exhaustion.** The plan said the app pings you.
  Proposal: the app opens a Home attention item; Claude and Codex, while
  working, see it and ping you through `bin/notify-telegram`. Limitation: if
  neither agent is running, no ping is sent. Background jobs can still spend
  budget then (follow-ups and reply processing, once B4 and B5 schedule real
  calls), and an exhaustion would wait until you open Home or an agent next
  looks. In R0 itself only runs you or the agents start make real calls.
  Proposal: accept this for R0, and add a story to revisit an app-side ping
  before B4 schedules real follow-ups. Alternative: the app sends the ping
  itself now (a reviewed outbound integration that needs the bot token at
  runtime; more scope).

## 7. Gate record (to fill)

- Entity-model reviewer: Codex via ai-pair (capabilities ai_pair=true,
  codex_review=true).
  - Round 1 at ffb5866: **BLOCKED** (consultation
    m_1791822345400446750_7d6aa44d, reply 01a130f3). Four must-fix items:
    1. the NOT VALID check still applies to legacy updates;
    2. the workshop reserve had no allocation;
    3. the launch check conflicted with the facade's sent boundary;
    4. the refusal Failure would roll back.
  - Revised in this commit: generation cutover predicate, the reserve as an
    ordinary allocation, the moved sent boundary with `admit_launch/2`, and a
    separate refusal transaction.
  - Round 2 at 8cf4fed: **BLOCKED** (consultation
    m_1791823182209851208_8ec00bce, reply 01a130ff). Three narrow items:
    1. an explicit chain-head lock before the eligibility reads;
    2. the full non-room re-check;
    3. replayed or foreign ids must not mutate the row.
  - Revised in this commit, together with atomic refusal dedupe.
  - Round 3 at dc01a65: **PASS** (consultation
    m_1791823520931364917_90effde5, reply 01a13103; private report sha256
    074d794b). The PASS covers the modeled human-admin authority. A
    designated-owner variant (OQ-2 alternative) would need a new delta and
    re-review. OQ-3 and OQ-4 are owner scope decisions. The PASS is not
    implementation, proof-call or deploy authority.
- C9 PR-B stop-action delta (AgentRun status reasons, stop arguments,
  causal link; Failure and Operation rows above): Codex at e73e132
  **NEEDS-REVIEW** (private re-review report of PR #132, 2026-10-12): bind
  the exact refusal (request, reason category, Operation), define the human
  resolution race, take the clock after the locks, and record the delta
  here. Revised in this commit; awaiting re-review. The round-3 PASS does
  not cover this delta.
  - C9 PR-B stop-action delta (AgentRun `:grant_exhausted`/`:grant_unavailable`,
    receipt arguments, Failure refusal provenance and historical-cause link,
    Operation resolution-race outcome, admission instant as `reserved_at`):
    NEEDS-REVIEW at e73e132 (Codex re-review of PR #132), then **PASS** at
    b6ee298 (Codex via ai-pair, report sha256 bc9dcf73). The PASS does not
    cover launch admission, profiles/switch or R0-07 entities.
- Owner G5: **approved.** Words: "approve R0 G5" (with "(b) with the
  calibration exception"); 2026-10-12, America/Denver; private Claude
  session chat. Gate record: `docs/sdlc/gates/G5-R0.md`.

## 8. Next authorized scope (when G5 passes)

Implement R0-02..R0-06, C2-01..C2-02 and C9-01..C9-06 as reviewed PRs
(Claude authors, Codex reviews, exact-head CI), as adjusted by the owner's
answers: human-admin grant authority (OQ-2 a), no app-side Telegram (OQ-4;
C9-06 = Failure item only), and the witness tuple work R0-07 (OQ-3 b).
Preconditions inside this scope:
- **R0-07.** Its implementation (result gate, tuple promotion) starts only
  after an ADR-0005 amendment is accepted by the owner and its entity/action
  delta has an independent PASS. Hermetic candidate projections may be
  drafted before then.
- **Calibration.** The four calibration attempts run only after C9 is merged,
  the owner has created G-R0 in the admin form, and the isolated calibration
  setup is reviewed.
- **No ordinary real calls** until a tuple is promoted.

Nothing else.
