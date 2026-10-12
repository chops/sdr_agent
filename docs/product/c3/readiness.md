# C3 readiness packet: lead admission

Status: **draft for independent entity review and owner G5.** C3-01 (#55),
Claude author → Codex reviewer. Nothing here authorizes C3-02 (#56) or C3-03
(#57) code, a migration, a model call or real data. Implementation starts
only after (1) Codex records an entity-model verdict of PASS on section 3 and
(2) the owner approves a scoped C3 G5. The R0 G5 does not cover C3.

Sources: build plan v3 (D-097) §3 contract C3, §9, §9a
([`owner-decisions`](https://github.com/chops/sdr_agent/blob/owner-decisions/docs/product/build-plan.md));
backlog draft C3-01..03, B1-03, B2-04, B5-04, B6-01..03, C8-02;
decisions D-048, D-049, D-052, D-056, D-059, D-060, D-066, D-084, D-095,
D-101, D-104; ADR-0014 amendment 2 (constraint 7, accepted 2026-10-12);
ADR-0009 (persistence and audit conventions), ADR-0010 (lifecycles). Code
facts are from `main` at 182bde6.

All examples are synthetic (reserved domains, invented names).

## 1. Scope and non-goals

C3 defines how a person at a company becomes a lead. Every source enters one
path: validate → dedupe → admit → research (queued) → qualification. Nothing
reaches a draft without research and qualification.

In scope:

- C3-01: this packet (entity delta, action contracts, lock order, tests).
- C3-02: `SdrAgent.SDR.admit_lead/2`, the single admission action for the five
  source kinds, with dedupe, provenance and the one-active-target invariant.
- C3-03: `SdrAgent.SDR.hand_off_referral/2`, which closes the original lead as
  `referred`, keeps its history and admits the referred person at the same
  company.

Non-goals (owned elsewhere, each with its own review):

- Input surfaces: manual-add form (B1-03), CSV parse, preview, batch and
  partial-commit policy (B6-01..03), HubSpot identity, field mapping,
  re-sync and remote opt-out (C8), contact candidates and their confirmation
  (B2-05..07), reply capture and classification (B5-02). They call C3 with a
  validated input; C3 does not parse files or call providers.
- Account-only discovery and target lists (B2-03). C3 admits people, not
  account lists.
- The real-data guard policy itself (C5-04). C3 calls the existing guard and
  adds no bypass.
- Changing a lead's person or company after admission; merging accounts or
  contacts; multi-stakeholder outreach (D-059: post-MVP).
- Drafting the referral email (B5-04). C3 provides the referrer link only.

## 2. Requirements (observable behavior)

| ID | Requirement |
|---|---|
| C3-R1 | Every lead created after C3-02 has exactly one admission record naming its source kind: `manual`, `csv`, `hubspot`, `agent_found` or `referral`. No other path creates a lead (seed fixtures in dev/test excepted). |
| C3-R2 | Provenance answers who, what and when without copying personal data: the requesting human, the source kind, an opaque id-only source reference (for example an import id and row number), the campaign, the time, and a hash of the normalized input. It never contains a name, email or free text. |
| C3-R3 | The same source reference submitted twice with the same input returns the stored result and writes nothing new (no second lead, run or event). The same reference with different input is refused. |
| C3-R4 | Dedupe uses the normalized company domain and the normalized person email. A duplicate never creates a second account, contact or open lead; the outcome is recorded with the matched lead and shown to the caller. |
| C3-R5 | A company has at most one open (active outbound) lead at a time, enforced by the database. Closed leads stay as history. A second person at a company with an open lead is recorded as `active_target_exists`, except through the referral handover. |
| C3-R6 | An admitted lead gets its research run queued in the same transaction. It can reach `qualified` only through a recorded qualification after research, and a draft only from `in_outreach`. No source, flag or role skips research or qualification (D-049, D-052). |
| C3-R7 | A suppressed email, email domain or company domain is never admitted. The attempt is recorded as `suppressed`; no account, contact or lead is created for it. |
| C3-R8 | Only an active human admin admits, from any source. Reviewers, auditors and every system actor are refused, and the refusal is audited. The agent proposes people (B2); a human confirms them. |
| C3-R9 | A referral handover is one transaction: the original lead becomes `referred` (terminal, kept in history), its open enrollment, drafts, unclaimed deliveries and granted approvals are closed, and the referred person is admitted as the company's active lead with a link to the original lead for drafting. If the referred person cannot be admitted, nothing about the original changes. |
| C3-R10 | Real company and person data is accepted only under constraint 7 as amended: with the real-data switch off, a non-reserved domain or email is refused before any lookup or write, and the refusal does not echo the value. Admission, provenance and errors put no personal values in logs, trace attributes, telemetry or public evidence. |
| C3-R11 | Concurrent admissions for the same company, person or source reference serialize: exactly one wins and the others get a deterministic recorded outcome or a typed retryable conflict, never a deadlock by design and never a partial write. |

## 3. Entity model (soft-stop)

Entity Model trigger: **yes**.
Reason: new persisted admission record, changed Lead source enum, statuses,
identities and actions, a new account-level invariant, a new terminal state
and cross-domain referral effects on enrollments, drafts and approvals.

| Entity | New / Existing | Purpose | Attributes | Relationships | Invariants / Lifecycle | Policy/Actor | Open Questions |
|---|---|---|---|---|---|---|---|
| Sales.LeadAdmission | New | One immutable record per admission request and its outcome: the provenance and dedupe history of every source observation | `id : uuid_v7`; `tenant_id : uuid, required`; `source_kind : atom, required, one_of [:manual, :csv, :hubspot, :agent_found, :referral]`; `source_ref : string, required, ≤ 120, per-kind grammar of ids only` (`manual:<uuid>` client request id; `csv:<import uuid>:<row ≥ 1>`; `hubspot:<portal digits>:<object digits>`; `agent_found:<run uuid>:<candidate uuid>`; `referral:<original lead uuid>:<reply or outcome uuid>`; DB check by regex, so no name or address fits); `input_version : int, required, = 1`; `input_sha256 : string, required, 64 lowercase hex` (canonical JSON of the normalized input); `outcome : atom, required, one_of [:admitted, :duplicate_open_lead, :active_target_exists, :previously_worked, :contact_at_other_account, :contact_archived, :account_archived, :suppressed]`; `suppression_scope : atom, nullable, one_of [:email, :domain]`; `readmit : boolean, required, default false`; `account_created`, `contact_created : boolean, required, default false`; `inserted_at`; `trace_id`, `span_id` | belongs_to Tenant (required, restrict); belongs_to User `requested_by` (required, restrict); belongs_to Campaign (required, restrict); belongs_to Account (optional, restrict); belongs_to Contact (optional, restrict); belongs_to Lead `matched_lead` (optional, restrict); belongs_to AgentRun (optional, restrict); belongs_to Lead `referral_from_lead` (optional, restrict); has_one Lead (via `Lead.admission_id`, unique). Identity unique `(tenant_id, source_kind, source_ref)`. No FK to Outreach (Sales sits below Outreach); a suppressed outcome records only the scope, and the never-lifted suppression row is found by value | Append-only (`Audit.SQL.append_only`); no update or destroy. DB checks: `matched_lead_id` not null iff outcome in (`duplicate_open_lead`, `active_target_exists`); `suppression_scope` not null iff outcome = `suppressed`; `agent_run_id` not null iff kind = `agent_found`; `referral_from_lead_id` not null iff kind = `referral`; `readmit` only for `manual` and `referral`; `account_created`/`contact_created` true only when outcome = `admitted`; `account_id`/`contact_id` not null when admitted. Deferred constraint trigger (`DEFERRABLE INITIALLY DEFERRED`, checked at commit): an `admitted` row is referenced by exactly one lead. Replay of the identity with the same `input_sha256` returns the stored row marked `:sdr_replayed` (no event, no side effect); a different hash is refused `:source_ref_conflict` | `:record` (create): active human admin, only inside the admission orchestrator (`Sales.Checks.AdmissionContext` marker, as `QualificationContext`); every other actor and any call without the marker forbidden; auditor refusal audited by Guard. Reads: ADM, REV, AUD roles; `agent_runtime` (referrer lookup for drafting), `auditor_cli`, kernel. Audited `sales.admission.recorded` | OQ-1, OQ-2 change which outcome applies, not the shape |
| Sales.Lead | Existing (delta) | The person being worked; now always admitted | `source`: enum becomes `[:manual, :csv, :hubspot, :agent_found, :referral, :fixture, :crm]`; `:fixture` only via `:seed`; `:crm` legacy rows only (no action writes it after C3-02; existing rows never relabelled). Add `admission_id : uuid, nullable, unique where not null`; DB check: `admission_id IS NOT NULL OR source IN ('fixture','crm','manual')`, so the four new kinds always carry an admission; `:create` requires `admission_id`, so a new manual lead always has one too, and only legacy manual rows keep null (test-pinned). Add `referred_from_lead_id : uuid, nullable, unique where not null`; check: not null iff `source = 'referral'`. Status adds `:referred` (terminal) | belongs_to LeadAdmission (restrict); belongs_to Lead `referred_from` (restrict) via composite FK `(referred_from_lead_id, tenant_id, account_id)` → `leads (id, tenant_id, account_id)` (new unique index on that triple), so the successor is at the same company. New identity `one_open_per_account [:tenant_id, :account_id] where status not in (disqualified, converted, nurture, stopped, referred)`, partial unique index. Existing `unique_open_lead` (per contact) kept, its `where` gains `referred` | Open = new, assigned, researching, qualifying, qualified, in_outreach, replied, blocked (same set as `Outreach.Locks.open_leads/0`, pinned by a test). New transition `{:refer, [:in_outreach, :replied], :referred}`: stamps `closed_at`, `status_reason = "referred"`, event `sales.lead.referred` (previous status, successor admission id). `referred` is terminal: no reopen, override or stop. `:create` now accepts `admission_id`, `referred_from_lead_id` and only the five source kinds. `:reopen` and `:requalify_by_override` make a closed lead open again; the account identity refuses them while another lead at the company is open, mapped to a typed field error (`account_id: "company has an active lead"`). Unchanged: `new → assigned → researching → qualifying → qualified/disqualified`, qualification-only `qualify`/`disqualify`, `in_outreach` only from `qualified` | `:create`: `forbid_unless AdmissionContext`, then active human admin (was ADM without marker). `:refer`: `forbid_unless ReferralContext` (new private marker set only by the handover), then active human admin. All other policies unchanged | none |
| Sales.Account | Existing (delta) | Company identity used for dedupe and the active-target slot | `source`: enum becomes `[:manual, :csv, :hubspot, :agent_found, :referral, :fixture, :crm]` (the kind of the admission that created it; existing values kept). `NormalizeDomain` also strips one trailing `.` and one leading `www.` label (trim and lowercase already); a URL, port or path is still refused, not parsed; subdomains stay distinct; non-ASCII is refused (callers send punycode) | new inverse has_many LeadAdmission (read only). has_many Lead now carries the account-level identity above (at most one open lead per account) | Migration pre-check: if any two existing accounts in a tenant collide after the new normalization, or any account has two open leads, the migration aborts with counts and changes nothing; resolution is an explicit admin action, never automatic. Admission locks the row `FOR SHARE` (blocks a concurrent archive). `:archive` unchanged; archived accounts get no new leads (existing `LeadAccount`) | `:create` policy unchanged (ADM); admission calls it inside the admission transaction. Direct `create_account` stays for admin use; it creates no lead | none |
| Sales.Contact | Existing (relationship delta only) | Person identity used for dedupe | — | new inverse has_many LeadAdmission (read only); account is immutable after create (unchanged, relied on for the account-level identity) | Admission normalizes the email (trim, lowercase) before calling `:create`; no dot or plus folding. Admission never overwrites an existing contact's fields (D-008 field ownership; C8 owns CRM updates). Locked `FOR SHARE` by admission (blocks archive and `:change_email`) | unchanged (ADM create) | none |
| Sales.CampaignEnrollment | Existing (delta, C3-03) | Stop the original lead's sequence on referral | `stop_reason` adds `:referred` | unchanged | `:stop` from active/paused with `:referred` only inside the handover | `:stop` policy adds `authorize_if ReferralContext` (same pattern as `SuppressionContext`) | none |
| Outreach.Approval | Existing (delta, C3-03) | Invalidate granted approvals of the original lead's open drafts | `invalidated_reason` adds `:lead_referred` (enum and DB check) | unchanged | `granted → invalidated` via the existing `:invalidate` (InternalWrite) | unchanged; called from the new Outreach-owned closer below | none |
| Outreach.Draft / DeliveryOperation | Existing (behaviour delta, C3-03) | Cancel the original lead's open work | no schema change; `status_reason "referred"`, delivery `last_error %{"reason" => "lead_referred"}` | unchanged | Same effects and selection as `ApplySuppression` for one lead: pending-review and unclaimed queued drafts cancelled; pending/failed_retryable deliveries cancelled; a claimed delivery is left to its outcome (capture only). Run by a new Outreach-owned function (`SdrAgent.Outreach.Referral.close_open_work/3`) that sets `InternalWrite`, so Sales still never calls Outreach and SDR never sets an Outreach marker | unchanged | none |
| Outreach.Suppression | Existing | Do-not-contact facts admission must honor | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found | — | none |
| Research.Qualification / EvidenceClaim | Existing | Mandatory qualification after research | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found | — | none |
| Agents.AgentRun | Existing | Queued research run; agent_found provenance | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found (admission uses `usage_origin :assignment`, the handover `:referral`, both existing D-104 buckets) | — | none |
| Sales.Campaign | Existing | Program the admitted lead is assigned to | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found | — | none |
| Accounts.User / Audit.Tenant / Actor | Existing | Requester identity and tenant | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found (no new role or system actor type) | — | none |

Configured reviewer: Codex via ai-pair (`ai_pair=true`, `codex_review=true`).
Verdict: **UNREVIEWED** (section 13).

## 4. Action contracts

### 4.1 `SdrAgent.SDR.admit_lead(input, actor:)` (C3-02)

Lives in SDR (as `assign_lead/2`) because it spans Sales and Outreach reads.
Wrapped in `Audit.Guard.run` and one `Audit.transaction`.

Input (validated before any lock): `source_kind`, `source_ref`,
`campaign_id`, `company` (`domain` required; `name` required when new;
optional `website_url`, `industry`, `employee_count`, `geography`),
`person` (`email` required; `first_name`, `last_name` required when new;
optional `title`, `timezone`), `agent_run_id` (agent_found only), `readmit`
(manual and referral only). Missing email is refused; B2/B5 turn it into a
confirmation task, never a placeholder address.

Decision order (first match wins; the outcome is recorded unless it is an
error):

| Step | Condition | Result | Writes |
|---|---|---|---|
| 1 | actor not an active admin of the tenant (re-read) | `{:error, :forbidden}` | Guard denial audit only |
| 2 | invalid input, grammar or real-data guard refusal | `{:error, {:invalid, fields}}` / `:real_data_disabled` | nothing |
| 3 | campaign missing or not `active` | `{:error, :campaign_not_active}` | nothing |
| 4 | same `source_ref`, same hash | stored result, `replayed?: true` | nothing |
| 5 | same `source_ref`, different hash | `{:error, :source_ref_conflict}` | nothing |
| 6 | suppression on the email, the email's domain or the company domain | `suppressed` | admission row |
| 7 | email belongs to a contact at another account | `contact_at_other_account` | admission row |
| 8 | contact archived / account archived | `contact_archived` / `account_archived` | admission row |
| 9 | contact has an open lead | `duplicate_open_lead` (matched) | admission row |
| 10 | account has an open lead for another person | `active_target_exists` (matched) | admission row |
| 11 | contact has only closed leads and not (`readmit` and kind in manual, referral) | `previously_worked` | admission row |
| 12 | otherwise | `admitted` | account and contact if new, admission row, lead `new`, then assign → `assigned` with a queued research run |

Returns `{:ok, %{admission, outcome, lead, run, replayed?}}` (`lead`/`run` nil
unless admitted). Errors are closed atoms or field lists without values. A
unique violation raised by a concurrent direct `create_account` or
`create_contact` outside admission rolls the whole transaction back and
returns `{:error, :conflict}`; a retry is safe (C3-R3).

Agent-found admissions also require `agent_run_id` to be a run of the tenant
with `usage_origin :discovery`, and the run id in `source_ref` to equal it.

### 4.2 `SdrAgent.SDR.hand_off_referral(input, actor:)` (C3-03)

Input: `original_lead_id`, `source_ref` (`referral:<original>:<reply or
outcome id>`), `campaign_id`, `person` (as above), optional `readmit`.
Company is always the original lead's account (same-company only, D-095).

Extra refusals before any write (`{:error, reason}`, nothing written):
`:original_not_referable` (not `in_outreach` or `replied`, or not in the
tenant), `:original_run_active` (a queued or running run on the original),
`:self_referral` (same contact or same email). Then steps 4-12 above apply
with one difference at step 10: the open lead at the account is the original,
so the handover proceeds. If the outcome is anything but `admitted`, only the
admission row is written and the original is untouched (C3-R9); the owner
decides what to do with it.

On `admitted`, in one transaction (all locks already held, section 6):
contact (if new) → admission row (`referral_from_lead_id` = original) →
original `:refer` (its event links that admission) → enrollments stopped
(`:referred`) → `Outreach.Referral.close_open_work/3` → lead (`source
:referral`, `referred_from_lead_id` = original; the original is already
closed, so the account index admits it) → assign with `usage_origin
:referral`.
The referrer for drafting is the original lead's contact, read through
`referred_from_lead_id`; no name is copied.

## 5. Dedupe identity rules

| Identity | Normalization | Store | Notes |
|---|---|---|---|
| Company | trim, lowercase, strip one trailing `.`, strip one leading `www.`; host of ≥ 2 labels, no scheme, port or path | `accounts (tenant_id, domain)` unique (existing) | `eu.orbit.example.org` and `orbit.example.org` are different companies; no public-suffix guessing. Name is never a key |
| Person | trim, lowercase whole address | `contacts (tenant_id, email)` unique, ci (existing) | no provider-specific folding; email domain need not equal the company domain |
| Source observation | exact `source_ref` | `lead_admissions (tenant_id, source_kind, source_ref)` unique (new) | idempotency, not identity of a person |
| Active target | — | `leads (tenant_id, account_id)` partial unique over open statuses (new) | the C3-R5 invariant |
| CRM ids | — | existing `accounts.crm_external_id` identity | C3 writes none; C8 owns HubSpot identity and mapping |

Per source, the same rules apply; only the provenance differs:

| Source | Typical duplicate | Recorded outcome |
|---|---|---|
| manual | founder adds a person already being worked | `duplicate_open_lead`; form shows the existing lead |
| csv | the same person on two rows or two imports | first row admitted; later rows `duplicate_open_lead` (or a replay if the same import row is resubmitted) |
| hubspot | object already admitted from CSV or by hand | `duplicate_open_lead`; C8 links the CRM id under its own delta |
| agent_found | candidate at a company that already has a target | `active_target_exists` (B2-04) |
| referral | referred person already open elsewhere in the tenant | `contact_at_other_account` or `duplicate_open_lead`; original unchanged |

## 6. Lock order and concurrency

Rule (ADR-0009): every row lock before the first audit append. Admission and
the handover never take `FOR UPDATE` or `FOR NO KEY UPDATE` on campaigns,
accounts, contacts or users, only `FOR SHARE`/`FOR KEY SHARE`, so existing
writers that lock those rows first can never wait on them in a cycle.

Order (both actions):

1. **Admission keys** (transaction advisory locks,
   `pg_advisory_xact_lock(hashtextextended(key, 0))`, precedent in
   `Outreach.Webhooks`): `admission-ref:<tenant>:<kind>:<ref>`,
   `admission-domain:<tenant>:<domain>`, `admission-email:<tenant>:<email>`,
   and `admission-domain:<tenant>:<email domain>` when it differs. All keys of
   a transaction are taken in ascending 64-bit key order, before any row
   lock. A multi-row transaction (a B6 batch) collects every row's keys first
   and takes them in one sorted pass. For the handover, the domain is read
   unlocked from the original's account, then re-checked after step 4; a
   change returns `:conflict`.
2. Requesting user `FOR SHARE` (the authorization re-read; a concurrent
   demotion or disable waits for commit).
3. Campaign `FOR SHARE` (must be `active`).
4. Agent run `FOR KEY SHARE` (agent_found only), before any lead lock, so a
   worker holding the run and wanting a lead never waits on us.
5. Account by domain `FOR SHARE`, contact by email `FOR SHARE` (each if it
   exists).
6. Every lead of the account, one query ordered by id: `FOR SHARE` for
   admission, `FOR UPDATE` for the handover. This makes `:reopen` and
   `:requalify_by_override` (which lock their lead before the head) serialize
   with admission instead of meeting it at the unique-index slot after the
   head. Bounded: one open lead per company plus its history.
7. Handover only: `Outreach.Locks.targets(tenant, %{lead_ids: [original],
   contact_ids: []})` — the original (already held), its active/paused
   enrollments, open drafts, unclaimed deliveries, granted approvals, each
   `FOR UPDATE` by id, the existing Outreach order.
8. Reads without locks: replay lookup (serialized by the ref key),
   suppressions (append-only, never lifted), active runs of the original
   (no new run can be created for it while step 6 holds it).
9. Chain head `FOR UPDATE` at the first append; then all writes.

Implicit locks taken by inserts (foreign-key checks take `FOR KEY SHARE` on
the referenced row):

| Insert | Referenced rows (implicit `FOR KEY SHARE`) | Already held? |
|---|---|---|
| Account (new) | tenant | tenant: no writer locks tenant rows (to verify in C3-02 RED) |
| Contact (new) | tenant, account | account: own new row or step 5 |
| LeadAdmission | tenant, user, campaign, account, contact, matched lead or referral original, agent run | steps 2-6 (stronger or equal modes) |
| Lead | tenant, contact, account, admission, referred_from (composite) | own rows or steps 5-6; `LeadAccount` re-locks the account `FOR SHARE` (held) |
| Assign path (reused from `SDR.assign_lead/2`) | lead (own), campaign (step 3), agent definition, Operation, Oban job | inherited order; the definition lookup is unchanged from today |

Count for the largest case (handover admitting a new person at the
original's company): up to 4 advisory keys; up to 10 explicit row-lock
statements (user, campaign, account, contact if it exists, account leads,
then the 5 `Outreach.Locks` queries); 1 chain head; about 18 implicit
key-share checks (contact 2, admission 6, lead 5, assign path about 5). Each
targets a row this transaction created or already holds in an equal or
stronger mode, except tenant and agent definition rows, which no writer
locks exclusively today (to confirm in C3-02 RED).

Cycle check against existing writers:

| Writer | Its order | Why no cycle |
|---|---|---|
| `BindApproval` | enrollment SHARE → draft UPDATE → campaign SHARE → contact SHARE → head | our campaign/contact locks are SHARE (compatible); we wait on its enrollment, it never waits on us |
| `ApplySuppression` | leads → enrollments → drafts → deliveries → approvals → head | same suffix order as step 6-7; it never requests our prefix locks |
| `Outreach.Webhooks` | message advisory key → Locks superset → head | does not take admission keys; same suffix order |
| Account/Contact `:archive`, `:change_email` | row UPDATE → head | blocks on our SHARE while holding nothing we need |
| User role/status change | active admins UPDATE → head | blocks on our SHARE while holding nothing we need |
| Campaign transitions | campaign UPDATE → (enrollments) → head | campaign first, as we do |
| Lead `:reopen`, `:requalify_by_override`, agent transitions | lead UPDATE → head | either they wait at the lead (holding nothing we need) or we wait at step 6 before the head |
| `SDR.assign_lead/2`, `retry_run/2` | lead UPDATE → head → inserts | lead-first, as step 6 |

Known residual (for review): a suppression whose contact lookup runs before
an admission commits, while the admission's suppression read runs before the
suppression commits, can leave a new open lead for a suppressed address. No
contact can follow: `AcceptAssignment`'s deterministic suppression gate runs
before any research or model call, and enrollment and the send gate check
again. The lead then holds the company slot until an operator stops it.
Closing this fully would need `Suppression` creates to take the same email or
domain key first, which changes the reviewed suppression and webhook lock
order; this packet does not propose that.

## 7. Real-data guard and public surfaces

- Admission validates the domain and email with the existing guard
  (`Sales.Validations.Reserved` today, C5-04's policy once merged) **before**
  any key, read or write. A refusal writes nothing, so a real value is never
  stored while the switch is off.
- With the switch off, C5-04 also stops processing of already persisted real
  leads; admission adds no path around it (the queued run is refused by that
  gate, an attention Failure follows, the lead never advances).
- Provenance holds ids and a hash, never values. Error messages name fields,
  not values. Admission adds no log line or span attribute containing a name,
  email or domain; tests assert it. Contact rows and their audit after-images
  hold personal data locally only, the accepted limitation of amendment 2.
- Every fixture, test, doc and screenshot for C3 uses reserved domains.

## 8. Events

| Event | When | Content |
|---|---|---|
| `sales.admission.recorded` (new) | every new admission row, any outcome | after-image: kind, ref, outcome, ids, hash; no personal fields |
| `sales.account.created`, `sales.contact.created`, `sales.lead.created` (existing) | admitted path | lead after-image now includes `source`, `admission_id`, `referred_from_lead_id` |
| `sales.lead.assigned`, `sdr.lead.assigned`, run/Operation events (existing) | admitted path | unchanged; run `usage_origin` gives the D-104 bucket |
| `sales.lead.referred` (new) | handover | previous status; successor admission id |
| `sales.enrollment.stopped`, `outreach.draft.cancelled`, `outreach.delivery.cancelled`, `outreach.approval.invalidated` (existing) | handover | new reason values `referred` / `lead_referred` |
| `authz.denied` (existing) | refused actor | via Guard |

A replay appends nothing.

## 9. Test plan (RED first, synthetic only)

C3-02 (`test/sdr_agent/sdr/admission_test.exs`, `test/sdr_agent/sales/lead_admission_test.exs`):

- Each of the five kinds admits a new person at a new company: one account,
  contact, admission, lead; lead ends `assigned` with one queued run
  (`usage_origin :assignment`); stored rows and events asserted.
- Policy: active admin allowed; reviewer, auditor (audited), disabled admin, a
  stale admin struct demoted in the DB, every system actor denied; direct
  `Lead :create` and `LeadAdmission :record` without the marker denied.
- Every outcome row of the decision table, per source where it differs; no
  account/contact created for suppressed (email, email domain, company
  domain), other-account, archived outcomes.
- Normalization: `WWW.Orbit.Example.org.` and `orbit.example.org` dedupe;
  `eu.orbit.example.org` does not; URL input refused; email case and
  whitespace dedupe.
- Idempotency: replay returns the stored row with no new row, run or event;
  same ref, different input refused; concurrent same-ref submissions produce
  one admission.
- `source_ref` grammar: each kind's valid form; a ref containing `@`, spaces
  or letters outside hex refused by the action and by the DB check.
- Invariant: two concurrent admissions of different people at one company →
  one `admitted`, one `active_target_exists`; direct insert of a second open
  lead at an account fails at the index; `:reopen` and
  `:requalify_by_override` refused with the typed error while another lead is
  open; closed leads do not block.
- No skip: an admitted lead cannot `qualify`, `start_outreach`, enroll or get
  a draft without research and a recorded qualification (each attempt
  refused), for every source kind.
- `readmit`: allowed for manual, refused for csv/hubspot/agent_found; a
  re-admitted contact gets a new lead and keeps the old one.
- Deferred trigger: an `admitted` row without a lead fails at commit.
- Real data: a non-reserved domain or email is refused with nothing written;
  the value is absent from the error, logs and captured spans.
- Migration: collision pre-check aborts on synthetic colliding data; legacy
  `crm`/`fixture`/`manual` rows untouched; `Outreach.Locks.open_leads/0`
  equals the Lead open set.

C3-03 (`test/sdr_agent/sdr/referral_handover_test.exs`):

- Handover from `in_outreach` and from `replied`: original `referred` with
  `closed_at`; enrollment stopped `:referred`; pending and unclaimed queued
  drafts cancelled; unclaimed deliveries cancelled; granted approvals
  invalidated `:lead_referred`; claimed delivery untouched; new lead
  `assigned` with `usage_origin :referral` and `referred_from_lead_id`.
- Refusals with nothing written: original in any other state, active run on
  the original, self-referral, cross-tenant ids, non-admin actors.
- Referred person suppressed, at another company or already worked: admission
  row recorded, original unchanged.
- Duplicate handover (same ref) replays; a second handover from the now
  `referred` original refused; `referred` cannot be reopened, overridden or
  stopped.
- Races: handover vs approval of the original's draft, vs suppression of the
  original, vs a concurrent admission at the same company; each ends in one
  consistent order with the one-open-lead invariant held.
- Composite FK: a `referred_from_lead_id` at another account is rejected by
  the DB.

Gate: `bin/verify` and `mix credo` on an isolated test partition; never the
owner's demo database; no model calls (Fake provider only).

## 10. Affected modules and proposed slices

No code changes in C3-01. Names are proposals.

**C3-02** (after PASS and G5):

- New: `lib/sdr_agent/sales/lead_admission.ex`,
  `lib/sdr_agent/sales/checks/admission_context.ex`,
  `lib/sdr_agent/sdr/admission.ex`; migration (table, identities, checks,
  append-only and deferred triggers, `leads` index and columns, account
  pre-check).
- Changed: `lib/sdr_agent/sales/lead.ex` (source enum, `admission_id`,
  identity, `:create` policy), `lib/sdr_agent/sales/account.ex` (source
  enum), `lib/sdr_agent/sales/changes/normalize_domain.ex`,
  `lib/sdr_agent/sales.ex` (admission reads), `lib/sdr_agent/sdr.ex`
  (`admit_lead/2`; extract the assign body so admission reuses it inside its
  transaction), `test/support/sales_fixtures.ex` (leads through admission),
  `lib/sdr_agent/demo/fixtures.ex` if a seed shares an account.
- Diagrams: regenerate the Sales domain diagram (new resource) and the
  data-flow diagram (new public admission flow).

**C3-03** (after C3-02 merges):

- Changed: `lead.ex` (`:referred`, `:refer`, `referred_from_lead_id`,
  composite FK), `campaign_enrollment.ex` (`:referred`, ReferralContext),
  `outreach/approval.ex` (`:lead_referred`), `sdr.ex`
  (`hand_off_referral/2`).
- New: `lib/sdr_agent/sales/checks/referral_context.ex`,
  `lib/sdr_agent/outreach/referral.ex`.

ADR: not required. The admission record and invariants follow ADR-0009 and
ADR-0010 inside the Sales domain; the advisory-key pattern already exists in
`Outreach.Webhooks`; the one-target rule is an owner decision (D-095). The
reviewer may ask for one if the key pattern is judged cross-cutting.

## 11. Risks

| Risk | Mitigation |
|---|---|
| Existing tests and demo seeds create two open leads at one account | C3-02 updates fixtures to admit through the new path; assertions are not weakened |
| Migration meets colliding domains or two open leads in the owner's dev data | pre-check aborts with counts; the owner chooses, nothing is merged automatically |
| Suppression race residual (section 6) | downstream deterministic gates; recorded for review |
| B6 batch transactions take many keys | sorted single pass; B6 chooses batch size and partial-commit policy under its own review |
| B1 needs a campaign for manual add | admission requires `campaign_id` (existing assign contract); B1 chooses the default campaign in its packet |

## 12. Questions for the owner (G5)

- **OQ-1 Re-admitting someone already worked.** A person whose earlier lead
  closed (disqualified, nurture, converted, stopped, referred). Proposal:
  CSV, HubSpot and agent-found never re-target them; they are recorded as
  "previously worked". Manual add and referral may, with an explicit "work
  this person again" confirmation. A suppressed person is never re-admitted
  either way. Alternative: every source may re-admit.
- **OQ-2 Companies already in a relationship.** A company whose last lead
  ended converted or nurture. Proposal: same rule as OQ-1 for the company:
  automatic sources skip it ("company in relationship", a new outcome),
  manual add allowed. Alternative: treat it like any company with no open
  lead (only the open-lead rule applies). This packet models the
  alternative until you answer; the proposal adds one outcome value.
- **OQ-3 Referral to another company.** "Talk to my colleague at our parent
  company." Proposal: not a handover. The original stays as it is; you can
  add the person by hand at the other company and note the reply. The
  referral handover stays same-company only (D-095). Alternative: a
  cross-company handover that closes the original as referred too.

## 13. Gate record (to fill)

- Entity-model reviewer: Codex via ai-pair (capabilities `ai_pair=true`,
  `codex_review=true`).
  - Verdict: **UNREVIEWED.** Not yet submitted; correlation id, reply id and
    report hash to be recorded here. UNREVIEWED blocks C3-02/C3-03.
- Owner G5 (scoped C3): pending; answers to OQ-1..OQ-3 recorded here.
- C3-01 docs verification: docs-only change; no code, migration or test
  changed.

## 14. Next authorized scope (when PASS and G5)

Implement C3-02 then C3-03 as reviewed PRs (Claude authors, Codex reviews,
exact-head CI), adjusted by the owner's answers. No real data until C5-04
merges and the switch is on; no ordinary real model calls until R0's
conditions hold. Nothing else.
