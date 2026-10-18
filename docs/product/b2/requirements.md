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

## 13b. Contract notes (Codex reviews `2056f8b9`, `e273c68a`)

These notes are implementation readings of the owner-accepted wording in sections 1 to 13. They don't change that wording; section 14 is the contract they bind to.

- **Real data (all sections).** Constraint 7's real-data amendment is already accepted (ADR-0014 Amendment 2). What is missing is the implemented and reviewed C5 guard for these paths (C5-04), which is a prerequisite for real enablement. While the guard is off:
  - **Allowed:** synthetic behaviour on reserved names, exactly as today: `.test`, `.example`, `.invalid`, `example.com/.net/.org` domains and emails, synthetic E.164 phone fixtures in the reserved 555-01xx range, and `.example` profile and source URLs. The hermetic implementation and test workflow runs entirely on these.
  - **Refused, with `:real_data_disabled` and nothing written:**
    - ingesting any real value (candidate, evidence, observation, company contact, phone, URL);
    - **dispatching any real query** (the guard is checked on the query's terms and target before reservation, not only on the result row);
    - any processing, recheck or admission of an already persisted real row.
- **Stopping on a strong result (§2, §3, rule J).** The ladder looks for email, phone and profile together. **Owner answer (D-167): keep looking.** A strong result stops the search for **that kind** only. The ladder keeps going for the kinds still missing (email first, because admission needs it). A cycle ends when every kind has a strong result, the ladder is exhausted, or a section 11 limit is reached. It never runs beyond those limits, and a strong result for one kind never resets or extends them.
- **"Sent without a bounce" (§3, rule E).** This is an observation. It proves neither that the person owns the mailbox nor that they can be reached. Delivery is capture-only under ADR-0014 (constraint 1), so in this phase a captured delivery never produces `verified`. Nothing here implies a verification send or a paid verification service. `verified` stays defined for a future reviewed real-delivery path, which would record its method, time and limits.
- **"Links to evidence, not copies of pages" (§5 rule I).** This constrains only CandidateEvidence's own fields. The accepted C5 and ADR-0014 flow is unchanged: permitted fetched content is stored as local audit payloads, and model traffic goes to the private witness store.
- **Decision payloads.** Decision payloads are metadata only: counts and ids. A Decision may point to private input payloads, but it never becomes a path to log, query or name their content.
- **Source permission (§2, §8, §10, §13).**
  - Each source is enabled only after its source contract is reviewed: terms and access, retention, role access, allowed processing and export, and query disclosure. This entity packet approves no source.
  - Your risk acceptance is not platform permission. D-164 records direction and the account risk; never-do rule 2 still applies; the D-164 and D-165 gates stay.
  - Until its contract passes, a source is a blocker for the slice that uses it.
- **Paid sources (§10, §11).** A paid search API's quota is not permission for paid enrichment. Paid enrichment stays out (ADR-0014 Amendment 2, rule 3; D-041).
- **Publication dates (§3, rule A).** An unknown publication date stays null. It is never estimated.
- **Screenshots (§8, §9).** This slice includes no screenshot handling of any kind. The D-110 local citation screenshot stays a reviewed concept for a later slice, with its own store and linkage. D-165's image processing and cloud backup need their own entity, ADR and C5 approvals.
- **Tasks (§2 step 8, rule O).** The no-email confirmation and ask-the-company tasks are persisted rows (Research.ContactFindingTask, section 14). Showing them on Home needs a separate reviewed C1 producer contract (ADR-0015). This slice adds no C1 producer, counter, Home or H1 change.
- **Later plan obligations.** Every completion, error and stop transition is an idempotent guarded action, with race and error tests. That belongs to the affected-module plan; nothing is implemented here.

## 14. Entity model (B2-05 to B2-07 contact finding)

Entity Model trigger: yes. Reason:
- new persisted concepts: research subjects, suggested people, contact-detail candidates and their evidence, observed company addresses, email formats, company contacts, the search budget and trail, admission intents, and owner tasks;
- new lifecycles and owner-only actions;
- changes to the existing Contact, Suppression (and its matcher, side effects and identity keys), Decision, settings and delivery-webhook effects.

**Baseline:** `origin/main` `258283d`, plus C3-01 as reviewed documentation (PR #141, `4c1eabb`).
- `Sales.Contact` stores email only, on reserved synthetic domains until C5-04.
- Suppression scopes are `email` and `domain`.
- Nothing models candidates, observations or contact-detail evidence.
- **C3-01 is documentation only.** Every reference here to `SDR.admit_lead/2` (C3-02), `SDR.hand_off_referral/2` (C3-03), `LeadAdmission`, `Audit.IdentityKeys` or the identity lock order is to an API still to be implemented. B2 code that calls them starts only after C3-02 and C3-03 merge.

**Domain layering (ADR-0009 §7: `Audit <- Accounts <- Operations <- Agents <- Sales <- Research <- Outreach`).**
- **Every new resource is in Research.** It holds FKs only to the lower Research, Sales, Agents and Accounts resources.
- **Lower to higher:** a lower domain never holds an FK to a higher one. Sales.Contact does not reference Research, and Research does not reference Outreach. Where a lower row needs a higher id, it stores a plain uuid, validated by the orchestrating action.
- **Multi-domain operations** are orchestrated at the existing `SdrAgent.SDR` interface, as C3 places `SDR.admit_lead/2`:
  - `SDR.confirm_person/2`;
  - `SDR.settle_admission/2`;
  - `SDR.apply_contact_detail/2`;
  - `SDR.stop_contact/2`;
  - the review-tray read `SDR.contact_candidates/2`.

  Each calls the owning domain's guarded action, with an explicit actor. No domain action calls a higher domain.

**Common to every new resource.**
- **Keys and tenancy:** `id : uuid_v7`; `tenant_id : uuid, required`, set from the actor (ADR-0009, single tenant, no new isolation claim).
- **Foreign keys:** composite FKs `(x_id, tenant_id)` → `(id, tenant_id)`, all `on_delete: :restrict`. Where a row names both a parent and an account, a composite FK that includes `account_id` enforces that they share the account.
- **Audit:** every write appends an audit event, with `trace_id` and `span_id` columns. Auditors never write. `:seed` is dev/test only.
- **Actors are explicit:**
  - an admin user (the owner);
  - `%SdrAgent.Actor{}` system actors (ADR-0009 §8): `:agent_runtime` (a discovery run), `:scheduler`, `:reconciler`, `:webhook_ingestor`.

  There is no generic "system" actor. A row created inside an admin's action is attributed to that admin.
- **Privacy:** names, values, URLs and query text never reach logs, trace attributes, metrics or telemetry content. Only the ADR-0005 allowlist does: opaque ids, bounded counts, fixed error categories. Tests show it for each new path (ADR-0014 Amendment 2, rule 2).
- **Real data:** every ingestion and every dispatch checks the live real-data guard (C5-04) before its first read and again after its locks, as C3 steps 4 and 9 do (section 13b).
- **Reads:** a read follows `Sales.Contact`'s read policy (admin, reviewer and auditor roles, plus the named system actors). A read refused by policy is indistinguishable from not found and fails closed. Every auditor view is audited. B2 personal fields get the same treatment as Contact fields in every existing read and export path.
- **Authority:** the agent runtime only proposes, observes and searches. A human admin chooses, approves, rejects, confirms, applies and rechecks. A runtime actor changes a Contact in exactly one case: the person-wide stop of `SDR.stop_contact/2`, from a checked reply Decision bound to that Contact (Sales.Contact row below). No runtime action changes a Lead or the CRM.
- **Observations are immutable; decisions change state.** Observation rows (evidence, email observations, formats, company contacts, requests once completed) are append-only. An admission intent's input, hash and provenance are immutable; its only changes are the listed one-way control fields (`:pending` → settled outcome, `settled_at`). Mutable state lives only in subjects, candidates, cycles and tasks. It changes only through guarded actions carrying `expected_revision`, and returns `:conflict` on a stale revision.

| Entity | New / existing | Purpose | Attributes | Relationships | Invariants / lifecycle | Policy / actor | Open questions |
|---|---|---|---|---|---|---|---|
| Research.ResearchSubject | New | The stable identity of one real person at an account: the budget subject and the history holder. Names are hints, not identity (§7 case 3). | `first_name_hint`, `last_name_hint : string, required, ≤ 80` (as first suggested; never an identity key); `status : atom, required, default :active, one_of [:pending_disambiguation, :active, :merged]`; `merged_into_subject_id : uuid, nullable` (`:merged` only); `revision : integer, required, default 1` | belongs_to Account (required); belongs_to Contact (nullable; set only from an `admitted` admission or an owner link to an existing contact); has_many PersonCandidate, ContactSearchCycle, AdmissionIntent; self FK `merged_into_subject_id` (same account; composite FK) | **Creation:** a suggestion is attached to an existing subject **only by person-specific identifier evidence**: a **seen** (never inferred) personal email, or a profile link, already held by that subject and observed as this person's own; or a listing entry that names **this particular person**. Never eligible: an inferred address (a company-format guess), any phone number (often shared), a generic or company contact, a page or collection URL that lists several people, or bare equality to a value without person-specific evidence. Ambiguous or conflicting identifiers go to the owner for disambiguation: no automatic merge, no fresh budget. Otherwise a new subject is created.<br>**Name-only matches:** if another subject at the account has the same normalized name hint, the new subject starts `:pending_disambiguation`, and no search cycle opens for it until the owner decides (rule L):<br>- `:mark_distinct` → `:active`, with its own cycle 1;<br>- `:link_into` → `:merged` into the other subject, which keeps its cycle and history.<br>**Inheritance:** a distinct same-name person never inherits another subject's rejections, dispositions or budget. A merge moves no counters: the merged subject's spent requests stay spent. `:merged` is terminal. | `:create` — agent runtime (within its discovery run, with a Decision). `:mark_distinct`, `:link_into`, `:link_contact` — admin, with `expected_revision`. Read: Contact read policy. | — |
| Research.PersonCandidate | New | One suggestion of a subject, from one discovery run (B2-05) | `first_name`, `last_name : string, required, ≤ 80` (as printed on the source); `title : string, nullable, ≤ 160`; `status : atom, required, default :suggested, one_of [:suggested, :admission_pending, :admitted, :admission_refused, :set_aside, :rejected, :left_company, :wrong_account, :expired]`; `disposition_reason : string, nullable, ≤ 500`; `disposition_role : string, nullable, ≤ 160` (set_aside only); `left_on : date, nullable`; `left_source_url : string, nullable`; `proposed_account_id : uuid, nullable` (wrong_account only); `revision : integer, required, default 1` | belongs_to ResearchSubject (required; same account) and Account (required); belongs_to Campaign (required, from the run); belongs_to AgentRun (required, `origin :discovery`); belongs_to Decision (required, kind `:contact_candidate_proposed`, same run); has_many ContactCandidate, ContactFindingTask; employment evidence is reached through its ResearchSubject (CandidateEvidence kind `:employment` points to the subject) | **One active suggestion per subject:** at most one PersonCandidate per subject in `[:suggested, :admission_pending]` (partial unique). A later suggestion of the same subject appends evidence to that active one. If the subject's suggestions are all terminal, a new one may be created after `set_aside`, `admission_refused` or `expired`. After `rejected`, `left_company` or `wrong_account` it is refused with `:subject_disposed`, unless the owner reconsiders that disposition.<br>**Transitions** (each bumps `revision`):<br>- `suggested` → `admission_pending` (`SDR.confirm_person/2`, below), or → `set_aside` (wrong role; scoped to the account and `disposition_role`), `rejected` (not this person; the mismatch kept on this suggestion only), `left_company` (needs `left_on` or `left_source_url`), `wrong_account` (needs `proposed_account_id`; proposes, never relinks) or `expired` (scheduler, `candidate_expiry_days`).<br>- `admission_pending` → `admitted` or `admission_refused`, only by settling its AdmissionIntent.<br>- `admission_refused` → `admission_pending` only by a **new** owner-reviewed intent with a different approved email.<br>- `admitted`, `set_aside`, `rejected`, `left_company`, `wrong_account` and `expired` are terminal for this suggestion; expiry never deletes.<br>A person with no owner-approved email can't be confirmed: the owner's attempt opens a `:confirm_email` task instead (C3 §4.1; never a placeholder address). | `:propose` — agent runtime (discovery run, with its Decision). `:set_aside`, `:reject`, `:mark_left`, `:mark_wrong_account`, `:reconsider` — admin, with `expected_revision`. `:expire` — `:scheduler`. Admission transitions — only via `SDR.confirm_person/2` and `SDR.settle_admission/2`. Read: Contact read policy. | — |
| Research.ContactCandidate | New | One proposed way to reach a subject (B2-07) | `kind : atom, required, one_of [:email, :phone, :profile_url]`; `value : string, required`, normalized for identity per kind (email: trimmed, lowercased `local@host`; phone: E.164; profile_url: lowercased scheme and host only, path kept verbatim); `status : atom, required, default :candidate`, per kind:<br>- email `one_of [:candidate, :owner_approved, :verified, :bounced, :rejected, :expired]`;<br>- phone and profile_url `one_of [:candidate, :owner_approved, :rejected, :expired]`;<br>`decision_reason : string, nullable, ≤ 500` (required for `:rejected`); `decided_by_user_id : uuid, nullable`; `decided_at : nullable`; `verified_how : atom, nullable, one_of [:delivered_no_bounce]`; `verified_at`, `bounced_at : nullable`; `revision : integer, required, default 1` | belongs_to ResearchSubject (required; same account, composite FK) and Account (required); belongs_to PersonCandidate (required; the suggestion that first proposed it; same subject); belongs_to CompanyEmailFormat (nullable; allowed only when `kind = :email`; the format's account equals `account_id`); has_many CandidateEvidence (kind `:detail`) | **Identity:** unique `(tenant_id, account_id, kind, value)`. A re-observation appends evidence to the existing row and never creates a second one. A value already held by another subject is refused, recorded as `result :value_claimed` and flagged (rule L). This is also the strong identifier that attaches a suggestion to a subject.<br>**Provenance** is a calculation: `:seen` if any `:seen` evidence exists, else `:inferred`.<br>**Suppression is a derived fact, not a state.** `SDR.contact_candidates/2` composes `Outreach.SuppressionMatch` for every row, rejected and expired included, and shows "suppressed" with its reason. Suppressions are append-only, so the fact can never roll back, and no candidate state escapes it, `verified` included.<br>**Transitions:**<br>- `candidate` → `owner_approved` (`:approve`, admin) only if: the subject is `:active`; its active suggestion is `suggested`, `admission_pending` or `admitted` (**new details for an admitted person are approvable**); the subject's Contact, if any, is active with no `do_not_contact_at`; and no Suppression matches. All of this under the identity keys, including `contact:<id>` (Suppression row).<br>- `candidate` or `owner_approved` → `rejected` (admin) or `expired` (`:scheduler`).<br>- `expired` → `candidate` only by owner `:reconsider`. `rejected` and `bounced` are terminal. A duplicate proposal never resurrects a terminal row: identity makes it the same row, and evidence is only appended.<br>**Email only:** `owner_approved` → `verified` only from a reviewed real-delivery observation (none in this phase); `owner_approved` or `verified` → `bounced` on a hard bounce, keeping `bounced_at`, with an `:email` Suppression `hard_bounce` created in the same transaction by the existing webhook path.<br>**Phone and profile:** no verification state; verification is deferred.<br>**Staleness** is a calculation: `detail_freshness_days` against the latest `:seen` evidence `found_at`. Inferred evidence never refreshes it.<br>An approved value is not send permission. | `:propose` — agent runtime. `:approve`, `:reject`, `:reconsider` — admin, with `expected_revision`. `:expire` — `:scheduler`. `:mark_bounced` — `:webhook_ingestor`, inside the hard-bounce path only. `:mark_verified` — no actor in this phase. Read: Contact read policy. | — |
| Research.CandidateEvidence | New | One observation supporting a detail or an employment fact (rules A, C, P) | `kind : atom, required, one_of [:detail, :employment]`; `method : atom, required, one_of [:company_site, :name_domain_search, :format_inference, :document_pdf, :document_sheet, :phrase_search, :industry_listing, :linkedin_attended, :company_general]`; `provenance : atom, required, one_of [:seen, :inferred]` (`:inferred` only with `method :format_inference`); `source_url : string, required` (**stored verbatim, as cited**: no slash, fragment or parameter stripping); `published_on : date, nullable` (unknown stays null); `found_at : utc_datetime_usec, required` | belongs_to exactly one of ContactCandidate (`kind :detail`) or ResearchSubject (`kind :employment`): DB check `num_nonnulls = 1` plus kind/parent agreement; same account. belongs_to ContactSearchRequest (required: the request that observed it). belongs_to EmailObservation (required if and only if `method :format_inference`). | **Immutable** (append-only trigger).<br>**Replay identity:** unique `(tenant_id, contact_search_request_id, parent, method, source_url)`. Replaying one request writes nothing. A **new** authorized request at the same source records its own row, with its own `found_at` and content outcome, so rechecks refresh freshness.<br>**Freshness and employment checks** use the latest eligible `:seen` row. Inferred rows carry the observation they came from; reusing a format adds no fresher `found_at`.<br>**Source identity:** no canonical URL equivalence is defined in this slice. Two URLs differing in any character are distinct sources. A later source contract may add a justified source-specific equivalence.<br>Seen and inferred evidence for one value coexist; neither overwrites the other. Ranking wording is derived from method, provenance and dates (section 3); there is no numeric score. | `:record` — agent runtime, within the request's completion. Read: Contact read policy. | — |
| Research.EmailObservation | New | Another employee's address seen on a source, used only to learn the company's format (rule B), without making that employee a target or a subject | `value : string, required` (normalized email; its domain equals the account's canonical domain); `name_on_source : string, nullable, ≤ 160` (as printed; never becomes a subject unless separately proposed with its own Decision); `source_url : string, required` (verbatim); `published_on : date, nullable`; `found_at : utc_datetime_usec, required` | belongs_to Account (required); belongs_to ContactSearchRequest (required) | **Immutable.** Replay identity: unique `(tenant_id, contact_search_request_id, value, source_url)`. New requests record new observations of the same value, so the format's freshness is the latest observation.<br>**Seen only:** it is never derived from an inferred address, so inference can't bootstrap itself.<br>A value matching a Suppression is still recorded, as a fact about the format, but never proposed to anyone. | `:record` — agent runtime. Read: Contact read policy. | — |
| Research.CompanyEmailFormat | New | The account's email pattern: a reusable clue, never proof (rules B, K) | `pattern : atom, required, one_of [:first_dot_last, :first_initial_last, :first, :first_last_initial, :first_underscore_last, :last_dot_first, :first_last, :last_first_initial]`; `derived_at : utc_datetime_usec, required` | belongs_to Account (required); belongs_to EmailObservation (required: `first_observation_id`, same account, composite FK); has_many ContactCandidate (inferred emails) | **Immutable.** Unique `(tenant_id, account_id, pattern)`. Derived only from a `:seen` EmailObservation of the same account.<br>**Support** is a calculation: the account's EmailObservations whose value fits the pattern. Its freshness is the latest of them.<br>A candidate built from the format carries `:inferred` evidence that names the observation. Inference applies to email only. | `:derive` — agent runtime. Read: Account read policy. | — |
| Research.CompanyContact | New | The company's general email, phone or contact form (rule D, ladder step 8) | `kind : atom, required, one_of [:email, :phone, :form_url]`; `value : string, required` (normalized per kind; `form_url` verbatim); `source_url : string, required` (verbatim); `found_at : required` | belongs_to Account (required); belongs_to ContactSearchRequest (required) | **Immutable.** Replay identity: unique `(tenant_id, contact_search_request_id, kind, value)`.<br>It is never linked to a subject and never becomes a ContactCandidate.<br>Recording one for a subject with nothing else found opens an `:ask_company` task. | `:record` — agent runtime. Read: Account read policy. | — |
| Research.ContactSearchCycle | New | One authorized, bounded research cycle for one subject: the budget (rule O, section 11) | `cycle : integer, required, ≥ 1`; `max_requests : integer, required` and `max_active_ms : integer, required` (copied from the run's settings snapshot at open); `requests_reserved : integer, required, default 0, ≥ 0`; `active_ms_reserved : integer, required, default 0, ≥ 0`; `status : atom, required, default :open, one_of [:open, :exhausted, :limit_reached, :closed]`; `opened_by : atom, required, one_of [:subject_created, :owner_recheck]`; `open_request_key : string, required` (idempotency key of the open) | belongs_to ResearchSubject (required); belongs_to AgentRun (required: the run that searches it); belongs_to RunSettingsSnapshot (required: the pinned revision); `opened_by_user_id : uuid, nullable` (`:owner_recheck` only) | Unique `(tenant_id, research_subject_id, cycle)`; unique `(tenant_id, open_request_key)`; at most one `:open` cycle per subject (partial unique).<br>**Who opens cycles:**<br>- Cycle 1 opens only when its subject becomes `:active`, inside that action.<br>- Cycle n + 1 opens only by an admin `:recheck` (an explicit, authorized new research cycle). Its idempotency key means a double-click opens one cycle.<br>- **A restart, redelivery or new discovery run never opens a cycle.** A new run proposing an existing subject only appends evidence, so an exhausted allowance is never replenished.<br>**Counters** are never reset or decremented, and survive restarts, pause, resume and merges.<br>**Settings:** a change affects only cycles opened later. The cycle's limits stay the snapshot's. | `:open` — inside `ResearchSubject` activation (agent runtime or admin), or admin `:recheck`. `:close` — agent runtime, or `:reconciler` when it reconciles the last request. Counters change only via ContactSearchRequest reservation. Read: admin, reviewer, auditor. | — |
| Research.ContactSearchRequest | New | The pre-dispatch reservation and the work trail (rules H, O) | `request_key : string, required` (a stable caller identity: run job id + step + attempt; never null); `step : atom, required` (the CandidateEvidence `method` set); `query : string, nullable, ≤ 500` (local only); `attempt : integer, required, ≥ 1`; `status : atom, required, one_of [:reserved, :dispatched, :completed, :lapsed, :uncertain]`; `result : atom, nullable, one_of [:found, :nothing, :error, :refused_by_terms, :value_claimed]`; `lease_ms : integer, required, > 0`; `lease_expires_at : utc_datetime_usec, required`; `active_ms : integer, nullable, ≥ 0` (measured, informational); `next_step : atom, nullable`; `owner_user_id : uuid, nullable`; `due_at : nullable`; `reserved_at`, `dispatched_at`, `completed_at : nullable except reserved_at` | belongs_to ContactSearchCycle (required); belongs_to PersonCandidate (nullable: the suggestion it serves) | **Replay identity:** unique `(tenant_id, contact_search_cycle_id, request_key)`, non-null, so there's no SQL NULL hole. A redelivered job finds its own row and never reserves twice.<br>**Reserve:** in one transaction, lock the cycle row `FOR UPDATE`. Refuse if the cycle is not `:open`, if `requests_reserved + 1 > max_requests`, or if `active_ms_reserved + lease_ms > max_active_ms`. Otherwise increment both and insert `:reserved`. **Active time is charged at reservation, as `lease_ms`, before any work.** Two workers serialize on the cycle row, so the last allowed request is reserved at most once.<br>**Dispatch:** a guarded `:reserved` → `:dispatched` transition, allowed only while `now < lease_expires_at`, at most once per row. The network call's own timeout is ≤ the remaining lease. One reservation authorizes at most one attempt; a retry is a new reservation (`attempt + 1`, a new `request_key`), charged again.<br>**Complete:** `:dispatched` → `:completed`, with the result and the measured `active_ms` (excluding waiting on the owner). Nothing is refunded.<br>**Crash or uncertain:** after `lease_expires_at`, the `:reconciler` moves `:reserved` → `:lapsed` (never dispatched) and `:dispatched` → `:uncertain` (may have been sent). Both stay fully charged, and neither is retried under the same row.<br>**Account-level steps** made for a subject (company site, format, industry listing) are charged to that subject's cycle. Reusing a stored result (a format, a company contact) costs nothing.<br>`:nothing` is never read as "doesn't exist". Append-only, apart from the single guarded status steps. | `:reserve`, `:dispatch`, `:complete` — agent runtime. `:reconcile` — `:reconciler`. Read: admin, reviewer, auditor. | — |
| Research.AdmissionIntent | New | The immutable, owner-confirmed admission request, persisted before any C3 call, so uncertainty settles to the committed result (R2-5) | `source_ref : string, required` (`agent_found:<run>:<email ContactCandidate id>`); `input : map, required` (the exact normalized C3 input: names, title, email, account canonical domain, `campaign_id`, `agent_run_id`); `input_sha256 : string, required`; `email_candidate_revision`, `person_candidate_revision : integer, required`; `requested_by_user_id : uuid, required`; `status : atom, required, default :pending, one_of [:pending, :settled]`; `settled_outcome : atom, nullable` (C3 `LeadAdmission.outcome` set, or `:invalid`); `last_error : atom, nullable, one_of [:forbidden, :real_data_disabled, :campaign_not_active, :agent_definition_unavailable, :conflict, :source_ref_conflict, :uncertain]`; `settled_at : nullable` | belongs_to ResearchSubject, PersonCandidate and ContactCandidate (all required, same account); `lead_admission_id : uuid, nullable` (a plain FK to Sales.LeadAdmission, which is lower, so allowed) | **Immutable input:** `source_ref`, `input` and `input_sha256` never change. Unique `(tenant_id, source_ref)`. At most one `:pending` intent per subject (partial unique): **no new `source_ref` starts while one is unsettled.**<br>**`SDR.confirm_person/2` (admin):**<br>- **Tx 1:** under the identity keys, check the new attempt's mutable preconditions: an approved, unsuppressed email candidate at its revision; the subject `:active`; no `do_not_contact_at`; the suggestion `suggested` or `admission_refused`. Then insert the intent and move the suggestion to `admission_pending`.<br>- **Then** call `SDR.admit_lead/2` with the intent's stored input.<br>- **Tx 2:** record the result on the intent and the suggestion.<br>**`SDR.settle_admission/2`** (**admin only**, C3-R8: no system actor executes a C3 admission, on replay either) re-sends the **identical stored input** under the same `source_ref`. C3 step 6 returns the stored admission without writing. Only C3 steps 1 to 5 (authorization, input validity, the real-data guard, the key pass) are rechecked; **B2's mutable checks don't apply to settling.** A candidate expiring or a suppression appearing since never rebuilds a different input under the old ref, and never blocks reading the committed result.<br>**Reconciler (read-only reflection):** `:reconciler` may only reflect an **already committed** C3 admission whose `source_ref` and `input_sha256` match a stale `:pending` intent, through a narrowly authorized read, onto that intent and its suggestion. It never calls `admit_lead`, never impersonates `requested_by_user_id`, and never uses an authorize-false bypass. If no committed row is visible, the intent stays `:pending` (unknown, not proof that no admission occurred) and is surfaced for an admin to settle. Executing C3 as a system actor would need a separately reviewed C3 authorization change.<br>**Mapping:**<br>- `admitted` → settled, suggestion `admitted`, subject `contact_id` set.<br>- Every other C3 outcome (`duplicate_open_lead`, `active_target_exists`, `previously_worked`, `company_in_relationship`, `contact_at_other_account`, `contact_archived`, `account_archived`, `suppressed`) → settled, suggestion `admission_refused`, linking the matched lead or contact (case 5: link, never merge).<br>- `{:invalid, _}` → settled `:invalid` (deterministic for the stored input).<br>- `:source_ref_conflict` → stays `:pending` and is flagged for review (a stored-input defect; never retried with a new ref).<br>- `:forbidden`, `:real_data_disabled`, `:campaign_not_active`, `:agent_definition_unavailable`, `:conflict` and a timeout or crash (`:uncertain`) → stays `:pending` with `last_error`, and is settled later by replay.<br>- `:use_referral_handover` can't occur (`source_kind` is fixed).<br>**After a definite refusal,** a fresh approved email is a new owner-reviewed intent with a new `source_ref`. Unknown work is never abandoned by starting another. | `SDR.confirm_person/2` — admin. `SDR.settle_admission/2` (C3 replay) — **admin only**. `SDR.reflect_committed_admission/1` (read-only reflection; no C3 call) — `:reconciler`, bound to one recorded `:pending` intent. Read: admin, reviewer, auditor. | — |
| Research.ContactFindingTask | New | An owner task from contact finding (§2 step 8; C3 §4.1 no-email) | `kind : atom, required, one_of [:confirm_email, :ask_company]`; `status : atom, required, default :open, one_of [:open, :done, :dismissed, :superseded]`; `dedupe_key : string, required` (`<kind>:<subject id>`); `note : string, nullable, ≤ 500` (the owner's); `closed_at : nullable`; `revision : integer, required, default 1` | belongs_to Account and ResearchSubject (required, same account); belongs_to PersonCandidate (nullable); belongs_to CompanyContact (required if and only if `:ask_company`) | **Dedupe:** at most one `:open` task per `(tenant_id, dedupe_key)` (partial unique). Creation is idempotent: a replay returns the open task.<br>`:open` → `:done` or `:dismissed` (admin), or → `:superseded` when its subject is admitted or terminally disposed. Supersession happens in that same action, by that action's actor.<br>It never sends anything: the owner contacts the company personally. | `:open` — the admin, inside `SDR.confirm_person/2` (`:confirm_email`); the agent runtime, inside `CompanyContact :record` with its Decision (`:ask_company`). `:supersede` — the actor of the settling or disposing action: an admin, or `:reconciler` only when it reflects an already committed C3 result (R3-1). `:done`, `:dismissed` — admin. Read: admin, reviewer, auditor. Home display needs a separate C1 producer review. | — |
| Sales.Contact | Existing (delta) | Gains owner-applied phone and profile, and a person-wide stop | `phone : string, nullable` (E.164); `profile_url : string, nullable` (verbatim, as approved); `do_not_contact_at : utc_datetime_usec, nullable` (set once; never cleared by any runtime or system actor) | unchanged; **no FK to Research** (layering) | **New action `:set_contact_detail`** (admin; inputs `kind`, `value`, `expected_updated_at`; audits old and new). It is called only by `SDR.apply_contact_detail/2`, which, under the identity keys including `contact:<id>`:<br>- rechecks that the candidate is `owner_approved`, of kind phone or profile, for a subject linked to this contact;<br>- rechecks that the contact and account are active, the value and revision match, no Suppression matches, and `do_not_contact_at` is null;<br>- returns `:conflict` and writes nothing on any mismatch.<br>Email changes keep using `:change_email`, with the same rechecks.<br>**New action `:mark_do_not_contact`.** It sets `do_not_contact_at`, and is called only by `SDR.stop_contact/2`. Sales never calls Outreach. **This is the single runtime exception:** `:agent_runtime`, only with a checked reply-classification Decision whose reply belongs to **this contact** (`reply.contact_id = contact.id`, verified in the same transaction), or an admin. | `:set_contact_detail` — admin. `:mark_do_not_contact` — admin, or the agent runtime as above. | Owner question 2 decides whether the stop also covers later-linked addresses. |
| Sales.Account | Existing (delta) | Owns the account-level concepts | — | new inverse has_many ResearchSubject, PersonCandidate, EmailObservation, CompanyEmailFormat, CompanyContact, ContactFindingTask | Archived accounts take no new subjects, proposals, observations, cycles or tasks. Existing rows stay readable. | unchanged | — |
| Outreach.Suppression, SuppressionMatch, ApplySuppression and Audit.IdentityKeys | Existing (delta) | Phone do-not-contact, the person-wide stop, and serialization with candidate approval | `scope` gains `:phone` (`value` in E.164; DB check); `reason` unchanged | unchanged | **Phone:** add-only and append-only, as today. It only restricts; no calling or texting exists. In this slice, creation is admin `:manual` only. `IdentityKeys` gains `phone:<e164>`. `SuppressionMatch` covers `:phone` against Contact `phone` and phone candidates (for the derived fact).<br>**Contact key:** `IdentityKeys` gains `contact:<contact id>`. It is taken by `SDR.stop_contact/2`, and by every approval, apply or admission whose subject is linked to that contact. So a stop serializes with any later linking of an address, including for a stopped contact with no phone or profile.<br>**`SDR.stop_contact/2`** (in the SDR orchestration):<br>- **Locks:** `contact:` plus the email, domain and phone keys of the contact's current values.<br>- **Writes:** `Sales.Contact :mark_do_not_contact`, then `:email` Suppressions for every known email of the contact and of its linked subject's approved candidates: through `:from_classification` for a runtime stop (with the checked Decision), or `:manual` for an admin. **Phone rows are created only when the actor is an admin** (`:manual`). A runtime stop creates no phone rows and never switches actor mid-action. For it, the `do_not_contact_at` flag is what blocks the subject's other channels (approval, apply, admission, and any future calling or texting). An admin may add phone rows manually afterwards. A phone-bearing contact therefore never makes a runtime opt-out fail.<br>- **Lock span:** the `contact:` lock and the live `do_not_contact_at` check also span every later C3-write and apply transaction for a linked subject, not only an intent's validation. Settling an already committed result is reflection, not permission to start new work after a stop.<br>- **Coverage:** only via that explicit identity linkage (the subject's `contact_id`). A wholly unlinked new suggestion is not claimed as covered.<br>**ApplySuppression:** no change to candidates; suppression is derived (ContactCandidate row). Its existing lead, enrollment, draft, delivery and approval side effects are unchanged.<br>**A hard bounce** (webhook) suppresses that address only. A person-wide stop is separate (above). | unchanged actors; `:phone` via `:manual` (admin). | Owner question 2. Phone suppression from reply classification comes later, with calling. |
| Sales.LeadAdmission and Sales.Lead (C3-01 documented; C3-02 and C3-03 to implement) | Existing dependency | Admission of a confirmed person, and referral | — | inverse from AdmissionIntent (plain FK; read only) | Admission only through AdmissionIntent and `SDR.admit_lead/2` (above).<br>**Referral** (case 7) goes only through C3-03 `hand_off_referral/2`. A successful handover atomically closes the original as `referred` (C3 §4.2). B2 never closes the original itself, and promises neither that it closes nor that it stays open. | **Mutation (unchanged):** admission and referral stay admin-only (C3 step 1 requires an active admin requester; C3-R8 forbids every system actor, on replay too).<br>**New narrow read (existing-side delta):** `:reconciler` may look up a `Sales.LeadAdmission` row only for a recorded `:pending` AdmissionIntent, matching tenant, `source_ref` and the canonical input version and hash. It returns only the committed outcome and its bindings (lead, contact, admission ids) needed to reflect onto the intent. No matching visible row means the intent stays pending (unknown): no C3 call, no manufactured admin actor, no blanket policy bypass. | C3-02 and C3-03 must merge before B2 code. |
| Agents.Decision and Agents.AgentRun | Existing (delta) | Typed provenance for runtime proposals | Decision `kind` gains `:contact_candidate_proposed` (agent runtime in `kind_actors`; payload metadata only: counts and ids) | unchanged | Every runtime create (subject, proposal, evidence, observation, format, company contact, request) names its run (`origin :discovery`, same tenant). Proposals also name a decision of that run. A run that isn't `:discovery` is refused. A Decision's payload never carries names, values, URLs or queries. | Agent runtime records its own kind only. | — |
| Agents settings (SettingsRevision `:operational_limits`, RunSettingsSnapshot; C4) | Existing (delta) | The section 11 defaults, audited and revisioned | `:operational_limits` gains `contact_search_requests` (15), `contact_search_active_minutes` (10), `contact_paid_credits` (0), `detail_freshness_days` (90), `employment_freshness_days` (30), `candidate_expiry_days` (180), each range-checked | unchanged | Agents read them only from their run's snapshot (`RunSettings.allowance/2`), and a cycle copies its limits at open. No setting funds a source, or overrides C5 budgets, provider quotas, terms, access rules or attended-step gates. `contact_paid_credits > 0` grants nothing without a C5 budget. | As C4 (admin edits revisions). | — |
| Outreach delivery and webhook effects | Existing (delta) | Email candidate state from delivery outcomes | — | unchanged | The hard-bounce webhook path also marks a matching email ContactCandidate `:bounced`, in the same transaction as its Suppression. A captured delivery never marks `verified` (capture-only). | `:webhook_ingestor` (existing). | — |
| Accounts.User | Existing dependency | Owner identity on decisions, intents and tasks | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found | — | — |
| Research.EvidenceClaim | Existing dependency | Lead qualification evidence | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found | — | — |
| Home inbox (C1 InboxItem, ADR-0015) | Existing dependency | Where owner tasks would show | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found (no producer added; a ContactFindingTask producer needs its own C1 review) | — | — |

### Out of this slice

- Screenshots: all screenshot handling (the D-110 local citation, and the D-165 image and cloud direction).
- Phone and profile verification.
- Any calling or texting.
- Paid enrichment.
- Email verification services.
- A C1 producer for tasks.

### Owner questions (answered 2026-10-18, D-167)

1. **Strong result across kinds.** *Was blocking:* the ladder's strong-result stop (rule J). The ladder looks for email, phone and LinkedIn profile together. When it finds a strong result for one kind (say a phone number on the company website), should it stop for all kinds, or keep going for the kinds still missing (especially email, which admission needs), within the same limits?
   **Owner answer:** "keep looking". Each kind stops on its own strong result; the ladder continues for missing kinds within the same limits (see §13b).
2. **Person-wide "stop".** *Was blocking:* whether `SDR.stop_contact/2` also refuses and suppresses addresses linked to the subject **after** the stop. Its coverage of the contact's current values and approved candidates at stop time is in this slice either way. When someone asks not to be contacted, should the stop also cover any address we find for them later? (Proposed: yes. All their known addresses are suppressed, and any later one is refused and suppressed.)
   **Owner answer:** "yes". `SDR.stop_contact/2` covers the contact's current values and approved candidates at stop time, **and** any address later linked to the same subject: it is refused for approval and suppressed when linked. Coverage applies only through the explicit subject-to-contact link (R2-4).

### Soft-stop review record

- **Capabilities:** `.workflow/recipe.json` `ai_pair=true`, `codex_review=true`.
- **Reviewer:** Codex, through ai-pair. Correlation `m_1792361161434085042_8bd95445`.
- **Round 1:** NEEDS-REVIEW on 2026-10-18 (UTC), head `2056f8b`, report `codex-b202-2056f8b9-review.md`.
- **Round 2:** NEEDS-REVIEW on 2026-10-18 (UTC), head `e273c68`, report `codex-b202-e273c68a-review.md` (reply `ec1d5f25`).
- **Round 3:** NEEDS-REVIEW on 2026-10-18 (UTC), head `51ead4b`, report `codex-b202-51ead4b7-review.md` (reply `e73e36b3`). R3-2 was resolved by the owner's answers (D-167) at `111b680`. The `do_not_contact_at` gate blocks every linked-subject approval and apply in any case.
- **Round 4:** this revision (R3-1 admin-only settle with read-only reconciler reflection; R3-3 person-specific identity evidence; R3-4 runtime stop creates no phone rows; the important bullets). Resubmitted for review. Only an explicit PASS releases the soft stop. Until then, no affected-module planning or build.
- **Binding planning obligations (Codex round 3):**
  - the stored intent input and hash use the C3 canonical input version;
  - Tx 2 settlement is recoverable and idempotent;
  - "called only by SDR" is enforced at the lower action boundary by contextual policy (the C3 pattern), so a direct Ash call cannot bypass the candidate, revision or source checks. Race tests are required.
