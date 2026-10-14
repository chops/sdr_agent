# C3 readiness packet: lead admission

Status: **entity/action PASS by Codex at 1737063 (round 4); owner gates
answered 2026-10-14; OQ-2 revision PASS by Codex at ef74d2a (round 5).**
C3-01 (#55), Claude author → Codex reviewer; draft PR #141.
Rounds 1-3 were NEEDS-REVIEW (section 13); implementation obligations are in
section 15. On 2026-10-14 the owner accepted the ADR-0009 C3 amendment and
C4's ADR-0005 logging amendment (O4), answered OQ-1..OQ-3 (section 12) and
approved the scoped C3 G5 including the stricter company-domain suppression
(O8), on this packet as revised for OQ-2 (section 4.4), which Codex passed
at ef74d2a. Nothing here
authorizes C3-02 (#56) or C3-03 (#57) code, a migration, a model call or real
data. Implementation starts only after (1) Codex records an entity-model
verdict of PASS on sections 3-7, (2) the owner accepts the proposed ADR-0009
identity-key amendment, and (3) the owner approves a scoped C3 G5. The R0 G5
does not cover C3.

Sources: build plan v3 (D-097) §3 contract C3, §9, §9a
([`owner-decisions`](https://github.com/chops/sdr_agent/blob/owner-decisions/docs/product/build-plan.md));
backlog draft C3-01..03, B1-03, B2-04, B5-04, B6-01..03, C8-02;
decisions D-048, D-049, D-052, D-056, D-059, D-060, D-066, D-084, D-095,
D-101, D-104; ADR-0014 amendment 2 (constraint 7, accepted 2026-10-12);
ADR-0009 (persistence and audit conventions, plus the proposed identity-key
amendment in this PR), ADR-0010 (lifecycles). Code facts are from `main` at
182bde6.

All examples are synthetic (reserved domains, invented names).

## 1. Scope and non-goals

C3 defines how a person at a company becomes a lead. Every source enters one
path: validate → dedupe → admit → research (queued) → qualification. Nothing
reaches a draft without research and qualification.

In scope:

- C3-01: this packet and the proposed ADR-0009 amendment.
- C3-02: `SdrAgent.SDR.admit_lead/2` for `manual`, `csv`, `hubspot` and
  `agent_found`; the shared identity keys (`SdrAgent.Audit.IdentityKeys`) and
  their adoption by every writer of an email, domain or open-lead identity,
  including Suppression and the webhook paths. Logging and span controls come
  from C4's proposed ADR-0005 amendment (O4), not from C3.
- C3-03: `SdrAgent.SDR.hand_off_referral/2`, the only `referral` entry point.
  It closes the original lead as `referred`, keeps its history and admits the
  referred person at the same company.

Non-goals (owned elsewhere, each with its own review):

- Input surfaces: manual-add form (B1-03), CSV parse, preview, batch and
  partial-commit policy (B6-01..03), HubSpot identity, field mapping,
  re-sync and remote opt-out (C8), contact candidates and their confirmation
  (B2-05..07), reply capture and classification (B5-02). They call C3 with a
  validated input; C3 does not parse files or call providers.
- Account-only discovery and target lists (B2-03).
- The real-data switch and guard policy (C5-04). C3 calls them at two points
  (section 7) and adds no bypass.
- Changing a lead's person or company after admission; merging accounts or
  contacts; multi-stakeholder outreach (D-059: post-MVP).
- Drafting the referral email (B5-04). C3 provides the referrer link only.

## 2. Requirements (observable behavior)

| ID | Requirement |
|---|---|
| C3-R1 | Every lead created after C3-02 has exactly one admission record whose source kind is `manual`, `csv`, `hubspot`, `agent_found` or `referral`, and that record says `admitted` for that lead's tenant, company, person and source. No other path creates a lead; the only exception is the dev/test `:seed` action with source `fixture`. Existing leads keep their stored values. |
| C3-R2 | Provenance answers who, what and when without copying personal data: the requesting human, the source kind, an id-only source reference, the campaign, the time, and the sha256 of the normalized input (section 5.2). It never contains a name, email or free text. |
| C3-R3 | Submitting the same source reference again with the same normalized input returns the stored result and writes nothing, even if the campaign, the original lead or suppressions changed since. Only authorization, input validity and the live real-data guard can refuse a replay. The same reference with different input is refused. |
| C3-R4 | Dedupe uses the canonical company domain (old and new account rows alike) and the normalized email. A duplicate never creates a second account, contact or open lead; the outcome is recorded with the matched lead. |
| C3-R5 | A company has at most one open (active outbound) lead at a time, enforced by the database. Closed leads stay as history. A second person at a company with an open lead is recorded as `active_target_exists`; only the referral handover replaces the open lead. |
| C3-R6 | An admitted lead gets its research run queued in the same transaction. It reaches `qualified` only through a recorded qualification after research, and a draft only from `in_outreach`. No source, flag or role skips research or qualification (D-049, D-052). |
| C3-R7 | A suppressed email, email domain or company domain is never admitted, including when the suppression and the admission run at the same time: they serialize on shared identity keys, and in either commit order the person ends with no open lead. A suppressed attempt is recorded as `suppressed` with no account, contact or lead created for it. |
| C3-R8 | Only an active human admin admits, from any source. Reviewers, auditors and every system actor are refused, and the refusal is audited. The agent proposes people (B2); a human confirms them. |
| C3-R9 | Referral has one entry point. The handover is one transaction: the original lead becomes `referred` (terminal, kept), its open enrollment, drafts, unclaimed deliveries and granted approvals are closed, and the referred person is admitted at the same company with a link to the original. If the referred person cannot be admitted, only the observation is recorded and the original is untouched. `admit_lead` refuses `referral`. |
| C3-R10 | Real data only under amended constraint 7: the live real-data guard is checked before any read and again after all locks, just before the first write. A refusal writes nothing and does not echo the value. Executable tests show that no name, email or domain from an admission reaches logs (at debug), span attributes, span status or events (with dev content capture on), `oban_jobs.errors` or error terms, under the ADR-0005 C4 amendment's controls (O4), for valid, invalid, conflicting, suppressed and replayed input. |
| C3-R11 | Concurrent admissions, suppressions, direct account/contact writes, reopen/override and referral serialize on the identity keys before any shared row lock. Exactly one order wins; the others get a recorded outcome or a typed retryable conflict. No unique-index wait or deadlock occurs after the chain head by design, shown by tests on independent database connections. |

## 3. Entity model (soft-stop)

Entity Model trigger: **yes**.
Reason: new persisted admission record; changed Lead source enum, statuses,
identities, triggers and actions; new account-level invariant and canonical
domain key; new terminal state and referral effects on enrollments, drafts
and approvals; a new cross-cutting lock contract on Suppression, webhooks,
Account, Contact and Qualification writers.

| Entity | New / Existing | Purpose | Attributes | Relationships | Invariants / Lifecycle | Policy/Actor | Open Questions |
|---|---|---|---|---|---|---|---|
| Sales.LeadAdmission | New | One immutable record per new admission request and its outcome: provenance and dedupe history | `id : uuid_v7`; `tenant_id : uuid, required`; `source_kind : atom, required, one_of [:manual, :csv, :hubspot, :agent_found, :referral]`; `source_ref : string, required, ≤ 120`, per-kind grammar of ids only, DB-checked by regex: `manual:<uuid>`, `csv:<uuid>:<row ≥ 1>`, `hubspot:<digits>:<digits>`, `agent_found:<run uuid>:<candidate uuid>`, `referral:<original lead uuid>:<reply or outcome uuid>` (lowercase hex uuids); `input_version : int, required, = 1`; `input_sha256 : string, required, 64 lowercase hex` (section 5.2); `outcome : atom, required, one_of [:admitted, :duplicate_open_lead, :active_target_exists, :previously_worked, :contact_at_other_account, :contact_archived, :account_archived, :company_in_relationship, :suppressed]`; `suppression_scope : atom, nullable, one_of [:email, :domain]`; `readmit : boolean, required, default false`; `account_created`, `contact_created : boolean, required, default false`; `inserted_at`; `trace_id`, `span_id` | Composite FKs (all restrict; target unique indexes added where absent): `(requested_by_user_id, tenant_id)` → users `(id, tenant_id)`, required; `(campaign_id, tenant_id)` → campaigns `(id, tenant_id)`, required; `(account_id, tenant_id)` → accounts `(id, tenant_id)`; `(contact_id, tenant_id)` → contacts `(id, tenant_id)` and `(contact_id, account_id, tenant_id)` → contacts `(id, account_id, tenant_id)` (checked when both set, MATCH SIMPLE); `(matched_lead_id, tenant_id, account_id)` → leads `(id, tenant_id, account_id)`; `(agent_run_id, tenant_id)` → agent_runs `(id, tenant_id)`; `(referral_from_lead_id, tenant_id)` → leads `(id, tenant_id)`. Unique `(id, tenant_id, account_id, contact_id)` as target of the Lead binding FK. has_one Lead (via `Lead.admission_id`, unique). Identity unique `(tenant_id, source_kind, source_ref)`. No FK to Outreach (ADR-0009 layering); a suppressed outcome records the scope only | Append-only (`Audit.SQL.append_only`). DB checks: `matched_lead_id` not null iff outcome in (`duplicate_open_lead`, `active_target_exists`); `matched_lead_id IS NULL OR account_id IS NOT NULL` (both matched outcomes have a known company, so the MATCH SIMPLE triple FK on the matched lead is never skipped); `suppression_scope` not null iff outcome = `suppressed`; `agent_run_id` not null iff kind = `agent_found`; `referral_from_lead_id` not null iff kind = `referral`; `readmit` only for `manual` and `referral`; outcome `company_in_relationship` only for `csv`, `hubspot` and `agent_found`, and then `account_id` not null; `account_created`/`contact_created` only when outcome = `admitted`; `account_id` and `contact_id` not null when admitted; `account_id` null when outcome = `contact_at_other_account` (the contact's own account is not this company); source_ref's embedded run or original id equals `agent_run_id` / `referral_from_lead_id` (SQL `split_part`). Deferred constraint trigger (`DEFERRABLE INITIALLY DEFERRED`): an `admitted` row is referenced by exactly one lead at commit. Values the DB cannot check are validated in the action under lock before insert (section 5.3) | `:record` (create): active human admin, only inside the admission orchestrator (`Sales.Checks.AdmissionContext` marker, like `QualificationContext`); everything else forbidden, auditor refusal audited by Guard. Reads: ADM, REV, AUD roles; `agent_runtime` (referrer lookup for drafting); `auditor_cli`; kernel. Audited `sales.admission.recorded` | none (OQ-1 and OQ-2 answered 2026-10-14, sections 4.3 and 4.4) |
| Sales.Lead | Existing (delta) | The person being worked; now always admitted | `source` enum becomes `[:manual, :csv, :hubspot, :agent_found, :referral, :fixture, :crm]`. Add `admission_id : uuid, nullable, unique where not null`; `referred_from_lead_id : uuid, nullable, unique where not null`. Status adds `:referred` (terminal) | Composite FK `(admission_id, tenant_id, account_id, contact_id)` → lead_admissions `(id, tenant_id, account_id, contact_id)` (restrict); composite FK `(referred_from_lead_id, tenant_id, account_id)` → leads `(id, tenant_id, account_id)` (restrict; new unique index on that triple), so the successor is at the same company; composite FK `(contact_id, account_id, tenant_id)` → contacts `(id, account_id, tenant_id)`. New identity `one_open_per_account [:tenant_id, :account_id] where status not in (disqualified, converted, nurture, stopped, referred)`, partial unique index; existing `unique_open_lead` (per contact) kept, its `where` gains `referred` | **Cutover (BEFORE INSERT trigger `leads_admission_binding`):** a new row needs `admission_id`, except `source = 'fixture'` (seed; the action is dev/test-gated); `source = 'crm'` can no longer be inserted; with `admission_id`, the referenced admission must have outcome `admitted`, `source_kind = NEW.source` and `referral_from_lead_id IS NOT DISTINCT FROM NEW.referred_from_lead_id`. **BEFORE UPDATE trigger:** `source`, `admission_id`, `referred_from_lead_id`, `account_id`, `contact_id` are immutable. Existing rows (`manual`, `crm`, `fixture` with null admission) are never updated or relabelled; a new `manual` row without an admission is impossible. Open = new, assigned, researching, qualifying, qualified, in_outreach, replied, blocked (same set as `Outreach.Locks.open_leads/0`, pinned by a test). New transition `{:refer, [:in_outreach, :replied], :referred}`: stamps `closed_at`, `status_reason = "referred"`, event `sales.lead.referred` (previous status, successor admission id). `referred` is terminal: no reopen, override or stop. `:reopen` and `:requalify_by_override` take the company key first (section 6) and are refused with a typed field error while another lead at the company is open | `:create`: `forbid_unless AdmissionContext`, then active human admin. `:refer`: `forbid_unless ReferralContext` (new marker set only by the handover), then active human admin. Other policies unchanged | none |
| Sales.Account | Existing (delta) | Company identity for dedupe and the active-target slot | `source` enum adds `:csv, :hubspot, :agent_found, :referral` (kind of the admission that created it). New IMMUTABLE SQL function `sdr_canonical_domain(text)` = `regexp_replace(regexp_replace(lower(btrim(x)), '\.$', ''), '^www\.', '')` (exactly one trailing dot, exactly one leading `www.`), mirrored by `Sales.Domain.canonical/1`; input with consecutive dots, an empty label, more than one trailing dot or fewer than two labels after canonicalization is rejected before normalization (equivalence test, section 9). New unique expression index `(tenant_id, sdr_canonical_domain(domain))` and an Ash calculation `canonical_domain` used for every lookup. `NormalizeDomain` stores the canonical form on new or changed rows; URL, port, path and non-ASCII still refused; subdomains stay distinct | new inverse has_many LeadAdmission (read only); has_many Lead under the account identity above | **No existing row is rewritten:** old rows keep their stored `domain` and record hashes; dedupe finds them through the canonical expression (an old `www.orbit.example.org` row matches new input `orbit.example.org`). The migration builds the expression index; if two existing accounts collide, or an account already has two open leads, it aborts with counts and changes nothing; the owner resolves explicitly. `:create`, `:seed` and `:update` take the domain key first (section 6). Locked `FOR SHARE` by admission (blocks archive) | `:create` policy unchanged (ADM); admission calls it inside its transaction | none |
| Sales.Contact | Existing (delta) | Person identity for dedupe | — (email already ci-unique per tenant) | new inverse has_many LeadAdmission (read only); account immutable after create (unchanged, relied on); new unique `(id, tenant_id)` and `(id, account_id, tenant_id)` as composite FK targets | `:create`, `:seed` and `:change_email` take the email key of the new value first (section 6). Admission normalizes the email (trim, lowercase) and never overwrites an existing contact's fields (D-008; C8 owns CRM updates). Locked `FOR SHARE` by admission (blocks archive and `:change_email`) | unchanged (ADM) | none |
| Outreach.Suppression | Existing (lock-order and match delta) | Do-not-contact facts admission must honor | — | — | Every create action (`:manual`, `:seed`, `:from_webhook`, `:from_classification`) first acquires the identity key of its value (`email:<value>` or `domain:<value>`) through `IdentityKeys`, before `ApplySuppression` locks its targets; an embedding transaction (webhooks) must already hold it from its single key pass. Domain-scope matching is **strengthened**: contacts whose email domain equals the value (unchanged) **or** whose account's canonical domain equals it. Append-only, monotonic, never lifted (unchanged) | unchanged | none (strengthening only; flagged in risks) |
| Outreach.Webhooks (action contract) | Existing (lock-order delta) | Webhook paths that create suppressions | — | — | After locking its own WebhookEvent row (outside the identity lock domain), each path takes one key pass before any shared row lock: reply = `{reply-message, matched recipient email}` (the match is read unlocked first; the existing string key moves into the namespace); unsubscribe, bounce, complaint = `{email}` | unchanged | none |
| Research.Qualification | Existing (lock-order delta) | Human override that can reopen a lead | — | — | `:override` first acquires the company key of its lead (lead → account read unlocked), then proceeds; after `RecordOutcome` locks the lead, the account's canonical domain is re-checked and a change returns `:conflict`. `:record` (agent) is unchanged: it never opens a closed lead | unchanged | none |
| Sales.CampaignEnrollment | Existing (delta, C3-03) | Stop the original lead's sequence on referral | `stop_reason` adds `:referred` | unchanged | `:stop` from active/paused with `:referred` only inside the handover | `:stop` adds `authorize_if ReferralContext` | none |
| Outreach.Approval | Existing (delta, C3-03) | Invalidate granted approvals of the original's open drafts | `invalidated_reason` adds `:lead_referred` (enum and DB check) | unchanged | `granted → invalidated` via existing `:invalidate` (InternalWrite) | unchanged; called from the Outreach-owned closer | none |
| Outreach.Draft / DeliveryOperation | Existing (behaviour delta, C3-03) | Cancel the original's open work | no schema change; `status_reason "referred"`, delivery `last_error %{"reason" => "lead_referred"}` | unchanged | Same selection and effects as `ApplySuppression` for one lead, run by a new Outreach-owned `SdrAgent.Outreach.Referral.close_open_work/3` that sets `InternalWrite`; a claimed delivery is left to its outcome (capture only) | unchanged | none |
| Agents.AgentDefinition | Existing | Definition used by the reused assign path | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found (registration is a named bootstrap prerequisite outside admission; admission only reads the committed definition, section 6) | — | none |
| Agents.AgentRun | Existing | Queued research run; agent_found provenance | — | new unique `(id, tenant_id)` as composite FK target | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found (origins `:assignment` and `:referral` exist, D-104) | — | none |
| Research.EvidenceClaim, Sales.Campaign, Accounts.User, Audit.Tenant, Actor | Existing | Qualification evidence, program, requester, tenant | — | campaigns and users gain unique `(id, tenant_id)` as composite FK targets | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found (no new role or system actor) | — | none |

Configured reviewer: Codex via ai-pair (`ai_pair=true`, `codex_review=true`).
Verdict: **PASS** at 1737063 (round 4, after rounds 1-3 NEEDS-REVIEW; section 13).

## 4. Action contracts

Both actions live in SDR (as `assign_lead/2`), run inside `Audit.Guard.run`
and one `Audit.transaction`, and return closed reasons, never Ash error
structs (which can carry changeset values).

### 4.1 `SdrAgent.SDR.admit_lead(input, actor:)` (C3-02)

Input: `source_kind` (manual, csv, hubspot, agent_found), `source_ref`,
`campaign_id`, `company` (`domain` required; `name` required when new;
optional `website_url`, `industry`, `employee_count`, `geography`),
`person` (`email` required; `first_name`, `last_name` required when new;
optional `title`, `timezone`), `agent_run_id` (agent_found only), `readmit`
(boolean; accepted only with `manual` here, refused `{:invalid, [:readmit]}`
for `csv`, `hubspot`, `agent_found`; the handover accepts it for
`referral`, section 4.3). Missing email is refused; B2/B5 turn it into a confirmation
task, never a placeholder address.

| Step | Check | Result | Writes |
|---|---|---|---|
| 1 | actor struct not an admin of the tenant | `:forbidden` | Guard denial audit |
| 2 | `source_kind = referral` | `:use_referral_handover` | nothing |
| 3 | input invalid, grammar, embedded ids mismatch; normalize (5.2) | `{:invalid, [field]}` | nothing |
| 4 | live real-data guard on domain and email (C5) | `:real_data_disabled` | nothing |
| 5 | key pass (section 6); requester re-read `FOR SHARE`: active admin | `:forbidden` | Guard denial audit |
| 6 | same ref exists: same hash → stored result; different → refuse | replay / `:source_ref_conflict` | nothing |
| 7 | campaign missing or not `active` | `:campaign_not_active` | nothing |
| 8 | agent run missing, other tenant, or origin not `:discovery`; committed `SDRAgent` definition for the tenant missing (read only, never registered here) | `{:invalid, [:agent_run_id]}` / `:agent_definition_unavailable` | nothing |
| 9 | locks (section 6), then live real-data guard again on resolved values | `:real_data_disabled` | nothing |
| 10 | suppression on email, email domain or company domain | `suppressed` | admission row |
| 11 | email belongs to a contact at another account | `contact_at_other_account` | admission row |
| 12 | contact archived / account archived | `contact_archived` / `account_archived` | admission row |
| 13 | contact has an open lead | `duplicate_open_lead` | admission row |
| 14 | company has an open lead for another person | `active_target_exists` | admission row |
| 14a | kind is `csv`, `hubspot` or `agent_found`, and the company's most recently closed lead ended `converted` or `nurture` (rule 4.4) | `company_in_relationship` | admission row |
| 15 | contact has only closed leads and the readmit rule (4.3) does not allow it | `previously_worked` | admission row |
| 16 | otherwise | `admitted` | account and contact if new, admission row, lead `new`, assign → `assigned`, queued run (`usage_origin :assignment`) |

Replay (step 6) is refused only by steps 1-5. A replay returns the stored
admission and the lead's current status; it writes nothing even if the
campaign was paused, the lead moved on or a suppression appeared since
(the suppression has already acted on the lead through `ApplySuppression`).
Returns `{:ok, %{admission, outcome, lead, run, replayed?}}` or
`{:error, reason}`. Readmit never overrides steps 10-14a.

### 4.2 `SdrAgent.SDR.hand_off_referral(input, actor:)` (C3-03)

Input: `original_lead_id`, `source_ref` (`referral:<original>:<event>`),
`campaign_id`, `person` (as above), optional `readmit` (rule 4.3). Company is always the
original lead's account (same-company only, D-095); no company input exists.

Steps 1, 3, 4 as above (step 3 also requires the original id in
`source_ref` to equal `original_lead_id`, else `{:invalid,
[:source_ref]}`). Keys come from the original's account (read unlocked
before the pass, re-checked after locks; a change returns `:conflict`) plus
the referred email. Then step 5, then replay (step 6), **then** the mutable
preconditions for a new request: original in the tenant and `in_outreach` or
`replied` (`:original_not_referable`), no queued or running run on it
(`:original_run_active`), not the same contact or email
(`:self_referral`), campaign active, committed definition present
(`:agent_definition_unavailable`). These refusals write nothing. Then
steps 9-16, except that at step 14 the open lead is the original, so the
handover proceeds, and step 14a does not apply (rule 4.4).

If the outcome is not `admitted`, only the admission row is written (kind
`referral`, `referral_from_lead_id` = original); the original is untouched
and the owner decides. On `admitted`, in this order, all locks already held:
contact (if new) → admission row → original `:refer` (event links the
admission) → enrollments stopped `:referred` →
`Outreach.Referral.close_open_work/3` → lead (`source :referral`,
`referred_from_lead_id` = original; the original is closed, so the account
index accepts it) → assign with `usage_origin :referral`. The referrer for
drafting is read through `referred_from_lead_id`; no name is copied.

### 4.3 Readmit rule (one rule for both actions)

The owner chose this rule on 2026-10-14 (OQ-1, section 12):

- `readmit` is a boolean, default `false`, accepted only for `manual`
  (`admit_lead`) and `referral` (`hand_off_referral`). Any other kind with
  `readmit` present is refused `{:invalid, [:readmit]}`, nothing written.
- At step 15 a contact whose leads are all closed is admitted only when
  `readmit = true` and the kind is `manual` or `referral`; otherwise the
  outcome is `previously_worked` (for a referral: admission row only,
  original untouched).
- `readmit` never overrides steps 10-14a (suppression, other account,
  archived identities, open leads, company in relationship) or research and
  qualification.
- The DB check on `lead_admissions` matches: `readmit` only for `manual` and
  `referral`.

OQ-1's alternatives (every source may re-admit; nobody is re-admitted) were
not chosen and are not modeled.

### 4.4 Company-in-relationship rule (step 14a)

The owner chose OQ-2's proposal on 2026-10-14 (section 12). Added after the
round-4 PASS; it is the subject of Codex's narrow re-review.

- Applies only to `csv`, `hubspot` and `agent_found`. `manual` skips step
  14a: the owner adding a person by hand is the way to work such a company
  again. `referral` skips it too: its company has the original open lead
  (step 14).
- Reached only when the account already exists and has no open lead (steps
  13-14). A new company has no leads and passes.
- Under the company key held since step 9, read the account's most recently
  closed lead: `ORDER BY closed_at DESC NULLS LAST, id DESC LIMIT 1` over that
  account's leads in the tenant (a legacy closed row without `closed_at`
  sorts after every stamped one). If its status is `converted` or
  `nurture`, the outcome is `company_in_relationship`: admission row only,
  `account_id` = the existing account, no contact created, no lead. Any other
  last status (`disqualified`, `stopped`, `referred`) does not apply step
  14a; step 15 still applies to the person.
- The answer is stable while the key is held: no lead at the account is open
  (step 14), so none can close concurrently; a new lead there needs the
  company key (admission, handover); and `:reopen` and
  `:requalify_by_override` take the company key first (section 6).
- One bounded indexed read: C3-02 adds an index on
  `leads (tenant_id, account_id, closed_at DESC NULLS LAST, id DESC)`. No
  lead row is locked for it, and no lead content is loaded.
- `readmit` cannot override it (it is refused for these kinds), and nothing
  else changes: suppression (step 10) and the identity checks (11-13) still
  come first.

## 5. Identity, input hash and agreement

### 5.1 Dedupe identities

| Identity | Normalization | Enforced by | Notes |
|---|---|---|---|
| Company | `Sales.Domain.canonical/1` = SQL `sdr_canonical_domain`: trim, lowercase, strip one trailing `.`, strip one leading `www.`; host of ≥ 2 ASCII labels, no scheme, port or path | expression unique index `(tenant_id, sdr_canonical_domain(domain))` (new) plus existing `(tenant_id, domain)` | old rows found by the expression, never rewritten; subdomains distinct; name never a key |
| Person | trim, lowercase whole address | `contacts (tenant_id, email)` unique, ci (existing) | no provider folding; email domain need not equal the company |
| Source observation | exact `source_ref` | `lead_admissions (tenant_id, source_kind, source_ref)` (new) | idempotency, not identity |
| Active target | — | `leads (tenant_id, account_id)` partial unique over open statuses (new) | C3-R5 |
| CRM ids | — | existing `accounts.crm_external_id` identity | C3 writes none; C8 owns |

Per source, same rules: manual repeat → `duplicate_open_lead`; CSV second
row or second import → `duplicate_open_lead` (same import row resubmitted →
replay); HubSpot object already admitted → `duplicate_open_lead` (C8 links the
CRM id under its own delta); agent-found person at a targeted company →
`active_target_exists` (B2-04); referred person open elsewhere →
`contact_at_other_account` or `duplicate_open_lead`, original unchanged.

### 5.2 Input hash, version 1

`input_sha256 = lowercase hex sha256(SdrAgent.Audit.Canonical.encode(doc))`
(`sdr-canonical-json/1`). `doc` always has every key below; absent values
are `null`.

| Key | Type after normalization |
|---|---|
| `v` | string `"c3-admission-input/1"` |
| `tenant_id`, `campaign_id` | lowercase hyphenated uuid string |
| `source_kind` | string |
| `source_ref` | string, exactly as stored |
| `readmit` | boolean, default `false` |
| `agent_run_id`, `original_lead_id` | uuid string or null |
| `company` | object: `domain` (canonical; `null` for referral, where the company is derived), `name`, `website_url`, `industry`, `employee_count` (integer ≥ 0 or null), `geography` |
| `person` | object: `email` (normalized), `first_name`, `last_name`, `title`, `timezone` |

Normalization order: (1) reject non-UTF-8; (2) Unicode NFC; (3) trim; (4)
collapse internal whitespace runs to one space in `name`, `first_name`,
`last_name`, `title`, `industry`, `geography`; (5) empty string → null; (6)
domain canonical, email trimmed and lowercased; `website_url` trimmed only;
`timezone` as given (validated IANA name); (7) uuids lowercased.

Excluded: requester, outcome, resolved account/contact/lead ids, timestamps,
trace ids. The requester is stored on the row; a replay by another admin
writes nothing. The hash depends only on submitted values, so it is the same
before and after surrounding rows change. A new version string is required
to change any rule; stored hashes are never recomputed.

### 5.3 Agreement between stored relationships and the input

Checked by the database (composite FKs, checks and triggers, section 3):
tenant of requester, campaign, account, contact, matched lead (with
`account_id` required whenever `matched_lead_id` is set), agent run and
original;
contact at the stored account; matched lead at the stored company; lead bound
to an `admitted` admission of the same tenant, company, person, kind and
referrer; successor at the original's company.

Checked in the action under lock before the admission insert (tests for each):
stored `campaign_id`, `agent_run_id`, `referral_from_lead_id` equal the
hashed values; a stored account's canonical domain equals the hashed
`company.domain` (or, for referral, is the original's account); a stored
contact's email equals the hashed email; the agent run is `:discovery`; the
outcome matches the decision table for the locked facts.

## 6. Identity keys, lock order and concurrency

The shared key contract is the ADR-0009 C3 amendment (in this PR, accepted
by the owner on 2026-10-14) so no implementer invents a second namespace or
order. Summary:

- **Keys.** `SdrAgent.Audit.IdentityKeys`. Kinds: `email`, `domain`,
  `admission-ref`, `reply-message`. Lock id = first 8 bytes of
  `sha256("sdr-identity-key/1\0" <> kind <> "\0" <> tenant_id <> "\0" <>
  normalized value)` as a signed 64-bit integer, computed in Elixir and sent
  as an integer parameter (`SELECT pg_advisory_xact_lock($1::bigint)`), so no
  email or domain is ever a query parameter.
- **One pass.** A transaction acquires all its keys once: deduplicated by
  lock id, ascending signed order, before any row lock in the identity lock
  domain (users, campaigns, agent_runs, accounts, contacts, leads,
  qualifications of those leads, enrollments, drafts, deliveries, approvals,
  agent definitions, the chain head). A later call must ask only for keys
  already held; asking for a new key raises `IdentityKeys.LateAcquisition`
  (held keys read from `pg_locks` for the backend). Rows outside the domain
  (the transaction's own WebhookEvent) may be locked before the pass.
- **Collisions** only serialize unrelated work; never correctness.
- **Writers that take keys:** admission and referral (ref, company domain,
  email, email domain); Suppression creates (value); webhook paths (one pass,
  section 3); Account `:create`/`:seed`/`:update` (new canonical domain);
  Contact `:create`/`:seed`/`:change_email` (new email); Lead `:reopen` and
  Qualification `:override` (company domain of the lead). Inside admission
  these nested actions find their keys already held.

Admission order (both actions):

Prerequisite, not part of either action: the tenant's `SDRAgent`
definition is registered by a named bootstrap step,
`SdrAgent.SDR.bootstrap_definitions/1`, run at application start under the
existing kernel authority (`SDRAgent.register/1`, idempotent, its own
transaction and audit event). Admission never registers: inside its
transaction it reads the committed definition (no lock) and, if it is
missing, refuses `:agent_definition_unavailable` before any write. The
reused assign body takes the definition as an argument instead of calling
`register/1`, so no request writes a definition or its event, and no
admission waits on the definition's unique index after the head. Standalone
`SDR.assign_lead/2` keeps its current behaviour.

1. No locks: actor shape, input validation and normalization, preflight
   real-data guard; unlocked reads to derive keys (referral: original →
   account).
2. Key pass.
3. Requester `FOR SHARE` (authorization re-read). Replay lookup (no lock;
   serialized by the ref key).
4. Campaign `FOR SHARE`; agent run `FOR KEY SHARE` (agent_found).
5. Account by canonical domain `FOR SHARE`; contact by email `FOR SHARE`.
6. Open leads of the account `FOR SHARE` (`FOR UPDATE` for the handover).
   At most one row by the account index, so this is bounded by construction;
   closed history is read without locks, because the only way back to open
   (`:reopen`, Qualification `:override`) needs the same company key.
7. Handover only: `Outreach.Locks.targets(tenant, %{lead_ids: [original],
   contact_ids: []})` — enrollments, open drafts, unclaimed deliveries,
   granted approvals, each `FOR UPDATE` by id (existing Outreach order).
8. Live real-data guard on the resolved domain and email; suppression read
   (append-only; any concurrent suppression of these values is serialized
   by the keys).
9. Chain head `FOR UPDATE` at the first append; then the writes.

Implicit foreign-key key-share checks during the writes (contact 3,
admission up to 8, lead 6, assign path about 5) each target a row created by
this transaction or already held in an equal or stronger mode, except the
tenant row, which no writer locks. **Unique-index waits after the head**
are excluded per index: account domain (both indexes) and contact email:
every writer holds the key; admission ref: key; leads per account and per
contact: every writer that can make a lead open holds the company key;
agent definition: read, never inserted, by admission; Operation idempotency key and
signal id: fresh per assignment. Tests prove this on independent
connections (section 9).

**Suppression and admission, both commit orders** (C3-R7):

- Suppression first: admission waits at its key pass; its step 8 read then
  sees the suppression → `suppressed`, nothing else created.
- Admission first: the suppression waits at its key; after admission
  commits, `ApplySuppression`'s contact lookup (a later statement snapshot)
  sees the new contact, by email, email domain or (strengthened) company
  domain, and in the same transaction stops the new lead and its work.

Cycle check against existing writers:

| Writer | Its order | Why no cycle |
|---|---|---|
| Suppression create (`ApplySuppression`) | key → leads → enrollments → drafts → deliveries → approvals → head | keys first in both; same Outreach suffix |
| `Outreach.Webhooks` | own event row → key pass → Locks superset → head | event row outside the domain and never wanted by a key holder |
| Classification (`AssessmentRules`) | key (in Suppression create) → targets → head | no domain row lock precedes `ensure_suppression` in its transaction (to confirm in RED; the module already requires its locks before the first append) |
| `BindApproval` | enrollment SHARE → draft UPDATE → campaign SHARE → contact SHARE → head | takes no key; our campaign/contact locks are SHARE; we may wait on its enrollment, it never waits on us |
| Account/Contact writes | key → row UPDATE → head | key first |
| Lead `:reopen`, Qualification `:override` | key → lead UPDATE → head | key first; agent transitions take no key and only lock their lead |
| User role/status, campaign transitions | row UPDATE → head (no key) | they block on our SHARE while holding nothing we need |
| `SDR.assign_lead/2`, `retry_run/2` | lead UPDATE → head (no key) | lead-first as step 6; while the handover holds the original `FOR UPDATE`, an assignment of it waits and then fails its state check |

## 7. Real-data guard and privacy

- **Guard.** Checked at step 4 before any read, key or write, and at step 8
  after all locks on the resolved values (an adopted account or contact does
  not run create validations, so the second check is explicit). Both read
  the switch live through C5's API; C3 caches nothing. The step-8 check is
  authoritative and must be synchronized with the switch (obligation O5,
  section 15). Until C5-04 merges,
  the existing reserved-name guard is the policy. With the switch off, C5-04
  also stops processing of persisted real leads; the queued run is refused
  there, never bypassed.
- **Database logging and spans.** Ecto's default `:debug` query log
  includes parameters, so a contact insert logs its email in dev today.
  C3-02 depends on C4's proposed ADR-0005 amendment "metadata-only database
  logging and spans" (branch `c4-01-settings-delta` at 7f6d97d, pending
  owner acceptance), and adds no logger or span handler of its own. Its
  controls: metadata-only Repo logging in every environment (one
  allowlisted sanitizer; no parameters, SQL text, exception message,
  `DETAIL`/`HINT` or connection data); app `RepoSpans` with an allowlisted
  error status (`error_module`, `pg_code`, `constraint` only) and no
  `db.url` or `db.statement`; a primary `:logger` filter that rewrites
  Postgrex, DBConnection and Ash error structs in crash reports and
  framework logs; Oban workers sanitize database errors at their boundary,
  so `oban_jobs.errors` holds no message; dev
  `show_sensitive_data_on_connection_error: false`. C3's typed errors map
  database errors by constraint name or SQLSTATE, as the amendment requires.
  Separately, the owner-owned PostgreSQL server-log decision (or an explicit
  owner retention exception) is a prerequisite before private inputs or the
  real-data switch. C3-02's privacy canaries need the amendment accepted and
  merged; otherwise C3-02 waits (an architecture and acceptance gate, not
  implied by an entity PASS). Advisory keys use integer ids (section 6),
  never strings.
- **Errors and spans.** Closed reasons and field names only; no value, no Ash
  error struct, no changeset in any returned error, log line or span
  attribute. Span attributes are ids, kind and outcome.
- **Executable proof** (section 9): canary tests at Logger `:debug` with the
  amendment's `QueryLog`, `RepoSpans` and `:logger` filter attached and
  `otel_capture_content: true`, capturing log output, exported spans
  (attributes, events, status) and `oban_jobs.errors`, on valid, invalid,
  conflicting, suppressed and replayed input, for both actions.
- **Local storage.** Contact rows and their audit after-images hold personal
  data locally only (amendment 2's accepted limitation). Provenance holds ids
  and a hash. Every C3 fixture, doc and screenshot uses reserved domains.

## 8. Events

| Event | When | Content |
|---|---|---|
| `sales.admission.recorded` (new) | every new admission row | after-image: kind, ref, outcome, ids, hash; no personal fields |
| `sales.account.created`, `sales.contact.created`, `sales.lead.created` (existing) | admitted path | lead after-image now has `source`, `admission_id`, `referred_from_lead_id` |
| `sales.lead.assigned`, `sdr.lead.assigned`, run/Operation events (existing) | admitted path | unchanged; `usage_origin` gives the D-104 bucket |
| `sales.lead.referred` (new) | handover | previous status; successor admission id |
| `sales.enrollment.stopped`, `outreach.draft.cancelled`, `outreach.delivery.cancelled`, `outreach.approval.invalidated` (existing) | handover | reasons `referred` / `lead_referred` |
| `authz.denied` (existing) | refused actor | via Guard |

A replay or a refused request appends nothing (except Guard denials).

## 9. Test plan (RED first, synthetic only)

Race tests use **independent PostgreSQL connections** with committed data on
an isolated test partition (the pattern of
`test/sdr_agent/audit/concurrency_test.exs`), two or three processes and
explicit barriers at test-only hook points (after the key pass, after the
lock phase, before the first append). A monitor connection reads
`pg_stat_activity`/`pg_locks` to prove where a waiter blocks: on an
`advisory` lock, never on a `transactionid` (unique-index or row) wait while
the other side holds the chain head. Each race runs in both commit orders.

C3-02:

- Each of the four kinds admits a new person at a new company: one account,
  contact, admission, lead; lead `assigned` with one queued run; stored rows
  and events asserted.
- Policy: active admin allowed; reviewer, auditor (audited), disabled admin,
  a stale admin struct demoted in the DB, every system actor denied; direct
  `Lead :create` and `LeadAdmission :record` without the marker denied.
- Every decision-table outcome; no account/contact created for suppressed
  (email, email domain, company domain), other-account, archived and
  company-in-relationship outcomes.
- Step 14a (rule 4.4): for each of `csv`, `hubspot`, `agent_found`, a last
  closed lead `converted` and one `nurture` give `company_in_relationship`
  with `account_id` set and no contact or lead; last closed `disqualified`,
  `stopped` and `referred` do not; ordering by `closed_at` then `id`,
  including a legacy null `closed_at`; the same company admits through
  `manual`; a referral is unaffected. Direct-SQL negatives (one violated rule
  each): the outcome with kind `manual` or `referral`, and with null
  `account_id`.
- `admit_lead` with `source_kind :referral` refused, nothing written.
- Replay: identical replay writes nothing after the campaign is paused, the
  lead moved on, or a suppression appeared; replay refused only for a
  non-admin actor, invalid input or a guard refusal; same ref with different
  input refused; hash stable across surrounding-row changes; hash vectors
  for nulls, whitespace, NFC and case.
- Agreement: wrong-tenant campaign, run, account, contact and matched lead;
  a lead pointing at a non-admitted admission, another kind, another company
  or person; a run not `:discovery`; ref/run id mismatch — each refused by the
  action and, where modeled, by the database directly.
- Cutover: inserting a `manual` lead without admission, a `crm` lead, or
  changing `admission_id`/`source` fails at the trigger; a `fixture` seed
  still works in test; legacy rows untouched; migration aborts on synthetic
  colliding domains and on two open leads at one account.
- Canonical domain: an existing `www.orbit.example.org` account (inserted in
  its stored form) dedupes with `orbit.example.org`; `eu.orbit.example.org`
  does not; Elixir and SQL canonical functions agree on a corpus with
  repeated dots, empty labels, one and two trailing dots, Unicode and
  punycode, a leading `www.`, `www.` alone and surrounding whitespace
  (malformed input rejected by both before canonicalization); old row's
  `record_sha256` unchanged.
- Invariant: second open lead at an account fails at the index; `:reopen`
  and override refused with the typed error while another lead is open.
- No skip: an admitted lead cannot qualify, start outreach, enroll or get a
  draft without research and a recorded qualification, per kind.
- `readmit` (rule 4.3): `true`/`false` for manual; `true`/`false` for
  referral through the handover; present on csv, hubspot, agent_found →
  `{:invalid, [:readmit]}`, nothing written (an input-presence rule in the
  action, since the column defaults to `false`); DB check rejects a direct
  row with `readmit = true` on another kind; never overrides suppression, archived
  identities or the open-lead rule; the re-admitted contact gets a new lead,
  old kept.
- Missing definition: with the tenant's `SDRAgent` definition absent, every
  refusal before step 8 (forbidden, referral via `admit_lead`, invalid,
  guard, source-ref conflict, inactive campaign) leaves exact row and event
  counts unchanged and creates no definition row or event; an identical
  replay still returns its stored result with no write; any other new
  request, including one that would record `suppressed` or another outcome,
  returns `:agent_definition_unavailable` with nothing written. Same for the
  handover. The
  contended-registration race runs against `bootstrap_definitions/1` outside
  any admission transaction.
- Deferred trigger: an `admitted` row without a lead fails at commit.
- Matched-lead binding (direct SQL inserts): `duplicate_open_lead` or
  `active_target_exists` with `account_id` null fails the check; a matched
  lead from another tenant, or at another company than `account_id`, fails
  the triple FK; a valid same-tenant, same-company binding inserts.
- Key contract: `LateAcquisition` raised for a new key after a pass,
  including after an empty pass; savepoint rollback cases (O2); lock ids
  sent as integers.
- Races (independent connections, both orders): two admissions at one
  company; admission vs suppression of the email, the email domain and the
  company domain (person absent before; person existing); admission vs direct
  `create_account` and `create_contact`; admission vs `:reopen` and
  Qualification override; admission vs contended agent-definition
  registration; same-ref double submit; each with the waiter shown blocked
  on an advisory lock.
- Privacy canaries: unique synthetic name, email and domain values absent
  from captured logs, spans and returned errors for valid, invalid,
  conflicting, suppressed and replayed input, at debug with the ADR-0005
  C4 amendment's controls attached and content capture on; also absent
  from span status and `oban_jobs.errors` of the queued run.

C3-03:

- Handover from `in_outreach` and `replied`: original `referred`; enrollment
  stopped; drafts, unclaimed deliveries cancelled; approvals invalidated;
  claimed delivery untouched; new lead `assigned` with `usage_origin
  :referral` and `referred_from_lead_id`.
- Refusals with nothing written: original in another state or tenant, active
  run, self-referral, ref naming another original, non-admin.
- Non-admitted referral (suppressed, other company, worked with
  `readmit = false`): admission row only, original unchanged; worked with
  `readmit = true`: handover proceeds.
- Replay after the handover (original now `referred`) returns the stored
  result; a new request on the `referred` original is refused.
- Races (independent connections, both orders): handover vs approval of the
  original's draft, vs suppression of the original's or the referred email,
  vs a concurrent admission at the company.
- Composite FK: a successor at another account rejected by the database.
- Privacy canaries as in C3-02.

Gate: `bin/verify` and `mix credo` on an isolated test partition; never the
owner's demo database; Fake provider only, no model calls.

## 10. Affected modules and proposed slices

No code changes in C3-01. Names are proposals.

**C3-02** (after PASS, ADR amendment acceptance and G5):

- New: `lib/sdr_agent/audit/identity_keys.ex`,
  `lib/sdr_agent/audit/changes/identity_key_lock.ex`,
  `lib/sdr_agent/sales/lead_admission.ex`, `lib/sdr_agent/sales/domain.ex`,
  `lib/sdr_agent/sales/checks/admission_context.ex`,
  `lib/sdr_agent/sdr/admission.ex` (logging and span controls come from the
  ADR-0005 C4 amendment's implementation, not this slice); migration (table, identities, composite FK targets,
  checks, append-only, deferred and lead triggers, canonical function and
  index, pre-checks).
- Changed: `sales/lead.ex`, `sales/account.ex`, `sales/contact.ex`,
  `sales/changes/normalize_domain.ex`, `outreach/suppression.ex`,
  `outreach/locks.ex` (domain match), `outreach/webhooks.ex` (key pass),
  `research/qualification.ex` (override key), `sales.ex`, `sdr.ex`
  (`admit_lead/2`; extract the assign body for reuse),
  `test/support/sales_fixtures.ex`, `lib/sdr_agent/demo/fixtures.ex` if
  a seed shares an account.
- Diagrams: regenerate the Sales domain diagram and the data-flow diagram.

**C3-03** (after C3-02 merges): `lead.ex` (`:referred`, `:refer`,
`referred_from_lead_id`, composite FK), `campaign_enrollment.ex`,
`outreach/approval.ex`, `sdr.ex` (`hand_off_referral/2`); new
`sales/checks/referral_context.ex`, `outreach/referral.ex`.

ADR: the identity-key namespace and order spanning Sales, Research and
Outreach is a cross-cutting contract, proposed as the ADR-0009 "C3
amendment" in this PR (accepted by the owner on 2026-10-14). The rest follows ADR-0009
and ADR-0010.

## 11. Risks

| Risk | Mitigation |
|---|---|
| The key contract touches reviewed Suppression, webhook and override paths | every changed path gets a both-orders race test; Outreach suffix order unchanged; ADR amendment reviewed |
| Strengthened domain suppression stops more leads than today (contacts whose company domain is suppressed but whose email domain differs) | strengthening only; called out for the owner at G5; synthetic tests |
| Existing tests and seeds create two open leads at one account | fixtures admit through the new path; assertions not weakened |
| Migration meets collisions in the owner's dev data | pre-checks abort with counts; nothing merged automatically |
| Metadata-only logging and spans (ADR-0005 C4 amendment) reduce dev debugging detail | table, command, timing, outcome and allowlisted error class stay; reproduce values in a test or `psql` |
| B6 batches take many keys | one sorted pass per transaction; B6 sets batch size under its own review |
| B1 needs a campaign for manual add | admission requires `campaign_id`; B1 chooses the default in its packet |

## 12. Questions for the owner (G5)

Answered 2026-10-14 (America/Denver, about 14:28 MDT) in the private Claude
session chat: the owner replied "accept your recommendations" to the
proposals below. OQ-1 is modeled in section 4.3, OQ-2 in section 4.4; OQ-3
needs no model change (the handover was already same-company only).

- **OQ-1 Re-admitting someone already worked.** A person whose earlier lead
  closed (disqualified, nurture, converted, stopped, referred). Proposal:
  CSV, HubSpot and agent-found never re-target them; they are recorded as
  "previously worked". Manual add and referral may, with an explicit "work
  this person again" confirmation. A suppressed person is never re-admitted
  either way. Alternative: every source may re-admit. **Chosen: the
  proposal** (rule 4.3).
- **OQ-2 Companies already in a relationship.** A company whose last lead
  ended converted or nurture. Proposal: automatic sources skip it ("company
  in relationship", a new outcome), manual add allowed. Alternative: treat it
  like any company with no open lead. **Chosen: the proposal** (step 14a,
  rule 4.4).
- **OQ-3 Referral to another company.** Proposal: not a handover. The
  original stays as it is; you can add the person by hand at the other
  company and note the reply. The handover stays same-company only (D-095).
  Alternative: a cross-company handover that closes the original as
  referred too. **Chosen: the proposal.**

## 13. Gate record (to fill)

- Entity-model reviewer: Codex via ai-pair (capabilities `ai_pair=true`,
  `codex_review=true`).
  - Round 1 at 5987410: **NEEDS-REVIEW** (consultation
    m_1791845331000024185_00d7c797; private report
    `~/.local/state/sdr-agent/handoff-20261008/tmp/codex-c3-01-5987410-entity-review.md`,
    sha256 2c7c5698…). Six items:
    1. close the suppression-vs-admission race with shared serialization;
    2. replay before mutable preconditions (referral, campaign);
    3. one referral entry point;
    4. exact input hash and relationship agreement;
    5. canonical lookup over old rows and the legacy-null cutover;
    6. executable privacy and true-connection race proof.
    Plus: document the shared key order as an ADR-0009 amendment.
  - Revised in this commit: shared identity keys adopted by Suppression,
    webhooks, Account/Contact writers, reopen and override, with both commit
    orders (sections 3, 6) and the proposed ADR-0009 C3 amendment (item 1);
    replay at step 6 before campaign, original, run and suppression checks
    (section 4) (item 2); `admit_lead` refuses `referral`, the handover derives
    the company and checks the ref's original id (item 3); hash v1 table,
    normalization order, exclusions, composite FKs and action checks (section
    5) (item 4); canonical expression index without rewriting rows, insert and
    update triggers for the cutover (section 3) (item 5); integer lock ids,
    parameter-free query logging, live guard recheck, canary tests,
    independent-connection race tests with wait proof, bounded lead locking
    (sections 6, 7, 9) (item 6).
  - Round 2 at 47259b9: **NEEDS-REVIEW, narrow** (consultation
    m_1791848842000018304_5bf5b9ce; private report
    `~/.local/state/sdr-agent/handoff-20261008/tmp/codex-c3-01-47259b9-entity-review.md`,
    sha256 8d88e4cd…). The six round-1 directions are addressed. Two items:
    1. step 0 committed a definition before authorization, breaking
       "refusal writes nothing";
    2. the referral readmit rule was inconsistent across the invariant,
       step 15, the handover and OQ-1.
    Plus qualifications to carry as implementation obligations.
  - Revised in this commit: definition registration is a named bootstrap
    prerequisite; admission only reads it and refuses
    `:agent_definition_unavailable`; missing-definition no-write tests
    (sections 6, 4.1, 9) (item 1). One readmit rule (section 4.3) used by
    the invariant, step 15, the handover, the tests, with what changes for
    each OQ-1 choice (item 2). Qualifications recorded as obligations O1-O8
    (section 15); exact single-dot canonical rule (section 3); logging
    dependency on C4's proposed ADR-0005 amendment (section 7).
  - Round 3 at 0bc3056: **NEEDS-REVIEW, one narrow item** (consultation
    m_1791849604000007566_fbc28e8d; private report
    `~/.local/state/sdr-agent/handoff-20261008/tmp/codex-c3-01-0bc3056-round3-review.md`,
    sha256 cb494725…). Round-2 items resolved. Item: `matched_lead_id`'s
    triple FK is skipped (MATCH SIMPLE) when `account_id` is null, so
    matched-lead tenant/company agreement was not DB-enforced.
    Nonblocking: readmit test precision (DB constrains stored `true`;
    presence refusal is the action's); bootstrap tolerates the
    migration/empty-tenant lifecycle and runs after the tenant exists;
    O1-O8 stay code-review evidence.
  - Revised in this commit: check `matched_lead_id IS NULL OR account_id IS
    NOT NULL` (section 3), section 5.3 wording, direct-DB negative and
    valid-binding tests, readmit test wording (section 9).
  - Round 4 at 1737063: **PASS** (consultation
    m_1791853220000017297_1bb73c77, answer m_1791853352000000000_codexc3r4;
    private report
    `~/.local/state/sdr-agent/handoff-20261008/tmp/codex-c3-01-1737063-round4-pass.md`,
    sha256 acc20dd7…). No must-fix, nothing blocking. Implementation
    obligations from the report, added to O1-O8 (section 15): the
    matched-lead direct-SQL tests exercise both matched outcomes
    (`duplicate_open_lead`, `active_target_exists`) and isolate each negative
    so an unrelated constraint cannot mask the intended check or FK; the
    readmit tests keep the action's input-presence refusal separate from the
    DB restriction on stored `readmit = true`. The section 9 tests are a plan,
    not executed proof; no RED/GREEN verdict is implied. The PASS is not
    implementation, ADR acceptance, G5, real-data or spend authority.
- OQ-2 revision (round 5, after the PASS): outcome
  `company_in_relationship`, step 14a, rule 4.4, the LeadAdmission checks and
  the tests. **PASS by Codex at ef74d2a** (ask
  m_1792010596945028000_a37fb69c, answer
  8b8ec999-7fd9-4b2e-b337-f84f83396ab6, 2026-10-14T20:44:29Z; delta
  131ddc9..ef74d2a, docs only). No must-fix; it also checked that the owner
  records match the decision log. Tests to carry into C3-02 (already in
  section 9): `closed_at` plus id ties and legacy null timestamps; a latest
  other status after an older converted or nurture lead; no contact, run or
  lead writes on the skip; same-key serialization with admission, reopen
  and override. The PASS permits C3-02 RED under the scoped G5, not GREEN,
  merge, private inputs or spend; the server-log prerequisite (O4) stands.
  OQ-1 and OQ-3 needed no model change.
- ADR-0009 C3 amendment: **accepted by the owner on 2026-10-14** (about
  14:28 MDT, "yes" to "Accept the ADR-0009 C3 amendment (shared identity
  keys)?"), on the text Codex passed in round 4.
- ADR-0005 C4 amendment (logging and spans, O4): **accepted by the owner on
  2026-10-14** (recorded in C4, #140). The PostgreSQL server-log decision:
  direction approved 2026-10-14 (option 1); the proposal is pending and
  required before private inputs and the real-data switch.
- Owner G5 (scoped C3), including the stricter company-domain suppression
  (O8): **approved by the owner on 2026-10-14** (about 14:28 MDT,
  "approved"), on this packet as revised for OQ-2, which Codex passed at
  ef74d2a. It authorizes C3-02 then C3-03 under section
  14; it is not merge, real-data or spend approval.
- OQ-1..OQ-3: answered 2026-10-14 (section 12).
- C3-01 verification: docs-only change; no code, migration or test changed.

## 14. Next authorized scope (when PASS, ADR acceptance and G5)

Implement C3-02 then C3-03 as reviewed PRs (Claude authors, Codex reviews,
exact-head CI), adjusted by the owner's answers. No real data until C5-04
merges and the switch is on; no ordinary real model calls until R0's
conditions hold. Nothing else.

## 15. Implementation obligations (Codex round-2 qualifications)

These bind C3-02/C3-03 and their reviews. None is satisfied by this docs
packet or by an entity PASS.

| ID | Obligation | Evidence required |
|---|---|---|
| O1 | The key pass is an outer-transaction contract on every caller, not only a Suppression hook: classification and override flows, whole seed and bootstrap transactions, and B6 batches take their full key set before any shared row lock or append. No key or row lock is held while a model call waits. | full-path tests per caller (not the local `AssessmentRules` check alone), asserting the first shared lock follows the pass; a test that a model-call wait holds no key |
| O2 | Held-key state is transaction- and savepoint-aware. `pg_locks` is the authority for held keys; a transaction-local marker (`set_config('sdr.identity_pass', …, true)`, reverted with its savepoint) records that a pass was made, including an empty pass, so a later new key can never become a silent second pass. The whole sorted set is acquired before shared locks. | rollback-to-savepoint tests (keys and marker both reverted, re-pass allowed only then), empty-pass then new key → `LateAcquisition` |
| O3 | One exact domain rule in SQL and Elixir: exactly one trailing dot and one leading `www.` stripped; malformed hosts rejected before normalization. Old audited rows and their record hashes stay untouched. | equivalence corpus (section 9); hash assertions on existing rows |
| O4 | Logging and spans follow C4's ADR-0005 amendment (metadata-only database logging and spans, `c4-01-settings-delta` at 7f6d97d; accepted by the owner on 2026-10-14): metadata-only Repo logging in all environments; app `RepoSpans` with allowlisted error status and no `db.url` or `db.statement`; the `:logger` exception filter; Oban boundary sanitizing; dev `show_sensitive_data_on_connection_error: false`. The separate owner-owned PostgreSQL server-log decision (or retention exception) precedes private inputs and the real-data switch. C3 adds no logger of its own. | canary tests at debug with content capture on over logs, spans and `oban_jobs.errors`; ADR acceptance and the server-log decision recorded before C3-02 merges |
| O5 | Final real-data permission is authoritative at the first-write boundary, including replay output of persisted real records and adopted (not created) rows. If C5 makes the switch a runtime setting, admission reads it `FOR SHARE` after the key pass and before the head, and C5's toggle takes it `FOR UPDATE`, so a toggle waits for in-flight admissions and later ones see the new value; if C5 makes it boot-time configuration, it cannot change within a transaction. "Read twice" alone is not the proof. | a toggle race test on independent connections, matched to C5-04's chosen mechanism |
| O6 | Atomic cutover: the key namespace, every cooperating writer (admission, Suppression, webhooks, Account, Contact, reopen, override) and the migration ship in one release; no deploy mixes the old webhook key and the new namespace. The owner's instance is single-node and restarts on deploy, so no rolling mix exists. | one PR/release; a test that no `hashtextextended` advisory call remains |
| O7 | Seed boundary: `:seed` stays dev/test-only (`SeedingAllowed`); application writes cannot choose `source: fixture` (`:create` accepts only the admission kinds); the DB trigger's fixture exception is a trusted database-admin boundary only. Deferred lead binding and the account slot get direct DB negatives and transaction-rollback proof. | policy tests in prod config; direct SQL negatives |
| O8 | The strengthened company-domain suppression is an owner-visible behaviour change; it stays in the scoped G5 for the owner to accept. No agent approves it. | G5 record |
| O9 | Round-4 test obligations: matched-lead direct-SQL negatives cover both matched outcomes and isolate each negative (only the intended check or FK can fail); readmit tests separate the action's input-presence refusal from the DB restriction on stored `readmit = true`. | direct SQL tests with one violated rule each; readmit tests per kind |
