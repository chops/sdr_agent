# C1-03: fixed inbox commands

Status: **entity PASS; draft-3 implementation plan and slice A RED PASS**.
No implementation, RED tests or H1 screen changes yet.
Base: merged main `6f271abef7b3cfefa2c7eb6defcb07602c003181`, including
C1-02 (#169). Owner D-154 assigns C1-03 and the H1 packet to Codex, with
Claude reviewing. D-155 retains the full Nov 6 core and the existing
RC/S6 plan pending an approved replan; this document changes no dates.

## Summary and authority

Implement the fixed command portion of the accepted
[C1 contract](readiness.md), under accepted
[ADR-0015](../../adr/0015-home-inbox-projection-and-command-boundary.md).
The independently reviewed base entity/full contract and scoped C1 G5
remain the authority. This draft makes C1-03's implementation obligations
explicit; it does not expand the gateway into arbitrary domain dispatch.

Initial implemented commands are `approve_capture`, `edit_draft`,
`reject_draft` and `retry_run`, corresponding to scoped G5's
approve/edit/reject/re-run. Failure inspection and existing
acknowledge/resolve routes remain source-owned navigation, not newly
implemented mutations in this slice. This is a disclosed subset of the
six modeled commands in C1-01, not a claim that all six are implemented.
Claude confirmed this slice boundary in `81eea069`; the wider six-command
model is not retired.

Not included: H1 LiveViews, new producers/counts/tables, new actors or
roles, model enablement, real-data processing, grant mutation, automatic
retry, Reaper cleanup/release, external delivery, migrations or a task
lifecycle. Ordinary real calls remain staged. Layer 2 is Claude's separate
work; this gateway cannot bypass it.

## Entity Model

Entity Model trigger: **yes**.
Reason: implementing an ephemeral command/result and source-owned atomic
compare-and-mutate contracts changes the backend action surface. No new
persisted entity, attribute, relationship or policy authority is proposed.

| Entity | New / Existing | Purpose | Attributes | Relationships | Invariants / Lifecycle | Policy/Actor | Open Questions |
|---|---|---|---|---|---|---|---|
| InboxCommand | Existing modeled concept, new implementation contract | Execute one displayed condition's fixed command | Required opaque `item_id`, closed `action_id`, `expected_freshness_token`; action-specific exact revision/hash/recipient/channel binding and validated arguments. No actor, tenant, resource, module, function or URL selected by request. No new persisted idempotency record | Identifies one existing draft-review or Failure-attention condition through the fixed producer binding; no new FK, ownership or independent command status | Strict field/action/source-pair validation; current actor/source re-read; freshness comparison and mutation protected together by source-owned locks. Matching token is not authorization. Never replace the displayed binding with the newest facts | Authenticated active human in one server-owned tenant; source read and write policies apply. Draft commands retain existing admin/reviewer authority; retry is active-admin-only. Auditor/system/disabled/cross-tenant mutation denied | OQ-1: confirm the four-command initial slice; no ack/resolve gateway mutation added without reviewed scope |
| InboxCommandResult | Existing modeled outcome, new implementation contract | Report committed source outcome or safe refusal | Existing C1 result: `{:ok, %{outcome: :applied or :already_resolved, refresh?: true}}`; closed error category `:stale`, `:forbidden`, `:not_found`, `:blocked`, `:invalid_input`, `:producer_error`; safe stale category revision/recipient/lifecycle/recovery_guard where authorized | Refers only to the command's authorized source outcome; no bodies, tokens, alternate recipients or raw source errors echoed | Applied only after the producer action commits; already_resolved only from a producer-proven replay. A repeated stale command can refuse instead; it cannot create a second capture/run. Failure does not erase a row or manufacture success. UI must re-list after committed success | Result reveals no existence or content for unauthorized/cross-tenant refs; existing guarded denial audit remains | Exact representation of safe error details is deferred until the source APIs are inspected after this soft-stop; no additional reason families assumed |
| Outreach draft / revision / approval source adapter | Existing backend action-contract delta | Protect displayed draft freshness and exact source action atomically | No new persisted fields. Existing draft/revision id, content hash, recipient and email channel; validated edit fields or rejection reason | Uses existing enrollment/draft/campaign/contact/revision/approval ownership; the source domain retains all writes | Existing enrollment -> draft -> campaign -> contact -> audit-head order. Recompute source freshness while protected; edit/reject may not mutate a different revision or recipient after an unlocked check. Approval preserves exact displayed revision/hash/email. Edit keeps pending identity but creates source revision and invalidates old approval under source rules. Suppression/real-data/capture guards remain | Existing Outreach actions and their current actor checks; no raw resource mutation or policy bypass | Precise existing API fit and any required narrow source-action delta must return for review after inspection, before RED/implementation |
| Operations.Failure attention condition | Existing referenced action-context delta | Bind a retry request to exactly the displayed live condition | Existing id/status/subject/Operation/recovery metadata; no new columns | Failure belongs to its existing tenant and references an authorized retryable run through a closed typed mapping; arbitrary subject strings never dispatch | Open/acknowledged are live; resolved historic cause cannot be revived or silently replaced by another live Failure. Retry does not resolve a Failure merely to remove Home's row. Ack/resolve mutation semantics unchanged | Existing read/navigation policy; gateway retries only through active-admin run recovery, not by Failure.retryable alone | Source subject/run mapping is verified after PASS; unsupported subjects remain navigation/blocked, not speculative retry |
| AgentRun / Operation retry source adapter | Existing backend action-contract delta | Start one explicit new attempt through existing guarded recovery | Existing run id and retry/source-state metadata, current failure binding and human confirmation; no new lifecycle state or cleanup authority | New attempt uses existing source retry relationship; original run, invocation, failure and immutable provenance remain | Existing retry action owns comparison and mutation in its reviewed lock order. Double submission must not create a second new run/job. Any source-run invocation still reserved or sent, or unknown without reviewed settlement, blocks retry with no new run/job or audit success; this explicitly includes terminal-run sent rows and does not depend on layer-2 E1 landing. The gateway settles nothing. Unknown/unconfirmed cleanup, current provider/witness/grant or staging refusal cannot become retry permission. A later model call still reserves and rechecks at launch; advisory eligibility is not a reservation. No old result is released or reused | Existing active-admin-only retry and existing Operation-kind rules; humans cannot acquire system actor rights through the gateway | Atomic current-state/guard fit is checked after PASS. An unavailable guard yields blocked, not an enabled command; no new recovery authority inferred |
| InboxItem / InboxAction | Existing command-consumer delta | Supply stable source identity and advisory action binding | Existing metadata-only identity/freshness/capability fields; no new count or cursor format | Same two fixed producers; command never writes an Item or Action | Projection capability is not authorization. Current actor/source/guard checks determine execution. Edit changes freshness, not stable identity. A command does not trust a cached label, count, capability or hidden button | Existing list/read rules and current scoped actor | Reuse the merged C1-02 identity/freshness representation after the entity gate; incompatible changes require explicit review |
| Accounts.User / authenticated session / Tenant; ModelInvocation / ModelResultRelease / grants / witness / Reaper | Existing dependency | Existing authorization, release, billing and cleanup boundaries | unchanged | unchanged | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found. The gateway consumes current authenticated scope and existing guarded actions; it adds no session mechanism, release path, refund, grant edit, cleanup proof or lease operation | Existing policies and authoritative seams unchanged | Any discovered need to change these boundaries stops this slice for a separate delta |

Configured capabilities: `.workflow/recipe.json` has `ai_pair=true` and
`codex_review=true`. Reviewer precedence: ai-pair; reviewer **Claude**.
Draft-1 verdict: **NEEDS-REVIEW** by Claude, narrow must-fix: explicit
reserved/sent/unsettled-unknown retry refusal, including terminal-run sent.
Request `m_1792275394258875625_24167152`; answer
`m_1792275466070583000_81eea069`, 2026-10-17T22:17:46Z, reviewing draft-1
SHA256 `37a291e30295667324f6a803b79a7bd4ba72e60dce921b597a61ceea374d8f32`.
Review report SHA256
`f44739718d567fe28ddeef76f79d8559dc0ac670f5261585d1a917519b299c48`.
OQ-1: **CONFIRMED**, four-command subset stays inside scoped G5.
Draft-2 verdict: **PASS** by Claude, answer
`m_1792275600669312000_b6151911`, 2026-10-17T22:20:00Z, replying to
`m_1792275537524729000_4c21c534`, reviewing SHA256
`160fd07a97ac29030030f3d42b66ee9e85c4b47e8523762f91870ba7eb6bf811`.
The entity PASS permitted affected-module planning, not RED by itself.
Draft-3 implementation-plan verdict: **PASS for the plan and slice A RED**
by Claude, answer `m_1792276261466884000_c0d042d9`,
2026-10-17T22:31:01Z, replying to
`m_1792276221260854875_b2b6b2ee`, reviewing SHA256
`3c7fef6fd72159e17a3a4964efae0310c7844869452e76b2e7e81654d8d56a62`.
Claude independently verified the exact lock order and strengths against
`BindApproval`. RED obligations: locked-row freshness; explicitly flag the
edit-capability expectation change; assert retry remains blocked in A;
real-session revocation/demotion during lock wait; content/reason canaries
absent from errors, logs and audit diagnostics. B remains gated on its
separate preview/eligibility contract before B RED. Any newly identified
semantic source-action delta returns for entity review, rather than being
authorized by this status line.

## Observable behavior

1. Only the four fixed commands above and their exact source/action pairs
   enter the gateway. Reject unknown keys and malformed/forged bindings;
   never convert arbitrary input to atoms or dispatch a caller's module.
2. Actor and tenant are supplied by the current authenticated server scope,
   not the command. Revalidate the current actor/session as required by
   existing authentication and source policies; a cached role-bearing
   struct or earlier page authorization does not grant mutation authority.
3. Freshness and source mutation are one source-owned atomic operation,
   with dependent rows before audit head. The gateway takes no generic
   head lock or organizing process. No unlocked read-then-write adapter.
4. `approve_capture` binds the displayed revision id, lowercase content
   SHA256 and exact recipient email, with email channel. It invokes the
   governed approval/capture path only; it never sends a real message.
5. `edit_draft` binds the displayed revision/token plus validated new
   subject/body and only existing permitted optional fields. Concurrent
   edit or recipient change refuses the old command; no overwrite or
   silent retarget. No sensitive content is copied into gateway results,
   log metadata or a new task store.
6. `reject_draft` requires a nonempty reason and exact revision/hash;
   recipient/channel remain part of the atomic freshness check. Do not
   claim the existing source reject action independently compares email
   unless the reviewed adapter actually enforces that comparison.
7. `retry_run` requires explicit human confirmation and exactly the
   displayed Failure/run context. It calls only the existing guarded retry
   operation. Inspect/resolve remains available through its permitted
   source route when retry is blocked; no retry merely to clear a card.
   Preserve the existing retry action's own original-Failure resolution
   semantics exactly; the gateway adds or removes no resolution step.
   The no-unsettled-invocation rule below is an additional mandatory
   eligibility condition, not new recovery authority.
8. All duplicate submissions either return a producer-proven existing
   outcome or a safe stale/already-resolved refusal, with no duplicate
   capture, revision or retry job. A successful gateway result means the
    domain action committed, not that a later model call or delivery ran.
9. Time-dependent eligibility is checked at execution even if the token
   still matches. Nothing here reserves a grant or proves cleanup. Losing
   authorization or a source read/guard prevents mutation, not a fake
   empty/success result.
10. Keep the C1 error categories. Do not expose raw Ash/Postgrex/process
    errors, content, alternate recipients or hidden ids. A refusal leaves
    the source's durable state/audit semantics intact. Counts cannot grant
    or revoke an otherwise valid command; H1 will refresh committed state.

### Retry: no unsettled source-run invocation

Every eligibility read and execution path used by C1-03 must treat any
source-run invocation still `reserved` or `sent`, or an `unknown` outcome
without reviewed settlement, as blocking. Return C1's typed `:blocked`
category with the existing `:unknown_outcome` blocked reason; do not mutate
an invocation into that status merely to return the reason. Create no new
run/job, capture, approval or success audit event, and leave the source
run, invocation and Failure unchanged. Existing guarded refusal/denial
audit semantics are not suppressed.

In particular, a terminal source run with a `sent` invocation remains
blocked: its terminal run status and an open/resolved Failure are not
evidence that the invocation settled or that its child work stopped.
This guard must hold on the current baseline, independently of E1's
future settlement work. The gateway does not settle the invocation,
refund it, release a lease or acquire recovery authority. A later E1
transition to `unknown` is not by itself cleanup proof or retry permission.
If no existing reviewed positive settlement/cleanup evidence can be
obtained, keep retry blocked; do not invent a C1 settlement marker.

The implementation plan must pin the authoritative source facts and
atomic lock/read boundary for this guard after the entity gate passes.
The adapter cannot replace it with a cached capability, Failure.retryable,
run-terminal check or a successful lookup from another run/tenant.

## Required RED evidence

- One real successful subject path for every command in the implemented
  subset; no all-blocked dispatcher masquerading as GREEN.
- Unknown/malformed/extra fields, unknown producer/action, wrong pairs,
  forged id/token and foreign-tenant references; no source mutations or
  hidden-detail leakage.
- Auditor, disabled/demoted user, revoked session and stale actor snapshots;
  positive admin/reviewer draft paths and admin-only retry.
- Stale revision/hash, changed recipient, contact suppression/inactive
  state, closed campaign and real-data-off; assert source rows and audit
  effects, not just return tuples.
- Controlled interleavings prove comparison and mutation share the source
  lock boundary. Double approve/edit/reject/retry cannot create duplicate
  source work; retry preserves the original historic records.
- Failed/unknown prior CLI work, held/missing provider, staged ordinary
  calls, absent/expired/revoked/exhausted allocation, witness withholding
  and unreadable guard facts cannot enable unsafe retry.
- A terminal source run with a `sent` invocation and open Failure returns
  typed blocked/unknown_outcome: no new run, job or success audit; source
  rows unchanged. Cover `reserved` and unsettled `unknown` too, and prove
  the rule does not depend on E1 being merged or on run status alone.
- Resolved Failure versus a distinct live Operation cause; no newest-cause
  lookup, arbitrary subject dispatch or automatic cause resolution.
- Returned and raised producer failures use safe typed outcomes; canary
  body/reason/model payload does not leak into errors/logs/audit diagnostics.
  All fixtures remain synthetic; no real model calls.

## ADR and implementation gate

No new ADR is proposed: this implements the accepted ADR-0015 stateless
fixed-command/source-owned mutation boundary, without new persistence,
dynamic dispatch, cleanup authority or producer registration. If source
inspection requires a changed durable boundary or materially different
lock/authorization contract, return for entity/ADR review rather than
silently widening this plan.

The source inspection and staged implementation plan below follow the
entity/action PASS. Independent intended-reason RED verification precedes GREEN.
Full gate, exact-head CI, independent code review and owner merge remain
required. H1's packet/G5 is separate; no H1 code starts from this contract.

## Source inspection and interface refinements

These are proposed implementation contracts, not claims of existing code.

- `Inbox.refresh/2` already accepts a stored user-session token and resolves
  it through `Accounts.current_operator/1`; it does not accept an actor
  option. Reuse that session boundary for commands. After waiting for source
  locks, revalidate the token/current operator again before writing, so a
  revocation or demotion during lock wait cannot use the entry actor.
- Current item ids and freshness are HMAC digests, not decodable source
  references. A command therefore needs the displayed `source_id` UUID
  beside its `item_id`; action id determines the resource. Recompute both
  HMACs against the authorized source row. No scan of the whole inbox and
  no caller-provided resource/module or unverified run id.
- `Outreach.edit_draft/3` accepts `subject`, `body_text`, optional `angle`
  and `cta`; no other edit fields. `Draft :edit` locks the draft but does
  not compare displayed revision/recipient. It needs the source adapter's
  transaction and locks around the existing action.
- `BindApproval` already locks enrollment -> draft -> campaign -> contact
  -> head. It checks revision/hash for approve and reject; only approve
  compares recipient email. The command adapter must enforce the complete
  displayed freshness for all three draft commands while holding that same
  lock order, then invoke the existing guarded action.
- `SDR.Retry` already locks lead -> campaign -> prior run -> Operation ->
  attention Failure -> original job -> head, with child/trigger/job guards.
  Its current `settled/2` rejects sent rows only. The C1-specific entry must
  additionally block reserved/sent/unsettled unknown while holding the
  prior-run lock; it cannot call the old action after an unlocked check.
- `AgentRun :retry`'s existing `ResolveAttention` resolves live Failures of
  the prior run in the source transaction, with a note naming the new run.
  Preserve that exact source behavior; add no gateway-only resolution.
- `Audit.transaction/1` queues guarded denial audit until after the outer
  transaction ends. Use it, not a raw Repo transaction, for command writes.
  Existing source guards remain enabled; no new `authorize?: false` path.

### Proposed command shape

`Inbox.command(session_token, command)` is a synchronous backend API.
Canonical command maps use atom keys and fixed action atoms; no arbitrary
string-to-atom conversion or permissive Ash cast of the request is allowed.
Unknown keys or string/atom aliases are refused, not silently dropped.
H1 will later construct this typed request through a fixed parameter map;
it will not forward raw browser parameters as a domain command.

Common required fields:

    %{action_id: action, source_id: displayed_source_uuid,
      item_id: displayed_item_id,
      expected_freshness_token: displayed_token, args: action_arguments}

All ids and digests are validated before source dispatch, after session
authentication. `source_id` is a draft id for draft commands, and the exact
displayed Failure id for retry; it is never a run id supplied by the caller.
This field refines the already modeled command's source binding and needs
explicit confirmation in this plan review.

| Action | Exact arguments |
|---|---|
| `approve_capture` | `draft_revision_id`, lowercase `content_sha256`, exact displayed `recipient_email`, `channel: :email` |
| `edit_draft` | The same displayed revision/hash/recipient/channel binding, plus required `subject`, `body_text`; only optional `angle`, `cta` |
| `reject_draft` | The same displayed revision/hash/recipient/channel binding, plus nonempty `reason` |
| `retry_run` | `confirm: true`; run identity is derived and verified from the displayed Failure and the locked prior run |

Binding fields are consumed by the adapter, not passed as new permissive
arguments to existing Ash actions. Edit passes only its four source fields;
approve/reject pass only their existing source binding/reason fields.
Source validation stays authoritative; no new body limits or new persisted
arguments are invented here.

### Duplicate and error outcomes

This initial implementation chooses a **stale refusal for every repeated
command**, rather than asserting a successful replay without a receipt.
`already_resolved` remains part of the wider C1 model but is not emitted by
this implementation. This is permitted by the reviewed contract.

| Action | Source fact that makes the old command stale |
|---|---|
| Approve | Draft is no longer pending, or its revision/recipient/freshness changed; an existing approval is not a fresh approval request |
| Edit | Current revision/token changed; identical edit content is not proof that this command committed |
| Reject | Terminal/non-pending draft or changed binding; no new rejected Approval is created |
| Retry | Existing retry child, changed/resolved source Failure or changed recovery context; no second job/run |

Map source lifecycle/revision/recipient/recovery refusals into the existing
safe C1 categories without returning the source error term. Forbidden
remains audited through the source guard. A generic producer error or lost
reply is not a promise of rollback: consumers must re-read authoritative
state and must not automatically retry or claim 'not applied'. No input
body, reason, session token or raw exception is logged by this boundary.
The H1 packet must cover sensitive-input tagging for its channel/tasks
before it starts holding operator edits; this plan adds no H1 process.

Exact error representation was confirmed by Claude in answer
`m_1792276534986533000_7f2b090a`, 2026-10-17T22:35:34Z, replying to
`m_1792276460103465750_25cbb419`: `{:error, %{reason: category}}` with
the six C1 categories, optionally `change: :revision | :recipient |
:lifecycle | :recovery_guard` only on authorized stale outcomes, or
`blocked_reason:` from C1's existing closed codes only on authorized blocked
outcomes. No other keys or raw terms. Unknown, foreign-tenant and otherwise
unreadable source references return byte-identical
`{:error, %{reason: :not_found}}`, with no change/block detail. `:forbidden`
is actor/session/role-level refusal, not an existence oracle.

## Affected Modules (proposed)

- `lib/sdr_agent/inbox.ex`: expose `command/2`; retain refresh/count/cursor
  behavior except the capability change explicitly covered by RED.
- `lib/sdr_agent/inbox/command.ex`: new strict command parser and fixed
  source dispatch; no persistence, process, query or generic action runner.
- `lib/sdr_agent/inbox/binding.ex`: pure shared identity/freshness/HMAC
  codec extracted from the existing private helpers, preserving their
  current version and digest inputs. No domain reads or policy decisions.
- `lib/sdr_agent/outreach.ex` and `outreach/inbox_commands.ex`: fixed
  source-domain command entry and atomic adapter for the three draft
  commands. Reuse the existing guarded approve/edit/reject APIs.
- `lib/sdr_agent/outreach/inbox.ex`: an id-bound metadata fetch using the
  same current context/release/synthetic predicates; no all-page lookup,
  body load or new list/count membership policy.
- Later retry slice: `lib/sdr_agent/sdr.ex`, `sdr/retry.ex` and an optional
  source-local retry-binding helper. Its exact preview/read API and bounded
  query contract are reviewed separately before that slice's RED, as below.
- Tests: `test/sdr_agent/inbox/command_test.exs`,
  `test/sdr_agent/outreach/inbox_commands_test.exs`,
  `test/sdr_agent/inbox/command_race_test.exs`; new domain-API fixtures only
  where existing synthetic fixtures cannot express the subject.

The shared codec depends on no facade/domain. Source adapters may use the
codec, but never call `Inbox.refresh/2` or depend on its counts. No source
write moves into the web layer or a shared application dispatcher.

## Implementation Steps

The story is two independently reviewed code slices; it is not complete
until both land. This plan requests approval to prepare **slice A RED**,
not to skip the remaining retry design gate.

1. **A RED: three draft commands and command boundary.** Tests assert the
   missing public API with ExUnit before invoking it (no UndefinedFunction
   crash); exercise approve/edit/reject success, strict input/authentication,
   stale/foreign/source-policy refusals and safe result shapes through the
   real public APIs. Add controlled edit/recipient/role races and duplicate
   submissions. Change the existing 'edit blocked until C1-03 exists'
   capability assertion during RED to its new intended behavior and flag
   that deliberate change in the RED request. Do not alter retry's current
   blocked capability in A. Send intended-reason failures for independent
   tdd-verify; no production changes during RED.
2. **A GREEN: smallest parser/codec/source adapter.** Source command entry
   authenticates and reads the authorized draft metadata to name its
   immutable dependent ids, enters `Audit.transaction`, locks enrollment
   FOR SHARE -> draft FOR UPDATE -> campaign FOR SHARE -> contact FOR SHARE,
   re-reads the bound metadata and token/current operator, verifies the
   source's synthetic/release/integrity and command freshness predicates,
   then calls the existing guarded source action. No head lock is acquired
   in advance. The source actions still own approval/outbox, revision and
   rejection writes. Returning a refusal rolls back source work, preserving
   the source's post-transaction guarded denial audit. Actor-permitted edit
   is enabled only after the adapter exists; safe edit/reject do not become
   approval or model-call permission.
3. **A verification/review.** Run source action, existing C1 projection and
   new command suites; independently exercise the actual transaction
   boundaries with separate test connections. Then full gate, privacy and
   architecture review, exact-head CI and owner merge. Extracting the codec
   must preserve existing item ids/tokens; no blanket snapshot/test rewrite.
4. **B source contract before RED.** Add a fixed `SDR` inbox-retry entry
   joining the existing `SDR.Retry` locked path before any write, not a
   wrapper that takes a Failure lock first and calls retry later. The
   displayed Failure must be the prior run's exact attention Failure with
   the expected subject/tenant and live state; unsupported subjects stay
   navigation/blocked. Preserve lead -> campaign -> prior run -> Operation
   -> Failure -> original job order, perform the stricter invocation-status
   check under the run lock, and keep the original child/job/trigger/depth
   checks and source `ResolveAttention` behavior. Re-authenticate after
   lock waits. No C1-specific flag may weaken old source guards.
5. **B bounded capability/eligibility agreement.** Before B RED, submit the
   exact read-only metadata preview and any additive source API for review.
   It must not lock domain rows merely to render a capability, scan all
   runs/invocations or use per-row aggregate/head/audit work. At most the
   existing bounded page's source ids may be considered; guard lookup
   failures stay blocked. Execution repeats authoritative checks and actual
   model reservation/launch remain later gates. Real-provider retry stays
   blocked when cleanup or current grant/witness/provider eligibility
   cannot be positively obtained from a reviewed seam; E3 changing staging
   cannot silently flip this to enabled. Fake known-outcome paths provide
   meaningful positive tests, but do not claim real-retry readiness. The
   precise join with Layer 2 is a producer-consumer review, not guessed in A.
6. **B RED/GREEN and completion.** After its refined contract passes, test
   assignment and reply retry success through the real source orchestration,
   reserved/sent/unsettled-unknown and terminal-sent negatives, exact Failure
   and current session, concurrent duplicate/no-child/job races and refused
   guards. Assert stored rows/events and unchanged historic invocation/grant
   state. Independently verify RED, implement, run focused/full gates and
   peer code review; close C1-03 only when both reviewed slices meet scope.
   H1 implementation and any real-data/real-model acceptance remain separate.

## Verification Environment and Commands

Use the repository Nix/devenv environment; the plain tool shell currently
has Nix but no `mix` or `direnv` on PATH. No attempt to run a Mix command
outside that environment is part of this plan. Before RED, verify the
selected dev-shell command, available generators and local Postgres 5520
readiness without starting or stopping the owner's app or services.

All DB tests use an explicitly isolated test partition, for example
`MIX_ENV=test MIX_TEST_PARTITION=_codex_c103` (database
`sdr_agent_test_codex_c103`), never `sdr_agent_dev`, calibration, or another
agent's partition. Do not inherit the owner's real-provider/store/secrets
variables into a test run. True-connection fixture setup/cleanup must assert
the actual database name and owned synthetic tenant before any material
write; use bounded, joined contenders, not sleeps as the race oracle.

Within the verified environment, focused checks include:

    mix format --check-formatted
    mix compile --warnings-as-errors
    mix test test/sdr_agent/inbox/command_test.exs test/sdr_agent/outreach/inbox_commands_test.exs
    mix test test/sdr_agent/inbox/command_race_test.exs
    mix test test/sdr_agent/inbox test/sdr_agent/outreach test/sdr_agent/sdr/retry_run_test.exs test/sdr_agent/sdr/retry_race_test.exs

Record raw ExUnit Results and exact baseline/head; preserve original tests
outside documented, reviewed expectation changes. Full completion gate is
the project's `mix precommit` plus canonical Credo, dependency audit and
any configured workflow/codegen checks. No API/DB/provider configuration
is weakened for a pass. Exact commands and log hashes go in RED/GREEN
requests once the environment is verified; no tests have run yet.

## Risks and Design Review Questions

- Approve/reject create an outbox/revision history, not just a mutable row:
  compare-and-mutate must wrap the real source action and its full commit.
- C1-02 reviewers conservatively withhold gen-2 model-backed rows; preserve
  that known limitation (#152) and H1 real-data withholding obligation
  (#153), rather than widening field policy for the gateway.
- User input can appear in automatic crash reports even without an explicit
  logger call; H1's channel/task privacy contract must address this before
  H1 code. Current DB/raw-error safeguards remain mandatory in source tests.
- Count and list failures are not command authority. A count failure alone
  neither permits a command nor invalidates an independently fresh binding.
- Reviewer confirmation requested: approve slice A's exact `source_id`
  shape, strict atom-keyed backend request and lock/session/source API plan;
  keep B's preview/eligibility refinement as an explicit gate before B RED.
  This is sequencing within the four-command story, not a scope cut or a
  claim that C1-03/H1 is complete after only A.

## Questions for the independent reviewer

- **OQ-1 resolved:** Claude confirmed the four-command C1-03 subset
  matches scoped G5. Acknowledge/resolve remain source navigation, not new
  gateway writes; the wider modeled C1 contract remains for later work.
- Confirm draft 2 resolves the explicit reserved/sent/unsettled-unknown
  retry must-fix without changing invocation lifecycle or recovery authority.
- Are any source ownership, actor, lock, duplicate-submission or guarded
  recovery promises above incompatible with the accepted C1-01 contract?
  Source/API mechanics and module choices are intentionally deferred until
  this entity gate passes.

Nonblocking review obligations retained for the implementation plan:
pin the source fact proving replay per command (otherwise return stale,
never already_resolved); preserve existing retry/Failure-resolution
semantics exactly; enumerate the edit action's exact optional fields from
source, with unknown fields refused, before writing RED tests. No new
optional input is admitted by this entity draft.
