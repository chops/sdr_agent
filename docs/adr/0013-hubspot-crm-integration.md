---
status: proposed
date: 2026-10-07
supersedes: null
---

# ADR-0013: HubSpot CRM Integration (Developer Test Account, Service Key, Polling, Outbox Writeback)

## Status

Proposed (2026-10-07, Claude). The owner decided on 2026-10-07 to integrate
with HubSpot. Testing runs against a **free HubSpot developer test account**.
The app stays a personal, local demo run with the owner's own credentials: no
hosting and no public webhook endpoint. This ADR is design only. Every slice
it plans (H1–H3, `notes/features/hubspot-integration.org`) is a separate
reviewed PR. The first live write to HubSpot also needs an owner checkpoint
(see "Writeback").

The entity-model delta is in `notes/features/hubspot-integration.org`. It is
under Codex entity soft-stop review. This ADR cannot be accepted until that
review records PASS.

## Context

The owner's architecture spec (§17) calls for a CRM anti-corruption layer: a
`CRM` behaviour (`fetch_contact/1`, `update_contact/2`, `record_activity/1`)
with `HubSpotAdapter`, `SalesforceAdapter` and `FakeCRMAdapter`, and Req kept
inside the adapters. Today only `SdrAgent.Integrations.FakeCRM` exists. It is
read-only fixtures, and its writes return `{:error, :read_only}`. The S2 entity
model left two rows unbuilt: `IntegrationCredential` (assigned to S6, never
built) and `CrmActivity` (write-back, DEFERRED).

This ADR is bound by these existing decisions:

- **ADR-0001 invariants.** Never weaken suppression, approval binding,
  idempotency or the audit trail. Never enable a delivery path that can reach
  a real recipient. Never print, log, commit or transmit secret values. Data is
  synthetic fictional data only. A CRM write is not email delivery. It is still
  an external side effect, so it gets the same outbox, idempotency and audit
  discipline as `DeliveryOperation`.
- **ADR-0002.** Postgres is the system of record. Every import, decision and
  write must be reconstructable from the ledger. Full content is stored only
  because the data is synthetic.
- **ADR-0004.** The model has no tools. Jido is the only action executor. CRM
  text reaches the model only as prompt data.
- **ADR-0005.** Req tracing is opt-in. Content stays out of spans outside dev.
- **ADR-0008.** A new dependency needs a reviewed pin and a blocking audit.
- **ADR-0009 / ADR-0010.** UUIDv7 keys, the tenant column, append-only
  triggers, same-transaction audit, the domain layering
  `Audit <- Accounts <- Operations <- Agents <- Sales <- Research <- Outreach`,
  explicit transition actions, and the synthetic-data guard (reserved domains
  only).

### Facts established on 2026-10-07 (each URL was opened)

