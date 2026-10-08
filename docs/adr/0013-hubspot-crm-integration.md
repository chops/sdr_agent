---
status: proposed
date: 2026-10-07
supersedes: null
---

# ADR-0013: HubSpot CRM Integration (Developer Test Account, Service Key, Polling, Outbox Writeback)

## Status

Proposed (2026-10-07, Claude). Revision 2 addresses Codex entity review
`4ab68bc3-c1ea-44ff-970d-a063d59f8fdd` (NEEDS-REVIEW on `fa44235`, findings
1–6 and the important items). The mapping from findings to changes is in
`notes/features/hubspot-integration.org` under "Soft-stop review".

The owner decided on 2026-10-07 to integrate with HubSpot, tested against a
**free HubSpot developer test account**. The app stays a personal, local demo
run with the owner's own credentials: no hosting and no public webhook
endpoint.

This ADR is design only. Each slice (H0–H3) is a separate reviewed PR. The
entity delta is split:

- **H1 (read-only)** is submitted for PASS now.
- **H2/H3 (writes, sync)** are revised here and re-submitted for review
  before H2a starts.

ADR acceptance requires entity PASS and owner answers to the open questions.
The first live write is an owner checkpoint.

## Context

The owner's architecture spec (§17) calls for a CRM anti-corruption layer: a
`CRM` behaviour with HubSpot, Salesforce and Fake adapters, with Req kept
inside the adapters. Today only the read-only `SdrAgent.Integrations.FakeCRM`
exists. The S2 rows `IntegrationCredential` (never built) and `CrmActivity`
(DEFERRED) are the starting points.

This ADR is bound by:

- **ADR-0001 invariants.** Never weaken suppression, approval binding,
  idempotency or audit. Never enable a delivery path that can reach a real
  recipient. Never print, log, commit or transmit secrets. Data is synthetic
  only. A CRM write is not email delivery, but it is an external side effect,
  so it gets outbox, idempotency and audit discipline.
- **ADR-0002.** Everything is reconstructable from Postgres.
- **ADR-0004.** The model has no tools.
- **ADR-0005.** No content in spans outside dev.
- **ADR-0008.** No unreviewed dependency.
- **ADR-0009 / ADR-0010.** Layering, same-transaction audit, append-only
  triggers, explicit transitions, and the synthetic guard.

### Facts established on 2026-10-07 (each URL was opened; nothing called or created)

**Developer test accounts**
- Free, up to 10 per standard account, with a 90-day trial of many Enterprise
  features. Marketing email goes only to users added to the test account.
