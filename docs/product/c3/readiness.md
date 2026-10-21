# C3 readiness packet: lead admission

Status: **entity/action PASS by Codex at 1737063 (round 4); owner gates
answered 2026-10-14; OQ-2 revision PASS by Codex at ef74d2a (round 5).**
C3-01 (#55), Claude author → Codex reviewer; draft PR #141.
Rounds 1-3 were NEEDS-REVIEW (section 13); implementation obligations are in
section 15. On 2026-10-14 the owner accepted the ADR-0009 C3 amendment and
C4's ADR-0005 logging amendment (O4), answered OQ-1..OQ-3 (section 12) and
approved the scoped C3 G5 including the stricter company-domain suppression
(O8), on this packet as revised for OQ-2 (section 4.4), which Codex passed
at ef74d2a. This packet by itself authorizes no code, migration, model call
or real data. Its three preconditions for implementation are met (Codex
entity-model PASS on sections 3-7, the accepted ADR-0009 identity-key
amendment and the scoped C3 G5; section 13), so the owner's G5 authorizes,
as distinct steps:

1. C3-02 (#56) RED;
2. C3-02 GREEN under its own reviewed plan;
3. a merge per D-157, only after O4's PostgreSQL server-log decision is
   recorded;
4. then C3-03 (#57), the same way (section 14).

It is not authority for private inputs, real data (C5-04 and the switch),
real model calls or spend. The R0 G5 does not cover C3.

**C3-02 D0 (docs, before RED), 2026-10-19.** This packet now records the
docs slice D0 of the C3-02 module plan (`claude-c302-plan-r8.md`, sha256
94fe05cb…, §10.2) and the owner's decisions **D-174** (Q-O1..Q-O6,
2026-10-19): the C3-02 entity/action delta (section 3.1), the domain and
email representations (section 5.4), the key sets, lock orders, per-index
list, definition lookup, reply hand-off and suppression boundary (section
6), the C5-04 prerequisite (section 7), the marker name (sections 3 and 10)
and the gate record (section 13). The ADR-0009 C3-02 amendment was accepted
by the owner on 2026-10-19 (D-176). C3-02 RED still needs Codex's final
correlated entity and module review of these exact D0 artifacts (section
13).

Sources: build plan v3 (D-097) §3 contract C3, §9, §9a
([`owner-decisions`](https://github.com/chops/sdr_agent/blob/owner-decisions/docs/product/build-plan.md));
backlog draft C3-01..03, B1-03, B2-04, B5-04, B6-01..03, C8-02;
decisions D-048, D-049, D-052, D-056, D-059, D-060, D-066, D-084, D-095,
D-101, D-104; ADR-0014 amendment 2 (constraint 7, accepted 2026-10-12);
ADR-0009 (persistence and audit conventions, plus the proposed identity-key
amendment in this PR, and its C3-02 amendment, accepted 2026-10-19, D-176),
ADR-0010 (lifecycles). Code facts are from `main` at
182bde6 unless marked otherwise. The run-settings contract (section 4.5) and
the privacy baseline (section 7) were refreshed against `main` at fb54000
(2026-10-19, rebase review). C3-02's plan re-inventories callers on current
main (O11) rather than relying on the historical tables.

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
  from C4's ADR-0005 amendment (O4; accepted 2026-10-14, merged in C4-01a),
  not from C3. Run settings come from C4's existing assignment contract
  (section 4.5), not from C3.
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
| Sales.LeadAdmission | New | One immutable record per new admission request and its outcome: provenance and dedupe history | `id : uuid_v7`; `tenant_id : uuid, required`; `source_kind : atom, required, one_of [:manual, :csv, :hubspot, :agent_found, :referral]`; `source_ref : string, required, ≤ 120`, per-kind grammar of ids only, DB-checked by regex: `manual:<uuid>`, `csv:<uuid>:<row ≥ 1>`, `hubspot:<digits>:<digits>`, `agent_found:<run uuid>:<candidate uuid>`, `referral:<original lead uuid>:<reply or outcome uuid>` (lowercase hex uuids); `input_version : int, required, = 1`; `input_sha256 : string, required, 64 lowercase hex` (section 5.2); `outcome : atom, required, one_of [:admitted, :duplicate_open_lead, :active_target_exists, :previously_worked, :contact_at_other_account, :contact_archived, :account_archived, :company_in_relationship, :suppressed]`; `suppression_scope : atom, nullable, one_of [:email, :domain]`; `readmit : boolean, required, default false`; `account_created`, `contact_created : boolean, required, default false`; `inserted_at`; `trace_id`, `span_id` | Composite FKs (all restrict; target unique indexes added where absent): `(requested_by_user_id, tenant_id)` → users `(id, tenant_id)`, required; `(campaign_id, tenant_id)` → campaigns `(id, tenant_id)`, required; `(account_id, tenant_id)` → accounts `(id, tenant_id)`; `(contact_id, tenant_id)` → contacts `(id, tenant_id)` and `(contact_id, account_id, tenant_id)` → contacts `(id, account_id, tenant_id)` (checked when both set, MATCH SIMPLE); `(matched_lead_id, tenant_id, account_id)` → leads `(id, tenant_id, account_id)`; `(agent_run_id, tenant_id)` → agent_runs `(id, tenant_id)`; `(referral_from_lead_id, tenant_id)` → leads `(id, tenant_id)`. Unique `(id, tenant_id, account_id, contact_id)` as target of the Lead binding FK. has_one Lead (via `Lead.admission_id`, unique). Identity unique `(tenant_id, source_kind, source_ref)`. No FK to Outreach (ADR-0009 layering); a suppressed outcome records the scope only | Append-only (`Audit.SQL.append_only`). DB checks: `matched_lead_id` not null iff outcome in (`duplicate_open_lead`, `active_target_exists`); `matched_lead_id IS NULL OR account_id IS NOT NULL` (both matched outcomes have a known company, so the MATCH SIMPLE triple FK on the matched lead is never skipped); `suppression_scope` not null iff outcome = `suppressed`; `agent_run_id` not null iff kind = `agent_found`; `referral_from_lead_id` not null iff kind = `referral`; `readmit` only for `manual` and `referral`; outcome `company_in_relationship` only for `csv`, `hubspot` and `agent_found`, and then `account_id` not null; `account_created`/`contact_created` only when outcome = `admitted`; `account_id` and `contact_id` not null when admitted; `account_id` null when outcome = `contact_at_other_account` (the contact's own account is not this company); source_ref's embedded run or original id equals `agent_run_id` / `referral_from_lead_id` (SQL `split_part`). Deferred constraint trigger (`DEFERRABLE INITIALLY DEFERRED`): an `admitted` row is referenced by exactly one lead at commit. Values the DB cannot check are validated in the action under lock before insert (section 5.3) | `:record` (create): active human admin, only inside the admission orchestrator (`Sales.Checks.LeadAdmissionContext` marker, like `QualificationContext`; named so by C3-02 D6); everything else forbidden, auditor refusal audited by Guard. Reads: ADM, REV, AUD roles; `agent_runtime` (referrer lookup for drafting); `auditor_cli`; kernel. Audited `sales.admission.recorded` | none (OQ-1 and OQ-2 answered 2026-10-14, sections 4.3 and 4.4) |
| Sales.Lead | Existing (delta) | The person being worked; now always admitted | `source` enum becomes `[:manual, :csv, :hubspot, :agent_found, :referral, :fixture, :crm]`. Add `admission_id : uuid, nullable, unique where not null`; `referred_from_lead_id : uuid, nullable, unique where not null`. Status adds `:referred` (terminal) | Composite FK `(admission_id, tenant_id, account_id, contact_id)` → lead_admissions `(id, tenant_id, account_id, contact_id)` (restrict); composite FK `(referred_from_lead_id, tenant_id, account_id)` → leads `(id, tenant_id, account_id)` (restrict; new unique index on that triple), so the successor is at the same company; composite FK `(contact_id, account_id, tenant_id)` → contacts `(id, account_id, tenant_id)`. New identity `one_open_per_account [:tenant_id, :account_id] where status not in (disqualified, converted, nurture, stopped, referred)`, partial unique index; existing `unique_open_lead` (per contact) kept, its `where` gains `referred` | **Cutover (BEFORE INSERT trigger `leads_admission_binding`):** a new row needs `admission_id`, except `source = 'fixture'` (seed; the action is dev/test-gated); `source = 'crm'` can no longer be inserted; with `admission_id`, the referenced admission must have outcome `admitted`, `source_kind = NEW.source` and `referral_from_lead_id IS NOT DISTINCT FROM NEW.referred_from_lead_id`. **BEFORE UPDATE trigger:** `source`, `admission_id`, `referred_from_lead_id`, `account_id`, `contact_id` are immutable. Existing rows (`manual`, `crm`, `fixture` with null admission) are never updated or relabelled; a new `manual` row without an admission is impossible. Open = new, assigned, researching, qualifying, qualified, in_outreach, replied, blocked (same set as `Outreach.Locks.open_leads/0`, pinned by a test). New transition `{:refer, [:in_outreach, :replied], :referred}`: stamps `closed_at`, `status_reason = "referred"`, event `sales.lead.referred` (previous status, successor admission id). `referred` is terminal: no reopen, override or stop. `:reopen` and `:requalify_by_override` take the company key first (section 6) and are refused with a typed field error while another lead at the company is open. `:seed` (dev/test) also takes its account's company key before its account `FOR SHARE` and re-checks it (C3-02, section 3.1) | `:create`: `forbid_unless LeadAdmissionContext`, then active human admin. `:refer`: `forbid_unless ReferralContext` (new marker set only by the handover), then active human admin. Other policies unchanged | none |
| Sales.Account | Existing (delta) | Company identity for dedupe and the active-target slot | `source` enum adds `:csv, :hubspot, :agent_found, :referral` (kind of the admission that created it). New IMMUTABLE SQL function `sdr_canonical_domain(text)` = `regexp_replace(regexp_replace(lower(btrim(x)), '\.$', ''), '^www\.', '')` (exactly one trailing dot, exactly one leading `www.`), the key and index form (`strip`, section 5.4); `Sales.Domain.canonical/1` is the company-identity form `company/1`, whose result is a fixed point of that function (section 5.4); input with consecutive dots, an empty label, more than one trailing dot, fewer than two labels after canonicalization or (C3-02, D-174 Q-O6) a repeated leading `www.` is rejected before normalization (equivalence test, section 9). New unique expression index `(tenant_id, sdr_canonical_domain(domain))` and an Ash calculation `canonical_domain` used for every lookup. `NormalizeDomain` stores the canonical form on new or changed rows; URL, port, path and non-ASCII still refused; subdomains stay distinct | new inverse has_many LeadAdmission (read only); has_many Lead under the account identity above | **No existing row is rewritten:** old rows keep their stored `domain` and record hashes; dedupe finds them through the canonical expression (an old `www.orbit.example.org` row matches new input `orbit.example.org`). The migration builds the expression index; if two existing accounts collide, an account already has two open leads, or (C3-02, D-174 Q-O6) an existing account's indexed value is not a valid company fixed point (legacy-identity pre-check, section 5.4), it aborts with counts and changes nothing; the owner resolves explicitly. `:create` and `:seed` take the new domain's key first; `:update` takes the old and the new domain's keys first and re-checks the old value on the locked row (section 6). Locked `FOR SHARE` by admission (blocks archive) | `:create` policy unchanged (ADM); admission calls it inside its transaction | none |
| Sales.Contact | Existing (delta) | Person identity for dedupe | — (email already ci-unique per tenant) | new inverse has_many LeadAdmission (read only); account immutable after create (unchanged, relied on); new unique `(id, tenant_id)` and `(id, account_id, tenant_id)` as composite FK targets | `:create` and `:seed` take the email key of the new value first; `:change_email` takes the keys of the old email, the new email and the new email's domain first, re-checks the old value on the locked row, and (D-174 Q-O2) is refused when the new address or its domain is suppressed (section 6). Admission normalizes the email (trim, lowercase) and never overwrites an existing contact's fields (D-008; C8 owns CRM updates). Locked `FOR SHARE` by admission (blocks archive and `:change_email`) | unchanged (ADM) | none |
| Outreach.Suppression | Existing (lock-order and match delta) | Do-not-contact facts admission must honor | — | — | Every create action (`:manual`, `:seed`, `:from_webhook`, `:from_classification`) first acquires the identity key of its value (`email:<value>` or `domain:<value>`) through `IdentityKeys`, before `ApplySuppression` locks its targets; an embedding transaction (webhooks) must already hold it from its single key pass. Domain-scope matching is **strengthened**: contacts whose email domain equals the value (unchanged) **or** whose account's canonical domain equals it. Append-only, monotonic, never lifted (unchanged) | unchanged | none (strengthening only; flagged in risks) |
| Outreach.Webhooks (action contract) | Existing (lock-order delta) | Webhook paths that create suppressions | — | — | After locking its own WebhookEvent row (outside the identity lock domain), each path takes one key pass before any shared row lock: reply = `{reply-message, matched recipient email}` (the existing string key moves into the namespace; C3-02 takes the keys from the payload, `{reply-message: Message-ID, email: from}`, since every match must equal the validated `from`, then reads the match unlocked and revalidates it under the locks, section 3.1); unsubscribe, bounce, complaint = `{email}` | unchanged | none |
| Research.Qualification | Existing (lock-order delta) | Human override that can reopen a lead | — | — | `:override` first acquires the company key of its lead (lead → account read unlocked), then locks the account `FOR SHARE` and the lead `FOR UPDATE`, and re-checks on the locked rows that the lead's account is unchanged and the account's canonical domain equals the keyed value (a mismatch is a typed conflict), all before its INSERT (D3 order, section 6). `:record` (agent) never opens a closed lead; C3-02 makes it lock its lead `FOR UPDATE` before its reads and INSERT (section 3.1) | unchanged | none |
| Sales.CampaignEnrollment | Existing (delta, C3-03) | Stop the original lead's sequence on referral | `stop_reason` adds `:referred` | unchanged | `:stop` from active/paused with `:referred` only inside the handover | `:stop` adds `authorize_if ReferralContext` | none |
| Outreach.Approval | Existing (delta, C3-03) | Invalidate granted approvals of the original's open drafts | `invalidated_reason` adds `:lead_referred` (enum and DB check) | unchanged | `granted → invalidated` via existing `:invalidate` (InternalWrite) | unchanged; called from the Outreach-owned closer | none |
| Outreach.Draft / DeliveryOperation | Existing (behaviour delta, C3-03) | Cancel the original's open work | no schema change; `status_reason "referred"`, delivery `last_error %{"reason" => "lead_referred"}` | unchanged | Same selection and effects as `ApplySuppression` for one lead, run by a new Outreach-owned `SdrAgent.Outreach.Referral.close_open_work/3` that sets `InternalWrite`; a claimed delivery is left to its outcome (capture only) | unchanged | none |
| Agents.AgentDefinition | Existing (lifecycle delta, C3-02; section 3.1) | Definition used by the reused assign path | — | — | registration is a named bootstrap prerequisite outside admission; admission, standalone assignment and the reply hand-off only read the committed definition (section 6) | — | none |
| Agents.AgentRun | Existing | Queued research run; agent_found provenance | — | new unique `(id, tenant_id)` as composite FK target | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found (origins `:assignment` and `:referral` exist, D-104) | — | none |
| Agents.SettingsRevision, Agents.RunSettingsSnapshot (C4) | Existing | Business settings a run needs; the run's frozen settings and budget | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found (admission reaches them only through the reused assign path's `AgentRun :create`, section 4.5; it reads revisions, never writes one, and the snapshot is created by `BuildSettingsSnapshot` exactly as for a standalone assignment) | — | none |
| Research.EvidenceClaim, Sales.Campaign, Accounts.User, Audit.Tenant, Actor | Existing | Qualification evidence, program, requester, tenant | — | campaigns and users gain unique `(id, tenant_id)` as composite FK targets | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found (no new role or system actor) | — | none |

Configured reviewer: Codex via ai-pair (`ai_pair=true`, `codex_review=true`).
Verdict: **PASS** at 1737063 (round 4, after rounds 1-3 NEEDS-REVIEW; section 13).

### 3.1 C3-02 entity/action delta (D0, 2026-10-19)

From the C3-02 module plan r8, section 3. "plan §n" points into
`claude-c302-plan-r8.md`. The table above keeps its PASS; it is
incorporated, not re-approved, and unchanged resources are not redrawn.
Where a row below differs from the table above, the row below governs.
Labels: **Chosen** = proposed for review; **Decided (owner, D-174)** = the
owner's decision of 2026-10-19; **Alternative** = not chosen (one-line
record).

```
Entity Model trigger: yes
Reason: changed action contracts, key sets and input acceptance on existing
resources; new transaction-scoped value objects with material invariants;
a changed agent-definition lifecycle; changed webhook outcomes, including
a committed reply phase with a deferred agent hand-off on the existing
WebhookEvent lifecycle (Q-O5); a new cutover pre-check and fence.
```

| Entity | New / Existing | Purpose | Attributes | Relationships | Invariants / Lifecycle | Policy/Actor | Open Questions |
|---|---|---|---|---|---|---|---|
| IdentityKeys pass record (value object) | New | Bind one application scope's pass to its token, backend and id set | `v1`, token (128-bit hex), backend pid, set of signed int64 ids (possibly empty); process state `none / acquiring / passed / poisoned` | transaction-local GUC `sdr.identity_pass`; process dictionary | **Chosen:** plan §2.3-2.5. Written once after the last lock; reverted with the locks; a request must be in the set and the whole set held; failed acquisition poisons the scope; a proven revert may re-pass; trusted-writer convention. **Alternative:** never re-pass in a scope (not chosen; would change O2) | internal | none |
| Domain/email representations (value objects) | New | One stated representation per purpose | `strip`, `company`, `key_value` (section 5.4) | `Sales.Domain.canonical/1` = `company/1`; SQL `sdr_canonical_domain` = `strip` | **Chosen:** each applied once per purpose (section 5.4); `K(raw) = H(strip(key_value(raw)))` with `H` hashing exactly the given bytes; company values are fixed points (`company(c) == {:ok, c}`); suppression and email validity unchanged; content-free errors. **Decided (owner, D-174), Q-O6 = accept:** the company-input restriction (repeated `www.` refused) | — | none |
| Sales.Account | Existing (delta) | Company identity | stored `domain` = `company(raw)` on new or changed rows; calculation `canonical_domain` = `sdr_canonical_domain(domain)` | — | **Chosen:** `:create`/`:seed`/`:update` refuse `company`-invalid domains (new: repeated `www.`); keys are new (create/seed) and old+new `canonical_domain` (update), with a locked re-check and a typed `:conflict`; migration pre-checks: canonical collisions, double open leads (section 3), and legacy rows whose indexed value `c` fails `company(c) == {:ok, c}` (new). **Decided (owner, D-174), Q-O6 = accept:** repeated `www.` refused at input, and the migration aborts on such legacy rows. **Decided (owner, D-174), Q-O1 = A (A.4):** `:update` to a suppressed domain is refused under its keys | ADM unchanged | none |
| Sales.Contact | Existing (delta) | Person identity | — | — | **Chosen:** `:create`/`:seed` key the new email; `:change_email` keys old, new and the new email's domain, with a locked re-check and `:conflict`. **Decided (owner, D-174), Q-O2 = refuse (OQ6 (ii)):** when the new address or its domain is suppressed, `:change_email` is refused under the keys with a typed error and writes nothing. (Alternative (i), proceed with sending blocked by the gates, not chosen) | ADM unchanged | none |
| Sales.Lead | Existing (delta beyond section 3) | Lead lifecycle | — | — | **Chosen:** `:seed` keys its account's `canonical_domain` before `LeadAccount` and re-checks under account `FOR SHARE`; `:reopen` takes key → account SHARE → lead UPDATE → re-checks → open-lead refusal; override transitions use `require_held`. **Decided (owner, D-174), Q-O1 = A (A.3):** re-open is refused for a covered contact | `SeedingAllowed` unchanged | none |
| Research.Qualification | Existing (delta) | Human override; agent record | — | — | **Chosen:** `:override`: key → account `FOR SHARE` → lead `FOR UPDATE` → re-checks → (re-open only) the open-lead rule and A.3 (Decided, D-174) → INSERT → … → head; a same-outcome override takes the same locks and moves nothing. **Chosen (MF1):** `:record`, root and successor: lead `FOR UPDATE` by `lead_id` and tenant as its first before_action, before the `Supersedes` and `QualificationRules` reads and the INSERT; a lead absent from the actor's tenant is a fixed typed refusal on `:lead_id` with nothing written; no key and no account lock; `supersedes_id` stays accepted (successors stay supported); lineage rules, policies and the lead lifecycle are unchanged (plan §4.6) | ADM/REV (`:override`) and AGT (`:record`) unchanged | none |
| Outreach.Suppression | Existing (delta) | Do-not-contact facts | stored `value` unchanged | — | **Chosen:** every create keys `key_value`, then `strip` of its stored value, before `ApplySuppression`; `:from_webhook` uses `require_held`; `NormalizeSuppression`, stored values and the email/email-domain matching are unchanged; the strengthened company match (section 3) compares the stored value with `canonical_domain`. **Decided (owner, D-174), Q-O1 = A:** `:matching` and `Outreach.matching_suppressions/2` are unchanged in C3-02. (Alternative B, company matching in `:matching`, not chosen; it is the C5-04/real-data prerequisite of section 6) | unchanged | none |
| Cutover fence (migration pre-check) | New | Initial-state premise for option A | counts per category (section 6) | reads contacts, accounts, suppressions, leads, enrollments, drafts, deliveries, approvals | **Decided (owner, D-174), Q-O1 = A (A.5):** abort with counts only when any covered-contact open lead or eligible dependent work exists; no override flag; no backfill | — | none |
| Outreach.Webhooks (action contract) | Existing (delta) | Provider events | — | — | **Chosen:** keys from the payload; duplicate detection under the reply-message key; locked revalidation; transient `:reply_match_changed` and `:conflict` (whole-event rollback, unchanged). **Decided (owner, D-174), Q-O5 = no wait; design Chosen (plan §6.7):** a matched reply's own phase (Reply, `ApplyReply` effects, `unsubscribe_rule` Decision, any `unsubscribe_reply` Suppression and its `ApplySuppression` effects) commits even when the definition is missing; the event then stays unprocessed, and `process/4` returns `{:error, :agent_definition_unavailable}` so the existing `WebhookWorker` job retries; a retry of the same event finds its own stored Reply under the reply-message key and runs only the hand-off; the hand-off commits with `:mark_processed`; on the final attempt the event goes to `failed` (class `:crash`, fixed reason) with its Failure, and the existing operator retry completes it while a retry path remains and the definition is restored (limits in section 6). A duplicate event (another WebhookEvent, same Message-ID) stays a no-op. (Alternative, r7's whole-event rollback on a miss, not chosen) | WHK unchanged | Q-C17 (Codex) |
| Outreach.ReplyIntake (seam behaviour, `lib/sdr_agent/outreach/reply_intake.ex`) | Existing (delta) | The Outreach→agent-plane seam | — | — | **Chosen (plan §6.7):** `received/3` returns `:ok`, `{:deferred, :agent_definition_unavailable}` (the callee wrote nothing) or `{:error, term}`. It is called in the reply's first transaction or, after a deferral, in a later transaction of the same event with the match rebuilt from the stored Reply. Whatever it records commits with that event's `:mark_processed`, not necessarily with the Reply (replaces `:6-9`, `:12-15`) | — | Q-C17 |
| Operations.WebhookEvent (state meaning only) | Existing (delta: no attribute, state, transition or policy change) | Webhook lifecycle | — | — | **Chosen (plan §6.7):** for a `reply` event, `received` and `failed` may now also mean "this event's Reply phase committed; its hand-off is owed". `processed` still means fully applied, now including the hand-off. Transitions (`webhook_event.ex:49-54`), terminal immutability (`:98-110`) and the operator retry (S13b) are unchanged | WHK and ADM unchanged | Q-C17 |
| Reply hand-off owed (derived state; **no new record**) | New (derived) | Make the deferred hand-off an explicit, reviewable invariant | none persisted. Derived from a matched Reply R, the event E with `E.id = R.webhook_event_id` (unique, `reply.ex:207`), and `E.processing_status` | Reply → WebhookEvent (existing FK) | **Chosen, invariant I-H:** for every matched R, E is `processed` if and only if R's hand-off (reply AgentRun, ReplyWorker job, `sdr.reply.received` event) committed, and both commit in one transaction. While E is `received` its job retries; when E is `failed` its open Failure is the attention record. A duplicate event never owns R's hand-off | — | Q-C17 |
| Outreach.Approval / DeliveryOperation gates | Existing (unchanged) | Approval and send gates | — | — | **Decided (owner, D-174), Q-O1 = A:** no change in C3-02. (Alternative B, account `FOR SHARE` after contact `FOR SHARE` and company matching in the gates, not chosen; the alignment stays a hard prerequisite of C5-04 and real data) | unchanged | none |
| Agents.AgentDefinition | Existing (delta; section 3 said "unchanged") | SDRAgent definition | — | — | **Chosen:** registered only by `bootstrap_definitions/1`, outside any transaction (at boot before Oban and the Endpoint, and after a tenant is created); request paths only read it, checking tenant, name, version, `active` and the hash computed from current code at each lookup. The separate test-seam `CalibrationConsole` definition keeps its own registration (plan §7.1). **Decided (owner, D-174), Q-O4 = the app does not start:** a non-success boot disposition returns `{:error, {:definition_bootstrap_failed, class}}` | KRN unchanged | none |
| SDR `assign_lead/2` (contract) | Existing (delta) | Standalone assignment | — | — | **Chosen:** no registration; read-only lookup before any write; `:agent_definition_unavailable`, nothing written; options unchanged | ADM/REV unchanged | none |
| SDR `ReplyIntake.received/3` (contract) | Existing (delta) | Reply hand-off | — | — | **Chosen (plan §6.7):** no registration; the read-only lookup is its first step (replacing `SDRAgent.register` at `lib/sdr_agent/sdr/reply_intake.ex:28`); a miss returns `{:deferred, :agent_definition_unavailable}` before any write; a hit writes the run, its job and the signal as today (`:29-56`). It is not itself idempotent: at-most-once comes from invariant I-H (event row lock and `:mark_processed` in the same transaction) | — | Q-C17 |

Line references in this table are at main `425d7c9` (plan §0).

New in plan r8 (Q-O5): no new persisted entity, attribute, state or
transition. The new contracts are the `{:deferred, …}` return of the
ReplyIntake seam, the resume branch of the webhook reply path, the widened
meaning of WebhookEvent `received`/`failed` for replies, and invariant I-H.

Configured reviewer: Codex via ai-pair. Verdict on this delta: **PASS**
(final correlated entity/action and module review, 2026-10-19; consultation
`m_…b99bf459`, answer `01a156c3-d930-71f4-8797-f9e695bd2c4c`; report
`codex-c302-final-d0-10325fd0-review.org`, sha256 `8f16b628b2549e7a25da31ba98c4a9fab9fc8bb37030518f84e265038d1ecd2a`).
It covers plan r8 (sha256 `94fe05cb9cefe46618c7ee5e63c92145506aa615a9a663d26bb8e643f145b344`,
kept unchanged) and these D0 artifacts at `10325fd0`. It permits the
planned RED only: no verified RED, GREEN, spend or real-data authority.
The owner decisions it created (Q-O1..Q-O6) are decided (D-174,
2026-10-19) and recorded above. The owed-hand-off follow-up (section 6)
is a separate contract owned by Claude, a prerequisite of real data, and
not in C3-02's scope.

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
| 8a | run settings incomplete for the server-owned origin (`:assignment`; section 4.5), plain pre-check | `{:settings_incomplete, kinds}` | nothing |
| 9 | locks (section 6), then live real-data guard again on resolved values | `:real_data_disabled` | nothing |
| 10 | suppression on email, email domain or company domain | `suppressed` | admission row |
| 11 | email belongs to a contact at another account | `contact_at_other_account` | admission row |
| 12 | contact archived / account archived | `contact_archived` / `account_archived` | admission row |
| 13 | contact has an open lead | `duplicate_open_lead` | admission row |
| 14 | company has an open lead for another person | `active_target_exists` | admission row |
| 14a | kind is `csv`, `hubspot` or `agent_found`, and the company's most recently closed lead ended `converted` or `nurture` (rule 4.4) | `company_in_relationship` | admission row |
| 15 | contact has only closed leads and the readmit rule (4.3) does not allow it | `previously_worked` | admission row |
| 16 | otherwise | `admitted` | account and contact if new, admission row, lead `new`, assign → `assigned`, queued run (`usage_origin :assignment`) with its settings snapshot and frozen budget (section 4.5); a snapshot refusal here rolls back the whole transaction: `{:settings_incomplete, kinds}` / `:settings_default_unavailable`, nothing written |

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
(`:agent_definition_unavailable`), run settings complete for origin
`:referral` (`{:settings_incomplete, kinds}`, section 4.5). These refusals
write nothing. Then
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

### 4.5 Run settings prerequisite (C4, existing contract)

These code facts are from `main` at fb54000. They are the existing C4
assignment contract, which C3 reuses. They are not a C3 design.

- **The reused path already enforces it.** `SDR.assign_lead/2` runs
  `Agents.settings_complete(:assignment, actor: agent)` as a plain pre-check
  before any write (`lib/sdr_agent/sdr.ex:90`).
- **The authoritative check is under the head.** `AgentRun :create` runs
  `Agents.Changes.BuildSettingsSnapshot`. Under the tenant's chain head
  (reentrant), it:
  - reads the current revision of each kind;
  - refuses a missing required kind (`settings_incomplete`);
  - builds the `RunSettingsSnapshot` (`settings_default_unavailable` when a
    code default fails its pinned check);
  - freezes the run's budget at the lower of the caller's argument and the
    snapshot's `run_*` limit.

  A database trigger refuses a new run without a snapshot.
- **Which origins need settings.** `RunSettings.completeness/0` requires
  `:offering_profile` for every business origin:
  `:assignment`, `:referral`, `:followup`, `:discovery` and `:channel`.
  The `:reply` and `:proof` exemptions do not apply to admission or
  referral.

C3 obligations:

1. **Origin is server-owned.** The extracted assign body takes the usage
   origin as an argument set by the orchestrator: `:assignment` from
   `admit_lead/2`, `:referral` from `hand_off_referral/2`. It is never input.
   The pre-check and the snapshot both use that origin.
2. **The pre-check runs for every new request (step 8a).** It comes after
   replay (step 6) and the definition check (step 8), and before locks
   (step 9). A refusal returns `{:settings_incomplete, kinds}` and writes
   nothing.
   - **Scope.** This applies to every new request, including one that would
     have recorded a non-admitted outcome (steps 10-15). That scope is C3's
     own added precondition, chosen conservatively to mirror the
     missing-definition rule. It is not an existing C4 rule: C4 checks
     completeness only where a run is created.
   - **The ref stays free.** No admission row is stored, so the source ref
     stays free. An identical resubmission after the owner saves the
     settings is a new request.
3. **Replay does not depend on today's settings.** Replay (step 6) comes
   first and returns the stored result and the stored run's snapshot. It
   never builds a new snapshot.
4. **The snapshot is authoritative.** A refusal from `BuildSettingsSnapshot`
   at step 16 rolls back the whole transaction. The return is the same closed
   reason (`{:settings_incomplete, kinds}` or `:settings_default_unavailable`),
   never an Ash error struct. So `admitted` is never returned without the
   lead's queued run and its snapshot: they commit together or not at all.
5. **No bypass.** No C3 flag, default or input skips completeness or
   budgets. `admit_lead/2` and `hand_off_referral/2` take no budget fields, so
   the run's budget is the snapshot's `run_*` limits.
6. **Prerequisite for the owner, before the first admission:** an offering
   profile saved in `/settings` (C4-01b, #166). C3-02's tests save a
   synthetic offering profile in per-test setup.

## 5. Identity, input hash and agreement

### 5.1 Dedupe identities

| Identity | Normalization | Enforced by | Notes |
|---|---|---|---|
| Company | SQL `sdr_canonical_domain` (`strip`, for keys and the index): trim, lowercase, strip one trailing `.`, strip one leading `www.`; `Sales.Domain.canonical/1` (`company/1`, for input and storage): that result accepted only as a valid fixed point, a host of ≥ 2 ASCII labels, no scheme, port or path, no repeated `www.` (section 5.4) | expression unique index `(tenant_id, sdr_canonical_domain(domain))` (new) plus existing `(tenant_id, domain)` | old rows found by the expression, never rewritten; subdomains distinct; name never a key |
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

### 5.4 Domain and email representations, applied once per purpose (C3-02)

From the C3-02 plan r8, section 2.7, and the ADR-0009 C3-02 amendment
(item 3).

**Why one function is not enough.** The rule of section 3 strips *exactly
one* leading `www.` and one trailing `.`. That rule is not idempotent:
`strip("www.www.acme.test") = "www.acme.test"`, but
`strip(strip(x)) = "acme.test"`. So C3-02 separates three purposes, each
applied once.

| Function (`SdrAgent.Audit.IdentityKeys.Normalize`) | Definition | Rejects | Purpose |
|---|---|---|---|
| `strip/1` (key canonicalization) | `lower(btrim(x))`, then remove exactly one trailing `.`, then exactly one leading `www.`. Character-for-character the SQL `sdr_canonical_domain` of section 3 | nothing (total on strings) | the SQL index/lookup expression, and domain key ids |
| `company/1` (company identity) | `c = strip(raw)`, accepted only if `c` matches the host grammar (labels `[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?`, ≥ 2 labels, ≤ 253 bytes), `c` has no leading `www.` and no trailing `.`, and `raw` has no consecutive dots or empty label. **`c` is therefore a fixed point: `strip(c) = c` and `company(c) = {:ok, c}`.** | repeated `www.` (`www.www.acme.test`), two or more trailing dots, fewer than two labels after stripping (`www.test`), URL/port/path/non-ASCII, malformed hosts | account identity, dedupe, the admission hash |
| `key_value/2` (representation guard for key inputs) | for `domain`: trimmed, lowercase, 1..253 bytes, no `@`, no whitespace or control characters; for `email`: trimmed, lowercase, exactly one `@`, non-empty local and host parts, no whitespace or control characters. **No host-grammar, label-count or reserved-name check.** | only non-representable input | keeps every currently valid suppression and email keyable |

Invalid input gives a fixed, content-free error: `company/1` returns
`{:error, :invalid_domain}`, shown as `{:invalid, [:domain]}` or a fixed
`InvalidAttribute` message; `key_value/2` raises
`IdentityKeys.InvalidKeyValue` carrying the kind only.

**Raw input stays as valid as today.** `NormalizeSuppression` and the
contact email rules (`Validations.Reserved`) are unchanged. Suppression and
email values only pass through `key_value/2` and `strip/1`, never through
`company/1`, so `www.test` stays a valid domain suppression and `a@www.test`
a valid suppression email, and both stay keyable.

**Input restriction (Decided (owner, D-174), Q-O6: accepted).** The only
input restriction is on company identity:
- Account `:create`, `:seed` and `:update` refuse a domain that `company/1`
  rejects;
- the admission input (step 3) refuses a company domain that `company/1`
  rejects.

The repeated-`www.` refusal is new; fewer than two labels after stripping
is already in section 3. The migration stop on legacy accounts (below) is
part of the same decision. The ADR-0009 C3-02 amendment records Q-O6 by
reference only.

**Where each purpose is applied, exactly once:**

| Path | Representation used | Normalization applied |
|---|---|---|
| Admission input (step 3) | `c = company(raw)`; hashed `company.domain = c` (section 5.2 step 6) | `company/1` once |
| Account `:create`/`:seed`/`:update` storage (`NormalizeDomain`) | stores `c` | `company/1` on the attribute; input already `c` (from admission) gives `c` again (fixed point) |
| SQL index and lookup | index on `sdr_canonical_domain(domain)`; lookup `WHERE sdr_canonical_domain(domain) = $c` | `strip` once, on the **stored** value. New rows: `strip(c) = c`. Legacy rows: `strip(stored)`, which the legacy-identity pre-check guarantees is a valid fixed point |
| A stored row's identity (key input for Account `:update` old, Lead `:seed`/`:reopen`, override, Lead `:create` `require_held`, the strengthened company match) | the Ash calculation `canonical_domain` = the SQL expression, read from the database | none in Elixir |
| Domain key ids (`IdentityKeys`) | `K_domain(raw)` | `strip` once, inside IdentityKeys, on the caller's raw key input |
| Email key ids | `K_email(raw)` | trim and lowercase only |

**Key input versus digest.**
- `H(kind, tenant, bytes)` is the digest of section 6 (first 8 bytes of
  the sha256, signed 64-bit). It never normalizes.
- `K_domain(raw) = H("domain", tenant, strip(key_value(:domain, raw)))`;
  `strip` runs exactly once, inside `K_domain`.
- `K_email(raw) = H("email", tenant, key_value(:email, raw))`; no strip.
- Callers always pass the raw key input (the compared value), never a
  `strip` result, and never call `H` directly.

**Legacy-identity pre-check (additive migration, counts only, aborts).**
For each existing account, let `c = sdr_canonical_domain(stored domain)`,
the indexed value.
- Accept only when `company(c) == {:ok, c}`: `c` passes every
  company-validity check **and** comes back unchanged.
- A normalization that succeeds to a **different** value aborts. Example:
  stored `www.www.x.test` indexes as `c = www.x.test`; `company(c)` returns
  `{:ok, "x.test"}`, which is not `{:ok, c}`.
- SQL equivalent (in the migration, using the same strip function):

  ```sql
  length(c) BETWEEN 1 AND 253
  AND c ~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$'
  AND c !~ '^www\.'
  AND sdr_canonical_domain(c) = c
  ```

- Any account failing the predicate aborts the migration, reporting counts
  only. Rows are not repaired, rewritten or backfilled. It runs alongside
  the collision and double-open-lead pre-checks of section 3.
- Examples: legacy `www.orbit.example.org` (`c = orbit.example.org`) and
  `www.x.test` (`c = x.test`) pass; `www.www.x.test` and `www.test`
  (`c = test`, not a valid company) abort.

**Runtime check.** Every place that reads an indexed value as company
identity checks `company(c) == {:ok, c}` before keying: Account `:update`
(old key), `CompanyKey` (Lead `:seed`, `:reopen`, `:create`) and
`OverrideCompanyLock`. A failure is a fixed typed refusal with no value.
After the pre-check this cannot happen; the check is defensive.

**Agreement.** After the pre-check every indexed value `c` is a valid fixed
point, and the same bytes `c` are used by the lookup, the stored identity,
the admission hash and every company key, `K_domain(c) = H("domain", t, c)`.
Admission's pass key, the nested Account `:create` key and the nested Lead
`:create` key are all `H(c)`, so every `require_held` matches the pass and
nothing raises `LateAcquisition`. Equal compared raw values always give
equal keys: email = email; a domain suppression `s` equal to an email
domain `h` or to an account's `canonical_domain` `c` gives the same key.

**The `www.` consequence.** `K_domain("www.acme.test") = H("acme.test") =
K_domain("acme.test")`. This merges keys that cover nothing: it adds
serialization only, and coverage is unchanged. A `www.acme.test`
suppression covers email domain `www.acme.test` and no account. Vectors:
- suppression `www.www.acme.test` is valid and stored as-is; its key
  preimage is `www.acme.test` (stripped once, not `acme.test`), and email
  `a@www.www.acme.test` has the same preimage, so it is covered by the
  email-domain match and serialized in both commit orders; as a company
  domain it is refused;
- suppression `www.test` and email `a@www.test` are valid, with key
  preimage `test`; as a company domain `www.test` is refused;
- company `WWW.Acme.Test.` gives `acme.test`, and a replay with `acme.test`
  gives the same hash and the stored result.

For every refused domain or email, the returned error, the logs and the
span attributes do not contain the input value.

## 6. Identity keys, lock order and concurrency

The shared key contract is the ADR-0009 C3 amendment (in this PR, accepted
by the owner on 2026-10-14) so no implementer invents a second namespace or
order. Its C3-02 amendment (accepted by the owner on 2026-10-19, D-176) adds
the application-transaction lifetime, the key-set additions and the
normalization by purpose (section 5.4). Summary:

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
  "Transaction" here is the outermost application transaction: under the
  Ecto SQL sandbox it is a savepoint, and keys of an earlier, released one
  on the same backend neither count as this transaction's pass nor block it
  (ADR-0009 C3-02 amendment, item 1).
- **Collisions** only serialize unrelated work; never correctness.
- **Writers that take keys** (key sets as amended by C3-02):
  - admission and referral: ref, company domain, email, email domain;
  - Suppression `:manual`, `:seed`, `:from_classification`: its value;
    `:from_webhook` finds it held (`require_held`);
  - webhook paths: one pass (section 3; reply = `{reply-message: Message-ID,
    email: from}`, unsubscribe = `{email}`, bounce and complaint =
    `{email: stored recipient}`);
  - Account `:create`/`:seed`: the new canonical domain;
  - Account `:update` with a domain change: the old and the new canonical
    domain;
  - Contact `:create`/`:seed`: the new email;
  - Contact `:change_email`: the old email, the new email and the new
    email's domain;
  - Lead `:seed` (dev/test): its account's canonical domain;
  - Lead `:reopen` and Qualification `:override`: the company domain of the
    lead's account.

  Account `:update`, Contact `:change_email` and Lead `:seed` re-check the
  keyed value on the locked row and refuse a stale one with a typed
  `:conflict`, requesting no further key. Inside admission the nested
  Account, Contact and Lead creates and Lead `:assign` find their keys
  already held (`require_held`).

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
`SDR.assign_lead/2` and `SDR.ReplyIntake.received/3` no longer
register. They look the committed definition up read-only (tenant,
`SDRAgent`, the code's version, `active`, `definition_sha256` equal to the
hash computed from current code) before any write (assign), or as the
first step of the reply hand-off (reply), and fail closed with
`:agent_definition_unavailable`. For a reply, only the hand-off waits: the
Reply, its effects, the `unsubscribe_rule` Decision and any
`unsubscribe_reply` Suppression with its effects commit at once, the
WebhookEvent stays unprocessed, and the event's own retries (then its
operator retry) perform the hand-off exactly once, committed with the
event's `processed` transition. `SDR.bootstrap_definitions/1` is the only
registration path for the `SDRAgent` definition; it refuses to run inside
a transaction and is idempotent. It runs at application start before Oban
and the Endpoint, and right after a tenant is created (demo seed,
`mix sdr.bootstrap_admin`, test setup). This does not cover the separate
`CalibrationConsole` definition of the test-seam calibration console,
which keeps its own registration, in its own transaction, outside any
request transaction, unchanged by C3-02.

**Boot disposition (Decided (owner, D-174), Q-O4: the app does not
start).** The boot child `SdrAgent.SDR.DefinitionBootstrap` starts after
`SdrAgent.Repo` and before Oban and the Endpoint. On any non-success
disposition (classes `:timeout`, `:crash`, `:schema_not_migrated`,
`:connection`, `:definition_conflict`) the child returns
`{:error, {:definition_bootstrap_failed, class}}`, with `class` sanitized,
and the application does not start. No tenant gives `:ignore`, which is not
a failure. A `:timeout` means "not confirmed", not "nothing written";
idempotence makes the next boot or call converge. (Record: the alternative,
log the class, return `:ignore` and let request paths fail closed, was not
chosen.)

**Reply hand-off deferral (Decided (owner, D-174), Q-O5: no wait).** The
mechanism behind the paragraph above (plan §6.7):
- The seam `Outreach.ReplyIntake.received/3` returns `:ok`,
  `{:deferred, :agent_definition_unavailable}` (the callee wrote nothing)
  or `{:error, term}`.
- **T1**, the first processing of the event: the reply phase writes as
  today. On a miss the deferral skips `:mark_processed`, the transaction
  commits the reply phase, and the event stays `received`. `process/4`
  gains one clause before `{:ok, _}`: not final, `{:error, reason}` and Oban
  retries; final, the event is failed as `:crash` with the fixed reason
  "reply hand-off pending: agent definition unavailable" and an open
  Failure.
- **T2**, a later attempt or an operator retry of the same event: under
  the same key pass, the event's **own** stored matched Reply selects the
  resume branch, which rebuilds the match from the stored Reply and runs
  only the hand-off (no `reply/5`, no `Locks.targets`, no domain row lock).
  A Reply of another event is a duplicate, `:ok`, as today.
- **Invariant I-H:** for every matched Reply, its event is `processed` if
  and only if the hand-off committed, and both commit in one transaction.
  The suppression and the reply effects are applied at most once (T2 never
  calls `reply/5`; the Reply identities, the `:from_webhook` upsert and the
  Decision's idempotency key are backstops), and the hand-off is written at
  most once (event row lock, runnable states, `processed` terminal).

**Limits of the deferral (disclosed, plan §6.7.6).** "Exactly once" above
is at most once, and the hand-off completes only while a retry path
remains and the definition has been restored:
1. **Retry horizon.** The event's job retries a bounded number of times
   (`max_attempts: 3`). After the final attempt the event is `failed` with
   an open Failure and the hand-off owed. The operator retry allows at
   most 3 requests and needs the original job, which is pruned a day after
   it completes (`:retry_window_expired`). After that the Failure stays
   open and the hand-off stays owed, but no existing path completes it. No
   eventual completion is claimed, and C3-02 adds no unbounded retry or
   sweeper.
2. **Model-only unsubscribes.** A reply that the deterministic rule misses
   gets its suppression only when the classification runs, which needs the
   run and so the definition.
3. **Other hand-off failures.** A database error in the hand-off (snapshot,
   run or job insert) still rolls the whole event back, as today.
4. **Transient races.** `:reply_match_changed` and `:conflict` stay
   whole-event rollbacks; on a final attempt the reply's unsubscribe waits
   for an operator retry.

**Follow-up (owned work, outside C3-02).** Completing an owed hand-off
after the retry horizon needs a new contract (an owed-hand-off sweeper, or
an ADM action) with its own entity review. **Owner: Claude** (named
2026-10-19 for Codex r8 review, important 2). It is tracked as a separate
contract, and it must land before any real reply is processed, i.e.
before C5-04 enables real data.

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
this transaction or already held in an equal or stronger mode, with two
exceptions. The first is the tenant row, which no writer locks. The second is
the pre-existing settings revisions named by the run's snapshot: their
`FOR KEY SHARE` is compatible with an editor's `FOR NO KEY UPDATE`, as
described below. **Unique-index waits after the head**
are excluded per index: account domain (both indexes) and contact email:
every writer holds the key; admission ref: key; leads per account and per
contact: every writer that can make a lead open holds the company key;
agent definition: read, never inserted, by admission; Operation idempotency key and
signal id: fresh per assignment; suppression value
(`suppressions_unique_value_index`, added by C3-02): every Suppression
create and every bounce and complaint holds the value key (O11 correction,
below). Tests prove this on independent connections (section 9).

The C4 settings dependencies (section 4.5; facts from `main` at fb54000) are
part of the assign path's set above:

- **Settings revisions.** `BuildSettingsSnapshot` reads the current revision
  of each kind, unlocked, only after it holds the chain head. No revision can
  commit between that read and the run, because a save appends under the
  head.
- **Snapshot insert.** The `RunSettingsSnapshot` row is fresh. Its foreign
  keys check, in `FOR KEY SHARE`:
  - the tenant row, which no writer locks;
  - up to five pre-existing revisions, one composite foreign key per kind:
    `(<kind>_revision_id, tenant_id, <kind>_kind, <kind>_content_sha256)` →
    `settings_revisions (id, tenant_id, kind, content_sha256)`
    (`RunSettingsSnapshot` migration statements, `run_settings_snapshot.ex:106-119`).
- **Run to snapshot.** The run's `(settings_snapshot_id, tenant_id)` foreign
  key targets that row, created in this transaction.

**Revision writers.** The `/settings` save, `SettingsRevision
:create_revision` through `Agents.Changes.SettingsRevisionChain`, runs in
this order (moduledoc steps 1-5, `lock_current/2`):

1. it locks the kind's current revision `FOR NO KEY UPDATE`, before the
   head;
2. it inserts the next revision;
3. it appends under the chain head.

It takes no identity key and locks no other domain row. C4 chose `FOR NO
KEY UPDATE` so that a snapshot's `FOR KEY SHARE` foreign-key check never
waits on an editor. These two modes do not conflict.

**Both orders:**

- **Admission holds the head first.** The editor holds the revision `FOR NO
  KEY UPDATE` and waits for the head. The admission's snapshot `FOR KEY
  SHARE` on that same revision is granted without waiting. The admission
  commits, then the save proceeds. No cycle.
- **The save holds the head first.** The admission waits at the head (or
  before it, at a key-holding step that is unrelated to the save). After the
  save commits, the admission reads the new current revision under the head.

C3 adds no revision `UPDATE` lock and does not refactor C4. RED proves the
actual order on independent connections (section 9). It does not assert
that there is no lock.

The cycle table below is historical code facts from 182bde6, plus the C4 row
and the C3-02 rows for Lead `:seed`, Lead `:reopen` and Qualification
`:override`/`:record` (the D3 order; plan r8 §4.2-4.6 and §8.3, at main
`425d7c9`). C3-02's plan re-checks it against current main, including the
C1 command boundary (O11).

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
| Lead `:seed` (C3-02) | key → account S → INSERT → head | key first; removes the seed-vs-admission deadlock at one account |
| Lead `:reopen` (C3-02) | key → account S → lead U → re-checks → open-lead refusal, A.3 refusal → transition → head | key first; agent transitions take no key and only lock their lead |
| Qualification `:override` (C3-02, D3 order) | key → account S → lead U → re-checks (lead's account unchanged; locked account's canonical domain = keyed value, else typed conflict) → (re-open only) open-lead rule and A.3 → INSERT (lead KEY SHARE, held) → evidence links → lead update (re-lock, held) → head | key first; no row lock after the head and no late key; `:archive` (account U, no key) and agent transitions (lead U, no account lock) never hold what the override waits for while waiting on it |
| Qualification `:record`, root and successor (C3-02) | lead U (by `lead_id` and tenant) → Supersedes and QualificationRules reads → INSERT (KEY SHARE on the held lead) → evidence links → lead update (re-lock) → head | lead-first like the override, so no qualification index entry is held by a writer that waits for the lead; no key and no account lock; the second writer waits on the lead and, if the first committed, gets a typed refusal |
| User role/status, campaign transitions | row UPDATE → head (no key) | they block on our SHARE while holding nothing we need |
| C4 settings revision save (`:create_revision`, fb54000) | current revision `FOR NO KEY UPDATE` → insert → head (no key, no other domain row) | admission takes only `FOR KEY SHARE` on revisions (snapshot FKs, under the head), which is compatible with `FOR NO KEY UPDATE`; the save never waits on a key or domain row we hold (both orders proved on independent connections in RED) |
| `SDR.assign_lead/2`, `retry_run/2` | lead UPDATE → head (no key) | lead-first as step 6; while the handover holds the original `FOR UPDATE`, an assignment of it waits and then fails its state check |

**O11 inventory correction (C3-02).** Bounce locks no lead
(`webhooks.ex:468-470` at main `425d7c9`). After `:change_email`, a manual
suppression of the old address (INSERT, then head) and a bounce (head, then
INSERT on `suppressions_unique_value_index`,
`priv/repo/migrations/20261007142841_s8a_outreach.exs:285`) can deadlock
today. The value key removes this: bounce and complaint take
`{email: stored recipient}` before `lock_suppression`, and the per-index
list above gains that index. Plan r8 §8.2 lists the other deltas to the O11
inventory.

**Suppression boundary (Decided (owner, D-174), Q-O1 = A with A.3, A.4 and
A.5; Q-O2 = refuse).** "Covered" means matched by email, email domain or
account canonical domain. Option A enforces where openness or company
identity changes, leaves the gates unchanged, and fences the initial state:
- **A.1:** the strengthened `Locks.contacts` (section 3).
- **A.2:** admission step 10 (section 4.1).
- **A.3:** a re-open by `:reopen` or override is refused for a covered
  contact (typed error, under the company key).
- **A.4:** Account `:update` to a suppressed `company` domain is refused
  under its keys. In the rename-first order, the suppression waits on the
  key, and `Locks.contacts` then sees the new domain.
- **A.5: cutover fence.** A migration pre-check, before any schema change
  of the cutover migration, per tenant (all joins match `tenant_id`). The
  covered contact set CC is every contact whose account has a
  `domain`-scope suppression equal to `sdr_canonical_domain(a.domain)`,
  whatever the lead status. It counts (a) open leads of CC, and, across
  **all** leads of CC, (b1) active or paused enrollments, (b2) unclaimed
  deliveries (`pending`, `failed_retryable`) of `queued` drafts, (b3)
  eligible drafts (`pending_review`, or `queued` with a delivery in (b2)),
  and (b4) `granted` approvals of (b3). Any non-zero count aborts the
  migration with per-category counts and no values; nothing is changed.
  There is no bypass (no flag, environment variable or recorded acceptance)
  and no backfill; any remediation needs its own reviewed contract outside
  C3-02. One SQL text (`SdrAgent.Sales.CutoverFence.counts_sql/0`) is run by
  the migration and by the tests.
- **OQ6 (ii) (Q-O2):** `:change_email` keys the old email, the new email
  and the new email's domain. When the new address or its domain is
  suppressed, it is refused under the keys with a typed error and nothing
  written.
- **Unchanged in C3-02:** `SuppressionMatch`, `:matching`,
  `Outreach.matching_suppressions/2`, and the approval and send gate lock
  orders. With a clean fence, P1 (no application action grants an approval
  or claims a delivery for a covered contact after a suppression commits;
  not promised for deliveries already claimed, dev/test seeds or raw
  database writes) holds for the
  company domain because no covered contact can gain an open lead
  (A.2-A.4, A.1) or keep eligible work (A.5, then suppression effects).
- **Hard prerequisite of C5-04 and of real data:** aligning
  `SuppressionMatch` and the send gate with company domains (the change
  option B would have made in C3-02). Follow-up owner: Claude (plan r8
  §5.4).
- (Record: option B, changing the gates in C3-02, and OQ6 (i), proceeding
  with sending blocked by the gates, were not chosen.)

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
- **Database logging and spans (baseline on `main` at fb54000).** C4's
  ADR-0005 amendment, "metadata-only database logging and spans", was
  accepted by the owner on 2026-10-14 and merged in C4-01a. C3-02 builds on
  it and adds no logger or span handler of its own. The controls in force:
  - **Repo logging.** Metadata-only in every environment, through
    `SdrAgent.Repo.QueryLog` and its one allowlisted sanitizer,
    `SdrAgent.Repo.SafeMetadata`. It logs no parameters, SQL text,
    exception message, `DETAIL`/`HINT` or connection data.
  - **Spans.** `SdrAgent.Telemetry.RepoSpans` has an allowlisted error
    status (`error_module`, `pg_code` and `constraint` only) and no
    `db.url` or `db.statement`.
  - **Log filter.** The primary `:logger` filter,
    `SdrAgent.Logger.ExceptionFilter` (`:sdr_agent_exception_filter`),
    rewrites Postgrex, DBConnection and Ash error structs in crash reports
    and framework logs.
  - **Oban.** The worker boundary (`SdrAgent.Workers.ErrorBoundary`)
    sanitizes database errors, so `oban_jobs.errors` holds no raw database
    or exception message (only the fixed safe summary persists).
  - **Dev connection errors.** Dev sets
    `show_sensitive_data_on_connection_error: false`.

  C3's typed errors map database errors by constraint name or SQLSTATE, as
  the amendment requires. Advisory keys use integer ids (section 6), never
  strings.
- **Separate gates, none implied by the baseline above or by an entity
  PASS:**
  1. **PostgreSQL server log (5b, #156).** The owner-owned decision, or an
     explicit owner retention exception, must be **recorded before C3-02
     merges** (O4). That is the operative gate, and the stricter one. It
     must also be in force before any private input or the real-data
     switch.
  2. **Input-surface protection.** The database sanitizer protects database
     telemetry, not the processes that hold operator input. D-141's
     sensitive-input tagging (ADR-0005 R0-05 amendment) covers only the
     AdminLive channel, and ADR-0005 OQ-R5-1 excludes SettingsLive. Every
     future input surface that calls C3 (B1-03, B6, C8, B2) brings its own
     reviewed protection. C3 neither provides nor assumes it.
  3. **C5-04 and the real-data switch.** C5-04 and any real data also
     need the `SuppressionMatch`/send-gate company-domain alignment first,
     a hard prerequisite (section 6, D-174 Q-O1).
  4. **Private data.**
  5. **Spend.**
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
- Run settings (section 4.5):
  - **Pre-check refusal.** With no offering profile saved, for each of the
    four kinds, a new request is refused `{:settings_incomplete,
    [:offering_profile]}`. Three shapes are covered: one that would be
    admitted, one that would record `suppressed`, and one that would record
    `duplicate_open_lead`. Exact row and event counts are unchanged: no
    account, contact, admission, lead, run, Oban job, Operation,
    RunSettingsSnapshot, signal or success audit. No admission row exists for
    the ref. Once a profile is saved, the same source ref is accepted as a new
    request: it is admitted, or it records its outcome.
  - **Authoritative refusal.** A snapshot-build refusal at step 16 is shown
    by the C4 tests' existing mechanism for `settings_default_unavailable`;
    if none reaches it, the plan names the code path. It rolls back
    everything above and returns the closed reason.
  - **Successful assignment.** The run's `settings_snapshot_id` is set, its
    slots match the current revisions, its budget equals the snapshot's
    `run_*` limits, and `usage_origin` is `:assignment`.
  - **Replay.** After a new settings revision, a replay returns the stored
    result. The run's snapshot is unchanged and no snapshot row is created.
  - **Race** (independent connections, both orders): admission against a
    `/settings` save of the first offering profile. Either the request is
    refused with nothing written, or it is admitted with its run and
    snapshot. `admitted` is never returned without the queued run.
  - **Lock order of save vs snapshot** (independent connections, both
    orders, monitor on `pg_locks`/`pg_stat_activity`). An editor holds the
    current revision `FOR NO KEY UPDATE` and waits at the head, while the
    admission holds the head and its snapshot foreign key takes `FOR KEY
    SHARE` on that revision.
    - **Granted at once.** The `FOR KEY SHARE` is granted with no wait.
    - **Waits only at the head.** The editor is shown waiting only on the
      head.
    - **The reverse order.** With the save holding the head, the admission
      waits at the head, then snapshots the new revision.

    RED asserts this actual order, not an absence of locks.
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
  :referral` and `referred_from_lead_id`, its snapshot built for origin
  `:referral`.
- Run settings: with no offering profile, a new handover request is refused
  `{:settings_incomplete, [:offering_profile]}`. Nothing is written and the
  original is untouched.
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
  `lib/sdr_agent/sales/checks/lead_admission_context.ex` (D6),
  `lib/sdr_agent/sdr/admission.ex` (logging and span controls come from the
  ADR-0005 C4 amendment's implementation, not this slice); migration (table, identities, composite FK targets,
  checks, append-only, deferred and lead triggers, canonical function and
  index, pre-checks).
- Changed: `sales/lead.ex`, `sales/account.ex`, `sales/contact.ex`,
  `sales/changes/normalize_domain.ex`, `outreach/suppression.ex`,
  `outreach/locks.ex` (domain match), `outreach/webhooks.ex` (key pass),
  `research/qualification.ex` (override key), `sales.ex`, `sdr.ex`
  (`admit_lead/2`; extract the assign body for reuse, taking the definition
  and the server-owned usage origin as arguments; the C4 settings modules
  are unchanged),
  `test/support/sales_fixtures.ex`, `lib/sdr_agent/demo/fixtures.ex` if
  a seed shares an account.
- Diagrams: regenerate the Sales domain diagram and the data-flow diagram.
- C3-02's full module list is plan r8 §8.1, which adds the reply hand-off
  deferral files (`outreach/reply_intake.ex`, `sdr/reply_intake.ex`,
  `outreach/webhook_worker.ex` moduledoc) and the boot child.
- As built (C3-02 GREEN, G1–G7; plan r8 sections 14–17): the plan's
  `sales/admission_locks.ex` was not created; the admission's lock reads
  stay in `lib/sdr_agent/sdr/admission.ex`. The plan's
  `sales/changes/company_key.ex` is realized as `Sales.CompanyLock` (the
  shared company reads), `Sales.Changes.CompanyKey` (the Lead `:seed` and
  `:reopen` key and locked re-check), `Sales.Changes.ReopenGuard` (the
  re-open refusals, A.3), `Research.Changes.OverrideCompanyLock` and
  `Research.Changes.RecordLeadLock`. Suppression keys are
  `Outreach.Changes.SuppressionKey`; the admission seams are
  `SDR.Admission.TestHooks` and `IdentityKeys.TestFaults` (test builds
  only). No contract changes with these names.
- Documentation obligations carried from Codex's r8 review (G3, with the
  deferral): the moduledoc at `lib/sdr_agent/outreach/reply.ex:19`
  promises that the signal commits in the same transaction as the Reply,
  which becomes false on a deferral and must be corrected; the SDR
  `ReplyIntake` moduledoc must describe both T1 and the resumed T2
  (section 6).

**C3-03** (after C3-02 merges): `lead.ex` (`:referred`, `:refer`,
`referred_from_lead_id`, composite FK), `campaign_enrollment.ex`,
`outreach/approval.ex`, `sdr.ex` (`hand_off_referral/2`); new
`sales/checks/referral_context.ex`, `outreach/referral.ex`.

ADR: the identity-key namespace and order spanning Sales, Research and
Outreach is a cross-cutting contract, proposed as the ADR-0009 "C3
amendment" in this PR (accepted by the owner on 2026-10-14). C3-02's
application-transaction lifetime, key-set additions and normalization by
purpose are the ADR-0009 "C3-02 amendment" (accepted by the owner on
2026-10-19, D-176). The rest follows ADR-0009 and ADR-0010.

## 11. Risks

| Risk | Mitigation |
|---|---|
| The key contract touches reviewed Suppression, webhook and override paths | every changed path gets a both-orders race test; Outreach suffix order unchanged; ADR amendment reviewed |
| Strengthened domain suppression stops more leads than today (contacts whose company domain is suppressed but whose email domain differs) | strengthening only; called out for the owner at G5; synthetic tests |
| Existing tests and seeds create two open leads at one account | fixtures admit through the new path; assertions not weakened |
| Migration meets collisions in the owner's dev data | pre-checks abort with counts; nothing merged automatically |
| Metadata-only logging and spans (ADR-0005 C4 amendment) reduce dev debugging detail | table, command, timing, outcome and allowlisted error class stay; agents reproduce values in a synthetic test; reading private values on the owner's dev database with `psql` is owner-only (proposed D-168 summary access grants no raw read) |
| An admission needs a saved offering profile (section 4.5); without one every new request is refused | the owner saves one in `/settings` (C4-01b) before the first admission; the refusal is closed and writes nothing |
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
- **Rebase and drift review (round 6), 2026-10-19.**
  - **Rebase.** Onto `main` at 967a45e, as `09311b5`: 8/8 patches `=`, docs
    only.
  - **Verdict.** Codex NEEDS-REVIEW, narrow (answer
    m_1792385273990083083_33eab6d8; report
    `codex-c301-09311b5-drift-review.md`). The original entity/action PASS
    is retained.
  - **MF1 (C4 settings contract).** New section 4.5, step 8a, the step-16
    rollback, the settings lock inventory (section 6), tests (section 9),
    O10.
  - **MF2 (privacy baseline).** The merged baseline in section 7; the
    separate gates listed; O4's server-log decision stated as the
    operative gate before C3-02 merges.
  - **Other updates.** The header and section 14 now separate
    RED/GREEN/merge. Since D-157 (2026-10-18), merges no longer wait for the
    owner, but the server-log gate still applies. The historical code facts
    are labelled. B2 consumer (O12) and current-main caller inventory (O11)
    added.
  - **Server-log state.** The 5b proposal is #156, pending owner decision.
  - **Records.** The historical records above keep their original SHAs and
    wording.
- **C3-02 D0 (docs, before RED), 2026-10-19.**
  - **Plan.** C3-02 module plan r8 (`claude-c302-plan-r8.md`, sha256
    94fe05cb…), base main `425d7c9`. This packet records its §10.2 D0 items:
    the entity/action delta (section 3.1), the representations and the
    legacy-identity pre-check (section 5.4), the key sets, D3 order,
    per-index list, definition lookup text, boot disposition, reply
    hand-off deferral and its limits, O11 correction and suppression
    boundary (section 6), the C5-04 prerequisite (section 7), and D6
    (`Sales.Checks.LeadAdmissionContext`, sections 3 and 10).
  - **Owner decisions D-174 (2026-10-19), binding.** Q-O1 = A with A.3,
    A.4 and A.5; Q-O2 = refuse (OQ6 (ii)); Q-O3 = a new ADR-0009 amendment,
    not a clarification; Q-O4 = the app does not start; Q-O5 = no wait (only
    the agent hand-off waits); Q-O6 = accept (repeated `www.` refused, and
    the migration stops on such legacy accounts), separate from Q-O3.
  - **Codex review of r8** (`codex-c302-plan-r8-review.md`, request
    m_1792428494601268000_33c16e30). Technical design PASS, no must-fix.
    The formal entity/module gate stays NEEDS-REVIEW solely for these exact
    D0 artifacts and their correlated final review. Its carry-forward notes
    are in sections 6 (retry-horizon qualification and follow-up) and 10
    (moduledoc obligations); its concurrent same-event resume control is a
    RED test item, not a docs item.
  - **ADR-0009 C3-02 amendment: accepted by the owner on 2026-10-19
    (D-176),** through a pre-acceptance conditional on Codex's exact-text
    PASS of the draft (sha256
    149b3c7f0cb115d73d07600b3e71467b08b348e0d6654bfa798736ea3056c371),
    given in review `c1847c86`. The ADR carries exactly that text, with its
    status paragraph rewritten for acceptance. D-174 decided the route
    (Q-O3); it did not itself accept the text. A later substantive edit
    does not inherit the acceptance.
  - **Before C3-02 RED:** these D0 docs; the amendment acceptance (above);
    and Codex's final correlated entity and module review PASS of r8,
    including the reply hand-off deferral, on these exact artifacts.
  - **Verification:** docs-only change; no code, migration or test changed.
- **C3-02 GREEN slices G1–G7, 2026-10-20 to 2026-10-21** (branch
  `c3-02-red`; reviewer Codex via ai-pair; private reviews in the handoff
  `tmp/` directory). Each is a staged slice approval, not GREEN, merge or
  deployment approval:
  - **G1 and G2:** APPROVE at `b41bca1` and `3c833fe`; after the rebase
    onto `14de644`, RED, G1 and G2 re-signed at `7fc693f`
    (`codex-c302-7fc693f-rebase-resign.org`).
  - **G3:** APPROVE at `ec0eab3` (`codex-c302-g3-ec0eab31-review.org`).
  - **G4:** APPROVE at `069a9ff` (`codex-c302-g4-069a9ff-approve.org`).
  - **G5:** PASS at `58571c3`, including the migration up/down/up proof
    (`codex-c302-g5-58571c3-final-review.org`).
  - **G6:** PASS at `b6620d8` (`codex-c302-g6-green-b6620d8-review.org`).
  - **G7:** PASS at `853e399` (`codex-c302-g7-green-853e399-review.org`):
    FULL 3554 passed, 0 failures.
  - **Open:** G8 (negative controls, diagrams, full gate), the #209 rebase
    and equivalence review, exact-head CI, O4's server-log decision (5b,
    #156) and the D-157 merge.

## 14. Next authorized scope (when PASS, ADR acceptance and G5)

Implement C3-02, then C3-03, as reviewed PRs (Claude authors, Codex
reviews, exact-head CI), adjusted by the owner's answers. Each step is
distinct:

1. **RED.** The plan is reviewed (O11 included), then Codex reviews RED.
2. **GREEN.** Then Codex reviews GREEN.
3. **Merge.** Per D-157: Codex's exact-head sign-off, green `verify`, up to
   date. C3-02 also needs O4's server-log decision (5b, #156) recorded first.

Not covered:
- no private inputs until their own gates (section 7);
- no real data until C5-04 merges and the switch is on;
- no ordinary real model calls until R0's conditions hold.

Nothing else.

## 15. Implementation obligations (Codex round-2 qualifications)

These bind C3-02/C3-03 and their reviews. None is satisfied by this docs
packet or by an entity PASS.

| ID | Obligation | Evidence required |
|---|---|---|
| O1 | The key pass is an outer-transaction contract on every caller, not only a Suppression hook: classification and override flows, whole seed and bootstrap transactions, and B6 batches take their full key set before any shared row lock or append. No key or row lock is held while a model call waits. | full-path tests per caller (not the local `AssessmentRules` check alone), asserting the first shared lock follows the pass; a test that a model-call wait holds no key |
| O2 | Held-key state is transaction- and savepoint-aware. `pg_locks` is the authority for held keys; a transaction-local marker (`set_config('sdr.identity_pass', …, true)`, reverted with its savepoint) records that a pass was made, including an empty pass, so a later new key can never become a silent second pass. The whole sorted set is acquired before shared locks. | rollback-to-savepoint tests (keys and marker both reverted, re-pass allowed only then), empty-pass then new key → `LateAcquisition` |
| O3 | One exact domain rule in SQL and Elixir: exactly one trailing dot and one leading `www.` stripped; malformed hosts rejected before normalization. Old audited rows and their record hashes stay untouched. | equivalence corpus (section 9); hash assertions on existing rows |
| O4 | Logging and spans follow C4's ADR-0005 amendment (metadata-only database logging and spans; accepted by the owner on 2026-10-14; merged in C4-01a): `Repo.QueryLog` with `Repo.SafeMetadata`, `Telemetry.RepoSpans` with allowlisted error status and no `db.url` or `db.statement`, `Logger.ExceptionFilter`, `Workers.ErrorBoundary` sanitizing, dev `show_sensitive_data_on_connection_error: false` (section 7). The separate owner-owned PostgreSQL server-log decision (5b, #156) or retention exception is recorded before C3-02 merges, and in force before private inputs and the real-data switch. C3 adds no logger of its own. | canary tests at debug with content capture on over logs, spans and `oban_jobs.errors`; ADR acceptance and the server-log decision recorded before C3-02 merges |
| O5 | Final real-data permission is authoritative at the first-write boundary, including replay output of persisted real records and adopted (not created) rows. If C5 makes the switch a runtime setting, admission reads it `FOR SHARE` after the key pass and before the head, and C5's toggle takes it `FOR UPDATE`, so a toggle waits for in-flight admissions and later ones see the new value; if C5 makes it boot-time configuration, it cannot change within a transaction. "Read twice" alone is not the proof. | a toggle race test on independent connections, matched to C5-04's chosen mechanism |
| O6 | Atomic cutover: the key namespace, every cooperating writer (admission, Suppression, webhooks, Account, Contact, reopen, override) and the migration ship in one release; no deploy mixes the old webhook key and the new namespace. The owner's instance is single-node and restarts on deploy, so no rolling mix exists. | one PR/release; a test that no `hashtextextended` advisory call remains |
| O7 | Seed boundary: `:seed` stays dev/test-only (`SeedingAllowed`); application writes cannot choose `source: fixture` (`:create` accepts only the admission kinds); the DB trigger's fixture exception is a trusted database-admin boundary only. Deferred lead binding and the account slot get direct DB negatives and transaction-rollback proof. | policy tests in prod config; direct SQL negatives |
| O8 | The strengthened company-domain suppression is an owner-visible behaviour change; it stays in the scoped G5 for the owner to accept. No agent approves it. | G5 record |
| O9 | Round-4 test obligations: matched-lead direct-SQL negatives cover both matched outcomes and isolate each negative (only the intended check or FK can fail); readmit tests separate the action's input-presence refusal from the DB restriction on stored `readmit = true`. | direct SQL tests with one violated rule each; readmit tests per kind |
| O10 | Run settings (section 4.5) are C4's existing contract, reused unchanged: <br>- the origin is server-owned (`:assignment` or `:referral`); <br>- the step-8a pre-check runs after replay and before locks; <br>- the snapshot under the head is authoritative and rolls back the whole admission; <br>- no C3 flag, default or input bypasses completeness or budgets; <br>- replay never builds a snapshot; <br>- refusals are closed reasons. | the section 9 run-settings tests (nothing-written counts, origin and budget asserted, replay unchanged, the save race on independent connections) |
| O11 | C3-02's module plan inventories every changed caller and lock order on **current** main, not the historical 182bde6 tables. That includes the C1 command boundary (C1-03) and the C4 settings writers. | the plan's caller/lock table with source line references at its base SHA, reviewed before RED |
| O12 | B2 is a consumer, not a C3 change: <br>- B2's merged requirements (`docs/product/b2/requirements.md` §14) treat the C3 APIs as future work; <br>- B2's `:reconciler` reads only an already committed admission (`reflect_committed_admission/1`), matched on tenant, `source_ref` and the section 5.2 input version and hash, which must agree with what B2's AdmissionIntent stores; <br>- this is no permission to call `admit_lead` as a system actor, and C3-R8 is unchanged; <br>- any LeadAdmission read policy for `:reconciler` is its own reviewed delta, at C3-02 or B2 planning. <br>B2's intent mapping also needs a disposition for `{:settings_incomplete, kinds}` and `:settings_default_unavailable` (section 4.5; not in its `last_error` set at fb54000). That is a B2 planning item. | B2 planning record; a C3-02 test that the stored input hash is the one replay matches |
