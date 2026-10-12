# R0 readiness packet: model runtime, profiles, switch, call grants

Status: **draft for independent review and owner G5.** Nothing here starts
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
| REQ-R0-3 | Every new model invocation records its profile, grant and allocation. Rows written before R0 keep their original values and are never relabelled, and their legal lifecycle transitions keep working. |
| REQ-R0-4 | The admin page shows the desired profile, the effective (running) profile, any pending or blocked switch with its reason, the pinned CLI version and the last attestation, without making a model call. |
| REQ-R0-5 | An admin can switch profiles on the admin page, with a confirmation step. The switch is recorded in the audit trail. The app does not restart; only the model server does. Switching makes no model call: the new server passes a no-call preflight (pinned binary present, version reported), and the model itself is attested on its first real call. |
| REQ-R0-6 | During a switch, no new call is admitted. Calls already reserved or queued under the old profile finish or are refused, within a bounded wait. A call never launches under a profile other than the one it was reserved for. |
| REQ-R0-7 | If the new profile fails to activate, the old profile keeps running when nothing from the attempt is unconfirmed; otherwise the provider shows blocked with the reason until an admin acts. A restart restores the persisted desired profile; a switch interrupted by a restart is recorded as failed (or blocked if work is unconfirmed) and never resumed silently. |
| REQ-R0-8 | Every real-model attempt is charged to exactly one allocation of one owner-created grant when it is reserved, and admitted again just before launch. Attempts count whatever their outcome and are never refunded. With no eligible grant and allocation, no real call is made and nothing is charged. Fake calls need no grant. |
| REQ-R0-9 | Only a human admin (an active, persisted user with the admin role, re-read at the time of the action) creates or edits a grant or its allocations, revokes it, or releases a held allocation early, through an admin form with a confirmation step; each change is audited with the previous values and revision. No system or agent actor can change a grant. |
| REQ-R0-10 | When a reservation is refused (no eligible grant, allocation or day room) or a reserved call is refused at launch, the refusal is committed durably as an operator-attention item and an audit event, even though the reservation itself is rolled back. |
| REQ-R0-11 | Proof: two synthetic attempts per profile succeed through the app with per-call attestation and raw wire-witness capture, and the owner switches Opus → Sonnet → Opus in the app. (Witness reconciliation for the new pairs: owner question OQ-3.) |

## 2. Entity model

