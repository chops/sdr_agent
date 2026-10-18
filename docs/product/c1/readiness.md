# C1 Home inbox contract and readiness

Status: **full amended contract PASS; ADR-0015 amended wording accepted;
scoped C1 G5 approved**. C1-01 (#85), Codex author → Claude reviewer.
Full independent review passed at `2526a22`; the owner accepted the amended
wording and separately approved scoped C1 G5 on 2026-10-14 (recorded below).
C1-02/03 proceed RED-first as separate PRs, each with independent Claude
review, full verification, green exact-head CI and merge (owner merge until D-157, Claude/Codex since). H1 screens,
new producers/metrics, new tables, spend and real calls are outside this G5;
H1 has its own owner task/prototype gate.

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

Home's three selected count tiles use exact authorized section totals:
pending email drafts, live Failures, and committed local captures this week.
Capture history is count-only, not an additional task producer or a general
analytics dashboard. Row paging remains capped; totals do not use the cursor.

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
Verdict: **PASS** by Claude at `354c590`, consultation
`m_1791836746489647500_488f78d2`, answer
`m_1791836856639537000_6cbd35cf` (2026-10-12 20:27:36 UTC). Review report
sha256 `818854327931d8638b9d6eb642c21e1f2a0d3a4860464c6d062aad9981df5bef`.
The seven full-contract requirements are addressed below. This PASS permits
affected-module planning, not C1-02/03 code or owner G5. Claude's full review
and B1/H1 producer-consumer agreement are recorded below.

### Exact-total amendment: entity/action delta

Entity Model trigger: **yes**. Reason: new derived aggregate result and
domain read contracts, changed page/error semantics and auditor aggregate
access; no schema, persisted counter, new role, dependency or Task resource.

| Entity | New / Existing | Purpose | Attributes | Relationships | Invariants / Lifecycle | Policy/Actor | Open Questions |
|---|---|---|---|---|---|---|---|
| SectionTotal (derived value object) | New | Exact authorized metric independent of visible rows | closed `metric : pending_email_drafts / live_failures / local_captures_this_week`; `status : ready / unavailable`; nonnegative integer `value` only ready, null unavailable; UTC `observed_at`; scope/filter fingerprint; optional UTC week bounds and timezone; bounded unavailable reason `forbidden / timeout / producer_error / withheld` | One explicitly registered source-owned count read; belongs to ephemeral Home/Page result. No counted ids or bodies returned | Exact whole authorized metric, no cursor/LIMIT/estimate/50+ substitution. A refresh error removes an old number; successful zero differs from unavailable. No independent lifecycle, cache/counter or action authority | Current active authenticated actor/session/tenant and source read policies, never kernel/bypass count | none; constants and week semantics accepted in the amended wording on 2026-10-14 |
| InboxPage / ProducerReadResult | Existing delta | Separate bounded list work from exact counts | per-section SectionTotal and separate list/count result states; completeness includes unavailable required sources | Draft+Failure row registry unchanged; capture history is a separate count-only source | 50 shown rows remains a cap, not the total. Source list/count failure makes its number unavailable; fresh authorized rows and healthy siblings may remain usable, but no stale capability is preserved. Counts exact at recorded observations, not one global snapshot. All-clear still needs complete successful coverage | Existing actor/session/tenant rules; losing scope clears rows and numbers | none |
| Outreach.Draft count read | Existing read-contract delta | Ready-for-outreach total | distinct authorized email Draft ids in the same pending_review/current-revision membership as list | Source-owned aggregate; no revision/body/model-output loading | Count drafts, not distinct people. Invalid required source context is producer_error, not silent success. Pagination excluded | Same current Draft read policy and permitted view/real-data scope as rows | no new mutation or source-policy shortcut |
| Operations.Failure count read | Existing read-contract delta | Needs-attention total | distinct authorized Failure ids, status open or acknowledged | Same attention membership | Acknowledged remains counted; resolved historical cause excluded, distinct live Operation cause included. No grouping/deduplication on Lead | Existing Failure read policy/scope | none |
| Outreach.DeliveryOperation count-only read | Existing read-contract delta | Captured-this-week history | provider capture; committed accepted_at within server-computed week; one logical operation | Existing acceptance metadata; no new task/relationship/mutation | Never count unknown/uncommitted acceptance, attempts or files. Historical accepted_at is not erased by later lifecycle state. Local capture is not external delivery | Existing DeliveryOperation metadata read policy/scope | Monday 00:00 America/Denver to next Monday, half-open UTC bounds; no new user timezone field |
| AuditAccess aggregate Home view | Existing read-contract delta | Preserve auditor-view audit without a hot-path head lock for ordinary users | existing record_view and bounded aggregate view ref/scope/metric/window coverage; no new field/enum | At most one coalesced audit per auditor refresh, retaining bounded actually-shown row refs; no counted-member enumeration | All reads finish/cancel and release connections before a separate short bounded AA+AE transaction. Audit failure withholds the auditor view/numbers. Admin/reviewer counts have no AuditAccess/head lock | Existing record_access policy; only auditor-role Home refresh needs this audit | Exact target-ref format must fit existing constraints or return for explicit review before code |
| User/session/Tenant, DraftRevision, DeliveryReceipt | Existing dependency | Current authorization and integrity | unchanged | unchanged | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found | Existing policies | none |

Configured reviewer: ai-pair (ai_pair=true, codex_review=true), Claude.
Delta verdict: **PASS**, answer `m_1791862258000010202_eafd672b`,
2026-10-13 03:30:58 UTC, replying to
`m_1791862244899940459_b5524726`. First round
`m_1791862035000012543_aa02e046` required removing per-count hot-path audit;
auditor-only coalescing and post-read bounded append resolve it. This PASS
permits affected-boundary planning, not full-text/owner acceptance or code.

## Observable requirements

| ID | Behavior |
|---|---|
| C1-R1 | An authorized founder sees only committed pending tasks in the declared inbox coverage. Initial coverage is email draft review and live Failure attention, not every future MVP task. |
| C1-R2 | The same source condition has the same item identity across refresh and edit; its freshness token changes when relevant facts change. Acknowledged Failures remain pending. |
| C1-R3 | Every row explains why it needs a human and offers only fixed, currently permitted actions. Blocked recovery explains its guard; it never becomes an enabled retry merely because Failure.retryable is true. |
| C1-R4 | Approval submits the displayed draft_revision_id, content_sha256 and recipient_email. The producer checks them again under its existing approval locks. Capture never means a message reached a real inbox. |
| C1-R5 | All mutations revalidate scope, current actor/session, source, freshness and source action rules. A stale or double submission never approves another revision, overwrites another edit or creates a second run/capture. |
| C1-R6 | List candidates/metadata joins remain row-bounded; exact aggregates are scalar/time-bounded, not fixed-scan-work bounded. More work, producer failures and withholding are visible; an error is never reported as an empty inbox. |
| C1-R7 | List summaries contain no draft body, research/model output, diagnostic stderr or Payload content. Detail and evidence retain source authorization and audited reads. |
| C1-R8 | Item resolution follows committed source state. A failed action leaves the item visible; after success the UI re-lists. No optimistic deletion or independent task lifecycle. |
| C1-R9 | Each future producer adds a reviewed row/action contract and tests before registration. Registration is closed reviewed code, not a plugin or caller/model-selected module. |
| C1-R10 | Each Home tile shows its exact authorized metric independently of paging, or unavailable without a number. No shown-row/50+/estimate/stale-number substitute; successful zero requires complete successful source reads. |
| C1-R11 | Ordinary authorized metadata count queries take no head/domain row lock. Auditor view audit is coalesced at most once per refresh after count work releases connections; bounded append failure withholds that view/numbers. Existing guarded denial auditing is not suppressed. |

## Initial producers and actions

| Producer | Pending membership | Summary and context | Permitted next steps | Resolution |
|---|---|---|---|---|
| outreach_drafts | Outreach's review_queue read, exposed today as Outreach.list_review_queue/1: Draft.status = pending_review, current revision exists. Only email until C6/B3 adds channels. | Draft id, displayed recipient, revision number/id/hash, current subject, typed risk/blocked labels. Metadata only; no body/citation payload is loaded for the list. | Inspect; edit; approve for capture; reject with reason. Admin/reviewer only for mutations, under source policy. Auditor gets authorized read/inspect only. | Approved → queued, rejected → rejected, cancelled → cancelled: disappear from pending list. Editing stays pending with a new revision/token. A revoked approval returning the draft to pending_review returns the same stable item. |
| operations_failures | Operations' attention read, exposed today as Operations.list_attention/1: status open or acknowledged. | Failure id, severity/class, redacted bounded message, occurred_at, typed source ref and allowed next step. No detail Payload/model/process output is loaded. | Inspect; acknowledge when open; resolve with required note. Admin/reviewer under Operations policy. Retry an eligible AgentRun only through SDR.retry_run/2, active admin only, after the reviewed safety joins are available. Grant repair is an admin navigation action, not a model/agent grant mutation. | Acknowledge changes token, not membership. Resolved disappears. Retrying follows the source contract's resolution of the original cause and creation of a new run; no task is silently marked fixed just because a new job was queued. |

Missing revision or required context is **producer_error**, not a fabricated
reviewable row. A denied detail read cannot leave an actionable old row on
screen. A provider/grant refusal appears through its existing Failure, not a
new parallel task. A resolved historical refusal cause is not shown, but its
distinct live Operation Failure is.

An unknown Failure subject string never selects a resource/module or URL;
inspect the authorized Failure itself instead of inventing a source action.
Auditor views preserve the existing AuditAccess convention, recording only
the bounded source ids actually shown. Do not record hidden ids or claim an
unperformed content access; guarded mutation and denial auditing remain with
the source actions.

### Command binding and outcomes

Commands carry `item_id`, a fixed `action_id`, the displayed freshness token,
and only that action's validated arguments. Actor and tenant come from the
current authenticated scope, never the command. Unknown fields, producers,
actions and cross-source pairs are rejected, not dynamically dispatched.

| Command | Required source binding and arguments | Authoritative call |
|---|---|---|
| approve_capture | draft_revision_id, lowercase hex content_sha256, reviewer-seen recipient_email; channel email | Outreach.approve/3 → BindApproval. Never infer recipient or substitute the newest revision for an old command. |
| reject_draft | draft_revision_id, content_sha256, nonempty reason; displayed recipient/channel stay in the freshness check | Outreach.reject/3. Current domain rejection does not compare recipient; C1 must not claim otherwise. |
| edit_draft | displayed current revision, token and validated subject/body/optional angle/CTA | Outreach.edit_draft/3, **only after** a producer-owned freshness check held in the same transaction as the edit. A separate unlocked read then write is insufficient. |
| acknowledge_failure | exact Failure id and displayed token | Operations.acknowledge_failure/2; source lock/state rules apply. |
| resolve_failure | exact Failure id/token and nonempty resolution_note | Operations.resolve_failure/3; never manufacture a note or resolve merely to clear Home. |
| retry_run | validated target run id, source Failure ref/token, explicit human confirmation | SDR.retry_run/2 plus reviewed current cleanup/provider/witness/grant admission guards. No generic retry by Failure class or subject string. |

The source adapter owns the transaction for compare-and-mutate, acquires its
established dependent-row locks before the audit head, recomputes freshness
while those facts are protected, and invokes the guarded domain action with
the current actor. Approval keeps enrollment → draft → campaign → contact →
head. The edit adapter uses that same enrollment → draft → campaign → contact
order, since freshness includes recipient/campaign facts; it must not lock
the draft before the enrollment. Failure writes keep Failure → head; run retry keeps its reviewed source
order. No generic gateway head lock is taken before entering a producer.
If a source action cannot meet this compare-and-mutate contract, that action
stays blocked as `guard_not_available` until a reviewed source adapter/delta
exists. Do not extend action arguments or lock rules silently in C1 code.

Success is `{:ok, %{outcome: :applied | :already_resolved, refresh?: true}}`.
An existing producer's successful identical replay may return already_resolved;
otherwise repeated commands return a typed stale outcome. Error reasons are
closed: `:stale`, `:forbidden`, `:not_found`, `:blocked`, `:invalid_input`,
`:producer_error`. Stale results name a safe change category (revision,
recipient, lifecycle, recovery_guard), not hidden source content. Cross-tenant
and unauthorized references do not reveal existence or alternate recipients.
Guarded denials remain audited. No error response publishes a raw exception,
stacktrace, command line or model payload.

### Freshness inputs

Version 1 hashes a canonical, server-owned tuple including contract version,
authenticated tenant, producer, kind, source id and channel, then:

- **Draft:** pending status, current revision id and stored content hash,
  recipient contact id and exact displayed email, contact status, campaign
  lifecycle and the producer's applicable suppression/approval guard facts.
- **Failure:** status, acknowledgment/resolution timestamps, class/severity,
  subject and Operation refs, retryable flag, and applicable recovery guard
  facts (run status/retry state, cleanup confirmation, effective provider and
  reviewed admission eligibility). No payload or body is hashed by loading it.

`observed_at` is the read time and is not hashed: time passing alone does not
invalidate an item. Time-dependent eligibility is rechecked at execution;
crossing a grant/window boundary can block a command even with a matching
token. Token comparison is not authorization and never replaces current
source rules. Capabilities whose required facts cannot be read are blocked,
not guessed. Edit keeps item identity but changes the revision/token; source
state transitions and recipient changes invalidate the displayed command.

### Blocked reasons

Fixed reason codes cover `actor_not_permitted`, `recipient_suppressed`,
`recipient_inactive`, `campaign_closed`, `real_data_disabled`, `model_staged`,
`tuple_not_promoted`, `grant_unavailable`, `grant_exhausted`, `witness_withheld`,
`cleanup_unconfirmed`, `unknown_outcome`, `guard_not_available` and
`producer_unavailable`. Their plain-language labels are display copy, not
permission or routing. Scope them to the affected action: a blocked retry
does not necessarily block inspection or acknowledgment. Safe rejection or
resolution is not automatically denied merely because generating another
draft is blocked. An unreleased model result is never surfaced as business
detail while reporting the witness block.

## Page bounds, ordering and truthful empty states

Proposed fixed default and hard maximum: **50 items per page** (caller may
request 1..50). Each initial producer queries at most **51 candidates** after
source authorization and the cursor predicate: 50 plus one lookahead. The
two-producer first scope therefore reads at most 102 source candidates.
Metadata joins are by those bounded ids, selecting only required fields.
Never list every Draft, Contact, Account, run, Payload or past revision and
then take 50. Existing unbounded domain readers need bounded domain-owned
successors before C1-02 uses them; a limit ignored by the current API is not
a valid bound.

Stable ordering: critical Failures first; all remaining initial items second.
Within either group, oldest source timestamp first, then producer id, then
source id. Draft uses inserted_at; Failure uses occurred_at. Read-time
observed_at does not affect order. Exact scalar count queries are separate
from row paging and do not alter its limits or continuation.

One opaque keyset cursor records the last **returned** sort key, contract/
producer-set version, authorized tenant/actor scope and fixed filters. Each
producer applies that global continuation before its query limit; consuming
all fetched candidates would skip items not returned in the merged page.
Reject malformed/cross-scope/version-mismatched cursors. New items can appear
on a fresh first-page load; pagination is not a frozen snapshot of changing
work. Freshness checks protect actions independently of paging.

Read success returns items, next_cursor, observed_at, completeness and typed
producer errors/withheld reasons. A partial page can show authorized successful
rows but prominently reports the missing producer. Returned errors and raised
failures use the same truthful state. Losing actor/session authorization clears
old rows/actions immediately. Refresh failure cannot keep old buttons enabled.

Empty copy for initial coverage: **“No drafts or failures need your attention
in this view.”** Only on the first page, with complete successful reads and
no next_cursor. **“Nothing needs your attention”** is reserved for H1 after
all required founder-task producers are registered and successfully read.
An empty later page means “No more items”; a partial/error/withheld page never
claims empty success. Auditor/read-limited coverage never claims the owner's
whole queue is empty.

### Exact totals, authorization, errors and performance

One closed domain-owned aggregate statement per count metric per refresh
(three initially), not one query per shown row. The count uses full source
membership, fixed view filters and **the same current authorization/real-data
scope as rows**, with no pagination cursor or row LIMIT. Never load all rows
into Elixir and filter/count there. If source policy or required source
integrity cannot be enforced in the aggregate, return producer_error/withheld,
not an unauthorized total or a silently reduced successful count. Actor and
tenant are server-owned; no client-selected resource, SQL predicate or module.
Scope fingerprints use nonsensitive server-owned identity/filter references,
not credentials or session tokens. Metadata-only integrity predicates must
not silently hide malformed pending rows behind a reduced successful count.

| Metric | Exact unit and predicate | Not counted |
|---|---|---|
| pending_email_drafts | One currently reviewable authorized email Draft, pending_review with required current revision/context, matching list membership | Other channels/states, unauthorized/withheld scope; not distinct people or per-campaign dedupe |
| live_failures | One authorized Failure, open or acknowledged, matching attention membership | Resolved historical causes; never collapse different live conditions by Lead |
| local_captures_this_week | One authorized capture-provider DeliveryOperation with committed accepted_at in `[week_start_utc, next_week_start_utc)` | Unknown/uncommitted acceptance, retries/attempts/files; never imply external delivery |

The history window is computed by the server from the refresh's reference
instant: Monday 00:00 America/Denver to next Monday 00:00, converted to UTC.
Returned timezone and boundaries make DST and week rollover explicit;
do not use a fixed 168-hour UTC subtraction or add a persisted user timezone.
The pending badge may sum successful pending metric values, not history;
if either required pending source is unavailable it has no numeric total.

Each total has its own observed_at/scope fingerprint. Separate row/count
observations may differ when work changes; do not clamp a legitimate total
to the page length or promise an atomic global snapshot. Counts never govern
actions or generate a cursor. Scope/version/filter mismatch discards the
result. A source's list or count error, denial, withholding or timeout makes
its total unavailable and clears any prior number; healthy fresh rows may
still be shown if their own authorization/freshness reads succeeded. A count
failure alone does not grant or revoke an otherwise valid source command.
Raised and returned errors have the same sanitized outcome; no SQL, raw
exception, diagnostic body or hidden ids escape. A successful exact zero is
not an error fallback. Initial empty copy also requires both pending totals
ready at zero and the existing complete-first-page/no-cursor condition.
History does not add pending membership, but a required history read failure
keeps the whole Home refresh partial, not an all-clear.

**Performance proposal (not code):** one scalar aggregate result per metric;
hard 2500 ms per-count end-to-end deadline including authorization/pool wait;
database statement_timeout at most 2000 ms and the remaining deadline.
Both ceilings can only be lowered; invalid/zero config cannot disable them.
Cancel/roll back on deadline and release the connection; no orphan query or
automatic count retry. Exact COUNT can scan many eligible/index entries:
fixed scan cardinality/O(1) cost is not promised. Required tenant/filter
indexes and large synthetic cardinality/foreign-tenant query-plan tests must
support the deadline. On failure show unavailable, never a capped/estimated
number. This does not claim an overall page-refresh latency independent of
source/audit work.

Admin/reviewer count/list metadata reads do not append per-count AuditAccess
or introduce a head lock for successful authorized reads. Existing guarded
denial auditing remains separate and is not suppressed. Auditor Home reads
preserve their existing view-audit
convention: at most one coalesced record_view per refresh, with a bounded
aggregate ref identifying authorized scope/metric/window plus the bounded
source ids actually shown. Never enumerate ids merely counted or claim a
body read. Every count finishes/cancels and releases its read connection
outside head/domain row locks before the separate short AA+AE append; the
append has its own hard 2500 ms ceiling. Its failure withholds the auditor
view/numbers. Exact target-ref format must fit existing record_access/5
constraints or be independently reviewed as a delta before code. An old
auditor view's audit is not reused to authorize a new scope or refresh.

## Synthetic contract examples and owner task walk

All names and addresses below are fictional reserved-domain examples. These
are acceptance scenarios, not implemented screens or actual actions.

| Example | What the owner sees | Expected behavior |
|---|---|---|
| Fresh draft D1 | Draft D1, revision R3, hash H3, recipient sam@orbit.example.org, email, “About developer onboarding”; Review/Edit/Approve for capture/Reject | Approve command carries R3 + H3 + that exact email + token T3. Producer checks source state and captures only through the existing outbox; it does not send real email. |
| Edited while reviewing | D1 was R3/T3; another edit committed R4/T4 | Approve or edit with T3 returns stale/revision. No approval, capture or overwrite. Refresh shows R4; a fresh decision is required. |
| Recipient changed | Same D1/R3, contact email now changed to pat@orbit.example.org | Old sam binding returns stale/recipient, not approval for pat. Owner must review the newly displayed recipient. |
| Resolved failure | Failure F1 was open; another operator resolved it | A stale acknowledge/resolve command cannot recreate it. Refresh removes F1; the immutable historical cause remains in source records. |
| Read-only actor | Auditor can inspect D1/F1 through permitted reads | No enabled mutation. Forged approve/retry fails source policy and is audited; no new rows. |
| Grant/cleanup block | Failure F2 needs recovery; grant exhausted or prior process cleanup unconfirmed | Explain the exact block. Admin may inspect grant status, but no enabled rerun until current safeguards pass. No agent edits a grant. |
| One producer failed | Draft query succeeded with D1; Failure query failed | Show D1 with a visible partial-read warning; never “nothing needs you.” A failed producer has no fabricated row or safe-to-click stale action. |
| Over page cap | 53 authorized pending source items | Tile shows exact 53 while list shows stable first 50 plus cursor; next page has remainder with total still independent of cursor. No skipped candidates, hidden counts or body loads. |
| Count failed, list succeeded | Fresh authorized drafts shown; draft aggregate timed out | Draft total unavailable (no old number/0/50+); fresh rows remain, refresh partial. Healthy Failure metric remains available. |
| Complete pending empty, historical captures | Both pending sources/metrics succeeded at zero; capture history succeeded at 12 | Scoped pending empty copy may appear; 12 is history, never pending membership or proof of external delivery. |
| Resolved refusal, live Operation | Original run cause F3 is resolved; Operation has live F4 naming F3 | Show F4 once, not F3 as pending and not a collapsed “fixed” lead. Inspection explains historical cause versus remaining operator attention. |

Open the [synthetic task prototype](task-prototype.html) locally for the
fragment-linked walkthrough below. It has no scripts, network access,
database or real actions. R3/H3/T3 are symbolic labels, not API-valid values.
The prototype only presents the already modeled contract: no entity/action
delta or runtime behavior is added by this static markup.

Owner task walk (no model calls):

1. From Fresh draft D1, identify the recipient, revision and why approval is
   required; choose approve, edit or reject and explain what capture means.
2. Encounter Edited while reviewing; explain what changed and why the old
   approval cannot stand. Repeat with Recipient changed.
3. Investigate F2; identify what blocks retry and what only an admin can do.
4. Distinguish Resolved failure from Resolved refusal/live Operation.
5. Describe One producer failed versus a complete empty initial inbox.

Record the owner's answers/changes with no coaching. This clickable contract
example is not an accepted H1 visual design; H1-01 supplies the fuller desktop
prototype and accessibility/keyboard task check. Neither owner acceptance nor
a passed usability test is claimed here.

## Affected boundaries and proposed implementation slices

Initial and exact-total entity PASS now permit this planning. **No files below are changed in this
docs PR.** Names are proposed, not claims that C1 is implemented.

- `SdrAgent.Inbox` / Item / Page / Command / SectionTotal: a stateless application facade
  over fixed producers; no Ash domain/resources, supervisor or Task table.
- Outreach and Operations: bounded actor-scoped source reads, three authorized
  scalar count readers (including count-only capture history), and typed
  producer compare-and-mutate adapters. Source modules own queries/locks and
  source actions; the web layer does not query Repo or mutate resources.
- SDR/Agents and the merged C2/C9/R0-07 contracts: existing guarded recovery
  and no-call status/admission reads. Until a required guard is available,
  rerun stays blocked. C1 does not build model/profile/budget controls.
- Future H1 LiveViews: consume the contract, keep data loading out of mount,
  clear stale capability state on failures and refresh after committed writes.

Steps after contract review, owner ADR acceptance and scoped G5:

1. C1-02 RED: bounded source/list tests for authorization, ordering, cursors,
   projection fields, truncation, exact counts and empty/partial/returned/raised errors.
2. C1-02 GREEN: smallest stateless projection and bounded domain adapters;
   no new producer or persistence beyond reviewed scope.
3. C1-03 RED: exact approval binding, stale edit/recipient/state, double-submit,
   demotion/session revocation, suppression and recovery guards.
4. C1-03 GREEN: fixed command routing and producer-owned compare-and-mutate;
   guarded domain actions, no generic dynamic dispatch.
5. H1/B1 integrate only after the contract merges; run the owner task script,
   source regressions, full gate, security review and applicable diagrams.

Required negative tests include cross-tenant/forged source refs, arbitrary
action/resource strings, unknown producers, bad/cross-scope cursors, withheld
model output, real-data off, closed grants, cleanup ambiguity and a resolved
historical cause with a distinct live Operation condition. Assert stored rows
and audit events, not only returned tuples. Every producer extension needs
its own bounded-read and mutation-negative tests before registration.

Exact-total RED obligations: >50 and later-page totals; same membership and
actor/tenant/role filters as lists; acknowledged/resolved/live-Operation
Failures; count-only history logical idempotent acceptance, unknown outcomes,
week boundary/DST and no history-as-pending badge. Returned/raised/timeout
count and list failures clear numbers, never fake zero; scope revocation
clears old rows/counts. Prove scalar-only SQL/result selection and no body,
Payload or member-id loads; one aggregate per metric; large synthetic/foreign
tenant EXPLAIN and end-to-end pool/held-lock/statement timeout with query
cancellation/no orphan. Held-head tests prove non-auditor refresh takes no
head lock and counts proceed while a writer holds it; auditor count work
also finishes outside it, then one bounded append fails closed. Prove bounded
actually-shown audit refs, no counted-id enumeration, and no additional
per-metric AuditAccess. No real-model calls are needed for any of these.

## Architecture decisions and readiness

ADR required: **yes**, [ADR-0015](../../adr/0015-home-inbox-projection-and-command-boundary.md)
records the durable shared read/command boundary and compares it with a
persisted task mirror and UI-owned composition. It adds no dependency and
preserves existing domain ownership. Owner accepted the architecture with
exact totals; independent full amended-text review passed at `2526a22`,
and the owner accepted that wording on 2026-10-14. ADR-0015 is **accepted**;
scoped C1 G5 was separately approved at 11:04 MDT, with the scope below.
Implementation should update the component/data-flow diagrams for the new
public runtime path; no actual runtime changed in this docs record, so
current diagrams are not rewritten to pretend it exists.

| Readiness item | Status |
|---|---|
| Entity/action soft-stop | Base PASS at 354c590; base full contract PASS at 202349d; exact-total delta PASS via eafd672b (03:30:58 UTC); full amended contract PASS by Claude at 2526a22 via a21b80ed (2026-10-13 04:04:19 UTC) |
| B1 producer / H1 consumer agreement | Base PASS by Claude at 202349d; amended count/row/audit agreement PASS by Claude at 2526a22 via a21b80ed |
| Owner task walk / interactive H1 prototype | A selected with collapsible nav; diff-view and phone layout explicitly confirmed at 0b740d8; prompted walkthrough, not an unprimed usability trial or C1 code gate |
| ADR-0015 owner acceptance | Amended wording at 2526a22 accepted 2026-10-14 11:01 MDT: "accept the amended ADR-0015 wording", relayed in m_1791997310000000000_622e6df7 |
| Scoped C1 G5 | Approved 2026-10-14 11:04 MDT: "approve scoped C1 G5 for C1-02 and C1-03", relayed in m_1791997445000000000_58eb5fd6; scope below |
| C1-01 docs verification | Base d6ed725: workflow receipt, format, compile, canonical Credo, Hex audit, codegen, `mix precommit` and 1126 tests passed locally; base prototype link/browser checks passed. Exact-total amendment verification/review is recorded separately; no implemented-count or new runtime test claim. |
| Owner acceptance status update (2026-10-14) | Documentation diff and relative links pass; workflow receipt, format, canonical Credo and Ash codegen check pass; isolated `mix precommit` exits 0: 1126 passed, 1 skipped, 4 excluded (303.6s). Acceptance-delta peer review and CI on the resulting commit remain required. No runtime code changed. |

Full contract review: Claude at `202349d`, consultation
`m_1791838602052826250_0c9eae1c`, answer
`m_1791838859000005695_8cfb65f1` (2026-10-12 21:00:59 UTC), **PASS**.
Record C1-02 tests for recipient changes invalidating a reject token too;
future reviewed severity changes moving between page groups (not a frozen
snapshot); and bounded successors to both initial source readers. None is a
new story or a claim that the code already exists.

Full amended-text and B1/H1 producer-consumer review: Claude at
`2526a22e7bfa1fd9bdd1f0e4d5540bfd3affaebb`, answer
`m_1791864259000019496_a21b80ed` (2026-10-13 04:04:19 UTC), **PASS**.
It preserves the three closed metrics, exact authorized membership,
unavailable-versus-zero semantics, fixed lowerable-only deadlines,
America/Denver week, and coalesced auditor audit after reads. H1 copy must
name drafts rather than distinct leads or people.

Owner decision record: `m_1791861397000025639_2dad34b9` routed the verbatim
acceptance and clarification recorded in ADR-0015 amendment 1. On the chosen
Home prototype the owner said “yes, that's what i had in mind” for the diff
view (`m_1791860394000027513_96d010c7`) and “yes, that's the right behavior
on phones” for the compact <=760px layout
(`m_1791860524000028222_a65cab21`). These answers do not replace scoped G5.

Amended-wording acceptance: on 2026-10-14 at 11:01 MDT, the owner said
"accept the amended ADR-0015 wording" for PR #137 at `2526a22` (private
Claude chat, relayed verbatim in `m_1791997310000000000_622e6df7`). This
accepts ADR-0015 Amendment 1; the scoped G5 decision is separate.

Scoped C1 G5: on 2026-10-14 at 11:04 MDT, the owner said "approve scoped
C1 G5 for C1-02 and C1-03" (private Claude chat, relayed verbatim in
`m_1791997445000000000_58eb5fd6`). C1-02 covers bounded draft/failure lists
and the three exact counts; C1-03 covers the fixed existing domain action
gateway (approve/edit/reject/re-run). Each is RED-first in its own PR under
steps 1-4 and the RED obligations above, with independent Claude review,
the full gate, green exact-head CI and merge (owner merge until D-157, Claude/Codex since). This approval excludes
H1 screens (separate G5), new producers/metrics, new tables, spend and real
calls.

This contract draft does not complete C1-02/03 or H1, expand spend authority,
add channels, change suppression, bypass the release gate, or authorize
processing real leads while the real-data switch is off.
