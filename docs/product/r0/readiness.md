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
| REQ-R0-1 | The app launches the Claude CLI only from its own pinned build, by absolute path. Updating the system or agent CLI does not change what the app runs. If the pinned build is missing, real calls are refused with a typed reason; there is no fallback to the system CLI or to the Fake. |
| REQ-R0-2 | Two reviewed profiles exist: `claude_cli_opus` (alias `opus`, resolved `claude-opus-5-5`) and `claude_cli_sonnet` (alias `sonnet`, resolved `claude-sonnet-5-5`), both on the one pinned CLI version. No other model can be selected; there is no free-text model input. |
| REQ-R0-3 | Every new model invocation records its profile. Rows written before R0 keep their original values and are never relabelled. |
| REQ-R0-4 | The admin page shows the desired profile, the effective (running) profile, any pending or blocked switch with its reason, the pinned CLI version and the last attestation, without making a model call. |
| REQ-R0-5 | An admin can switch profiles on the admin page, with a confirmation step. The switch is recorded in the audit trail. The app does not restart; only the model server does. |
| REQ-R0-6 | During a switch, no new call is admitted. Calls already prepared, reserved, queued or running under the old profile finish or are refused, within a bounded wait. A call never launches under a profile other than the one it was admitted for. |
| REQ-R0-7 | If the new profile fails to activate, the old profile is restored only when nothing from the attempt is unconfirmed; otherwise the provider shows blocked with the reason until an admin acts. A restart restores the persisted desired profile. |
| REQ-R0-8 | Every real-model attempt is admitted against an owner-created grant, checked when the call is reserved and again just before it launches. Attempts count whatever their outcome and are never refunded. With no eligible grant, no real call is made. Fake calls need no grant. |
| REQ-R0-9 | Only the owner, signed in as a human admin, creates, edits or revokes a grant, or releases its reserve, through an admin form with a confirmation step; each change is audited with the previous values. No system or agent actor can change a grant. |
| REQ-R0-10 | When a grant, allocation or day limit is exhausted, or a reserved call becomes ineligible before launch, the attempt is refused with a typed reason and an operator-attention item opens (later shown as a Home row through C1). |
| REQ-R0-11 | Proof: two synthetic attempts per profile succeed through the app with attestation and wire-witness capture, and the owner switches Opus → Sonnet → Opus in the app. |

## 2. Entity model

Entity Model trigger: **yes**. New persisted resources (grant, allocation,
profile setting, switch record), new attributes and invariants on
ModelInvocation and AgentRun, a new owner-only authorization boundary, a new
lifecycle (switch), and changed backend action contracts (reservation
admission, launch admission).

