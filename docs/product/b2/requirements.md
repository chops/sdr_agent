# B2 requirements: finding a person's contact details (draft 3, owner-accepted wording)

- **Status:** draft 3, Claude author. **The owner accepted the wording** ("accept the draft. proceed", 2026-10-18), with the 11d answers.
- **Next steps:** Codex review, the entity delta (section 14), then the owner's B2 G5.
- **Sources:**
  - the walkthrough of 2026-10-18 (D-163, D-164, D-165);
  - the B2 mockups (#186);
  - the build plan's B2 row.
- **Authority:** this is direction only. It authorizes no build, keys, access, spend or real calls.

All examples use made-up people and companies: Alex Morgan at Lumen Freight, `lumenfreight.example`.

## 1. Scope

B2-07 ("contact candidates via the owner's method") and the contact-finding parts of B2-05 and B2-06. Given one person at one account, the app finds and proposes ways to reach them: email, phone and LinkedIn profile. Each proposal carries its evidence. The owner reviews every proposal before it is used.

Out of scope for now:
- email verification services (a possible later addition, with its own budget);
- the app contacting the company itself (the owner does that personally for now);
- unattended operation.

## 2. The search ladder (the owner's method)

The app looks for email, phone and LinkedIn profile **at the same time**, with the same steps. Steps run in this order, and the ladder stops at the first strong result (rule J). A step needs no paid source the owner hasn't approved.

1. **The company's own website.** A team page, directory, staff page or any page listing the person with contact details.
2. **Name plus email domain.** The search is exactly: `"Alex Morgan" "@lumenfreight.example"`.
   - Every quoted part is a literal quoted phrase in the search. The quotes are required.
   - The domain term always includes the `@`.
3. **The company's email format.**
   - Find at least one other real address at the company, for example `jordan.lee@lumenfreight.example`.
   - Work out its format: first.last, first initial plus last name, and so on.
   - Apply the format to the person (`alex.morgan@lumenfreight.example`), and search for that exact address.
   - A format-derived address is labelled **inferred**, never "found" (rules B and K).
4. **Documents.**
   - `"Alex Morgan" "Lumen Freight" filetype:pdf`
   - `"Alex Morgan" "Lumen Freight" filetype:xls`, and `filetype:xlsx`. These are typically conference or industry-organization contact lists.
5. **The explicit phrase search.**
   - `"Alex Morgan" "Lumen Freight" "email address"`
   - `"Alex Morgan" "Lumen Freight" "phone number"`
6. **Industry organizations** (account-based campaigns). When several target companies belong to one industry organization, read that organization's member or contact listings where they are available and allowed (see the source contract).
7. **LinkedIn**, attended (section 8).
8. **The company's general contact.** If nothing is found for the person, but they are still listed as an employee: the company's generic email, phone or contact form. The app records it at **company** level (rule D) and creates a task for the owner to ask the company to be put in touch. The owner sends it personally.

**Preference:** public, published sources are preferred over data vendors, because the owner has found vendor email quality lower.

## 3. Judging whether a detail is right

**A strong result** (it stops the ladder, rule J) is either:
- contact details taken directly from the company's own website; or
- contact details from another source, **with** strong evidence the person still works there: they're listed in the company's directory or on its team page, or their LinkedIn profile shows them working there.

Anything else is a candidate that keeps the ladder going.

- **Strongest:** the person is listed with the detail on the company's own website.
- **Found elsewhere** (a document, spreadsheet or industry site): the app checks that the person still appears on the company website, or looks actively employed on LinkedIn.
- **When neither check is possible:** the app ranks by the source's publication date. A source from the last few months ranks higher than one from several years ago.
- **The final test is sending without a bounce.** Before any send, a detail is at most owner-approved, never "verified" (rule E).
- **Wording, not scores:** ranking is shown as plain words, for example "listed on the company website", "seen in a 2023 document" or "inferred from the company's format". There are no numeric confidence scores unless the owner asks for them.

## 4. Never-do rules (D-163; all owner-accepted)

1. Never get around logins, CAPTCHAs, access blocks or rate limits, or disguise automation to get past a site's rules.
2. Never use stolen or leaked lists, or any source we can't show we're allowed to use. Stop and ask instead.
3. Never upload contacts or screenshots to an outside AI or enrichment service without approved access, data-handling terms and retention limits. (D-165 adds the app's own model under its amendment.)
4. Never look for private phone numbers, home addresses or sensitive personal details for ordinary business prospecting.
5. Never invent contact details or sources, or call a guessed email "verified".
6. Never overwrite trusted CRM details with a guess.
7. Never contact someone who opted out, or get around a suppression list with another address, account or domain.
8. Never impersonate someone, invent a past relationship, or use misleading sender names or subject lines. That includes receptionists and contact forms.
9. Never send to guessed address formats to see which one doesn't bounce, and never keep mailing an address that bounced.
10. Never call or text against phone rules, such as numbers on do-not-call lists, or without consent where required.
11. Never send outreach or spend paid credits outside approved scope and budget.

The owner rejected "never use personal social media", because "sometimes business owners will use social media to communicate about their businesses". So a business-related social profile is an allowed source, subject to rules 1 to 4.

## 5. What the app keeps (A to I)

- **A. Per detail:**
  - the value and its kind (email, phone, profile link);
  - the source link, the source's publication date and the date found;
  - **seen** or **inferred**. For inferred, which known address the format came from.
- **B. The company's email format,** stored at company level and reused as a clue for other people there, never as proof.
- **C. Right-person evidence:** where and when the person was last confirmed at the company in that role.
- **D. Company contacts** (generic email, phone, contact form), kept separate from the person's own.
- **E. Status, kept separate:**
  - **candidate:** found, not yet reviewed;
  - **owner-approved:** accepted by the owner. This proves nothing about deliverability and is not outreach permission;
  - **verified:** with how and when, for example "sent, no bounce".
- **F. Who accepted or rejected each proposed change, and why.** A new guess never silently replaces a trusted CRM value.
- **G. Do-not-contact signals shown up front:** opt-outs, bounces, use restrictions.
- **H. A work trail:** what was tried, the result, the next step, who owns it and by when. That includes searches that found nothing, so work isn't repeated and "not found" isn't read as "doesn't exist".
- **I. Expiry:** how long details are kept before they're rechecked or removed. Links to evidence are kept, not copies of pages.

## 6. App behaviours (J to P)

- **J. The guided ladder:** section 2, in order, preparing each next search and stopping at the first strong result. Restricted-site steps stay attended.
- **K. Company memory:** formats and recent searches that found nothing, reused across people, with each new address labelled a guess.
- **L. An account summary** that flags possible duplicates, sources that disagree, and same-name people. It never silently picks the first match.
- **M. The review tray:** each proposed detail, with its source, date and "why this person". The owner accepts, rejects or defers it. Nothing changes in the CRM, and nothing is sent, without the owner.
- **N. Warnings before outreach:**
  - old employment information, stale details, bounces and opt-outs;
  - a recheck offered through an approved method.
- **O. Stop limits:** the ladder stops at an agreed time or credit limit and shows the best next step. If only a company contact is found, it offers the company record and the ask-for-help task.
- **P. Shown evidence:** the exact search and source behind every candidate.

## 7. When a suggestion is the wrong person

1. **Wrong role:** set aside for this account and role only, with the reason and source kept.
2. **Left the company:** record the departure, with its date and source; remove them from this account's shortlist; offer a search for their successor. Nothing moves or rechecks automatically.
3. **Same name, different person:** reject this match and remember the specific mismatch. It is not a blanket name exclusion.
4. **Wrong company:** reject the account match, and propose the corrected link for the owner to review. A CRM record is never silently relinked.
5. **Already in the CRM, or already the active target:** link to and show the existing record and its owner. No duplicate target, no automatic merge, no rewritten history.
6. **Bounced:** a hard bounce suppresses that address. A temporary or unclear failure pauses for review. The person is kept, and nothing retries blindly.
7. **"Not the right person, talk to X":** keep the referral evidence, and propose X as an unconfirmed candidate through the referral process (C3). Nothing contacts X automatically, and nothing closes irreversibly.
8. **Opt-out:**
   - "Not interested" closes this opportunity, with no automatic retry.
   - An explicit "stop" suppresses them at the requested scope, across known addresses.
   - Unclear scope means hold for review. Never switch to another of their addresses to get around it.

## 8. LinkedIn (D-164)

- **Fixed steps in the owner's own signed-in browser while the owner watches:** search for the name and company, open the profile, capture the name and profile link.
- **No AI model drives.**
- **Stops and asks** when the page is unexpected or several people match.
- **Stops on any CAPTCHA, security check or rate limit,** with no evasion or disguise.
- **Page content stays on the owner's machine.**
- **Disclosed:** LinkedIn's User Agreement section 8.2 prohibits bots and unauthorized automation, and the account-restriction risk is the owner's. It is not platform permission.

## 9. Citation screenshots (D-110, as amended by D-165, direction only)

- They are stored on the owner's machine, outside the repo, in an ignored folder.
- **Direction (not yet enabled):**
  - the app's own model may see them;
  - backups may include the cloud.
- **Before either is enabled:**
  - a written D-110 and ADR-0014 rule 5 amendment, accepted by the owner;
  - image support, terms and retention confirmed;
  - the witness, projection and calibration impact reviewed;
  - the backup destination, keys, access, deletion and expiry set.
- Development agents never see them.
- Logs and telemetry stay metadata-only (ADR-0005).

## 10. Source contracts (to fill; every field TBD until reviewed)

| Source | Provides | Reached by | Keys or account | Cost, quota and spend approver | Terms and restrictions | Stored | Fails how | Stops on |
|---|---|---|---|---|---|---|---|---|
| Company website | person or company email and phone | page fetch (C5 safe fetch) | none | none | robots.txt and site terms: TBD | detail + source link + date | not found; fetch refused | robots or terms refusal; rate limit |
| Web search (steps 2 to 5) | pages, documents | a search provider API (C5). It must support quoted phrases, `"@domain"` and `filetype:`; which providers do is TBD, to verify | the owner's provider key (C5-01) | per-query quota; budget TBD; owner approves | the provider's terms: TBD | query + result link + date (no raw pages) | quota; no results | quota or budget limit |
| Documents (PDF, XLS) | details in published lists | fetch of a found document | none | none | TBD | detail + document link + publication date | parse failure | size or type limits |
| Industry-organization listings | member contacts | page fetch | possibly a member login: TBD | TBD | **listing terms must allow it** (never-do 1 and 2): TBD | detail + listing link | access denied | logins or blocks (stop, never bypass) |
| LinkedIn (section 8) | name, profile link | the owner's browser, fixed steps, attended | the owner's own sign-in | none | User Agreement 8.2 (disclosed risk) | name + profile link (+ private screenshot) | unexpected page | CAPTCHA, security check, rate limit |
| Company general contact | generic email, phone, form | page fetch | none | none | site terms: TBD | company-level contact + a task for the owner | not found | — |

Every row still needs: retention, role access, allowed processing and export, and what a query discloses to the provider (C5 and ADR-0014).

## 11. Settings (defaults recommended by Claude and Codex; all changeable)

These are provisional starting values, not measured optimums. They are changeable through audited, revisioned settings, like C4's run settings. No setting can override a provider's quota or terms, a C5 budget, an access rule or an attended-step requirement.

| Setting | Default | Notes |
|---|---|---|
| Searches per person | 15 outbound search requests | Retries count. Usage carries over across pause and resume. |
| Active research time per person | 10 minutes | Time waiting on you doesn't count. |
| When the ladder stops | the first strong result, or the ladder exhausted, or a limit reached, whichever first | Then it shows the best next step (rule O). |
| Paid credits | 0 | Until you fund and authorize a source's budget (C5). |
| Contact-detail freshness | 90 days | After that the detail is marked stale and offered for a recheck. |
| Employment freshness before outreach | 30 days | Older evidence needs a recheck first. |
| Unconfirmed candidate expiry | 180 days | Marked expired, never silently deleted. Suppression is never forgotten. |

Rechecks still need approved access and budget. Retention and deletion follow C5.

## 12. Phone (US)

Your prospects are in the US. Before any calling or texting is built, these need review, with your confirmation and, where needed, legal confirmation. This is not complete compliance guidance, and B2B is not assumed to be exempt:
- the federal Do Not Call Registry, state do-not-call lists, and our own internal do-not-call list;
- consent rules, which depend on how a number is dialled or texted (for example autodialled calls and texts to mobiles);
- calling hours in the recipient's local time;
- call-recording consent, which varies by state.

This packet gives no calling or texting authority.

## 13. Industry organizations (owner answers to 11d)

- **Which organizations:** any industry organization relevant to the business or its vertical. The ladder searches for the organizations that type of business is likely to belong to, then reads their member or contact listings.
- **Member sign-in:** some listings need one, but not all.
  - A **public** listing is a normal source, subject to its terms.
  - A listing **behind a member sign-in** is never reached by bypassing it (never-do rule 1). It's used only through your own membership, in your own browser, attended (like LinkedIn, section 8). And only when the organization's terms allow collecting contacts for this use (never-do rule 2). Otherwise it's out.
  - This rule is Claude's reading of your answer, for review at G5.

## 13b. Contract notes (Codex review `2056f8b9`)

These notes are implementation readings of the owner-accepted wording in sections 1 to 13. They don't change that wording. Section 14 is the contract they bind to.

- **Real data (all sections).**
  - Constraint 7's real-data amendment is already accepted (ADR-0014 Amendment 2).
  - What is missing is the implemented and reviewed C5 guard for these paths (C5-04).
  - Until it is on, every B2 ingestion, search, recheck and processing step is refused, on reserved synthetic domains as today. That covers new candidates, evidence, observations, phones, URLs and queries. Already persisted real rows are not processed either (ADR-0014 Amendment 2, rule 2).
- **Stopping on a strong result (§2, §3, rule J).**
  - The ladder looks for email, phone and profile together.
  - Whether one strong result stops the search for every kind, or each kind stops separately, is not decided. It is an owner question (section 14). Meanwhile no search runs beyond the section 11 limits.
- **"Sent without a bounce" (§3, rule E).**
  - It is an observation: it proves neither that the person owns the mailbox nor that they're reachable.
  - Delivery is capture-only under ADR-0014 (constraint 1), so in this phase a captured delivery never produces `verified`, and no verification send or paid verification service is implied.
  - `verified` stays defined, for a future reviewed real-delivery path.
- **"Links to evidence, not copies of pages" (§5 rule I).** This constrains only CandidateEvidence's own fields. The accepted C5 and ADR-0014 flow is unchanged: permitted fetched content is stored as local audit payloads, and model traffic goes to the private witness store.
- **Source permission (§2, §8, §10, §13).**
  - Each source is enabled only after its source contract is reviewed: terms and access, retention, role access, allowed processing and export, and query disclosure.
  - Your risk acceptance is not platform permission. D-164 records direction and the account risk, and never-do rule 2 still applies.
  - Until a source's contract passes, that source is a blocker for the slice that uses it.
- **Paid sources (§10, §11).** A paid search API's quota is not permission for paid enrichment. Paid enrichment stays out (ADR-0014 Amendment 2, rule 3; F1c).
- **Publication dates (§3, rule A).** An unknown publication date stays null. It is never estimated.
- **Screenshots (§8, §9).**
  - This slice defers all screenshot capture.
  - The D-110 local citation screenshot stays a reviewed concept for a later slice, with its own store and linkage.
  - D-165's image processing and cloud backup need their own entity, ADR and C5 approvals.
- **Tasks (§2 step 8, rule O).** The no-email confirmation and ask-the-company tasks are persisted rows (ContactFindingTask, section 14). Showing them on Home needs a separate reviewed C1 producer contract (ADR-0015). This slice adds no C1 producer, counter or H1 change.

## 14. Entity model (B2-05 to B2-07 contact finding)

Entity Model trigger: yes. Reason: new persisted concepts (suggested people, contact-detail candidates and their evidence, observed company addresses, email formats, company contacts, the search budget and trail, owner tasks), new lifecycles and owner-only actions. It also changes existing Contact, Suppression (with its matcher, side effects and identity keys), Decision, settings and delivery-webhook effects.

**Baseline:** `origin/main` `258283d`, plus C3-01 as reviewed documentation (PR #141, `4c1eabb`).
- `Sales.Contact` stores email only (reserved synthetic domains until C5-04).
- Suppression scopes are `email` and `domain`.
- Nothing models candidates, observations or contact-detail evidence.
- **C3-01 is documentation only.** Every reference here to `SDR.admit_lead/2` (C3-02), `SDR.hand_off_referral/2` (C3-03), `LeadAdmission`, `Audit.IdentityKeys` or the identity lock order is to APIs still to be implemented. B2 code that calls them starts only after C3-02 and C3-03 merge.

**Common to every new resource.**
- `id : uuid_v7`; `tenant_id : uuid, required`, set from the actor (ADR-0009, single tenant, no new isolation claim).
- Composite FKs `(x_id, tenant_id)` → `(id, tenant_id)`, all `on_delete: :restrict`. Where a row names both a parent and an account, a DB check or a composite FK enforces that they share the account.
- Every write appends an audit event; there are `trace_id`/`span_id` columns. Auditors never write. `:seed` is dev/test only.
- **Privacy:** names, values, URLs and query text never reach logs, trace attributes, metrics or telemetry content. Only the ADR-0005 allowlist does: opaque ids, bounded counts, fixed error categories. Tests show it for each new path (ADR-0014 Amendment 2, rule 2).
- **Real data:** every ingestion action checks the live real-data guard (C5-04) before its first read and again after its locks, as C3 steps 4 and 9 do. It refuses with `:real_data_disabled`, writing nothing.
- **Reads:** a read follows `Sales.Contact`'s read policy (admin, reviewer and auditor roles, plus named system actors). A read refused by policy is indistinguishable from not found, and fails closed. B2 personal fields get the same treatment as Contact fields in every existing read and export path.
- **Authority:** only the agent runtime (a discovery run) proposes. Only a human admin (the owner) chooses, approves, rejects, confirms or applies. No runtime action changes a Contact, a Lead or the CRM.

| Entity | New / existing | Purpose | Attributes | Relationships | Invariants / lifecycle | Policy / actor | Open questions |
|---|---|---|---|---|---|---|---|
| Research.PersonCandidate | New | A suggested person at an account, before admission (B2-05) | `first_name : string, required, ≤ 80`; `last_name : string, required, ≤ 80`; `person_key : string, required` (lowercased, trimmed, single-spaced `first last`; derived, immutable); `title : string, nullable, ≤ 160`; `status : atom, required, default :suggested, one_of [:suggested, :admission_pending, :admitted, :admission_refused, :set_aside, :rejected, :left_company, :wrong_account, :expired]`; `admission_outcome : atom, nullable` (C3 `LeadAdmission.outcome` set); `last_admission_error : atom, nullable, one_of [:real_data_disabled, :campaign_not_active, :forbidden, :invalid, :source_ref_conflict, :uncertain]`; `disposition_reason : string, nullable, ≤ 500`; `disposition_role : string, nullable, ≤ 160` (set_aside only); `left_on : date, nullable`; `left_source_url : string, nullable`; `proposed_account_id : uuid, nullable` (wrong_account only); `employment_confirmed_at : utc_datetime_usec, nullable`; `revision : integer, required, default 1` (incremented on each transition) | belongs_to Account (required); belongs_to Campaign (required, from the discovery run); belongs_to AgentRun (required, `origin :discovery`); belongs_to Decision (required, kind `:contact_candidate_proposed`, same run); belongs_to LeadAdmission (nullable; the latest); belongs_to Contact and Lead (nullable; set only from an `admitted` admission); has_many ContactCandidate, CandidateEvidence (kind `:employment`), ContactSearchCycle, ContactFindingTask | Non-unique by design: a duplicate suggestion of the same `person_key` at the same account shares its search cycle and remembers prior mismatches. **Transitions** (each bumps `revision`):<br>`suggested` → `admission_pending` (owner chooses, with an owner-approved email; section 14 confirm), or → `set_aside` (wrong role; scoped to account + `disposition_role`), `rejected` (same name, different person; the mismatch kept), `left_company` (needs `left_on` or `left_source_url`), `wrong_account` (needs `proposed_account_id`; proposes, never relinks) or `expired` (system, `candidate_expiry_days`).<br>`admission_pending` → `admitted`, or → `admission_refused` (with `admission_outcome`), or stays pending (with `last_admission_error`).<br>`admission_refused` → `admission_pending` only via owner `:retry_admission` with a **different** owner-approved email candidate (a new `source_ref`).<br>`admitted`, `set_aside`, `rejected`, `left_company`, `wrong_account` and `expired` are terminal. Expiry never deletes. `chosen` never implies admitted. A person with no owner-approved email can't be confirmed: the owner's choice creates a `:confirm_email` task instead (C3 §4.1; never a placeholder address). | `:propose` — agent runtime (discovery run, with a decision). `:confirm`, `:retry_admission`, `:set_aside`, `:reject`, `:mark_left`, `:mark_wrong_account` — admin only, each with `expected_revision`. `:expire` — scheduler system actor. Read: Contact read policy. | — |
| Research.ContactCandidate | New | One proposed way to reach a person (B2-07) | `kind : atom, required, one_of [:email, :phone, :profile_url]`; `value : string, required, normalized per kind` (email: trimmed, lowercased, `local@host`; phone: E.164; profile_url: the URL normalization below); `status : atom, required, default :candidate`, per kind:<br>email `one_of [:candidate, :owner_approved, :verified, :bounced, :suppressed, :rejected, :expired]`;<br>phone and profile_url `one_of [:candidate, :owner_approved, :suppressed, :rejected, :expired]`;<br>`provenance` is a **calculation** (`:seen` if any `:seen` evidence, else `:inferred`); `decision_reason : string, nullable, ≤ 500` (required for `:rejected`); `decided_by_user_id`, `decided_at : nullable`; `verified_how : atom, nullable, one_of [:delivered_no_bounce]`; `verified_at : nullable`; `bounced_at : nullable`; `revision : integer, required, default 1` | belongs_to PersonCandidate (required) and Account (required; must equal the parent's account: composite FK `(person_candidate_id, account_id, tenant_id)`); belongs_to CompanyEmailFormat (nullable; allowed only when `kind = :email`, and the format's account must equal `account_id`); belongs_to AgentRun and Decision (required, as for the parent); has_many CandidateEvidence (kind `:detail`) | **Identity:** unique `(tenant_id, account_id, kind, value)`. A re-observation appends evidence to the existing row and never creates a second one. A value already held for another person is refused, the attempt recorded as `value_claimed`, and flagged for review (rule L). **No resurrection:** `rejected`, `suppressed` and `bounced` are terminal; `expired` reopens to `candidate` only by owner `:reconsider`.<br>**Transitions:** `candidate` → `owner_approved` (owner) only if the parent is `suggested` or `admission_pending`, the value matches no Suppression, the parent's Contact (if any) has no `do_not_contact_at`, under the identity keys (C3 §6). `candidate`/`owner_approved` → `rejected` (owner), `expired` (system).<br>**Email only:** `owner_approved` → `verified` only from a reviewed real-delivery observation (none in this phase, since delivery is capture-only); `owner_approved`/`verified` → `bounced` on a hard bounce (and an `:email` Suppression `hard_bounce`). `verified` is no escape: any matching Suppression moves any status except `rejected` and `expired` to `suppressed`.<br>**Phone and profile:** no verification state; verification mechanisms are deferred. Staleness is a calculation (`detail_freshness_days`), not a status. An approved value is not send permission. | `:propose` — agent runtime. `:approve`, `:reject`, `:reconsider` — admin, with `expected_revision`. `:expire` — scheduler. `:mark_verified` — none in this phase. `:mark_bounced` — webhook ingestor. `:mark_suppressed` — inside a Suppression create only (ApplySuppression). Read: Contact read policy. | — |
| Research.CandidateEvidence | New | Why we believe a detail or an employment fact (rules A, C, P) | `kind : atom, required, one_of [:detail, :employment]`; `method : atom, required, one_of [:company_site, :name_domain_search, :format_inference, :document_pdf, :document_sheet, :phrase_search, :industry_listing, :linkedin_attended, :company_general]`; `provenance : atom, required, one_of [:seen, :inferred]` (`:inferred` only with `method :format_inference`); `source_url : string, required` (normalized as below; for `:format_inference`, the observation's source); `published_on : date, nullable` (unknown stays null); `found_at : utc_datetime_usec, required`; `query : string, nullable, ≤ 500` (stored locally only, never logged); `source_ref_hash : string, required` (sha256 of the normalized URL + method) | belongs_to exactly one of ContactCandidate (`kind :detail`) or PersonCandidate (`kind :employment`): DB check `num_nonnulls = 1` plus kind/parent agreement. belongs_to EmailObservation (required if and only if `method :format_inference`); belongs_to ContactSearchRequest (required, the request that found it) | **Immutable** (append-only trigger). Unique `(tenant_id, parent, method, source_ref_hash)`: replaying the same observation adds nothing. Seen and inferred evidence for one value coexist, and neither overwrites the other. Ranking wording is derived from method, provenance and dates (section 3); there's no numeric score. **URL normalization:** lowercase scheme and host, strip the default port, the fragment, a trailing `/` and tracking parameters (`utm_*`); keep the path's case and the other query parameters. Hosts pass the real-data guard. | `:record` — agent runtime, inside the request's step. Read: Contact read policy. | — |
| Research.EmailObservation | New | Another employee's address, seen on a source, used only to learn the company's format (rule B), without making that employee a target | `value : string, required` (normalized email; its domain must equal the account's canonical domain); `name_on_source : string, nullable, ≤ 160` (as printed; never becomes a PersonCandidate unless separately proposed); `source_url : string, required`; `published_on : date, nullable`; `found_at : required` | belongs_to Account (required); belongs_to ContactSearchRequest (required) | **Immutable.** Unique `(tenant_id, account_id, value, source_url)`. **Seen only:** an observation is never derived from an inferred address, so inference can't bootstrap itself. A value matching a Suppression is still recorded, as a fact about the format, but never proposed to anyone. | `:record` — agent runtime. Read: Contact read policy. | — |
| Research.CompanyEmailFormat | New | The account's email pattern: a reusable clue, never proof (rules B, K) | `pattern : atom, required, one_of [:first_dot_last, :first_initial_last, :first, :first_last_initial, :first_underscore_last, :last_dot_first, :first_last, :last_first_initial]`; `observed_at : required` | belongs_to Account (required); belongs_to EmailObservation (required; same account, composite FK); has_many ContactCandidate (inferred emails) | **Immutable.** Unique `(tenant_id, account_id, pattern)`. Derived only from a seen EmailObservation of the same account. A candidate built from it carries `:inferred` evidence that names the format and its observation. Inference applies to email only. | `:derive` — agent runtime. Read: Account read policy. | — |
| Research.CompanyContact | New | The company's general email, phone or contact form (rule D, ladder step 8) | `kind : atom, required, one_of [:email, :phone, :form_url]`; `value : string, required` (normalized per kind); `source_url : required`; `found_at : required` | belongs_to Account (required); belongs_to ContactSearchRequest (required) | **Immutable.** Unique `(tenant_id, account_id, kind, value)`. Never linked to a person, and never a ContactCandidate. Finding one for a person with nothing else found creates a `:ask_company` task. | `:record` — agent runtime. Read: Account read policy. | — |
| Research.ContactSearchCycle | New | The budget subject: one bounded research cycle for one person (rule O, section 11) | `cycle : integer, required, ≥ 1`; `max_requests : integer, required` and `max_active_ms : integer, required` (copied from the run's settings snapshot at open); `requests_reserved : integer, required, default 0`; `active_ms_charged : integer, required, default 0, ≥ 0`; `status : atom, required, default :open, one_of [:open, :exhausted, :strong_result, :limit_reached, :closed]`; `opened_by : atom, required, one_of [:discovery, :owner_recheck]` | belongs_to Account (required); `person_key : string, required` (with the account: the budget subject, shared by duplicate suggestions); belongs_to AgentRun (required); belongs_to RunSettingsSnapshot (required; the pinned revision) | Unique `(tenant_id, account_id, person_key, cycle)`. Only one `:open` cycle per subject (partial unique). A new cycle (cycle + 1) opens only by owner `:recheck` (an explicit, authorized research cycle) or by a new discovery run after the prior cycle closed. Counters are **never reset or decremented**. Usage survives restarts, pause and resume, and duplicate suggestions. A settings change affects only cycles opened later. | `:open` — agent runtime (discovery) or admin (`:recheck`). Counters change only via ContactSearchRequest reservation. Read: admin, reviewer, auditor. | — |
| Research.ContactSearchRequest | New | The pre-dispatch reservation and the work trail (rules H, O) | `step : atom, required` (the CandidateEvidence `method` set); `query : string, nullable, ≤ 500` (local only); `attempt : integer, required, default 1` (retries are new rows); `status : atom, required, one_of [:reserved, :completed, :uncertain]`; `result : atom, nullable, one_of [:found, :nothing, :error, :refused_by_terms, :value_claimed]`; `lease_ms : integer, required` (`≤` the remaining active budget); `active_ms : integer, nullable, ≥ 0`; `next_step : atom, nullable`; `owner_user_id : uuid, nullable`; `due_at : nullable`; `reserved_at : required`; `completed_at : nullable` | belongs_to ContactSearchCycle (required); belongs_to PersonCandidate (nullable; set when person-specific) | **Reservation, before any network dispatch:** in one transaction, lock the cycle row `FOR UPDATE`, refuse if `requests_reserved + 1 > max_requests` or `active_ms_charged + lease_ms > max_active_ms`, else increment both and insert `:reserved`. Two workers serialize on the cycle row, so the last allowed request is dispatched at most once. Each retry is a new reservation and is charged.<br>**Completion** records `active_ms` (measured monotonic duration of active work only; waiting on the owner is excluded; `≤ lease_ms`) and refunds nothing.<br>**Crash or uncertain:** a reservation still `:reserved` after its lease is reconciled to `:uncertain` by a reconciler and stays fully charged (the request may have been sent). It is never retried under the same row.<br>**Account-level steps** made for a person (company site, format, industry listing) are charged to that person's cycle. Reusing a stored result (a format, a company contact) costs nothing.<br>**Replay identity:** `(cycle, step, query, attempt)`; a duplicate reservation is refused. Append-only except the one `:reserved` → `:completed`/`:uncertain` step. `:nothing` is never read as "doesn't exist". | `:reserve`, `:complete` — agent runtime. `:reconcile` — reconciler system actor. Read: admin, reviewer, auditor. | — |
| Sales.ContactFindingTask | New | An owner task from contact finding (§2 step 8; C3 §4.1 no-email) | `kind : atom, required, one_of [:confirm_email, :ask_company]`; `status : atom, required, default :open, one_of [:open, :done, :dismissed, :superseded]`; `note : string, nullable, ≤ 500` (owner's); `closed_at : nullable` | belongs_to Account (required); belongs_to PersonCandidate (required; same account); belongs_to CompanyContact (required if and only if `:ask_company`) | Dedupe: at most one `:open` task per `(tenant, kind, person_candidate)` (partial unique). Creation is idempotent: a replay returns the open task. `:open` → `:done` or `:dismissed` (owner), or → `:superseded` (system, when the person is admitted or terminally disposed). Terminal otherwise. Never sends anything; the owner contacts the company personally. | `:open` — the system, inside the PersonCandidate or CompanyContact action that needs it. `:done`, `:dismissed` — admin. Read: admin, reviewer, auditor. Home display needs a separate C1 producer review. | — |
| Sales.Contact | Existing (delta) | Gains owner-applied phone and profile, and a person-wide stop | `phone : string, nullable` (E.164); `profile_url : string, nullable` (normalized as above); `do_not_contact_at : utc_datetime_usec, nullable` (set once; never cleared by any agent or system actor) | inverse has_many ContactCandidate via PersonCandidate (read only) | **New action `:apply_contact_detail` (admin):**<br>- **Inputs:** `contact_candidate_id`, `expected_candidate_revision`, `expected_contact_updated_at`.<br>- **Under the identity keys** (`email:`/`domain:`/`phone:`; C3 §6) it rechecks that the candidate is `owner_approved` and of kind phone or profile; the parent is `admitted` with this contact; contact and account are active; the value and revision match; no Suppression matches; and `do_not_contact_at` is null.<br>- **Then** it sets the field and audits old and new. On any mismatch it returns `:conflict` and writes nothing.<br>Email changes keep using `:change_email` under the same rechecks. A person-wide stop sets `do_not_contact_at` and creates `:email` Suppressions for every known email of the contact. Later-linked addresses of a stopped contact are refused at approval and suppressed. | Admin only, as `:change_email`. The person-wide stop: admin `:stop_contact`, or the existing reply-classification suppression path (agent runtime with a checked Decision). | — |
| Sales.Account | Existing (delta) | Owns the account-level concepts | — | new inverse has_many PersonCandidate, EmailObservation, CompanyEmailFormat, CompanyContact, ContactSearchCycle, ContactFindingTask | Archived accounts take no new proposals, observations, cycles or tasks. Existing rows stay readable. | unchanged | — |
| Outreach.Suppression, SuppressionMatch, ApplySuppression, Audit.IdentityKeys | Existing (delta) | Phone do-not-contact, and suppression reaching candidates | `scope` gains `:phone` (`value` in E.164; DB check); `reason` unchanged | unchanged | Phone: add-only, append-only, as today. It restricts only; no calling or texting exists. Creation: admin `:manual` only in this slice.<br>`IdentityKeys` gains `phone:<e164>`. `SuppressionMatch` covers `:phone` against Contact `phone` and phone candidates.<br>**ApplySuppression** additionally moves matching ContactCandidates to `:suppressed`. A `:domain` suppression covers email candidates at that domain.<br>Suppression and candidate approval or apply serialize on the identity keys, so either order ends safely: approval after a suppression is refused, and a suppression after an approval suppresses it. A hard bounce (webhook) suppresses that address only. A person-wide stop is the Contact `do_not_contact_at` path above. | unchanged actors; `:phone` via `:manual` (admin). | Phone suppression from reply classification: later, with calling. |
| Sales.LeadAdmission and Sales.Lead (C3-01 documented; C3-02 and C3-03 to implement) | Existing dependency (delta) | Admission of a confirmed person, and referral | — | LeadAdmission gains an inverse from PersonCandidate (read only) | **Confirm** (admin) calls `SDR.admit_lead/2` with: `source_kind :agent_found`; `source_ref agent_found:<discovery run>:<approved email ContactCandidate id>`; `campaign_id` (the candidate's); `agent_run_id`; the approved email. It then records the stored admission on the PersonCandidate.<br>**Uncertain outcomes:** a timeout or crash leaves `admission_pending` with `:uncertain`. A retry replays the same `source_ref` and hash, so it returns the stored result and never makes a second admission.<br>**Outcome mapping:** `admitted` → `admitted`. `duplicate_open_lead`, `active_target_exists`, `previously_worked`, `company_in_relationship`, `contact_at_other_account`, `contact_archived`, `account_archived` and `suppressed` → `admission_refused`, with the outcome and a link to the matched lead or contact (wrong-person case 5: link, never merge). Closed errors stay pending with `last_admission_error`.<br>**Referral** (case 7) goes only through C3-03 `hand_off_referral/2`, whose successful handover atomically closes the original as `referred`. B2 never closes it, nor promises it stays open. | Admin (C3 step 1 requires an active admin requester). | C3-02 and C3-03 must merge before B2 code. |
| Agents.Decision and Agents.AgentRun | Existing (delta) | Typed provenance for runtime proposals | Decision `kind` gains `:contact_candidate_proposed` (agent runtime in `kind_actors`; payload metadata only: counts and ids) | unchanged | Every runtime create (proposal, evidence, observation, format, company contact, request) names its run (`origin :discovery`, the same tenant) and, for proposals, a decision of that run. A run that is not `:discovery` is refused. | Agent runtime records its own kind only. | — |
| Agents settings (SettingsRevision `:operational_limits`, RunSettingsSnapshot; C4) | Existing (delta) | Section 11 defaults, audited and revisioned | `:operational_limits` gains `contact_search_requests` (15), `contact_search_active_minutes` (10), `contact_paid_credits` (0), `detail_freshness_days` (90), `employment_freshness_days` (30), `candidate_expiry_days` (180), each range-checked | unchanged | Agents read them only from their run's snapshot (`RunSettings.allowance/2`). A cycle copies its limits at open. No setting funds a source or overrides C5 budgets, provider quotas or terms, access rules or attended-step gates. `contact_paid_credits > 0` grants nothing without a C5 budget. | As C4 (admin edits revisions). | — |
| Outreach delivery and webhook effects | Existing (delta) | Email candidate state from delivery outcomes | — | unchanged | The hard-bounce webhook path also marks a matching email ContactCandidate `:bounced` (same transaction as its Suppression). A captured delivery never marks `verified` (capture-only). | webhook ingestor (existing). | — |
| Accounts.User | Existing dependency | Owner identity on decisions and tasks | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found | — | — |
| Research.EvidenceClaim | Existing dependency | Lead qualification evidence | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found | — | — |
| Home inbox (C1 InboxItem, ADR-0015) | Existing dependency | Where owner tasks would show | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found (no producer added; a ContactFindingTask producer needs its own C1 review) | — | — |

### Out of this slice

- All screenshot capture: the D-110 local citation and the D-165 image and cloud direction.
- Phone and profile verification.
- Any calling or texting.
- Paid enrichment.
- Email verification services.
- A C1 producer for tasks.

### Owner questions (new)

1. **Strong result across kinds.** The ladder looks for email, phone and LinkedIn profile together. When it finds a strong result for one kind (say a phone number on the company website), should it stop for all kinds, or keep going for the kinds still missing (especially email, which admission needs), within the same limits?
2. **Person-wide "stop".** When someone asks not to be contacted, should the stop also cover any address we find for them later? (Proposed: yes. All their known addresses are suppressed, and any later one is refused and suppressed.)

### Soft-stop review record

- **Capabilities:** `.workflow/recipe.json` `ai_pair=true`, `codex_review=true`.
- **Reviewer:** Codex, through ai-pair.
- **Round 1:** NEEDS-REVIEW on 2026-10-18 (UTC, review of head `2056f8b`), correlation `m_1792361161434085042_8bd95445`, report `codex-b202-2056f8b9-review.md`.
- **Round 2:** this revision, resubmitted for review. Only an explicit PASS releases the soft stop. Until then, no affected-module planning or build.