Entity Model trigger: **yes**. New persisted resources (grant, allocation,
profile setting, switch record), new attributes and invariants on
ModelInvocation and AgentRun, a new admin-only authorization boundary, a new
lifecycle (switch), and changed backend action contracts (reservation
admission, launch admission, the facade's sent boundary).

| Entity | New / Existing | Purpose | Attributes | Relationships | Invariants / Lifecycle | Policy/Actor | Open Questions |
|---|---|---|---|---|---|---|---|
| ModelProfile (code registry, not persisted) | New | The closed set of reviewed model configurations | `id : atom` one of `:fake`, `:claude_cli_opus`, `:claude_cli_sonnet`; `adapter`; `cli_alias`; `resolved_model`; `cli_version`; `witness_disposition : :reconciled \| :captured_inferred` | Referenced by id from ModelInvocation, ModelProfileSetting, ModelProfileSwitch, ModelCallGrant, ModelCallAllocation | Changes only by reviewed code. `:fake` is never grant-checked and never a desired real profile. | n/a (code) | OQ-3 |
| ModelInvocation | Existing (delta) | Ledger row per model attempt | add `ledger_generation : int, not nil, default 1` (migration leaves every existing row at 1; R0 reservations write 2); add `profile_id : atom, nullable`; add `grant_id : uuid, nullable`; add `allocation_id : uuid, nullable`. All four written only by `:reserve` and immutable afterwards (excluded from the terminal-immutable trigger's mutable set and guarded by a new column-immutability check for non-terminal rows). | belongs_to ModelCallGrant (optional, restrict); belongs_to ModelCallAllocation (optional, restrict); composite FK `(allocation_id, grant_id)` → allocation `(id, grant_id)` so the allocation belongs to the recorded grant; grant, allocation, run and invocation share `tenant_id` (validated in `:reserve` and by composite FKs on `(grant_id, tenant_id)`) | Check constraint (applies to every insert and update, so it is a cutover predicate, not NOT VALID): `ledger_generation = 1 OR provider <> 'claude_cli' OR (profile_id, grant_id, allocation_id all not null)`. Generation-1 rows keep every existing transition (reserved/sent → failed/unknown/completed); a generation-1 `claude_cli` row is refused at launch (`legacy_invocation_without_grant`) and failed, never launched. **Sent boundary (changed):** for `claude_cli` the facade no longer marks sent before the provider call; the row stays `reserved` through queueing and becomes `sent` only inside `admit_launch/2` (below). Fake keeps today's order. | Unchanged: lifecycle actions by `agent_runtime`; reads by any present actor | none |
| AgentRun | Existing (delta) | Agent run with per-run budget | add `usage_origin : atom, nullable` (null only for runs created before R0), one of `:assignment, :referral, :reply, :followup, :discovery, :channel, :proof` | unchanged | Set at `:create` by trusted server code from the entry point (never from job args a caller can forge, never from model output); immutable; `:retry` copies it. A real reservation for a run with null `usage_origin` is refused (`no_usage_origin`), fail-closed. | Unchanged (`agent_runtime` / `scheduler` create; admin retry) | none |
| ModelCallGrant | New | An owner-granted budget of real-model attempts | `id : uuid_v7`; `tenant_id`; `name : string, not nil` (e.g. "G-R0"); `purpose : string, not nil`; `status : :active \| :revoked, default :active`; `profile_ids : {:array, atom}, not nil, non-empty, non-fake registry ids`; `total_attempts : int > 0`; `per_utc_day_attempts : int > 0, nullable` (null: only the global 200/day applies); `starts_at`, `expires_at : utc_datetime, not nil, expires_at > starts_at`; `revision : int ≥ 1`; `created_by_id`, `updated_by_id`; timestamps | belongs_to Tenant; has_many ModelCallAllocation; has_many ModelInvocation; belongs_to User (created_by, updated_by) | Consumed = count of ModelInvocations with this `grant_id` (derived, never stored, never refunded). Invariant: sum of its allocations' `attempts` ≤ `total_attempts` (checked on every terms edit under the grant row lock). Revocation is terminal. Edits carry `expected_revision` and are refused if stale. Lowering a total, day limit or allocation below what is consumed is allowed; it only stops new reservations. | `create`, `update_terms`, `revoke`: human admin only (active persisted `Accounts.User`, role re-read in the action); every system actor forbidden. Each action is guarded and appends `model.grant.created \| terms_changed \| revoked` with previous values and revision. Reads: admin, auditor, `agent_runtime`. | OQ-2 |
| ModelCallAllocation | New | One spendable slice of a grant | `id`; `tenant_id`; `grant_id`; `key : atom, not nil` (`:b1`..`:b5`, `:proof`, `:rehearsal`, `:daily_use`, `:workshop`); `applies_to : {:array, atom}, not nil` (usage buckets it may fund); `profile_id : atom, nullable` (restricts to one profile, e.g. G-R0's two per profile); `attempts : int > 0`; `available_from`, `available_until : utc_datetime, nullable`; `released_at : utc_datetime, nullable` | belongs_to ModelCallGrant (not nil, restrict); identity unique on `[grant_id, key, profile_id]`; unique `(id, grant_id)` for the invocation composite FK | The **workshop reserve is an ordinary allocation** (`key :workshop`, `available_from` = workshop day start), so there is one balance and no double counting. Available at t iff (`released_at` set or `available_from` null or t ≥ `available_from`) and (`available_until` null or t < `available_until`). Consumed = invocations with this `allocation_id`. Owner "release" sets `released_at` (early availability); owner "redistribute" is a terms edit moving attempts between allocations within the grant total; history is never rewritten because consumption is derived from immutable invocation rows. Never borrows from another allocation. | Created and changed only through its grant's admin actions (`update_terms`, `release_allocation`), audited (`model.grant.allocation_released`) | none |
| ModelProfileSetting | New (singleton per tenant) | The persisted desired real profile | `tenant_id` (unique); `desired_profile_id : atom, not nil, default :claude_cli_opus`, non-fake registry id; `revision : int ≥ 1` | belongs_to Tenant (unique) | Changes only when a switch completes. On boot the model server starts with `desired_profile_id`. | Read: admin, auditor, `agent_runtime`. No direct write action. | none |
| ModelProfileSwitch | New | One requested profile change and its outcome | `id`; `tenant_id`; `from_profile_id`, `to_profile_id : atom, not nil, different`; `status : :pending \| :completed \| :failed \| :blocked`; `requested_by_id`; `requested_at`; `finished_at : nullable`; `failure_reason : string, nullable`; `server_generation : int` (the server start the switch belongs to) | belongs_to Tenant; belongs_to User (requester) | pending → completed (new server passed no-call preflight; setting.desired := to, revision +1, same transaction); pending → failed (activation failed and old work confirmed clean; old profile keeps running; desired unchanged); pending → blocked (unconfirmed work or Reaper lease held; admission closed); blocked → completed or failed after an admin action. At boot a still-pending switch is set failed (`interrupted_by_restart`), or blocked if the Reaper lease shows unconfirmed work; the server starts with `desired_profile_id`. Completion/failure actions are idempotent on `(id, server_generation)` and refuse a stale generation. At most one pending or blocked switch per tenant (partial unique identity). `request` refused if setting revision is stale or `to` = current desired. | `request`, `resolve_blocked`: human admin (resolve reuses the Reaper release attestation that no CLI process is left). `complete` / `fail` / `block`: system actor `model_runtime` only. All append `model.profile.switch_*`. | none |
| Actor | Existing (delta) | System actor types | add type `:model_runtime` | n/a | Authorized only for ModelProfileSwitch `complete` / `fail` / `block`. No invocation, grant, allocation or setting write authority. `admit_launch/2` runs as `agent_runtime`, like `mark_sent` today. | n/a | none |
| Operations.Failure | Existing (delta) | Operator attention items | no new attributes; new `detail.reason` values: class `budget_exhausted`: `no_eligible_grant`, `no_allocation`, `ambiguous_allocation`, `grant_exhausted`, `allocation_exhausted`, `grant_day_exhausted`, `no_usage_origin`; class `provider_error`: `grant_ineligible_at_launch`, `profile_mismatch_at_launch`, `legacy_invocation_without_grant`, `profile_switch_blocked` | unchanged | Reservation refusal: opened in its **own** committed transaction after the reservation transaction rolls back (see contracts), deduplicated so a repeat of the same reason for the same grant and run while one is open adds no second item. Launch refusal: opened in the same transaction that fails the invocation. | `:open` by `agent_runtime` (existing system-actor permission) | none |
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
  - **Locks and selection.** Inside the existing transaction and lock order
    (run row, then chain head), and before the payload and row are written,
    it selects the eligible allocation: its grant is active, `starts_at ≤ t <
    expires_at`, the profile is in the grant's `profile_ids` and matches the
    allocation's `profile_id` if set, the bucket is in `applies_to`, and the
    allocation is available at t.
  - **Room check.** Grant consumed < total, grant today's (UTC, by
    `reserved_at`) consumed < day limit, and allocation consumed < attempts.
  - **Allocation choice.** Exactly one allocation must match. Zero matches
    refuses with `no_allocation` or `no_eligible_grant`. Two or more refuses
    with `ambiguous_allocation`. Owners configure non-overlapping windows
    (e.g. G-DEMO: `:b1`..`:b5` until Oct 26; `:rehearsal` Oct 27-29 for all
    buckets; `:daily_use` Oct 30-Nov 5; `:workshop` from Nov 6 or on
    release).
  - **Refusal path.** The transaction returns the error and rolls back, so
    there is no payload, no invocation and no counter change. The caller then
    opens the deduplicated Failure and appends `model.reservation.refused`
    in a separate guarded transaction as `agent_runtime`, and returns
    `{:error, reason}`.
  - **Duplicates.** A duplicate `idempotency_key` still fails on the
    existing identity, so a request never consumes twice.
- **`Agents.admit_launch(invocation_id, effective_profile)`** (new, actor
  `agent_runtime`).
  - **When it runs.** The ClaudeCLI server calls it once per dispatch: after
    dequeue, the deadline check and workspace preparation, and before it asks
    the Reaper to open the port.
  - **Transaction.** One transaction: lock the run row, then the invocation
    row; re-read both fresh and tenant-scoped; then take the chain-head lock
    through the event append.
  - **Refusal conditions.** It refuses if the invocation is missing, belongs
    to another tenant, is not `reserved` (this blocks replay of a terminal or
    already sent row), is generation 1, or is not `claude_cli`. It also
    refuses if its `profile_id` ≠ the effective profile.
  - **Grant terms re-check.** Grant not revoked; t < `expires_at`; profile
    still in `profile_ids`; allocation still in the grant and available. Room
    is not re-checked: the attempt was already charged at reservation. So a
    lowered cap never strands the last reserved slot, and a revocation or
    expiry does stop it.
  - **Outcome.** On success it marks the invocation `sent` and commits. On
    refusal it fails the invocation (never sent) and opens the Failure in the
    same committed transaction, then returns `{:error, reason}`.
  - **Linearization.** Grant revocation and terms edits also append under
    the chain-head lock, so either the edit commits first (launch refused) or
    admission commits first (launch proceeds; revocation does not kill a
    launched call). Admission never moves an invocation to another grant or
    profile.
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
- **Lock order summary.** Reservation: run → chain head. Launch admission:
  run → invocation → chain head. Grant edits: grant row → chain head (the
  reservation never locks grant rows; it reads committed terms under the
  chain head). Switch request: setting row → chain head. No cycles.

## 3. Out of scope

API-key providers (Anthropic API, OpenAI, Gemini, OpenRouter); concurrent
model calls (D-069); a grant editor beyond the admin form (B8 reuses it
later); real prospect data (needs the constraint-7 amendment, PR #125).
App-side Telegram sending and witness reconciliation for the new pairs are
owner questions (OQ-4, OQ-3), not silent cuts.

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
  - A repeated refusal is deduplicated.
- **Launch admission.**
  - Queued call after expiry, revocation, profile removal or allocation
    window close is refused, failed and never sent, with a Failure.
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
  neither agent is running, no ping is sent, though in that case nothing is
  spending budget unless you are using the app yourself. Alternative: the
  app sends the ping itself (a reviewed outbound integration that needs the
  bot token at runtime; more scope).

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
  - Round 2 verdict: _pending_.
- Owner G5: _pending_ (words, time, where).

## 8. Next authorized scope (when G5 passes)

Implement R0-02..R0-06, C2-01..C2-02 and C9-01..C9-06 as reviewed PRs
(Claude authors, Codex reviews, exact-head CI), as adjusted by the owner's
answers to OQ-2..OQ-4. The four proof attempts (R0-06) run only after C9 is
merged and the owner has created G-R0 in the admin form. Nothing else.