**Accounts**
- Developer test accounts are free. You can have up to 10 per standard
  account. They include a 90-day trial of many Enterprise features and cannot
  sync data with other accounts. Marketing email can only go to users added
  to the test account. To create one: Development → Testing → Test Accounts →
  *Create developer test account*. A test account "will expire after 90 days if
  no API calls are made to the account". It can be renewed manually, or by an
  API call with an OAuth token from an app in the same developer account
  (https://developers.hubspot.com/docs/getting-started/account-types).
- The account-information API (`GET /account-info/v3/details`) returns
  `portalId`, `accountType` (`STANDARD`, `DEVELOPER_TEST`, `SANDBOX`,
  `APP_DEVELOPER`) and `dataHostingLocation`. The only scope it lists is
  `oauth` (https://developers.hubspot.com/docs/api-reference/account-account-info-v3/guide).
  Whether a service key can call it is not documented, so H0 verifies this.

**Credentials**
- **Legacy private apps can no longer be created by new accounts.** Accounts
  created on or after 2026-09-28 lost the ability on that date. Older accounts
  lose it on 2026-10-26. The recommended replacement is Service Keys
  (https://developers.hubspot.com/changelog/legacy-private-app-creation-sunset).
  v1–v3 endpoints, legacy public apps and legacy private apps reach their
  enforcement date in September 2027
  (https://developers.hubspot.com/changelog/legacy-apis-and-legacy-apps-whats-going-unsupported-and-when).
  A test account created today is a new account, so it cannot use a legacy
  private app.
- **Service keys** are account-level credentials for REST calls only. They
  support no webhooks and no UI extensions. A super admin or a user with
  Developer tools access creates one at Development → Keys → Service keys, with
  granular scopes. The key is sent as `Authorization: Bearer pat-na1-…`. You can
  rotate with *Rotate and expire now* or *Rotate and expire later* (7-day
  grace). HubSpot recommends rotating every six months, and the docs mention no
  automatic expiry. Rate limits match privately distributed apps
  (https://developers.hubspot.com/docs/apps/developer-platform/build-apps/authentication/account-service-keys).
  The changelog lists them as public beta since 2026-02-10
  (https://developers.hubspot.com/changelog/service-keys). The docs do not say
  whether service keys work in a developer test account, so H0 verifies this.
- **Static auth.** A static-auth app with `private` distribution is "used for
  installing in a single account at a time". OAuth is required for multiple
  accounts
  (https://developers.hubspot.com/docs/apps/developer-platform/build-apps/authentication/overview).
- **OAuth.** OAuth access tokens last 30 minutes (`expires_in: 1800`) and are
  refreshed with a client secret. The flow needs a redirect URI that HubSpot
  calls with `code`, and https is required in production
  (https://developers.hubspot.com/docs/apps/developer-platform/build-apps/authentication/oauth/oauth-quickstart-guide).
- **Legacy private app tokens** have no built-in expiry. They rotate with a
  7-day grace option, and HubSpot recommends rotating every six months
  (https://developers.hubspot.com/docs/apps/legacy-apps/private-apps/overview).

**API versioning**
- Date-based versioning (DBV) puts the version in the path:
  `/crm/objects/2026-03/contacts`
  (https://developers.hubspot.com/docs/api-reference/2026-03/overview).
- GA versions ship in March and September. Each is supported for 18 months.
  HubSpot recommends pinning the version in one place
  (https://developers.hubspot.com/blog/a-developers-guide-to-hubspots-date-based-api-versioning).
- The "latest" reference pages already use `/2026-09/` paths.
- From the 2026-09 GA release, admin-configured validation rules are enforced
  on every CRM write path
  (https://developers.hubspot.com/docs/api-reference/latest/crm/associations/overview).

**Search**
- Endpoint: `POST /crm/objects/2026-09/{object}/search`.
- Limits: 5 requests per second per account; at most 200 results per page; a
  hard cap of 10,000 results per query; up to 5 filterGroups × 6 filters
  (18 total); one sort rule.
- Pagination uses an integer `after`. New or updated objects can take "a few
  moments" to appear in results, and archived objects never appear.
- The last-modified property is `lastmodifieddate` on contacts and
  `hs_lastmodifieddate` on companies.
- Notes, emails and tasks are searchable
  (https://developers.hubspot.com/docs/api-reference/latest/crm/search-the-crm).
- The *Last modified date* changes for any property update, including hidden
  internal ones and newly logged activity
  (https://knowledge.hubspot.com/properties/hubspots-default-contact-properties).
  The app's own writeback therefore bumps the cursor property.

**Rate limits** (privately distributed apps and legacy private apps)
- Free/Starter: 100 requests per 10 seconds per app, and 250,000 per day per
  account. The daily count resets at midnight in the account's time zone.
- A 429 response carries `policyName` (`DAILY` or `TEN_SECONDLY_ROLLING`).
- Response headers `X-HubSpot-RateLimit-Max`, `-Remaining` and
  `-Interval-Milliseconds` are returned, but not on search responses. Errors
  should stay under 5% of daily requests
  (https://developers.hubspot.com/docs/developer-tooling/platform/usage-guidelines).

**Errors**
- The error body has `status`, `message`, `errors[]`, `category` and
  `correlationId`. Treat every field as optional.
- 423 means the record is locked; wait at least 2 s.
- 477 means a migration is in progress; Retry-After is given in seconds.
- 502, 503, 504 and 524 mean pause, then retry.
- Batch creates can return 207 with per-input `objectWriteTraceId`.
- Retry-After on 429 is documented only for workflows (in milliseconds), not
  for API clients
  (https://developers.hubspot.com/docs/api-reference/error-handling).

**Engagements**
- **Notes** are created with `POST …/notes`. `hs_timestamp` is required, and
  `hs_note_body` holds up to 65,536 characters. The note-to-contact
  association type is `202`. Listed scopes: `crm.objects.contacts.read` and
  `.write`. Deleted notes go to the recycle bin
  (https://developers.hubspot.com/docs/api-reference/legacy/crm/activities/notes/guide).
- **Emails** are logged with `POST …/emails`. Fields:
  - `hs_email_direction` (`EMAIL`, `INCOMING_EMAIL`, `FORWARDED_EMAIL`)
  - `hs_email_status` (`BOUNCED`, `FAILED`, `SCHEDULED`, `SENDING`, `SENT`)
  - `hs_email_headers`
  - email-to-contact association type `198`

  Scopes: contacts read/write and `sales-email-read`. The API logs a timeline
  record. The page does not say whether HubSpot ever sends anything for it
  (https://developers.hubspot.com/docs/api-reference/legacy/crm/activities/emails/guide).
- **Tasks** use `POST /crm/objects/2026-09/tasks`. `hs_timestamp` is the due
  date. Other fields are `hs_task_subject`, `hs_task_body`, `hs_task_status`,
  `hs_task_priority`, `hs_task_type` and `hubspot_owner_id`. The
  task-to-contact association type is `204`. Listed scopes: contacts
  read/write
  (https://developers.hubspot.com/docs/api-reference/latest/crm/activities/tasks/guide).
- **Scopes.** The legacy scopes reference lists no note or task scope.
  `sales-email-read` is needed to read email engagement content. Custom
  timeline events need the `timeline` scope
  (https://developers.hubspot.com/docs/apps/legacy-apps/authentication/scopes).
  The legacy private-app page says custom timeline events need a public app.

**Properties and subscriptions**
- `hasUniqueValue` custom properties allow at most 10 per object and can be
  used as `idProperty`. The docs do not say whether activity objects support
  custom properties
  (https://developers.hubspot.com/docs/api-reference/latest/crm/properties/guide).
- Communication preferences are at
  `/communication-preferences/2026-09/statuses/{subscriberIdString}`.
  `subscriberIdString` is the contact's email address. The endpoints are:
  - `GET …?channel=EMAIL`
  - `POST …/unsubscribe-all`
  - `GET …/unsubscribe-all`

  Single-contact scopes are `subscriptions-status-read` and `-write`. Batch
  scopes need Marketing Hub Enterprise. Legal basis fields are required for
  status updates when data-privacy settings are on
  (https://developers.hubspot.com/docs/api-reference/latest/communication-preferences/guide).
  The legacy scopes page names these scopes `communication_preferences.*`, so
  H0 records which names the service-key scope picker shows.

**Webhooks** need a publicly reachable HTTPS endpoint. They cannot be
authenticated with a service key, which rules them out here.

**Not verified on an opened HubSpot page** (from search summaries only; H0
verifies each one):

- The contact property `hs_email_optout` is the internal name of
  *Unsubscribed from all email* and is read-only.
- `lifecyclestage` can only move forward unless it is first cleared.
- `hs_lead_status` takes the uppercase values `NEW`, `OPEN`, `IN_PROGRESS`,
  `OPEN_DEAL`, `UNQUALIFIED`, `ATTEMPTED_TO_CONTACT`, `CONNECTED` and
  `BAD_TIMING`.
- New accounts are seeded with two sample contacts on a real company domain.

## Options Considered

### Credential

| Option | Verdict |
|---|---|
| **A. Legacy private app token** | Rejected. A test account created now cannot create one (2026-09-28 cutoff), and legacy private apps reach enforcement in September 2027. |
| **B. Service key** (Development → Keys → Service keys), stored in a gitignored project-local sops file, reaching the server through `bin/with-secrets` | **Chosen.** Account-level and scoped. No app, no CLI, no backend. Rotation has a 7-day grace. It is a static bearer token, which fits `bin/with-secrets`. Webhooks are not supported, but we do not need them. Risk: public beta, and availability in developer test accounts is undocumented. |
| **C. Static-auth, privately distributed project app** (`hs project create --distribution private --auth static`) | **Fallback if H0 finds B unavailable in the test account.** It also yields a static bearer token, so the same adapter, secret path and policies apply. Costs: HubSpot CLI and project setup (owner side), and scope changes need a reinstall. |
| **D. OAuth app** with a `127.0.0.1` callback | Rejected for now. It needs a redirect endpoint and a client secret, and it stores and rotates 30-minute access tokens plus a long-lived refresh token. That is more secret material and more code for one single-user account. It does have one capability the others lack: renewing the test account by API (account-types page). Revisit only if the owner wants unattended renewal. |

### Change detection

- **Webhooks.** Rejected. They need a public HTTPS endpoint (the app has none
  by owner decision), and service keys cannot authenticate them.
- **Polling with an Oban cron and `lastmodifieddate` cursors.** **Chosen.** It
  is pull-only and needs no inbound network. Every result is persisted with
  its cursor before effects.

### Logging the captured send in HubSpot

- **Email engagement (`hs_email_status: SENT`).** Rejected for now. In this
  app nothing is sent: the capture adapter is the only delivery path (ADR-0001).
  Logging `SENT` would put a false statement into a system of record. It also
  needs `sales-email-read`, a sensitive scope.
- **Custom timeline event.** Rejected. It needs a public app.
- **Note.** **Chosen.** The note body states plainly that the message was
  approved and *captured locally, not delivered*. It carries the approval and
  revision hashes and a machine marker.

### Idempotency of HubSpot writes

- **`hasUniqueValue` custom property plus `idProperty` upsert.** Rejected for
  engagements. The docs do not say whether activities support custom
  properties, and it would need `crm.schemas.*.write`, a broader scope.
- **Search before create, by a marker.** Rejected as the primary mechanism.
  Search is eventually consistent, and filtering on note bodies is
  undocumented.
- **Local outbox plus marker plus reconciliation.** **Chosen.** Each write is
  a `CrmWriteOperation` with a unique idempotency key, claimed by exactly one
  worker. The request carries a deterministic marker and `hs_timestamp`. An
  unknown outcome is resolved by reading the contact's associated notes or
  tasks and matching the marker, or by reading the property or subscription
  state back. It is never resolved by resending blindly.

### Placement

- **Put the CRM code inside Sales/Outreach.** Rejected. Import creates Sales
  and Outreach rows (Suppressions), and writeback reads Outreach events. Either
  placement would need upward calls.
- **New top domain `SdrAgent.CRM`.** **Chosen.** It sits above Outreach in the
  layering, so it may FK and call every lower domain. Lower domains store CRM
  ids only as plain uuids.

## Decision

### 1. Credential and secret handling

- **The secret lives in its own gitignored sops file,**
  `secrets/hubspot.local.sops.yaml`, encrypted to the owner's age recipient
  through a new `.sops.yaml` creation rule. It is not added to the tracked
  `secrets/sdr_agent.sops.yaml`. A third-party credential stays out of git
  history even encrypted, so revoking it needs no history rewrite. It also
  avoids cross-worktree conflicts on the shared file.
  - Keys: `hubspot.service_key` (secret) and `hubspot.portal_id` (the
    allowlisted account; not secret, but owner-local).
  - The owner adds the values. Agents never ask for, read, print or copy the
    key.
- **`bin/with-secrets` gains two mapped names,** `SDR_HUBSPOT_SERVICE_KEY` and
  `SDR_HUBSPOT_PORTAL_ID`, each with its file and extract path. Run the server
  as
  `bin/with-secrets SDR_HUBSPOT_SERVICE_KEY SDR_HUBSPOT_PORTAL_ID -- mix phx.server`.
- **The key is read from the environment at request time** by the adapter.
  It never enters `Application` env, so it never reaches the redacted
  `ProvenanceSnapshot` config hash. It is never stored in Postgres, never a
  Req default option, never logged, and never put in a span, a Failure or an
  AuditEvent.
- **`IntegrationCredential` (S2 row, finally built in H1a) holds the
  reference only.** Provider `hubspot`; `credential_kind: sops_path`;
  `reference: "secrets/hubspot.local.sops.yaml#hubspot.service_key"`.
  - Status (`unverified`/`verified`/`missing`/`revoked`) is set by preflight.
  - `non_secret_fingerprint` = `"portal:<portalId>/<dataHostingLocation>"`.
    No part or hash of the key is stored.
  - `write_mode` is the persisted kill switch (§5).
- **Preflight, run at boot and before every sync or write batch, fails
  closed.** It requires all of the following:
  - the key is present and non-empty;
  - the account details call returns `accountType == "DEVELOPER_TEST"`;
  - `portalId` equals `SDR_HUBSPOT_PORTAL_ID`;
  - a read-only probe succeeds.

  A `STANDARD` account is refused in this ADR's scope: a real portal would
  contain real people. A 401 or 403 marks the credential `missing` and opens a
  critical Failure. Polling then stops; it never retries in a loop. If the
  service key cannot call account details, H0 records that, and the fallback
  check is a documented read the key can make plus the portal-id allowlist
  alone. Choosing that fallback needs a reviewed amendment.
- **The redactor gains an explicit HubSpot key shape:**
  `pat-` + region (`na1`, `eu1`, …) + UUID-like body. The existing long-run
  rules already catch most of it.
- **Minimal scopes, added per slice**:

  | Slice | Scopes | Why |
  |---|---|---|
  | H1 | `crm.objects.contacts.read`, `crm.objects.companies.read` | Import and research. Notes and tasks are read under contact scopes per the docs; H0 confirms with the 403 response. |
  | H1 (opt-out check) | `subscriptions-status-read` | Only if `hs_email_optout` is not reliable (H0). |
  | H2 | `crm.objects.contacts.write`, `subscriptions-status-write` | Notes, tasks, `hs_lead_status`, unsubscribe-all. |
  | never in this ADR | deals, owners, schemas/properties write, lists, `sales-email-read`, timeline, batch subscription scopes, any `.sensitive`/`.highly_sensitive` | Not needed. Tasks reuse the contact's existing `hubspot_owner_id` value, so no owners scope is needed. |

  Exact scope names come from the scope picker during H0 and are recorded in
  the H0 notes.

### 2. HTTP client (`SdrAgent.Integrations.HubSpot.Client`, Req only, no new dependency)

- **Base URL and API version.** Base URL is `https://api.hubapi.com`. One
  module attribute pins the DBV version (`"2026-09"`), and every path is built
  from it. No `/v3/` paths are used, except account-info if no dated
  equivalent works (H0).
- **Request rules:**
  - `redirect: false`. A 3xx is an error, never followed.
  - Before each request, the host must be exactly `api.hubapi.com` and the
    scheme `https`; otherwise the request is refused before Req runs.
  - `retry: false`. Oban owns all retries, so every attempt is counted,
    audited and bounded.
  - Explicit connect and receive timeouts.
  - Authorization goes through `auth: {:bearer, key}` per request.
- **Telemetry.** Instrumented through `SdrAgent.Telemetry.instrument_req/1`.
  Spans record method, templated route (e.g.
  `/communication-preferences/{v}/statuses/{subscriber}`) and status, never
  the raw path, because subscription endpoints carry the contact's email in
  the path. Bodies are never put in spans, and response bodies go to Payload
  only.
- **Errors are mapped to a closed set:**

  | HTTP result | Mapped to |
  |---|---|
  | 401 | `:unauthorized` |
  | 403 | `:forbidden`, keeping `category` and any required-scope hint, redacted |
  | 404 | `:not_found` |
  | 409 or validation error | `:conflict` / `:invalid` (permanent) |
  | 423 | `:locked` (retry ≥ 2 s) |
  | 429 | `:rate_limited` with `policyName` (`DAILY` → pause until the account's midnight; ten-secondly → back off ≥ 10 s) |
  | 477 | `:migrating` (honour Retry-After seconds, capped) |
  | 5xx, 52x | `:transient` |
  | timeout or closed connection *after the request was sent* | `:unknown` |
- **Self-imposed budget, well below Free tier limits.** All HubSpot traffic
  runs on a new Oban queue `crm` at concurrency 1.
  - Pacing: at most 5 requests/s overall and 2 search requests/s.
  - The `X-HubSpot-RateLimit-Remaining` header is honoured.
  - A persisted daily cap (default 5,000 requests per UTC day, configurable
    only downward) is counted from `CrmSyncRun.request_count` plus
    `CrmWriteOperation` attempts, under a row lock, the same way as the
    ADR-0004 model budget.
  - When exhausted, the run stops with a recorded reason and a warning
    Failure.

### 3. Data flow (a): IMPORT, HubSpot → Accounts/Contacts/Leads

**Trigger.** Run on demand with `mix sdr.crm.import [--dry-run]` or the Admin
button, or by the H3 cron. Actor: new system actor `:crm_sync` (CRS).

**Fetching.** Companies and contacts come from search with explicit property
lists (§ mapping). Each contact's company comes from its associations. The
default contact-to-company type `279` is used, with primary company label `1`
if present.

**Per-record gate.** Each remote record passes a deterministic Decision
(`crm_import_filter`, rule-versioned) in this order:

1. **Synthetic-data guard (not weakened).**
   - The company `domain` and the contact `email` must be under a reserved
     name (ADR-0009 §9). Records that fail are skipped: their properties are
     not stored, and the skip records only the remote id and the reason.
   - This rejects HubSpot's seeded sample contacts and anything real.
2. **Required fields.**
   - Company: `name` and `domain`.
   - Contact: `email`, `firstname` and `lastname`, plus an imported company.
3. **Archived or merged records** are handled as in §6.
4. **Opt-out.**
   - `hs_email_optout == true` → create a `Suppression` (scope email, new
     reason `crm_opt_out`) in the same transaction as the contact import.
   - If the property is absent, treat the state as **unknown** and check
     `GET …/statuses/{email}/unsubscribe-all` before any Lead is created.
   - Unknown state blocks Lead creation. It does not suppress.

**Upserts.**
- The remote identity is `(crm_provider: :hubspot, crm_portal_id,
  crm_external_id)`.
- Matching runs first by remote identity, then for contacts by email:
  - An unlinked local contact with the same email is *adopted*, recorded in
    the Decision.
  - A contact linked to a different remote id is a conflict: skipped, with a
    warning Failure.
- New rows are created through new `:import` create actions
  (`source: :crm`).
- Existing rows are updated through `:sync_update`, which changes
  HubSpot-owned fields only. An email change goes through the existing
  `:change_email` semantics: the event records old and new, and the S8 send
  gate already invalidates approvals bound to the old address.

**Snapshots.**
- Every imported remote version is stored as an append-only
  `CrmImportRecord`. Its canonical properties go to Payload, along with
  `remote_modified_at`, `properties_sha256`, the run, the outcome and the
  local subject.
- If `properties_sha256` matches the current snapshot, the record is
  `unchanged`: no domain write and no new snapshot, only a run counter. This
  absorbs the cursor bumps caused by our own writeback notes.

**Field mapping** (HubSpot → local). Anything not listed is not imported:

| HubSpot company | Account |
|---|---|
| `name` | `name` |
| `domain` | `domain` (normalized; reserved-name guard) |
| `website` | `website_url` (must also be reserved/synthetic host, else nil) |
| `industry` | `industry` |
| `numberofemployees` | `employee_count` (integer ≥ 0, else nil) |
| `country` | `geography` |
| `hs_object_id` | `crm_external_id`; `crm_portal_id` = portalId |

| HubSpot contact | Contact |
|---|---|
| `firstname`, `lastname`, `email`, `jobtitle` | `first_name`, `last_name`, `email`, `title` |
| primary company association | `account_id` |
| `hs_object_id` | `crm_external_id`; `crm_portal_id` = portalId |
| `hs_email_optout` | Suppression (`crm_opt_out`), never a Contact column |
| `lifecyclestage`, `hs_lead_status`, `hubspot_owner_id` | snapshot only (inputs to the Lead rule and to task ownership) |

**Lead rule** (deterministic Decision `crm_lead_rule`, open question OQ-3).
- A `Lead` (`source: :crm`, status `new`) is created only when all of these
  hold:
  - `lifecyclestage` ∈ {`subscriber`, `lead`, `marketingqualifiedlead`,
    `salesqualifiedlead`};
  - `hs_lead_status` ∉ {`UNQUALIFIED`, `CONNECTED`, `OPEN_DEAL`};
  - the opt-out state is known and not opted out;
  - the contact has no open Lead.
- Leads are **never auto-assigned**. Assignment to the agent stays the
  existing explicit operator action.

**Consent.** Only local Suppression counts at the send gate.
- HubSpot opt-out → local Suppression. This adds and never removes.
- A HubSpot re-subscribe never lifts a local suppression, which is monotonic
  (S2).
- Legal-basis fields are never written from this app.

### 4. Data flow (b): RESEARCH, HubSpot as an evidence source

**Adapter.** `SdrAgent.Integrations.HubSpotCRM` implements
`SdrAgent.Integrations.CRM`. `fetch_contact(crm_external_id)` returns the
contact and company properties (the mapped allowlist, not every property) and
the last 20 associated notes and tasks, ordered by `hs_timestamp`.
Email engagements contribute subject, direction and timestamp only;
bodies need `sales-email-read`, which is excluded.

**Two artifacts per call.**
- `crm_record`: structured properties, `trust_level: :medium`.
- New `crm_activity`: engagement free text, `trust_level: :unverified`.
- Both use the new provider `:hubspot` and the non-fetchable URI
  `hubspot://<portalId>/<objectType>/<id>`. The ResearchArtifact reserved-host
  rule is extended by exactly this scheme, never by `app.hubspot.com`.

**`GetPreviousInteractions`** (spec §6) is the `crm_activity` half. It may be a
separate action or the same `GetCRMHistory` call; that is an implementation
choice in H1c.

**Prompt injection.** CRM free text is untrusted data. The same rule applies to
web text.
- Prompt templates get a version bump. Every source is rendered inside a
  delimited, labelled data block, with a fixed instruction that text inside
  sources is data and never instructions.
- The model still has no tools (ADR-0004).
- Claims must be verbatim, grounded quotes (S5 EvidenceClaim check).
- Every draft still needs human approval bound to a revision (Tier 0).
- Our own writeback notes are recognized by marker and **excluded** from
  evidence, so the agent never cites its own output.
- Activity text is capped per artifact (stored in full in Payload; the excerpt
  is ≤ 2,000 chars as today).

### 5. Data flow (c): WRITEBACK through an outbox

**Planner (CRS, `crm` queue, cron).** The planner reads the **audit ledger**
after a `CrmSyncCursor` positioned on `sequence`. The chain is gap-free and
ordered, so this is a durable, replayable change feed, and Outreach needs no
code change and no upward call. For each relevant committed event, it inserts
one `CrmWriteOperation` with idempotency key `crm:<kind>:<source_row_id>`
(unique). In the same transaction it advances the cursor and enqueues the Oban
job. Replays are no-ops.

| Source event | CRM write (`kind`) | Content |
|---|---|---|
| `outreach.delivery.*` reaching `accepted` (capture receipt) | `log_note` on the contact | "SDR demo: email approved by <role> and **captured locally, not delivered**", subject, approval id, revision `content_sha256`, rendered sha256, marker. The message body is not copied; the revision hash points to it. |
| `outreach.reply.received` (matched) | `update_lead_status` → `CONNECTED` | property PATCH |
| `outreach.reply.assessed` with `classification: interested` (current assessment) | `create_task` (hand-off) | `hs_task_subject` "Interested reply — hand-off", `hs_task_type: TODO`, `hs_task_priority: HIGH`, `hs_task_status: NOT_STARTED`, `hs_timestamp` = assessed_at + 1 business day, `hubspot_owner_id` copied from the snapshot if present; body = classification, reason excerpt, marker |
| `outreach.suppression.created` with reason ≠ `crm_opt_out` | `unsubscribe_all` (channel EMAIL) | no legal-basis fields |
| `sales.lead.*` → `disqualified` | `update_lead_status` → `UNQUALIFIED` | property PATCH |

- `lifecyclestage` is never written. It is forward-only and owned by humans
  (OQ-4).
- A write is planned only for contacts with a current HubSpot link. Fixture
  and manual contacts are skipped and nothing is recorded.

**Gate.** Every claim (`pending → attempting`) runs one deterministic
`crm_writeback_gate` Decision. It requires:
- effective mode `live`;
- credential `verified` with the portal allowlisted;
- the target link is current and not archived or merged;
- for non-unsubscribe writes, the contact is not locally suppressed (an
  unsubscribe always passes);
- the daily request budget is available.

**Modes and kill switch.** Effective mode = the minimum of:
1. the config ceiling `config :sdr_agent, :hubspot, writeback: :off | :dry_run | :live`,
   which defaults to `:off` in every environment, is `:off` in test and is
   refused at boot in prod;
2. `SDR_HUBSPOT_WRITEBACK=live` in the environment;
3. the persisted `IntegrationCredential.write_mode`. Only ADM changes it. The
   change is AE'd and listed in the Denial-audit contract as a guarded action.

Behaviour per effective mode:
- `off`: operations stay `pending`, paused not cancelled, and planning
  continues so nothing is lost.
- `dry_run`: the exact request is built and stored in Payload, and the
  operation ends `skipped_dry_run` with **no HTTP**.
- `live`: the request is sent.

Lowering the mode takes effect at the next claim. Flipping `write_mode` to
`off` is the global kill switch: one action, no restart.

**Execution and outcomes.**
- **Request recording.**
  - Stored in Payload *before* the call: request method, templated route,
    body and marker.
  - Stored after: the response body. HubSpot responses carry no credentials,
    but error text still passes the redactor before it reaches a Failure.
  - Remote id: `remote_result_id`, the note or task id.
- **Outcome mapping:**
  - 2xx → `succeeded`.
  - `:transient`, `:locked`, `:rate_limited` or `:migrating` →
    `failed_retryable` with `not_before`, bounded `max_attempts` (3).
  - `:invalid`, `:conflict`, `:forbidden` or `:not_found` →
    `failed_permanent`, which opens a Failure (attention).
  - `:unknown` → `unknown`, which opens a `reconciliation_required` Failure.
- **Reconciliation of `unknown`** (REC actor, `crm` queue, deterministic
  `crm_write_reconciliation` Decision):

  | Write | How it is reconciled |
  |---|---|
  | `log_note`, `create_task` | Read the contact's associated notes or tasks and batch-read them for the marker. Found → `succeeded` with that id. Not found after 3 checks spread over ≥ 15 min (search and association lag) → `failed_retryable`, as a recorded decision, never a blind resend. A duplicate note would be benign and identifiable by marker and `hs_timestamp`. |
  | `update_lead_status` | Read the property back. |
  | `unsubscribe_all` | `GET …/unsubscribe-all`. |

  Resolving the operation resolves its Failure.
- **Audit.** Every transition is AE'd (`crm.write.*`). The Operations view
  lists the operations with state, mode, remote id and last error.

**Reach.**
- **What HubSpot does with these writes.**
  - Notes, tasks, lead status and unsubscribe-all do not email a contact.
  - A task may notify its HubSpot *owner* (a portal user), which is the owner
    themself.
  - Marketing email in a test account can only reach users added to it
    (account-types page).
  - So no write can reach a real recipient.
- **What the owner must not do.** The owner must not configure HubSpot
  workflows that email contacts on property changes. This is recorded in the
  setup steps.
- **First live write is an owner checkpoint.** The first enablement of `live`
  is a separate reviewed PR that cites H0 evidence, followed by the owner
  setting `SDR_HUBSPOT_WRITEBACK=live` and ADM flipping `write_mode`. This is
  the same pattern as S12d.

### 6. Data flow (d): SYNC by polling

**Cadence.** An Oban cron runs every 15 minutes (configurable 5–60 minutes),
only when the credential is `verified`. A full import runs only on demand.

**Cursors.** There is one `CrmSyncCursor` per `(portal, object_type, stream)`.
`object_type` is `company` or `contact`. `stream` is `modified`,
`archived_scan` or `ledger` (planner).

**Each `modified` run**
1. Search with `lastmodifieddate` (contacts) or `hs_lastmodifieddate`
   (companies) `GTE cursor − 10 min` (an overlap window for search lag),
   sorted ascending by that property, with `limit 200`, paging by `after`.
2. Process each page in its own transaction (snapshots, upserts, decisions).
3. Advance the cursor to the page's maximum modified timestamp and
   `hs_object_id`, so the cursor never decreases.
4. If a query nears 10,000 results, start a new query at the last
   `(timestamp, id)` seen, splitting on `hs_object_id GT` when many records
   share one timestamp.
5. Re-reads inside the overlap are absorbed by `properties_sha256`.

**Conflict rules (who wins)**

| Data | Owner | Rule |
|---|---|---|
| Company/contact identity and profile fields (mapped allowlist) | HubSpot | Import overwrites local values for linked rows. A local edit to a linked row is overwritten at next sync (local admin edits of linked rows are refused in H3, OQ-5). |
| Contact email | HubSpot | Applied via change_email semantics. Approvals bound to the old email are invalidated at the send gate. |
| Lead lifecycle, qualification, drafts, approvals, deliveries, replies | Local | HubSpot never changes them. HubSpot `hs_lead_status` is written by us and read only as a Lead-rule input at creation. |
| Suppression / opt-out | Union, most restrictive wins | An opt-out on either side ends contact. Neither side's re-subscribe lifts a local Suppression. |
| Records whose local copy is unlinked (fixture/manual) | Local | Never touched by sync, except email adoption, which is a recorded Decision. |

**Deletions and merges**
- **`archived_scan`** lists archived contacts and companies with
  `archived=true` on each run. A test portal is small, so this is bounded and
  is the only way to see deletions, because search excludes archived records.
- **A newly archived contact** gets a snapshot (`remote_state: archived`), its
  local Contact is archived, and a Suppression with new reason
  `crm_record_deleted` is created (OQ-6). The existing tested suppression side
  effects then stop enrollments, cancel pending deliveries and drafts,
  invalidate approvals and stop leads. If the record is later restored in
  HubSpot, it is not re-activated automatically.
- **A newly archived company** archives its Account (no new leads). Its
  contacts are handled per contact.
- **Merges.** The winner's `hs_merged_object_ids` re-point the loser's
  identity to the winner (snapshot `remote_state: merged`,
  `merged_into_remote_id`). No second Contact is created. If loser and winner
  map to different local contacts, the record is skipped with a warning
  Failure.
- **Test-portal expiry.** If the portal expires (90 days without API calls,
  or deleted), preflight fails (`missing`), polling stops and a critical
  Failure is opened. Local rows are kept. A new portal has a new `portalId`,
  so its records never collide with the old ones.

### 7. Tests (hermetic by default)

**Hermetic suite.**
- Req is configured in `:test` with `plug: {Req.Test, SdrAgent.Integrations.HubSpot.Client}`.
  Each test stubs with `Req.Test.stub/2` against hand-written, synthetic JSON
  fixtures (reserved domains, invented ids) under
  `test/support/fixtures/hubspot/`. No recorded real responses are used.
- A guard test proves that in `:test` the client refuses to run without the
  plug, and that a non-`api.hubapi.com` host, a redirect or `http://` is
  refused.

**Coverage required per slice.**
- Synthetic-guard skips, including the sample-contact shape.
- Opt-out → Suppression, and the unknown opt-out state.
- Adoption and conflict.
- Cursor monotonicity, overlap, and the 10k split.
- Archived and merge handling.
- Every write state, including `unknown` → reconciled (found and not found).
- Each mode (`off`, `dry_run`, `live`) and the kill switch.
- 429 `DAILY` and ten-secondly handling.
- The daily budget.
- Secret non-appearance: key absent from logs, Failures, AuditEvents,
  Payloads and spans, asserted with a canary value.
- Policy allow and deny for CRS, REC, ADM and AUR.
- Prompt-fencing render of untrusted activity text.

**Smoke test.** One `:external` read-only smoke test
(`test/external/hubspot_smoke_test.exs`, excluded by `test_helper.exs`) is run
manually as
`bin/with-secrets SDR_HUBSPOT_SERVICE_KEY SDR_HUBSPOT_PORTAL_ID -- mix test --only external test/external/hubspot_smoke_test.exs`.
It checks account details (`DEVELOPER_TEST`, portal allowlist) and one
contact search page, and it never writes. CI never runs it.

### 8. Dependencies

**None.** Req 0.7.5 (includes `Req.Test`), Plug, Oban and Ash are already
locked. HubSpot's Elixir SDK does not exist officially, and none is adopted.

## Justification

- **Service key.** It is the credential HubSpot now recommends for exactly
  this case: one account, system-to-system, no webhooks. It is also the only
  static-token option a newly created test account can still create without a
  CLI project. A static bearer token in a gitignored sops file, passed through
  `bin/with-secrets` and read per request, keeps secret handling identical to
  the existing anchor key.
- **Polling.** It respects the "no public endpoint" decision. With an
  overlap window and hash-deduplicated snapshots, it is correct under
  HubSpot's eventual consistency.
- **Ledger-driven outbox writes.** Each external write is idempotent,
  auditable and reconcilable without touching Outreach code or inverting the
  domain layering.
- **Fail-closed preflight.** Requiring a `DEVELOPER_TEST` account and the
  allowlisted portal keeps "synthetic data only" executable rather than a
  promise.

## Consequences

### Positive

- The spec §17 anti-corruption layer gets its first real adapter. FakeCRM
  stays the default for tests, CI and `bin/demo`.
- Every imported value has a snapshot, a Decision and an AuditEvent, and
  every write has an outbox row, so HubSpot activity is reconstructable from
  Postgres alone (ADR-0002).
- The kill switch and dry-run mode make writeback observable before any byte
  leaves the machine.

### Negative

- Service keys are in public beta, and their availability in developer test
  accounts is undocumented. Fallback C costs owner setup time.
- Polling adds up to 15 minutes of latency and uses daily request budget.
  Deletions are seen only through the archived scan.
- Note-based logging is less structured in HubSpot than an Email engagement.
- Marker reconciliation can, in a rare `unknown` + "not found" case, produce
  one duplicate note or task. That is recorded and harmless.
- The test portal expires after 90 days without API calls, and its content is
  lost. Local data survives, under a new portal id after re-setup.
- DBV `2026-09` is supported for 18 months. A version bump is a reviewed
  change.

### Neutral

- New top domain `SdrAgent.CRM` above Outreach. The layering becomes
  `… <- Outreach <- CRM`.
- Real HubSpot portals (`STANDARD`) remain out of scope until the ADR-0002
  data-classification ADR exists.
