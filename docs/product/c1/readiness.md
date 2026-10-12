# C1: Home inbox contract — entity draft

Status: **draft for independent entity/action review**. C1-01 (#85), Codex
author → Claude reviewer. No C1 code, new database table, UI mutation or
model call is authorized by this draft. The owner must approve scoped G5
before C1-02/03 implementation; H1 has its own owner task/prototype gate.

## Summary and scope

Specify what a founder task means before building Home: a bounded,
authorized projection of committed domain work that needs a human, with a
fixed next action, exact subject/revision/recipient/channel binding, and a
fresh-state check before any write. Home is not a dashboard and a task is
not a second source of truth for an agent run or draft.

Sources (precedence): owner-accepted Home framing, walkthrough 14-19
(D-084); approved build plan §3 C1 and backlog C1-01..03/H1-01;
ADR-0014 constraints 1-6; the accepted R0 packet for C2/C9 and the reviewed
S13b retry contract. Earlier P1/slice-A docs are historical inputs: their
read-only Home, founder-does-SDR-work framing and superseded channel/scope
limits are not carried forward.

First producers: **email draft review** and **failure attention**. Future
LinkedIn owner-send, call outcome, referral confirmation and CRM-preview
producers must add a reviewed row/action contract; no free-text producer or
arbitrary module/action dispatch. Provider status and grant balances belong
on Status/Admin, not in the task list. An actual provider/grant refusal is
a task through its committed live Failure; showing it never spends a call.

## Entity model (soft-stop)

Entity Model trigger: **yes**.
Reason: new derived task/page/command value objects, cross-domain subject
references, freshness/action contracts and authorization behavior; no
persisted Task resource is presumed.

| Entity | New / Existing | Purpose | Attributes | Relationships | Invariants / Lifecycle | Policy/Actor | Open Questions |
|---|---|---|---|---|---|---|---|
| InboxItem (derived value object, not persisted) | New | One committed condition requiring human attention | `id : opaque string, required` stable for `(tenant, producer, kind, subject, channel)`; `kind : closed atom` initially `draft_review` or `failure_attention`; `producer : closed atom` initially `outreach_drafts` or `operations_failures`; `subject_ref : typed {resource, id}, required`; `revision_ref : typed id/hash or null` (required for draft review); `channel : email or null` (email for draft, null for channel-independent failure); `recipient_binding : typed id + exact address or null` (required for approval); `freshness_token : opaque string, required`; `observed_at : UTC timestamp, required`; bounded plain-text `summary`; fixed `actions : list<InboxAction>`; typed `blocked_reasons : list`, possibly empty | References one producer-owned source condition. Draft review references the Draft's current immutable revision/recipient; failure attention references exactly one Failure and its optional owned run/Operation. Tenant derived from authenticated scope, never taken from client task id. | No task table, process or independent task status. Membership/resolution are recomputed from committed source state: current draft awaiting review; Failure open or acknowledged. Acknowledgment is not resolution. Editing keeps stable task identity but changes revision/freshness and invalidates approval under Outreach's rules. A resolved historical refusal cause is not itself a live task; an Operation-owned live Failure created after resolution is. Different live conditions remain different items; never silently discard one by grouping on Lead. Token is an optimistic-concurrency hint, never authority. | Active authenticated human scoped to one tenant; source read policy and source action policy both apply. Admin/reviewer may act only where existing domain rules allow; auditor is read-only where source policies permit. No policy bypass or capability inferred from a cached button. | Which initial actions can execute in-row versus navigate is finalized with B1/H1 producer-consumer review; no new action invented to fill a missing capability. |
| InboxAction (derived capability) | New | A typed, explainable next step | `action_id : closed atom`; `availability : enabled or blocked`; bounded `label`; `blocked_reason : typed reason or null`; `target_ref : typed source route/ref or null`; no arbitrary URL/module/function supplied by model or request | Belongs to one InboxItem. Invokes or navigates to one explicitly allowed producer action. | Display capability is advisory. Initial draft capabilities: inspect, edit, approve for **capture**, reject. Failure capabilities: inspect, acknowledge, resolve with note; explicit retry only where the run's existing retry contract and cleanup/provider/grant guards permit. No auto-retry, no unknown-outcome repeat, no grant adjustment by agents, no bulk approval and no claim that capture means delivery to a real inbox. | Domain rechecks current actor, session, tenant, role, subject ownership and action preconditions at execution. Only active admin may retry an agent run or edit budgets under accepted contracts; a reviewer can inspect/acknowledge/resolve only where permitted. | C9 launch guards and H1 retry join are not assumed implemented until merged. Unsupported recovery stays inspect/navigate with a reason, not an enabled rerun. |
| InboxPage / ProducerReadResult (ephemeral read contract) | New | Bound list work and distinguish completeness from failure | bounded `items`; opaque `next_cursor or null`; `observed_at`; `completeness : complete or partial`; typed per-producer `errors/withheld reasons`; fixed cap/ordering to be set in the full contract | Reads a fixed registry of producers; page cursor bound to authenticated scope, filters, producer set/version and stable sort keys. No unauthorized subject id/count/error detail returned. | Each producer bounds work at the query, not an unbounded scan then filter. Stable tie-breakers and cursor pagination; truncation is visible. Returned and raised read failures cannot become empty success. Only a successful complete authorized read with zero permitted pending tasks may show “Nothing needs your attention”; partial/withheld/error reads show their uncertainty. | Read authorization preserved per producer. Row omission due to policy does not declare the hidden condition resolved. Auditor's empty authorized view is not evidence that the owner's inbox is empty. | Exact storage/query strategy and caps are chosen after entity PASS; no all-history payload/body loading for the list. |
| InboxCommand (ephemeral action request) | New | Execute the displayed task safely | fixed `action_id`; opaque `item_id`; `expected_freshness_token`; exact `expected_revision/recipient/channel` where applicable; action-specific validated arguments (e.g. rejection/resolution note); server-returned typed outcome | Resolves to a single allowlisted producer/source action. Does not write InboxItem itself. | Re-read current source and actor before writing; reject stale/forged/cross-tenant references. Revision/recipient binding is enforced again by Outreach in the same action transaction, not only by a prior UI check. Double submission yields the existing action's idempotent result or typed stale/already-resolved outcome, never a second capture/run. Re-list after committed action; no optimistic removal before commit. Errors retain truthful source state and audit evidence. | No cached authorization, `authorize?: false`, raw Repo mutations or caller-selected resource/module dispatch. Client-supplied tenant/source metadata cannot authorize access. | Code action-gateway routing is designed only after PASS; requires C1-03 approval, not this docs draft. |
| Outreach.Draft / DraftRevision / Approval | Existing (projection/action delta only) | Source and exact approval binding for draft-review tasks | Existing ids, current immutable revision/hash, recipient and review lifecycle are referenced; no new persisted attributes proposed | Referenced by InboxItem/Command; domain owns all edits/approvals/rejections and capture admission | A task represents the **current** reviewable revision. Edit creates a revision, invalidates old approval; stale recipient/revision approval is refused. Task resolution follows committed domain state, not browser state. Existing suppression, channel and capture-only constraints remain enforced. | Existing domain reads/mutations remain authoritative; founder UI must pass the authenticated actor. Auditor cannot mutate. | Validate reviewable-state and rejection semantics against current domain APIs after entity PASS; B1 consumer agreement still required. |
| Operations.Failure | Existing (projection/action delta only) | Source of unresolved exception tasks | Existing id, status, class, severity, subject/Operation reference and redacted summary; no new columns | InboxItem points to Failure, optionally to its authorized subject context; action stays in Operations (or existing run retry orchestration) | Open and acknowledged are pending; resolved disappears on refresh. No duplicate task for the same Failure. Separate live causal conditions are not collapsed. Resolution requires existing note/authorization; unknown outcome does not acquire retryability because a task appears. Redacted list summary never loads model/process output or secret-bearing payloads. | Existing human read/acknowledge/resolve checks; retry permissions from the target run action, not Failure.retryable alone. | Failure-to-run/Operation navigation must remain tenant-scoped and typed; no arbitrary subject-resource dynamic dispatch. |
| Agents.AgentRun / Operations.Operation | Existing (referenced lifecycle delta only) | Identify permitted recovery and truthful source context | Existing run/Operation ids, status, attention Failure and cleanup/retry references; no new attributes/actions proposed here | Failure task may reference an existing run/Operation via validated stable ids; retry creates a new run and keeps the original record | Home may expose only the existing guarded retry. Failed/unknown process work is never blindly replayed; unconfirmed cleanup/provider/grant/witness admission remains blocked. A grant refusal's resolved historical Failure may remain the run's cause while its Operation owns a distinct live task. | Existing active-admin-only run retry and operation-kind actor rules unchanged; human cannot gain system-actor permissions through the gateway. | C2/C9/R0-07 producer semantics in flight must be consumed only after their reviewed contracts merge. |
| Accounts.User / authenticated session / Tenant | Existing | Scope and revocable authorization | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found; C1 consumes the current authenticated scope/session and rechecks it, never introduces a role or membership. | Existing role/session/domain policies | none |

Configured reviewer: ai-pair (ai_pair=true, codex_review=true), Claude.
Verdict: **UNREVIEWED**. Table review request to be staged with this artifact.
This is a soft-stop: no affected-module or C1-02/03 implementation plan is
approved until an independent PASS. Owner scope approval is separate.

## Next artifact work (docs only)

After entity PASS, finish the requirements, producer/action matrix, concrete
synthetic fresh/stale/resolved/unauthorized/error examples, owner task walk,
acceptance tests, affected boundaries and ADR/diagram evaluation. Request
Claude's full contract review and the owner's scoped acceptance. No scheduled
build-day estimate, real model call or unapproved producer implementation.