- To create one: Development → Testing → Test Accounts.
- An account "will expire after 90 days if no API calls are made to the
  account". API renewal needs an OAuth token from the same developer account
  (https://developers.hubspot.com/docs/getting-started/account-types).

**Account details**
- `GET /account-info/v3/details` returns `portalId`, `accountType`
  (`STANDARD`, `DEVELOPER_TEST`, `SANDBOX`, `APP_DEVELOPER`) and
  `dataHostingLocation`. The only listed scope is `oauth`
  (https://developers.hubspot.com/docs/api-reference/account-account-info-v3/guide).

**Credentials**
- **Legacy private apps** cannot be created by accounts made on or after
  2026-09-28. Older accounts lose the ability on 2026-10-26. Service Keys are
  the recommended replacement
  (https://developers.hubspot.com/changelog/legacy-private-app-creation-sunset).
- **Legacy apps and v1–v3 endpoints** reach their enforcement date in
  September 2027
  (https://developers.hubspot.com/changelog/legacy-apis-and-legacy-apps-whats-going-unsupported-and-when).
- **Service keys**
  (https://developers.hubspot.com/docs/apps/developer-platform/build-apps/authentication/account-service-keys):
  - REST only: no webhooks and no UI extensions.
  - Granular scopes.
  - Sent as `Authorization: Bearer pat-na1-…`.
  - Rotation is *expire now* or *expire later* (7-day grace). HubSpot
    recommends rotating every six months, and there is no automatic expiry.
  - Rate limits match privately distributed apps.
  - Public beta since 2026-02-10
    (https://developers.hubspot.com/changelog/service-keys).
- **Static auth.** Static-auth apps with `private` distribution install into
  one account at a time
  (https://developers.hubspot.com/docs/apps/developer-platform/build-apps/authentication/overview).
- **OAuth.** Access tokens last 30 minutes and are refreshed with a client
  secret through a redirect flow
  (https://developers.hubspot.com/docs/apps/developer-platform/build-apps/authentication/oauth/oauth-quickstart-guide).
- **Legacy private app tokens** never expire and rotate with a 7-day grace
  (https://developers.hubspot.com/docs/apps/legacy-apps/private-apps/overview).

**API versioning**
- Date-based versions go in the path, e.g. `/crm/objects/2026-03/contacts`
  (https://developers.hubspot.com/docs/api-reference/2026-03/overview).
- Versions ship every March and September, and each is supported for 18
  months. Pin the version in one place
  (https://developers.hubspot.com/blog/a-developers-guide-to-hubspots-date-based-api-versioning).
- The "latest" pages use `/2026-09/`.
- From 2026-09, admin validation rules apply to all CRM writes
  (https://developers.hubspot.com/docs/api-reference/latest/crm/associations/overview).

**Search**
- `POST /crm/objects/2026-09/{object}/search`.
- Limits: 5 requests/s per account, 200 results per page, a hard cap of
  10,000 results per query, 5×6 filters (18 total), one sort.
- `after` is an integer. Indexing lags "a few moments", and archived records
  are excluded.
- The last-modified property is `lastmodifieddate` on contacts and
  `hs_lastmodifieddate` on companies.
- Notes, emails and tasks are searchable
  (https://developers.hubspot.com/docs/api-reference/latest/crm/search-the-crm).
- *Last modified date* changes on any update, including logged activity
  (https://knowledge.hubspot.com/properties/hubspots-default-contact-properties).
  This means our own writes bump it.

**Rate limits and errors**
- Free/Starter: 100 requests per 10 s per app, and 250,000 per day per
  account (resetting at midnight in the account's time zone).
- A 429 response carries `policyName` (`DAILY` or `TEN_SECONDLY_ROLLING`).
- Rate-limit headers are returned, but not on search responses. Errors
  should stay under 5% of requests
  (https://developers.hubspot.com/docs/developer-tooling/platform/usage-guidelines).
- The error body has `status`, `message`, `errors[]`, `category` and
  `correlationId`, all optional.
- 423 means locked for 2 s. 477 means a migration is in progress (Retry-After
  in seconds). 502/503/504/524 mean pause, then retry.
- Batch creates support a 207 response with `objectWriteTraceId`. Retry-After
  on 429 is documented only for workflows
  (https://developers.hubspot.com/docs/api-reference/error-handling).

**Engagements**
- **Notes:** `hs_timestamp` is required; `hs_note_body` holds up to 65,536
  characters; association to contact is `202`; scopes are contacts
  read/write
  (https://developers.hubspot.com/docs/api-reference/legacy/crm/activities/notes/guide).
- **Emails:** fields `hs_email_direction` and `hs_email_status` (`SENT`, …);
  association `198`; needs `sales-email-read`
  (https://developers.hubspot.com/docs/api-reference/legacy/crm/activities/emails/guide).
- **Tasks:** `POST /crm/objects/2026-09/tasks`; `hs_timestamp` is the due
  date; association `204`; contact scopes
  (https://developers.hubspot.com/docs/api-reference/latest/crm/activities/tasks/guide).
- Custom timeline events need the `timeline` scope or a public app
  (https://developers.hubspot.com/docs/apps/legacy-apps/authentication/scopes).

**Properties**
- `hasUniqueValue` properties allow at most 10 per object and are
  addressable through `idProperty`. The docs do not say whether activity
  objects support them
  (https://developers.hubspot.com/docs/api-reference/latest/crm/properties/guide).

**Communication preferences**
- Endpoints live at `/communication-preferences/2026-09/statuses/{email}…`,
  including `unsubscribe-all` GET and POST.
- Single-contact scopes are `subscriptions-status-read` and `-write`. Batch
  scopes need Marketing Hub Enterprise
  (https://developers.hubspot.com/docs/api-reference/latest/communication-preferences/guide).

**Webhooks** need public HTTPS and cannot use a service key, which rules them
out here.

**Unverified (search summaries only; H0 must establish each one):**
- `hs_email_optout` is the read-only internal name of *Unsubscribed from all
  email*.
- `lifecyclestage` only moves forward.
- The `hs_lead_status` internal values.
- New portals are seeded with two sample contacts on a real company domain.
- Whether a service key can call account details.
- Whether service keys work in developer test accounts.
- Whether notes and tasks accept a custom `hasUniqueValue` property.
- The exact scope names shown in the scope picker.

## Options Considered

### Credential

| Option | Verdict |
|---|---|
| A. Legacy private app | Rejected: cannot be created by a new account; end of support September 2027. |
| **B. Service key** | **Chosen.** Account-scoped, granular scopes, 7-day-grace rotation, static bearer token. Public beta, and test-account support is unverified (H0). |
| C. Static-auth private project app | **Fallback** if B is unavailable. Same static token, same secret path; needs the owner to set up the HubSpot CLI. |
| D. OAuth app (`127.0.0.1` callback) | Rejected: a redirect endpoint, client secret and refresh token are more secret material for one account. Its only unique benefit is renewing the test account by API. |

### Change detection

- **Webhooks:** rejected. No public endpoint, and service keys cannot
  authenticate them.
- **Polling with typed cursors plus a daily full fingerprint scan:**
  **chosen.**

### Logging the captured send

- **Email engagement `SENT`:** rejected. Nothing is delivered in this app,
  and it needs `sales-email-read`.
- **Timeline event:** rejected. Needs a public app.
- **Note:** **chosen.** It says "captured locally, not delivered".

### Idempotency of HubSpot creates (revised per finding 1)

HubSpot documents no idempotency key for note or task creates. A local unique
key with one claimant prevents concurrent dispatch, but it cannot prevent a
duplicate remote create after an ambiguous response.

| Option | Verdict |
|---|---|
| Retry after N absent searches | **Rejected** (finding 1). Absence in an eventually consistent index is not evidence that the create did not apply. |
| **Provider-enforced unique marker property** `sdr_write_key` (`hasUniqueValue: true`) on notes and tasks, created by the owner in HubSpot settings (no schema scope for the app) | **Preferred, if H0 proves notes and tasks support it.** A repeated create with the same value is rejected by HubSpot. That is an authoritative idempotency guarantee, so a retry is safe and the outcome is readable by `idProperty` lookup. |
| **No automatic retry of uncertain creates** | **Required otherwise.** An `unknown` create stays `unknown` until there is an authoritative strong match (`succeeded`), authoritative non-application evidence, or a guarded human decision. |

## Decision

### 1. Credential, secret containment, preflight (finding 6)

**Storage.**
- The secret lives in a gitignored `secrets/hubspot.local.sops.yaml` (new
  `.sops.yaml` rule), with keys `hubspot.service_key` and `hubspot.portal_id`.
  The owner adds the values. Agents never ask for, read, print or copy the
  key.
- `bin/with-secrets` maps `SDR_HUBSPOT_SERVICE_KEY` and
  `SDR_HUBSPOT_PORTAL_ID`.

**Read once at boot, then removed from the environment.**
- A supervised `SdrAgent.Integrations.HubSpot.CredentialHolder` reads both
  variables at boot and keeps them in its process state.
  - The process is marked `Process.flag(:sensitive, true)` and implements
    `format_status/1` redaction, so the key does not appear in crash reports
    or tracing.
  - It then **calls `System.delete_env/1` on both HubSpot names**, so no
    child process spawned later inherits them. The audit-anchor key is not
    deleted, because `AnchorWorker` reads it from the environment at run
    time.
  - The key never enters `Application` env, Postgres, Req defaults, logs,
    spans, Failures, AuditEvents or Payloads.
- **Every child launch scrubs these names as well.** The child launchers are
  ClaudeCLI's `Port.open`, the `git`/`ots` `System.cmd` calls in provenance,
  anchoring and sinks, and any later one. Each passes `{name, false}` for
  every name in `SdrAgent.ChildEnv.secret_names/0`. This is defence in depth,
  because Erlang's `:env` option *adds to* the inherited environment rather
  than replacing it.
- A canary test runs each launcher against `/usr/bin/env` and asserts that
  no mapped name or value appears.
- *Pre-existing gap:* when the server runs under `bin/with-secrets`, the
  audit-anchor key is inherited today by the ClaudeCLI and `git` children.
  Only the OTS sink already unsets it. H1a's scrub list covers every mapped
  name, which closes this gap.

**Rotation needs a restart**, because the key is read once.
- The owner rotates with *expire later*, updates the sops file, and restarts
  the server within the 7-day grace.
- A key revoked in HubSpot surfaces as a 401. That marks the credential
  `missing` and opens a critical Failure, and all HubSpot I/O stops.

**`IntegrationCredential`** (S2 row, built in H1a) holds a reference only.
- Provider `hubspot`; `credential_kind: sops_path`.
- Fingerprint: `portal:<id>/<dataHostingLocation>`. No key material is kept.
- `credential_epoch` is incremented by every reference, portal, revoke or
  status change.
- `verified_until`.
- `write_mode` (`off`/`dry_run`/`live`, H2).

**Preflight is strict and fails closed.**
- `:record_preflight` (CRS) takes only the id of the `CrmApiCall` row for the
  account-details request. The action reads that call's stored response
  through a scoped content read and derives the result itself. No caller
  supplies a "verified" flag.
- `verified` requires both:
  - `accountType == "DEVELOPER_TEST"`;
  - `portalId == SDR_HUBSPOT_PORTAL_ID`.
- Validity lasts at most 1 h, bound to the current epoch. Every HubSpot
  request checks epoch and validity before I/O.
- No portal-id-only substitute exists. If neither credential type B nor C can
  prove `DEVELOPER_TEST`, the integration stays disabled.
- `STANDARD` portals are refused until the ADR-0002 data-classification ADR
  exists.

**Scopes (minimal, added per slice):**

| Slice | Scopes |
|---|---|
| H1 | `crm.objects.contacts.read`, `crm.objects.companies.read`; plus `subscriptions-status-read` only if H0 shows `hs_email_optout` is unreliable |
| H2 | `crm.objects.contacts.write`, `subscriptions-status-write` |

Never granted: deals, owners, schemas write, lists, `sales-email-read`,
timeline, batch scopes or sensitive scopes. The `sdr_write_key` property, if
used, is created by the owner in the UI.

**Echo containment.**
- Before any response body or error text is persisted (Payload, Failure, UI)
  or summarized, it is scanned for the exact key bytes held by the holder and
  for the redactor's secret shapes, including the new `pat-<region>-…` shape.
- An exact-key echo withholds the body: a placeholder Payload
  `{"withheld":"secret_echo"}` is stored and a critical Failure is opened.
- Spans never carry bodies.

### 2. One gate, metered on every request (finding 3)

**The gate.** *Every* HubSpot request goes through one supervised
`SdrAgent.Integrations.HubSpot.Gate`, whatever its caller:

- preflight;
- import and poll pages;
- archived and full scans;
- the research call `GetCRMHistory`, which runs synchronously on the
  `research` queue;
- subscription reads;
- writes;
- reconciliation lookups;
- the external smoke test.

**Pacing.**
- Concurrency 1 across the node. The app is single-node; a multi-node
  deployment would need a new ADR.
- At least 200 ms between requests and at least 500 ms between searches.
- `X-HubSpot-RateLimit-Remaining` is honoured.
- Each caller sets a bounded queue deadline (default 30 s). If it expires,
  the call returns `:gate_timeout` **before** any reservation or request.

**Reservation before I/O.** For each attempt the gate:
1. In a short committed transaction, increments `CrmRequestDay(tenant,
   portal, utc_date = reservation day)` with an atomic conditional
   `reserved < cap`. The default cap is 5,000 per UTC day; config may lower
   it, never raise it. In the same transaction it inserts a `CrmApiCall` row
   (`reserved`) carrying the purpose, templated route, caller reference and
   the credential epoch.
2. Releases all database locks, then performs the HTTP call. No database or
   chain lock is ever held across remote I/O.
3. In a second short transaction, records the outcome on the `CrmApiCall`.
   The state becomes `completed` with status, or `failed_before_send`, or
   `unknown`.

**Attribution and no refunds.**
- A request is attributed to the UTC day it was reserved, even if the
  response arrives after midnight.
- Reservations are never refunded. Uncertain and failed attempts count.

**Crash safety.**
- A `CrmApiCall` left `reserved` or `sent` past its deadline is marked
  `unknown` by the CRM sweeper (REC), opening an attention item.
- The sweeper never resends.

**Cap and limit handling.**
- An exhausted cap ends the caller's work with `request_budget` and a warning
  Failure.
- A 429 `DAILY` pauses all HubSpot I/O until the account's midnight.
- A ten-secondly 429 backs off for at least 10 s.
- Run counters no longer count requests. `CrmApiCall` is the single source,
  and the verifier recomputes `CrmRequestDay` from it.

**The HTTP client** sits inside the gate and uses Req only:
- Base `https://api.hubapi.com`, host and scheme checked before every
  request.
- DBV pinned to `2026-09` in one attribute.
- `redirect: false`, `retry: false` (the gate and Oban own retries), explicit
  timeouts.
- Telemetry is emitted by the gate itself, not by `OpentelemetryReq`'s
  automatic URL attributes. It records method, templated route
  (`…/statuses/{subscriber}`), status and the `CrmApiCall` id, and never the
  raw path, query, headers or body.
- A test asserts that no span attribute contains an email, the key, or
  `authorization`.

**Error classes:**

| Response | Class |
|---|---|
| 401 | `unauthorized` |
| 403 | `forbidden` (redacted scope hint) |
| 404 | `not_found` |
| 400/409/validation | `invalid` |
| 423 | `locked` |
| 429 | `rate_limited{policy}` |
| 477 | `migrating{retry_after_s}` |
| 5xx/52x | `server_error` |
| connect failure before any request bytes | `failed_before_send` |
| timeout or closed connection after send | `unknown` |

For writes, how each class is treated depends on whether the operation is
idempotent (§5).

### 3. Identity: links, merges, fingerprints, binding (finding 2)

**HubSpot identity lives only in `CrmLink`** (CRM domain). It is append-only,
with supersedes lineage, and maps a local subject (Account or Contact) to
`(provider, portal_id, object_type, remote_id :: bigint)`.

- Link states are `active`, `alias` (a merged-away remote id now served by a
  winner), `conflict`, `remote_archived` and `retired` (old portal).
- A change is a new row superseding the current one. A row is never edited.
- Account and Contact keep their existing `crm_*` columns for FakeCRM only,
  and no HubSpot identity is written into Sales columns. This removes the
  previous "immutable column vs merge re-point" contradiction.
- Every derived record pins the *specific link row* it used:
  `CrmWriteOperation.crm_link_id` and `ResearchArtifact.metadata.crm_link_id`.
  History stays pinned when a link is superseded.

**Merge rules**

| Case | Result |
|---|---|
| Loser and winner map to the same local contact, or only one maps | A new `alias` row for the loser and a current `active` row for the winner. |
| They map to different local contacts | Both links → `conflict` (no automatic local merge), a warning Failure, and writeback and research for both are frozen until an ADM resolution (an H3 guarded action). |

**Portal replacement.** A new allowlisted portal id creates new links; old
ones are never matched. ADM `retire_portal` (guarded) supersedes the old
portal's links with `retired` and cancels their pending writes.

**Qualified research identity**
- The `CRM` behaviour gains `fetch_record(%CrmRef{provider, portal_id,
  object_type, remote_id})`. `fetch_contact/1` is kept for FakeCRM. A HubSpot
  `fetch_contact/1` call with a bare id is refused.
- `GetCRMHistory` resolves the contact's *current active* `CrmLink`. The
  adapter refuses `{:error, :portal_mismatch}` unless the ref's portal is the
  verified portal and the epoch is current. An old portal's id therefore can
  never fetch a new portal's record.
- Each artifact records a version watermark in metadata: link id, portal,
  remote id, remote `lastmodifieddate` and the current `CrmImportRecord` id.

**Semantic fingerprint and high-water mark**
- `semantic_sha256` is computed over the canonical form of:
  - mapped properties;
  - remote state;
  - `merged_into`;
  - sorted `hs_merged_object_ids`;
  - the primary-company association remote id.
- Per remote subject, `CrmImportRecord` keeps a high-water mark of
  `(remote_modified_ms, fetched_at)`.
- A fetched version with an *older* `remote_modified_ms` than the current
  record's is `stale_ignored`: counted, never applied, never written.
- A version with an equal timestamp and a different fingerprint is applied
  only if fetched later (recorded as a tie).
- An unchanged fingerprint writes nothing.
- An out-of-order read can therefore never revert email, profile or link
  state.

**Binding checks inside each direct action, not only in orchestration**
- Each CRS action on a lower-domain row validates, inside the action, a
  `crm_import_filter` Decision. Decisions live in the lower Agents domain, so
  no upward dependency is created. The actions are Account/Contact
  `:import`/`:sync_update`/`:sync_email`, Lead `:create_from_crm`, and
  Suppression `:from_crm`.
- The Decision must match:
  - same tenant;
  - actor type CRS;
  - kind;
  - an `allow` (or `opt_out`) outcome;
  - a subject ref equal to the provider, portal and remote id passed as
    arguments;
  - for Contact writes, the target local subject id;
  - `outcome_detail.semantic_sha256` equal to the fingerprint of the values
    being written.
- A mismatch is refused, and the denial is audited.

### 4. IMPORT and RESEARCH (H1)

**Per-record gate.** Each fetched record passes, in this order:
1. **Synthetic guard** on company domain and contact email (ADR-0009 §9, not
   weakened).
2. **Required fields.**
3. **Opt-out.** `hs_email_optout == true` → Suppression `crm_opt_out` in the
   same transaction. If the value is absent, the state is unknown: it is
   checked with `GET …/unsubscribe-all` through the gate. Unknown blocks
   Lead creation.
4. **Link resolution:** existing link, email adoption of an unlinked local
   contact, or a conflict.

**Filtering before persistence.**
- Raw search pages are never persisted. Filtering happens in memory before
  anything is written.
- A skipped record stores only its remote id and reason, never its
  properties. This applies equally to dry-run reports, provenance and
  Payloads.
- The dry-run report holds counts, plus remote ids and reasons for skips,
  plus the mapped synthetic values of would-import records.

**Field mapping.** Unchanged from revision 1.
- Company → Account: `name`, `domain`, `website` (reserved hosts only),
  `industry`, `numberofemployees`, `country`.
- Contact → Contact: `firstname`, `lastname`, `email`, `jobtitle`, and the
  primary company.
- Lifecycle stage, lead status and owner id are kept in the snapshot only.

**Suppression guards**
- **Email change from HubSpot on a suppressed contact** (email or domain
  scope): refused. The link → `conflict` and a warning Failure is opened. The
  local email and the suppression both stay.
- **Adoption** of a local contact under a suppression keeps that suppression.
- **Restoring an archived record in HubSpot** does not lift
  `crm_record_deleted` (H3).
- **Sync can never move a contact's link or email in a way that drops an
  existing suppression.**

**Leads.** `:create_from_crm` follows the owner-confirmed rule (OQ-A) and is
never auto-assigned.

**Research**
- `crm_record` (structured properties): `trust_level: :medium`.
- `crm_activity`: the last 20 notes and tasks plus email metadata (no
  bodies), `trust_level: :unverified`.
- Both use the non-fetchable `hubspot://<portal>/<type>/<id>` URI.
- Prompt templates get a version bump and render every source inside a
  delimited data block marked as data and never instructions. There are
  still no model tools, grounded quotes are required, and Tier-0 approval
  still applies.
- Notes carrying our `sdr_write_key` or body marker are excluded from
  evidence.

### 5. WRITEBACK (H2; to be re-submitted before H2a; findings 1, 5)

**Planner (CRS)**
- Reads the audit ledger through a narrow `AuditEvent :crm_feed` read (§7).
  The feed filter is an allowlist of source event types; `crm.*`,
  `operations.*` and `audit.*` events are excluded.
- For each relevant event it creates a `CrmWriteOperation`.
- **Target-scoped key:**
  `crm:v1:<portal>:<kind>:<target_remote_id>:<source_resource>:<source_id>`.
  - `request_sha256` is computed over the immutable request meaning: kind,
    target, canonical body, `hs_timestamp`, marker.
  - Re-planning the same key with the same hash is a no-op.
  - The same key with a different hash fails with `IdempotencyConflict`,
    never a silent no-op.
  - A different portal or target is a different key. Old operations are
    never retargeted.
- **No idle churn.**
  - The ledger cursor is advanced only in a transaction that also inserts at
    least one operation.
  - Scanning past irrelevant events moves the scan position, held in the job
    arguments, with no database write.
  - A "high-water" cursor update is written only when 1,000 or more events
    have been skipped since the last one. That update is not AE'd and is a
    derived position the verifier recomputes.
  - Idle cycles write nothing. A test runs N idle cycles and asserts zero new
    AuditEvents and rows.
- Suppressions with reason `crm_opt_out` *or* `crm_record_deleted` never
  produce an `unsubscribe_all` write (no echo).

**Operation kinds**

| Kind | Idempotent remote effect? | Notes |
|---|---|---|
| `log_note` (capture) | No | "captured locally, not delivered" note |
| `create_task` (interested hand-off) | No | Task notifications reach portal users; a duplicate is an external effect, not harmless |
| `update_lead_status` (`CONNECTED` on reply, `UNQUALIFIED` on disqualify) | Yes | Set-to-value |
| `unsubscribe_all` | Yes | |

**Claim gate.** `pending → attempting` runs CRW's `crm_writeback_gate`
Decision inside the claim transaction. The claim:
- locks the operation row FOR UPDATE;
- sets `claimed_by_job_id` and `lease_expires_at`;
- records `credential_epoch`.

The Decision requires:
- **Mode:** effective mode `live`, which is the minimum of a config ceiling
  (default `:off`; `:off` in test; refused at boot in prod), an env flag, and
  the persisted `write_mode`. Only ADM changes `write_mode`, and the change
  is a guarded action.
- **Credential:** verified, in its validity window, on the same epoch, with
  the allowlisted portal.
- **Link:** the pinned `crm_link_id` is still the current active row for the
  target (not superseded, conflict, retired or archived).
- **Source still valid:**
  - the delivery is still accepted;
  - the ReplyAssessment is still the current, non-superseded assessment and
    is `interested`;
  - the matched reply still exists;
  - the lead is still disqualified;
  - the suppression still exists.
- **Contact:** the contact's email equals the email pinned at planning.
- **Suppression:** for every kind except `unsubscribe_all`, no local
  suppression (email or domain). This is the *only* check an unsubscribe
  bypasses. Portal, credential, mode, budget, link and identity checks still
  apply.
- **Age:** less than 7 days since planning (otherwise cancelled as `stale`).

Mode `off` leaves the operation pending. Mode `dry_run` ends it at
`skipped_dry_run` with no HTTP.

**Dispatch and outcomes**
- The worker reads its request Payload through the scoped read (§7) and
  sends it through the gate. The gate first re-checks that the epoch is
  unchanged and that the lease is held by this job. If either check fails,
  the operation is released to `pending` with no request sent.
- Outcome mapping:

| Result | Idempotent kinds | Non-idempotent creates |
|---|---|---|
| 2xx | `succeeded` | `succeeded` |
| `failed_before_send`, 429, 423, 477 | `failed_retryable`, bounded to 3 | `failed_retryable`, bounded to 3. These are rejections before processing or before any send. |
| 400/401/403/404/409 | `failed_permanent` + Failure | `failed_permanent` + Failure |
| 5xx/52x or `unknown` | Retryable after a read-back reconciliation | **`unknown`** + `reconciliation_required` Failure |

- The result transition is a conditional update requiring
  `state = attempting AND claimed_by_job_id = mine`.
- A late result whose lease was lost is stored as a `late_observation`
  Payload on the operation, not as a transition. REC then uses it as
  authoritative evidence.

**Reconciliation of `unknown` (REC, `crm_write_reconciliation` Decision)**
- **With `sdr_write_key`:** look up by `GET …/{notes|tasks}/{key}?idProperty=sdr_write_key`.
  - Found with a strong match → `succeeded`.
  - Authoritative 404 → `failed_retryable`. The retry is safe because HubSpot
    enforces uniqueness.
- **Without it:** read the contact's associated notes or tasks plus batch
  reads.
  - Exactly one **strong match** → `succeeded`.
  - Two or more → stays `unknown` and the Failure is raised to critical
    (ambiguous).
  - Zero matches → **stays `unknown`**. A negative search is not evidence of
    non-application.
- **A strong match requires all of these:**
  - same portal;
  - the expected association to `target_remote_id`;
  - the same object kind;
  - the full marker (64-hex sha256 of the key, in `sdr_write_key` or the
    body footer);
  - equal `hs_timestamp`;
  - a canonical body hash equal to the request's.
- **Human-guarded exits** (ADM; the reason is recorded and the denial
  audited):
  - `resolve_unknown_as_absent`: the operator has checked the HubSpot UI;
    → `failed_retryable`, which then needs another claim.
  - `abandon_unknown` → `abandoned` (T).
- Idempotent kinds reconcile by read-back: the property value or the
  unsubscribe-all status.
- Tests cover:
  - delayed visibility;
  - a lost response after a successful create;
  - an ambiguous duplicate;
  - a 5xx after send;
  - a late result after lease loss.

**Stale attempts.**
- The CRM sweeper (REC, `crm` queue, every minute) moves `attempting` rows
  past `lease_expires_at` to `unknown` (`stale_attempt`) with attention.
- It never resends. The original job, if it is still running, loses its
  conditional transition.

**Reach.**
- Notes, tasks, lead status and unsubscribe-all do not email contacts. Task
  notifications reach portal users (the owner).
- The owner must not configure HubSpot workflows that email on property
  changes.
- The first `live` enablement is a reviewed PR followed by the owner
  checkpoint.

### 6. SYNC (H3; to be re-submitted before H3)

**Typed cursors (important item).**
- A position is `(remote_modified_ms :: bigint, remote_id :: bigint)`,
  ordered numerically. The search `GT`/`GTE` filters use the same typed
  values.
- Each page runs in its own transaction. The cursor advances only with a
  committed page, and only monotonically.
- If a query nears 10,000 results, a new query starts at the last typed
  position, filtered on `hs_object_id GT` within an equal timestamp.

**Completeness.**
- The 10-minute overlap window handles normal indexing lag but is *not* a
  completeness proof.
- A daily `full_scan` (by `hs_object_id` ascending, no time filter) compares
  semantic fingerprints. A test portal is small, so this is bounded. Any
  record missed by a late index is caught within 24 h.
- Tests cover late, stale and equal-timestamp records, and crash recovery
  after an incomplete page.

**Runs.**
- `CrmSyncRun` is terminal-immutable and its Oban job runs with
  `max_attempts: 1`.
- The CRM sweeper marks a crashed run `failed` (`crash`) after its lease
  expires.
- Recovery is always a **new run** starting from the persisted cursor
  (cursor continuity). ADM may start one through the subject action
  `CRM.start_sync_run/2`, which creates the run, its Operation and its job.
  There is no generic Operation `:retry` row flip for CRM kinds (the S13b
  contract).

**Deletions and merges.**
- An `archived_scan` creates an archived `CrmImportRecord`, a link →
  `remote_archived`, an archived Contact, and a `crm_record_deleted`
  Suppression (OQ-C).
- Merges follow §3.

**Conflict rules.**
- HubSpot owns mapped profile fields.
- Local owns lead lifecycle, qualification, drafts, approvals, deliveries and
  replies.
- For suppression, the most restrictive state wins and is never lifted.
- ADM edits of HubSpot-owned fields on linked rows are refused (OQ-B).

### 7. Grants (finding 4)

New actors: CRS (`:crm_sync`) and CRW (`:crm_writer`). REC is existing.
Every grant below is narrow and has allow and deny tests. There is no broad
Payload read, no Kernel-context bypass and no `authorize?: false`.

| Resource | Delta |
|---|---|
| **Payload** | `:store` += CRS, CRW. `:read_crm_content`, a new generic action: CRW reads only its claimed operation's `request_sha256`; REC reads only that operation's request, response and `late_observation` hashes; CRS reads only one `CrmApiCall`'s response hash (preflight). Scope `SdrAgent.Audit.Checks.CrmContentScope`, built by the CRM domain from the authoritative row and attached as private context, mirroring `ReconciliationScope`. Fixed purposes: `crm_dispatch`, `crm_reconciliation`, `crm_preflight`. Fail-closed AuditAccess (`payload_view`) before content. Guarded. |
| **AuditAccess** | No schema change. Three new fixed purpose values written only by the kernel's read path. |
| **AuditEvent** | New read action `:crm_feed`, CRS only: event-type allowlist, `sequence > given`, `limit ≤ 500`, and fields `id, sequence, event_type, subject_resource, subject_id, occurred_at` only (no payload). It reads metadata, not content, so no AuditAccess is appended. This deviation is recorded: appending one would create events the feed would then read. |
| **Failure** | `@system` (`:open`) += `:crm_sync`, `:crm_writer`. `:resolve` is unchanged: REC, plus the opener resolved from the ledger by `FailureResolver`, which therefore also covers CRS and CRW for Failures they opened. |
| **Reads** | Account, Contact, Lead: += CRS, CRW. Suppression: += CRS, CRW. DeliveryOperation, DeliveryReceipt, Reply, ReplyAssessment: += CRS (planning), CRW (gate re-check). Decision: unchanged (`actor_present`). Operation: += CRS, CRW. IntegrationCredential: field-scoped. |
| **IntegrationCredential fields** | ADM: all fields. REV, AUR: provider, status, `write_mode`, `last_verified_at`. CRS, CRW, REC: status, `write_mode`, `credential_epoch`, `verified_until`, fingerprint. |
| **Writes** | Account, Contact: `:import`, `:sync_update`, `:archive` (CRS). Contact `:sync_email`, refused when suppressed (CRS). Lead `:create_from_crm` (CRS). Suppression `:from_crm` (CRS; reasons `crm_opt_out`, `crm_record_deleted`). Decision kinds `crm_import_filter` and `crm_lead_rule` (CRS), `crm_writeback_gate` (CRW), `crm_write_reconciliation` (REC). Operation kinds `crm_*` on queue `crm`, with no ADM `:retry` for them. |
| **Guarded actions** (denial-audit contract) | `set_write_mode`, `retire_portal`, `resolve_link_conflict`, `resolve_unknown_as_absent`, `abandon_unknown`, ADM cancel of a write operation, `:read_crm_content`. |

### 8. Lock order (finding 5)

Every CRM transaction pre-locks, before its first audited write, in this
fixed order:

1. `IntegrationCredential`
2. `CrmSyncCursor`
3. `CrmLink` current rows (ascending id)
4. Account
5. Contact
6. Lead(s)
7. `CrmWriteOperation`

Suppression creation then follows its existing S8 lock order. The audit
chain head is taken by the first append, so it is always last.

`CrmRequestDay` and `CrmApiCall` writes are their own short transactions,
never nested in the above, and never held across I/O.

**Residual window, accepted.** A note, task or status write already claimed
can still be sent if a Suppression commits between claim and HTTP. These
writes do not contact the person, and an unsubscribe is unaffected.

### 9. Tests and external smoke (important item)

- **Hermetic suite.** Tests use `Req.Test` stubs with hand-written synthetic
  fixtures only.
- **Refusals.** The client refuses to run in `:test` without the stub.
- **Smoke test.** The only escape hatch is
  `HubSpot.Client.live_smoke!/0`. It works only when all of these hold:
  - `MIX_ENV=test`;
  - `SDR_HUBSPOT_EXTERNAL_SMOKE=1`;
  - `ExUnit.configuration()[:include]` contains `:external`;
  - `CI` is unset.

  In that mode the gate allows only `GET account-details` and one `POST
  contacts/search` page. Every other route is refused.
- **CI guard.** A test fails CI if `SDR_HUBSPOT_EXTERNAL_SMOKE` is set there.

### 10. Dependencies

None. Req 0.7.5 (includes `Req.Test`), Plug, Oban and Ash are already locked.

## Justification

- **Service key.** It is HubSpot's recommended single-account, REST-only
  credential, and the only static option a new test account can still
  create without a CLI project.
- **Secret containment.** Reading the key once and removing it from the
  environment makes the "never transmit secrets" invariant hold for child
  processes too.
- **Single gate.** Metering every request in one place makes the request
  budget and serialization provable rather than per-queue.
- **Append-only links with pinned rows.** Merges, portal changes and history
  are expressible without mutating identity.
- **Non-idempotent creates stay `unknown`** without authoritative evidence,
  which keeps the no-blind-resend invariant.

## Consequences

### Positive

- Every imported value, API request and write is reconstructable from
  Postgres.
- Writeback can be observed in dry-run mode before any byte leaves the
  machine.
- The audit-anchor key also gains child-environment containment.

### Negative

- Service keys are in beta, and several H0 facts are unverified.
- An `unknown` create without the unique marker property needs a human
  decision.
- Rotating the key needs a restart.
- Polling latency is up to 15 minutes, with a 24-hour completeness bound.
- The gate is a deliberate single-node bottleneck.
- The test portal expires after 90 idle days.

### Neutral

- New top domain `SdrAgent.CRM`; the layering becomes
  `… <- Outreach <- CRM`. ADR-0009 §7 needs an amendment when this ADR is
  accepted.
- `STANDARD` portals stay out of scope.