| Entity | New / Existing | Purpose | Attributes | Relationships | Invariants / Lifecycle | Policy/Actor | Open Questions |
|---|---|---|---|---|---|---|---|
| ModelProfile (code registry, not persisted) | New | The closed set of reviewed model configurations | `id : atom` one of `:fake`, `:claude_cli_opus`, `:claude_cli_sonnet`; `adapter`; `cli_alias`; `resolved_model`; `cli_version`; `witness_disposition : :reconciled \| :captured_inferred` | Referenced by id from ModelInvocation, ModelProfileSetting, ModelProfileSwitch, ModelCallGrant | Changes only by reviewed code. `:fake` is never grant-checked and never selectable as the desired real profile. | n/a (code) | OQ-3 (witness disposition) |
| ModelInvocation | Existing (delta) | Ledger row per model attempt | add `profile_id : atom, nullable` (null only for rows reserved before R0), constraint: registry id; add `grant_id : uuid, nullable`; add `grant_allocation_id : uuid, nullable`. All three set by `:reserve` only; immutable afterwards (added to the terminal-immutable trigger's non-mutable set). | belongs_to ModelCallGrant (optional, `on_delete: :restrict`); belongs_to ModelCallGrantAllocation (optional, restrict) | New check constraint, NOT VALID for history: `provider <> 'claude_cli' OR (profile_id, grant_id, grant_allocation_id all not null)`. `profile_id` for a `claude_cli` row must be in the grant's `profile_ids`. Statuses unchanged. A refusal at launch moves reserved → failed with `error.reason = grant_ineligible_at_launch` or `profile_mismatch_at_launch`; never sent. | Unchanged: lifecycle actions by `agent_runtime`; reads by any present actor | none |
| AgentRun | Existing (delta) | Agent run with per-run budget | add `grant_bucket : atom, not nil for new runs, nullable for history`, one of `:b1, :b2, :b3, :b4, :b5, :proof, :rehearsal, :daily_use, :workshop` | unchanged | Set at `:create` by the entry point and immutable after; copied into each reservation's allocation selection. | Unchanged (`agent_runtime` / `scheduler` create) | OQ-1 (bucket vs. date window) |
| ModelCallGrant | New | An owner-granted budget of real-model attempts | `id : uuid_v7`; `name : string, not nil` (e.g. "G-R0"); `purpose : string, not nil`; `status : :active \| :revoked, default :active`; `profile_ids : {:array, atom}, not nil, non-empty, each a non-fake registry id`; `total_attempts : int > 0`; `per_utc_day_attempts : int > 0, nullable` (null = only the global 200/day applies); `starts_at : utc_datetime, not nil`; `expires_at : utc_datetime, not nil, > starts_at`; `reserve_attempts : int ≥ 0, default 0`; `reserve_available_from : utc_datetime, nullable`; `reserve_released_at : utc_datetime, nullable`; `revision : int ≥ 1`; `inserted_at`, `updated_at` | belongs_to Tenant; has_many ModelCallGrantAllocation; has_many ModelInvocation; `created_by` / `updated_by` belong_to User | **Consumed** = count of ModelInvocations with this `grant_id` (derived, never stored; attempts never refunded). Sum of allocations + reserve ≤ total. Eligible for a reservation at time t iff `status = :active`, `starts_at ≤ t < expires_at`, consumed < total, today's consumed < per-day limit (if set), and the chosen allocation has room. Lowering a total below consumed is allowed and simply exhausts it. Revocation is terminal. | Create / update_terms / revoke / release_reserve: **human `Accounts.User` with role `:admin` only**; every system actor (incl. `agent_runtime`, `kernel`, `seeder`) forbidden. Each action is guarded and appends `model.grant.created \| terms_changed \| revoked \| reserve_released` with previous values. Reads: admin, auditor, `agent_runtime`. | OQ-2 (owner = sole admin) |
| ModelCallGrantAllocation | New | A slice of a grant for one use | `id`; `grant_id`; `key : atom` (a `grant_bucket` value, or `:reserve` is not used: the reserve is the grant's own field); `attempts : int > 0`; `profile_id : atom, nullable` (limits this slice to one profile, e.g. G-R0 two per profile); `starts_at`, `ends_at : utc_datetime, nullable` (optional window) | belongs_to ModelCallGrant (not nil, restrict); identity unique on `[grant_id, key, profile_id]` | Consumed = invocations with this `grant_allocation_id`. A reservation picks the single allocation of an eligible grant matching the run's `grant_bucket`, the invocation's profile and the current time; zero matches → refuse `no_allocation`; more than one → refuse `ambiguous_allocation`. The reserve is usable only by bucket `:workshop` and only at or after `reserve_available_from`, or after `reserve_released_at`. | Created and changed only with its grant (same owner-only actions) | OQ-1 |
| ModelProfileSetting | New (singleton per tenant) | The persisted desired real profile | `tenant_id` (unique); `desired_profile_id : atom, not nil, default :claude_cli_opus`, non-fake registry id; `revision : int ≥ 1` | belongs_to Tenant (unique) | Changes only through ModelProfileSwitch actions. On boot the model server starts with `desired_profile_id`. | Read: admin, auditor, `agent_runtime`. No direct write action. | none |
| ModelProfileSwitch | New | One requested profile change and its outcome | `id`; `from_profile_id`, `to_profile_id : atom, not nil, different`; `status : :pending \| :completed \| :failed \| :blocked`; `requested_by : User`; `requested_at`; `finished_at : nullable`; `failure_reason : string, nullable`; `expected_setting_revision : int` | belongs_to Tenant; belongs_to User (requester) | Lifecycle: pending → completed (desired := to; server running `to`, attested); pending → failed (activation failed and old work confirmed clean; desired := from; old profile running); pending → blocked (unconfirmed work or Reaper lease held; admission stays closed); blocked → completed or failed after an admin action. At most one pending or blocked switch per tenant (partial unique identity). `request` refused if the setting revision moved (stale form) or `to = current desired`. Bounded drain: the server waits up to the per-call timeout ceiling for prior work, then refuses queued callers whose deadline would pass. | `request`: human admin. `complete` / `fail` / `block`: system actor `model_runtime` (new). `resolve_blocked`: human admin, after confirming no CLI process is left (reuses the Reaper release attestation). All append `model.profile.switch_*`. | none |
| Actor | Existing (delta) | System actor types | add type `:model_runtime` | n/a | May only perform ModelProfileSwitch `complete` / `fail` / `block`. | Granted nothing else; forbidden on grants. | none |
| Operations.Failure | Existing (delta) | Operator attention items | no new attributes; new `detail.reason` values under class `budget_exhausted`: `grant_exhausted`, `allocation_exhausted`, `no_eligible_grant`, `grant_ineligible_at_launch`; under `provider_error`: `profile_mismatch_at_launch`, `profile_switch_blocked` | unchanged | Opened in the same transaction as the refusal. | Unchanged | none |

Changed backend action contracts:

- `Agents.reserve_model_invocation/3`: for `provider: :claude_cli`, the
  existing transaction (run row lock, then chain-head lock) additionally
  selects the grant and allocation and counts consumed attempts under the
  same chain-head lock, before the payload and row are written. New error
  tuples: `{:error, {:budget_exhausted, :grant | :allocation | :grant_day}}`,
  `{:error, :no_eligible_grant}`, `{:error, :ambiguous_allocation}`,
  `{:error, :profile_switch_in_progress}`. A duplicate `idempotency_key`
  still fails on the existing identity, so one request can never consume
  twice.
- New `Agents.admit_launch/1`: called by the ClaudeCLI server immediately
  before `Port.open/2`. Under the chain-head lock it re-checks the grant
  (active, unexpired, not revoked) and that the effective profile equals the
  invocation's `profile_id`. On refusal the invocation is failed (never
  sent) and a Failure opens.
- `Runtime.status/0` gains `desired_profile`, `effective_profile`,
  `switch: nil | %{status, to, reason}`; `ClaudeCLI` gains a `:profile`
  start option replacing the hard-coded alias, model and version constants.

## 3. Out of scope

API-key providers (Anthropic API, OpenAI, Gemini, OpenRouter); concurrent
model calls (D-069); app-side Telegram sending (agents notify via
`bin/notify-telegram` when they see an exhaustion Failure, metadata only);
a grant editor beyond the admin form (B8 reuses it later); real prospect
data (needs the constraint-7 amendment).

## 4. Test plan (RED first, synthetic only)

- Profiles: registry closed; unknown or `:fake` desired profile refused;
  ClaudeCLI started per profile emits `--model <alias>` and attests the
  profile's model and version; drift still fails closed; missing pinned
  binary refused without fallback.
- Grants: owner allow / reviewer, auditor and every system actor deny for
  each action; audit event with previous values; allocations sum ≤ total;
  eligibility at boundaries (`starts_at`, `expires_at`, UTC day rollover,
  per-day limit, revoked); reserve unavailable before its time and after
  release; ambiguous and missing allocation.
- Admission: concurrent reservations at the last attempt (exactly one
  wins); duplicate idempotency key consumes once; refused-at-launch after
  expiry, revocation or profile switch while queued (invocation failed,
  never sent, Failure opened); attempts never refunded.
- Switch: admin allow / others deny; stale revision; concurrent switch
  requests; queued old-profile calls; caller death, server death and Reaper
  death during a switch; restart restores desired; failed activation with
  clean vs unconfirmed work (failed vs blocked); history never relabelled.
- Admin LiveView: status renders without a model call; switch and grant
  forms with confirmation; denial for non-admins.
- Full gate `bin/verify`; isolated test partition, never the owner demo
  database.

## 5. Risks

| Risk | Mitigation |
|---|---|
| The pinned CLI cannot be built from the project flake (unfree licence, npm source) or the shim cannot exec an absolute path | R0-02 starts with a spike; fallback is a reviewed wrapper that still never uses `PATH`. Escalate the same day. |
| The `sonnet` alias resolves to a different model id than expected | Attestation refuses it; registry updated by reviewed change after evidence. |
| Switch drain and Reaper lease interplay is subtle | Reuse the existing admission lease; switch never releases an unconfirmed lease; dedicated crash tests. |
| Scope is large for one sprint | Order: C9 → profiles → switch → admin UI → proof. If late, the B1 prototype moves to early S2 (owner-approved slip order). |

## 6. Questions for the owner (G5)

- **OQ-1 How calls pick an allocation.** Proposal: each agent run carries a
  bucket set by where it started (assigning a lead → B1, replies → B5,
  follow-ups → B4, finding people → B2, channel drafts → B3, the proof →
  proof). Rehearsal, daily-use and workshop buckets are chosen by a run
  option the owner sets when running them. A run whose bucket has no room
  stops; it never borrows.
- **OQ-2 Who counts as "owner".** Proposal: the owner's own admin login is
  the only admin account; grant actions require a human admin, never a
  system actor. If another admin is ever added, they could also edit grants
  unless we add an explicit owner flag (not proposed now).
- **OQ-3 Wire witness for the new CLI version and Sonnet.** The existing
  witness reconciliation was reviewed for exactly CLI 2.1.291 + Opus.
  Proposal: R0 captures raw traffic for both new profiles and labels their
  calls "inferred"; reviewed reconciliation for the new pairs becomes a
  follow-up story (R0-07, target S2-S3, not core). The alternative is to
  include it in R0, which likely pushes R0 into sprint 2.

## 7. Gate record (to fill)

- Entity-model reviewer: Codex via ai-pair. Verdict: _pending_.
- Owner G5: _pending_ (words, time, where).

## 8. Next authorized scope (when G5 passes)

Implement R0-02..R0-06, C2-01..C2-02 and C9-01..C9-06 as reviewed PRs
(Claude authors, Codex reviews, exact-head CI). The four proof attempts
(R0-06) run only after C9 is merged and the owner has created G-R0 in the
admin form. Nothing else.
