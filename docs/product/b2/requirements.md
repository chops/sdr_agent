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

## 14. Entity model (B2-05 to B2-07 contact finding)

Entity Model trigger: yes. Reason: new persisted concepts (person and contact-detail candidates, their evidence, company email formats, company contacts and the search trail), new lifecycles, and owner-only approval actions. It also changes existing Contact, Account and Suppression relationships.

The baseline is `origin/main` `258283d`:
- `Sales.Contact` stores email only, which must currently be a reserved synthetic domain.
- Suppression scopes are `email` and `domain`.
- Nothing models candidates or contact-detail evidence.
- C3-01 (PR #141, docs only) adds `LeadAdmission` (including `agent_found` and referral) and the one-open-lead-per-account rule.

**Common to every new resource.** Each has a `tenant_id` set from the actor (ADR-0009, single tenant). Keys are UUIDv7, and every write appends an audit event. Auditors never write, and `:seed` is dev/test only. Query text, names and values never go to logs or telemetry: metadata only (ADR-0005; section 9).

| Entity | New / existing | Purpose | Attributes | Relationships | Invariants / lifecycle | Policy / actor | Open questions |
|---|---|---|---|---|---|---|---|
| PersonCandidate | New | A suggested person at an account, before admission (B2-05) | `first_name`, `last_name` (required); `title` (nullable); `status` (required, default `suggested`); `disposition_reason`, `disposition_scope_role` (nullable; required by a disposition); `employment_confirmed_at`, `employment_source_url` (nullable) | belongs_to Account (required, restrict); has_many ContactCandidate, CandidateEvidence (kind `employment`) and SearchAttempt; `contact_id` (nullable) once admitted through C3 `LeadAdmission` (`agent_found`) | `suggested` → `chosen` (the owner picks; the admission is requested); `suggested` → `set_aside` (wrong role, scoped to the account and role), `rejected` (same name, different person), `left_company` (with a date and source), or `wrong_account` (proposes a relink, never applies one). `chosen` and the rejection states are terminal for this suggestion. A new suggestion for the same name is allowed, carrying the remembered mismatch. Never auto-admitted. | Created by the agent runtime with a `decision_id`. Every transition is admin-only (the owner). Read by admin, reviewer, auditor and the agent. | Admission needs an email (C3 §4.1). Is a chosen person with no approved email held as a task? (proposed: yes) |
| ContactCandidate | New | One proposed way to reach a person (B2-07) | `kind` (`email`, `phone`, `profile_url`; required); `value` (ci_string, required, normalized per kind); `provenance` (`seen`, `inferred`); `status` (required, default `candidate`); `decision_reason` (required when rejected); `decided_by_id`, `decided_at`; `verified_how`, `verified_at` (nullable) | belongs_to PersonCandidate (required); has_many CandidateEvidence; belongs_to CompanyEmailFormat (required if and only if inferred) | Unique `[tenant, person_candidate, kind, value]`. `candidate` → `owner_approved` (the owner, with a reason, in the review tray) or `rejected` (with a reason) or `expired` (system, after 180 days by default; never deleted). `owner_approved` → `verified` (delivery evidence: sent, no bounce; never inferred), or `bounced` (a hard bounce also creates an `email` Suppression, `hard_bounce`). A temporary failure stays `owner_approved` and is flagged for review. A value matching any Suppression cannot be approved. Staleness is a calculation (90 days for details, 30 for employment before outreach; section 11), not a status. | Created by the agent runtime. Approve and reject are admin-only. `verified` and `bounced` come only from the delivery and webhook actors. Never written to Contact or the CRM without an owner action (rule F). | — |
| CandidateEvidence | New | Why we believe a candidate or an employment fact (rules A, C, P) | `kind` (`detail`, `employment`); `source_url` (required); `published_on` (date, nullable); `found_at` (required); `method` (ladder step, required); `query` (the exact search, nullable; stored locally, never logged); `excerpt` (no; links only, rule I) | belongs_to ContactCandidate or PersonCandidate (exactly one; DB check) | Append-only, many per candidate. Rank wording is derived from the method and dates (section 3); no numeric score. | Created by the agent runtime; read like its parent. | Retention of query text (C5) |
| CompanyEmailFormat | New | The account's email pattern, a reusable clue (rules B, K) | `pattern` (enum: `first.last`, `flast`, `first`, `firstl`, `first_last`, `last.first`, …); `observed_from_candidate_id` (required); `observed_at` | belongs_to Account (required); has_many inferred ContactCandidate | Unique `[tenant, account, pattern]`. Never proof: candidates derived from it are always `inferred`. | Created by the agent runtime; read by admin, reviewer, auditor and the agent. | — |
| CompanyContact | New | The company's generic email, phone or contact form (rule D, ladder step 8) | `kind` (`email`, `phone`, `form_url`); `value`; `found_at`, `source_url` | belongs_to Account (required) | Kept separate from any person. Finding one creates an owner task to ask for an introduction; the owner sends it personally. | Created by the agent runtime; read like Account. | Where the task lives: the Home inbox (C1)? |
| SearchAttempt | New | The work trail and the limit counter (rules H, O) | `step` (ladder enum); `query` (local only); `result` (`found`, `nothing`, `error`, `limit_reached`, `stopped_by_terms`); `requests_used` (int ≥ 0, retries count); `active_ms`; `next_step`; `owner_id` (User, nullable); `due_at` | belongs_to PersonCandidate or Account (exactly one) | Append-only. The sum of `requests_used` and `active_ms` per person enforces the defaults (15 requests, 10 active minutes), carried across pause and resume. A `nothing` result is never read as "doesn't exist". | Created by the agent runtime; read by admin, reviewer and auditor. | — |
| Sales.Contact | Existing (changed) | Gains approved phone and profile fields | `phone` (nullable); `profile_url` (nullable) | unchanged | Set only by an owner-approved ContactCandidate, through an audited action, like `:change_email`. Never silently replaced (rule F). | Admin only, as `:change_email`. | The real-data guard: `email` and `Account.domain` are reserved-synthetic-only today. Real prospects need the C5 real-data guard and the constraint 7 amendment first. |
| Sales.Account | Existing (changed) | Owns the new account-level concepts | unchanged | has_many PersonCandidate, CompanyEmailFormat, CompanyContact, SearchAttempt | Archived accounts take no new candidates. | unchanged | — |
| Outreach.Suppression | Existing (changed) | Do-not-contact for phones (never-do 10, rule G) | `scope` gains `phone` (E.164-normalized) | unchanged | Phone suppression blocks approval of a matching phone candidate, and any calling or texting. Append-only, as today. | As today. | Add `phone` scope now, or when calling is built? (proposed: now, add-only) |
| Sales.Lead / LeadAdmission (C3-01) | Existing dependency | Admission of a chosen person | unchanged by B2 | PersonCandidate `chosen` → `LeadAdmission` `agent_found`; referral → C3 `hand_off_referral` (wrong-person case 7) | `active_target_exists` and duplicate outcomes map to wrong-person case 5 (link, never merge). | As C3-01. | C3-01 must merge first. |
| Settings (C4) | Existing dependency | The section 11 defaults | the new keys: `contact_search_requests`, `contact_search_active_minutes`, `paid_credits`, `detail_freshness_days`, `employment_freshness_days`, `candidate_expiry_days` | — | Audited and revisioned; never override provider quotas, terms or C5 budgets. | Admin. | Which C4 settings resource? |

**Citation screenshots** (section 9) have no entity until D-165's amendment is accepted.
