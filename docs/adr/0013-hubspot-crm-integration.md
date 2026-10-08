---
status: proposed
date: 2026-10-07
supersedes: null
---

# ADR-0013: HubSpot CRM Integration (Developer Test Account, Service Key, Polling, Outbox Writeback)

## Status

Proposed (2026-10-07, Claude). This is revision 3.

| Revision | Responds to | Codex verdict |
|---|---|---|
| 2 | `4ab68bc3-c1ea-44ff-970d-a063d59f8fdd` | NEEDS-REVIEW on `fa44235` |
| 3 | `c40afc58` (Part A, six blocking contracts) | NEEDS-REVIEW on `940df11` |

The finding-to-change mapping is in
`notes/features/hubspot-integration.org` ("Soft-stop review").

The owner decided on 2026-10-07 to integrate with HubSpot, tested against a
**free HubSpot developer test account**. The app stays a personal, local demo
run with the owner's own credentials: no hosting and no public webhook
endpoint.

This ADR is design only. Review is split into gates (§0):

- **A1:** H1a, the credential holder, the request gate and preflight.
- **A2:** H1b and H1c, import and research.
- **B:** H2 and H3, writes and sync. It is re-submitted later.

ADR acceptance requires entity PASS on every gate it covers, plus the owner's
answers. The first live write is an owner checkpoint.

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

## Owner Decisions

Relayed by the coordinator on 2026-10-07.

- **OQ-D (credential): DECIDED 2026-10-07, yes.**
  - A HubSpot service key (public beta) is the primary credential.
  - The static-auth private project app token is the fallback.
  - The secret lives in a separate gitignored sops file
    (`secrets/hubspot.local.sops.yaml`) that only the owner edits.
- **OQ-A (lead creation): DECIDED 2026-10-07.**
  - Leads are auto-created by the proposed rule (§4, `crm_lead_rule`).
  - Each lead must pass the reserved test-domain guard and the suppression
    checks.
  - Leads are never auto-assigned.
- **OQ-B (field ownership): DECIDED 2026-10-07, Option 1.**
  - HubSpot wins for the profile fields of linked contacts: name
    (first and last), title and email.
  - Local admin edits of those fields are refused.
  - The app owns lead lifecycle, approvals and deliveries.
  - The owner named contact fields. The same Option-1 rule is applied to the
    mapped fields of linked Accounts; this is flagged for owner confirmation
    in the notes.
  - The owner asked for two UI affordances in the plan: an **"Edit in
    HubSpot"** link on linked contacts, and an admin **"Sync now"** action
    metered through the Gate (§4).
- **OQ-C, OQ-E: open, for gate B.**

These answers satisfy every owner gate on A1 and A2: OQ-D gates H1a, and
OQ-A and OQ-B gate H1b. The entity-review gates A1 and A2 are still
required.

**Scope note (2026-10-07).** The coordinator is landing the `.gitignore`
entry and the `.sops.yaml` creation rule for
`secrets/hubspot.local.sops.yaml` as a small separate PR, so the owner can
store the key early. That work is no longer part of H1a.

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

### 0. Review gates

The design is reviewed in three gates. Each gate's rows are listed in
`notes/features/hubspot-integration.org`.

| Gate | Slices | Content | Also needs |
|---|---|---|---|
| **A1** | H1a | credential holder, child-env containment, Gate (ownership, metering), preflight bootstrap, Req client, and the grants for exactly these paths | entity PASS; owner answer OQ-D |
| **A2** | H1b, H1c | import, links, watermark, action bindings, opt-out suppression, research | entity PASS (owner answers OQ-A and OQ-B given 2026-10-07) |
| **B** | H2, H3 | writes and sync | re-submitted later; not covered by any A PASS |

**No grant listed under B is implied by an A1 or A2 PASS.** The CRW actor
and every CRW grant are Gate B.

### 1. Credential holder, child-env containment, epochs (A1)

**Storage.**
- The secret lives in the gitignored `secrets/hubspot.local.sops.yaml` with
  **flat** keys `hubspot_service_key` and `hubspot_portal_id`. Flat keys work
  with `sops exec-env` for the owner-only H0 probe (§10).
- `bin/with-secrets` maps them to `SDR_HUBSPOT_SERVICE_KEY` and
  `SDR_HUBSPOT_PORTAL_ID`.
- The owner adds the values. Agents never ask for, read, print or copy the
  key.

**`CredentialHolder`.** A supervised process and the *first* child of the
application supervisor: it starts before the Gate, Oban, the ClaudeCLI
runtime and every other launcher.

1. At start it reads both variables into its process state.
   - The process sets `Process.flag(:sensitive, true)`.
   - `format_status/1` redacts its state.
   - `Logger` metadata never carries the key.
2. It then calls `System.delete_env/1` for the two HubSpot names.
3. The anchor key is *not* deleted, because `AnchorWorker` reads it at run
   time. Child scrubbing below covers it.

**Holder loss fails closed.**
- If the holder crashes, its restart finds the variables already deleted. It
  starts in `:unavailable`, the Gate admits nothing, and a critical Failure
  ("restart required") is opened.
- Recovery needs a full server restart under `bin/with-secrets`.
- Key rotation works the same way. The owner uses *rotate and expire later*,
  updates sops, and restarts within the 7-day grace. A running process keeps
  the key it booted with.

**Child-env scrub, for every launcher.**
- *All* child processes are started only through `SdrAgent.ChildEnv`
  (`cmd/3`, `port_open/2`). These wrappers pass `{name, false}` for every
  name in `ChildEnv.secret_names/0`, which is every `bin/with-secrets`
  mapping. Erlang `:env` *adds to* the inherited environment, so the explicit
  unset matters.
- A source-inventory test fails if `lib/` calls `System.cmd`, `Port.open`,
  `:os.cmd` or `:erlang.open_port` outside `ChildEnv`. This covers the
  existing ClaudeCLI, git (provenance, anchoring, git sink) and ots
  launchers, and anything added on the rebased base (for example the #27
  ps/pgrep/kill reaper and #32 `id`).
- A canary test sets fake values for every mapped name, boots the holder,
  and runs each launcher kind against `/usr/bin/env`. Neither the names nor
  the values may appear. Agents never inspect the real key.
- This also closes the existing inheritance of the anchor key by the
  ClaudeCLI and git children; today only the OTS sink unsets it.

**`IntegrationCredential` (Operations) attributes**
- Existing: `provider`, `credential_kind`, `reference`, `status`.
- `allowlisted_portal_id`: set at registration from the holder's portal and
  changed only by a guarded ADM action.
- `credential_epoch`.
- `verified_until`.
- `last_evidence_sequence` (§2).

**The epoch increments exactly on:**
- **every boot** (KRN `:begin_boot_epoch`, so every boot needs a fresh
  preflight and a rotated key is never "already verified");
- ADM changes of `reference` or `allowlisted_portal_id`;
- `revoke`.

Status changes caused by preflight (verified, missing, expired) do *not*
increment it.

**When the holder and the row disagree.** The holder's boot-time portal must
equal `allowlisted_portal_id`. Otherwise the Gate admits nothing, preflight
included, until a restart, and the credential shows `restart_required`. A
reference or portal changed while running therefore stays closed until the
process reloads.

### 2. Preflight bootstrap and authoritative evidence (A1, finding 3)

**Admission rule.** Every CRM data route requires all of:
- `status = verified`;
- `credential_epoch` equal to the Gate's boot epoch;
- `verified_until > now`;
- the holder's portal equal to the allowlisted portal;
- the holder `:available`.

**Bootstrap exception.** Exactly one route is admitted *without* current
verification: `GET` account details (the dated path if H0 shows it works,
else `/account-info/v3/details`). It must also have:
- purpose `preflight`;
- actor CRS;
- credential status ∈ {unverified, verified, missing, expired};
- the current epoch;
- holder available;
- portal match.

It is still metered. `revoked` and `restart_required` refuse it too. No other
route is ever admitted before verification.

**Re-probe schedule** (`PreflightWorker`, CRS):
- at boot;
- every 50 minutes while verified (before `verified_until` lapses);
- with backoff while `missing` or `expired`: at most one automatic probe per
  15 minutes;
- on demand through ADM `request_preflight` (guarded). This is the
  controlled recovery path.

**Evidence that stays inside the lower layers.** Operations cannot read the
higher CRM `CrmApiCall` table. The evidence is therefore the Audit-domain
ledger event that the Gate's finish transaction appends:
`crm.api_call.finished`, recorded by the kernel with `actor_type`. Its
payload holds:
- `credential_id`, `credential_epoch`;
- `purpose`, `route_template`;
- `http_status`, `response_sha256`;
- `withheld` (echo detected);
- `finished_at`.

`IntegrationCredential :record_preflight` (CRS) takes **only** that event's
id. It reads the event through a new narrow Audit read
`AuditEvent :preflight_evidence` (CRS only; one event by id; fixed fields;
metadata, not content).

**The action itself validates:**
- the event type and `actor_type = crm_sync`;
- same tenant;
- `credential_id` equal to this row;
- epoch equal to the current epoch;
- purpose `preflight` and the exact account-details route template;
- `http_status = 200` and `withheld = false`;
- `finished_at` within 5 minutes of now;
- the event's sequence greater than `last_evidence_sequence` (no replay of an
  older or the same event).

**Reading and deciding.**
- The action then reads `response_sha256` through
  `Payload :read_crm_content` under `PreflightEvidenceScope`, an Audit check
  that admits only the hash named by that validated event, with fixed
  purpose `crm_preflight` and fail-closed AuditAccess.
- It parses the body and sets `verified` only if `accountType ==
  "DEVELOPER_TEST"` and `portalId == allowlisted_portal_id`.
  `verified_until` is set to now + 1 h and `last_evidence_sequence` advances.
- Any other result sets `missing`, opens a critical Failure, and still
  advances `last_evidence_sequence`. No caller supplies a result or a boolean.

**Required negative tests:**
- first boot (unverified; only bootstrap admitted);
- expired verification (data routes refused, re-probe admitted);
- missing with backoff;
- revoked;
- restart_required;
- evidence from an old epoch;
- a replayed or older event;
- wrong purpose or route;
- another credential's event;
- a non-CRS actor event;
- a non-200 or non-completed call;
- a withheld (echo) body;
- an event older than 5 minutes;
- `STANDARD`, `SANDBOX` and `APP_DEVELOPER` accounts, and a wrong portal.

### 3. Gate: serialization, metering, transport ownership (A1, finding 4)

**One admission point.** `SdrAgent.Integrations.HubSpot.Gate` is a single
supervised GenServer and the only way to reach HubSpot. Its callers are:

| Caller | Paths |
|---|---|
| CRS | preflight, import, scans, subscription reads |
| AGT | research, which runs synchronously on the `research` queue |
| REC | reconcile (Gate B) |
| CRW | writes (Gate B) |
| Smoke test | §10 |

At most one attempt is in flight per node. The app is single-node; more nodes
would need an ADR.

**Authority stays with the caller.** The Gate has no system identity of its
own for CRM data. It reserves and finishes each attempt *under the caller's
actor*. `CrmApiCall :reserve` authorizes against a fixed table of
`(actor type → purposes → route templates)`:

| Actor | Purpose | Routes |
|---|---|---|
| CRS | `preflight` | account details only |
| CRS | `import`, `poll`, `full_scan`, `archived_scan` | company and contact search, read and associations |
| CRS | `subscription_read` | unsubscribe-all GET |
| AGT | `research` | contact, company and association reads; note/task reads only if H0 enables them |
| REC, CRW | write and reconcile routes | Gate B |

A route outside the caller's row is refused before reservation.

**Lifecycle of one attempt.** Deadlines are absolute.

1. **Queue.** The caller calls `Gate.request/2` with a queue deadline
   (default 30 s). The Gate monitors queued callers. A caller that dies or
   whose deadline passes while queued is dropped. Nothing has been reserved,
   so nothing needs cleaning up.
2. **Reserve, then admit.** One short committed transaction:
   - increments `CrmRequestDay` with the conditional `reserved < cap`
     (default 5,000 per UTC day, config may only lower it);
   - inserts a `CrmApiCall` in `reserved` with the caller actor, purpose,
     route template, epoch, and `gate_incarnation` (a fresh UUID per Gate
     start);
   - attributes the call to the UTC day of the reservation.

   Admission re-checks the rule in §2.
3. **Mark `sent`, then transport.** The Gate commits `sent`, meaning "bytes
   may leave from now on", *before* starting the transport.
   - The transport is a `Task` owned by the Gate (`Task.Supervisor`, linked
     to the Gate).
   - Req runs with explicit connect and receive timeouts below the hard
     per-attempt HTTP deadline (default 20 s).
   - At that deadline the Gate kills the Task (`:brutal_kill`). Once the
     process that owns the socket is dead, the local transport is quiesced.
4. **Finish.** A second short transaction, a conditional update requiring
   `state ∈ {reserved, sent} AND gate_incarnation = mine`:
   - `completed` with status;
   - `failed_before_send`, for a connect failure reported by the Task before
     any request was written;
   - `unknown`, for a kill at the deadline, or a send with no response.

   It also appends `crm.api_call.finished`. Terminal rows are never
   overwritten. A killed Task has no late outcome.
5. **Caller death after admission.** The attempt completes and is recorded.
   The result is discarded. Gate B write ownership covers the write case.

**Restart cleanup.** Gate death kills its linked Task. When a Gate starts
(after a crash or a VM restart), `init` first commits a cleanup, as REC:
every `CrmApiCall` in `reserved` or `sent` whose `gate_incarnation` is not
its own is marked `unknown` (`incarnation_lost`), with one warning Failure
per cleanup. Only then does it admit. If the cleanup transaction fails, the
Gate stays closed and retries with backoff (**fail-closed admission**).

There is no deadline-only sweeper, so no row is marked unknown while its
transport could still be live in this incarnation. Nothing is ever resent.

**Locks and counting.** No database lock is held across I/O. Reservations
are never refunded. `CrmApiCall` is the only request count (run counters
hold none), and the verifier recomputes `CrmRequestDay` from it.

**Rate limits.**
- 429 `DAILY` closes admission until the account's midnight.
- A ten-secondly 429 backs off for at least 10 s.
- Pacing is at least 200 ms between requests and at least 500 ms between
  searches.
- `X-HubSpot-RateLimit-Remaining` is honoured.

**`CrmSyncRun` ownership (A2).** Each run carries an `owner_token` (UUID)
and `lease_expires_at`.
- Every page transaction runs `SELECT … FOR UPDATE` on the run row, then
  proceeds only if `status = running`, `owner_token = mine` and the lease has
  not expired. In the same transaction it applies the page's domain writes,
  advances the cursor and watermarks, and renews the lease. The finish
  transaction uses the same predicate.
- A worker whose predicate fails aborts without writing. Its in-flight HTTP
  outcome is still recorded on the `CrmApiCall` by the Gate.
- REC marks a run whose lease has expired `failed` (`crash`) under the run
  row lock.
- A partial unique index allows at most one `running` run per
  `(portal, kind)`. So `CRM.start_sync_run/2` (ADM or cron) can admit a
  replacement only after the old run is terminal. The replacement continues
  from persisted watermarks and cursors.

**Ownership tests:**
- transport Task killed at the deadline;
- Gate crash mid-request, then restart cleanup;
- a failed cleanup keeps the Gate closed;
- a queued caller dying;
- a caller dying after admission;
- a VM restart with `sent` rows;
- a late page racing lease expiry and a replacement run (the old worker
  writes nothing);
- the finish race.

**HTTP client.**
- Req only, against `https://api.hubapi.com`, with host and scheme checked.
- DBV `2026-09` pinned in one attribute.
- `redirect: false`, `retry: false`.
- Error classes: 401 `unauthorized`; 403 `forbidden` (redacted scope
  hint); 404 `not_found`; 400/409/validation `invalid`; 423 `locked`; 429
  `rate_limited{policy}`; 477 `migrating{retry_after_s}`; 5xx/52x
  `server_error`; a connect failure before any request bytes
  `failed_before_send`; a timeout or closed connection after send
  `unknown`.
- **Echo scan:** before anything is persisted, the body is checked for the
  holder's exact key bytes and for the redactor's secret shapes. An echo is
  stored as `withheld` plus a critical Failure.
- **Telemetry** is emitted by the Gate with the templated route, status and
  call id. It never uses `OpentelemetryReq`'s URL attributes, and a test
  checks that spans carry no email, key or `authorization`.

### 4. Identity, watermark, bindings, import, research (A2)

**`CrmLink` uses the immutable strategy** (S2 lineage, no mutable `current`
column).
- Rows are append-only and hashed, with backward `supersedes_id`.
- A partial unique index allows one root per remote subject:
  `(tenant, provider, portal, object_type, remote_id) WHERE supersedes_id IS NULL`.
- `unique (supersedes_id)` allows one successor per row.
- The current row is the one with no successor.

The "one current active link per local subject per portal" invariant is
enforced by serialization, not by an index:
- Every link write first takes transaction advisory locks, in sorted order,
  on `crm-link-remote:<tenant>:<portal>:<type>:<remote_id>` and
  `crm-link-local:<tenant>:<subject_id>`.
- It then checks, under those locks, that the local subject has no current
  active link, and the remote subject's current row.
- Race tests: two remote ids adopting one local contact; one remote id being
  imported concurrently; first-link creation.

**Link states and transitions** (each is a new superseding row):

| State | Meaning |
|---|---|
| `active` | The current mapping. |
| `alias` | A merged-away loser id, served by the winner. Created when loser and winner map to the same local subject, or only one maps. |
| `conflict` | Loser and winner map to different local contacts. Writes and research are frozen and a Failure is opened. |
| `remote_archived` | The record is archived in HubSpot. |
| `retired` | The portal was replaced. |

Every derived record pins the link row it used. Conflict resolution and
`retire_portal` belong to Gate B.

**Observation watermark** (finding 2). `CrmRemoteWatermark` is a new CRM row,
one per remote subject:
- `high_water_ms`;
- `high_water_observation_sha256`;
- `applied_observation_sha256` (the last applied);
- `equal_version_conflict` (boolean, with both digests in a payload);
- `observed_at`.

It is a mutable head with a monotonic guarded update, and every advance is
AE'd. It is *not* labelled append-only.

For an observation `(ms, digest)`:

| Observation | Result |
|---|---|
| `ms < high_water_ms` | `stale_ignored`: counted, no write |
| `ms > high_water_ms` | Advance `high_water` to `(ms, digest)` and clear the conflict flag. If `digest ≠ applied`, apply it: domain write, `CrmImportRecord`, `applied := digest`. Otherwise there is no domain write; only the watermark advances. |
| `ms = high_water_ms`, same digest | Nothing |
| `ms = high_water_ms`, different digest | **Conflicting equal-version observation: never applied.** Set the conflict flag and record both digests. Wait for a strictly newer version (or the full scan). Open a warning Failure if the conflict persists across 3 runs. |

Guarantee: an observation with `ms ≤ high_water_ms` never changes domain
state. Required tests cover
`(100,A) apply → (200,A) advance → (150,B) ignored` and
`(200,A) → (200,B) conflict, not applied`.

**Digests.** Both use the existing canonical encoding (`Audit.Canonical`).
- **`observation_sha256`** is the digest of the canonical bytes of the
  snapshot object:
  - mapped properties;
  - `remote_state`;
  - `merged_into`;
  - sorted `hs_merged_object_ids`;
  - the primary-company remote id;
  - `remote_modified_ms`.

  Those exact bytes are the Payload stored for a `CrmImportRecord`, so the
  Payload key *is* the `observation_sha256`.
- **`effect_sha256`** is the digest of
  `{action, resource, target_id | null, fields: <the exact attribute values
  the action will write>}`. The action computes it from its own changeset
  after all changes and validations, so it can be executed and compared.

**Binding matrix** (finding 6). Each action validates this *inside the
action*. The `decision_id` argument must name a Decision with:
- same tenant;
- `actor_type = crm_sync`;
- the kind and outcome listed below;
- `subject_ref = "hubspot:<portal>:<object_type>:<remote_id>"` matching the
  arguments;
- `outcome_detail.local_target_id` equal to the row being written;
- `outcome_detail.effect_sha256` equal to the effect computed by the action;
- `input_refs` containing the `observation_sha256`.

| Action | Kind | Outcome | Object type | Local target | Extra |
|---|---|---|---|---|---|
| Account `:import` | `crm_import_filter` | `allow_create` | company | none (new row id = detail.new_id) | |
| Account `:sync_update` | `crm_import_filter` | `allow_update` | company | `account_id` | OQ-B gate |
| Contact `:import` | `crm_import_filter` | `allow_create` | contact | none (new id) | `detail.account_id` = parent |
| Contact `:sync_update` | `crm_import_filter` | `allow_update` | contact | `contact_id` | OQ-B gate |
| Contact `:sync_email` | `crm_import_filter` | `allow_email_change` | contact | `contact_id` | `detail.suppression_check` = `none_under_lock`; OQ-B gate |
| Lead `:create_from_crm` | `crm_lead_rule` | `create` | contact | `detail.contact_id`, `detail.account_id` | OQ-A gate |
| Suppression `:from_crm` | `crm_import_filter` | `opt_out` | contact | `detail.contact_id` and `detail.email` | |

- Provenance is carried only by the validated `decision_id`. The plain
  `crm_import_record_id` on Suppression from revision 2 is **removed**; the
  existing Suppression `decision_id` column serves. The Decision's
  `input_refs` name the observation, and `CrmImportRecord` references the
  Decision. No lower-domain action accepts a free CRM-row id.
- Decision idempotency covers the run, the remote identity, the observation
  and the action. Replaying it with the same effect is a no-op, and a
  different effect fails the digest check.
- Negative tests:
  - wrong local Account or Contact;
  - wrong object type;
  - wrong kind or outcome;
  - effect digest mismatch;
  - observation not among the inputs;
  - a Decision from another tenant;
  - a Decision recorded by a non-CRS actor.

**Import transaction and lock order** (finding 1). The existing writers'
orders are:

| Writer | Order |
|---|---|
| hand-off (`HandOffProposal`) | Lead (U) → Campaign (S) → Contact (S) → AgentRun (S) |
| suppression (`ApplySuppression` via `Outreach.Locks.targets/2`) | leads → enrollments → drafts → deliveries → approvals (U), before its first append |
| delivery claim | enrollment → draft → delivery → approval → campaign (S) → contact (S) |
| Lead create | Account (S) |

The **global CRM order** below is compatible with all of them. It is taken
before the first audited write of the transaction:

1. **Advisory xact locks, in sorted key order.** The precedent is
   `Outreach.Webhooks`.
   - `crm-link-*` keys (above).
   - `sdr-suppression-email:<tenant>:<email>` and
     `sdr-suppression-domain:<tenant>:<domain>` for every email and domain
     the transaction reads or changes.
2. **CRM rows:** `IntegrationCredential` (S), `CrmSyncRun` (U), and the
   watermark rows by ascending id. No other domain locks these, so placing
   them first cannot invert an existing order.
3. **`Outreach.Locks.targets/2`** for the contact's leads (the full
   suppression superset: leads → enrollments → drafts → deliveries →
   approvals), whenever the transaction may create a Suppression or change an
   email. CRM is above Outreach, so the call is allowed.
4. Campaign (S), if read.
5. Contact (U), then Account (U/S).
6. Inserts: the Decision, Sales rows, `CrmLink`, `CrmImportRecord`, Lead,
   Suppression (its `targets/2` re-locks only rows already held), Failure.
   Inserts take no parent locks beyond those above. A Failure linked to an
   Operation locks the Operation row (U) *before* step 1 of the domain locks.
   That is safe because Operations rows are locked only by their own
   job/transition paths, and never after Sales or Outreach rows.
7. The chain head, taken by the first append, is always last.

**Suppression versus email change.** This is serialized without Sales
reaching upward into Outreach.
- **Existing-side delta:** `ApplySuppression` takes the same
  `sdr-suppression-email` or `-domain` advisory key *before* its existing
  `Locks.targets` call.
- The CRM orchestrator, which sits above Outreach, takes both keys for the
  old and the new email and domain. Under those locks it reads Suppression
  (granted to CRS) and refuses the change if either the old email or its
  domain is suppressed. Only then does it call `Contact :sync_email`.
- A suppression committing concurrently either finishes before the
  orchestrator's read, and is seen, or waits for the orchestrator's commit
  and then matches the contact by its new email. If that new email was
  itself suppressed, the read would have seen it.
- Pre-existing note: ADM `:change_email` does not take the key. It is an
  explicit human act, and the send gate re-checks the current email. This is
  unchanged and recorded.

**Held-lock concurrency tests:**
- import with opt-out vs hand-off on the same lead;
- `sync_email` vs suppression create (email and domain);
- import vs delivery claim;
- opt-out over an existing active lead with an active enrollment: the lead
  is stopped and the enrollment stopped with reason `unsubscribe`.

Each test holds one side's locks with a barrier and asserts no deadlock and
the serialized outcome.

**Opt-out side effects (existing-side delta).**
- `Sales.Checks.SuppressionContext` `@types` += `:crm_sync`. This is
  context-only: CRS still has no direct Lead or CampaignEnrollment `:stop`,
  and a raw CRS stop is denied (tested).
- Drafts, deliveries and approvals are reached through the existing
  actor-agnostic `Outreach.Checks.InternalWrite`, unchanged.
- `ApplySuppression.stop_reason/1` maps `crm_opt_out` to `:unsubscribe` (the
  current default would be `:suppressed`).
- **CampaignEnrollment existing side:** no attribute change. Its `:stop`
  policy already authorizes `SuppressionContext`, so it now admits CRS-made
  suppressions.

**Owner-question gates inside A2.** OQ-A and OQ-B were both answered on
2026-10-07, so Lead `:create_from_crm`, Account/Contact `:sync_update` and
Contact `:sync_email` are active, subject to the A2 PASS. The
`pending_owner_decision` counter is dropped.

**HubSpot-owned field lock (OQ-B, Option 1).** Sales cannot read the higher
CRM `CrmLink`, so ownership is carried downward by a marker on the row.

- **Marker.** Account and Contact gain `crm_managed : boolean` (default
  false).
  - It is set to true only by CRS `:import`, or by the link-adoption write
    (`:mark_crm_managed`), each bound by the same `crm_import_filter`
    Decision contract.
  - It is cleared only by Gate B link retirement or conflict resolution.
  - It is an ownership flag, not identity. HubSpot ids stay in `CrmLink`.
- **What is refused.** While `crm_managed` is true:
  - Contact ADM `:update` refuses changes to `first_name`, `last_name` and
    `title`.
  - Contact ADM `:change_email` is refused.
  - Account ADM `:update` refuses changes to the mapped fields `name`,
    `domain`, `website_url`, `industry`, `employee_count` and `geography`.

  These refusals are validations in the action ("owned by HubSpot; edit in
  HubSpot"), and the error names the field. Local-only fields (Contact
  `persona`, `timezone`) and lifecycle actions such as `:archive` stay with
  ADM. Lead, approval and delivery flows are untouched.
- **Tests.** For each field: refused on a CRM-managed row, allowed on an
  unmanaged row. CRS sync still applies. The flag cannot be set or cleared by
  ADM, AGT or by direct writes.

**UI affordances (H1b, operator plane).**

- **"Edit in HubSpot" link** on contact and account detail pages for rows
  with a current `active` link on the verified portal. It is hidden
  otherwise, including for `conflict`, `retired` or unverified links.
  - The link is built server-side from the link's `portal_id` and
    `remote_id`, plus a non-secret `ui_domain` recorded on
    `IntegrationCredential` by `:record_preflight` from the account-details
    evidence (`uiDomain`), for example
    `https://<ui_domain>/contacts/<portal>/record/0-1/<id>` (company `0-2`).
    The exact path format is confirmed in H0.
  - It is a plain human navigation (`target="_blank" rel="noopener
    noreferrer"`). The app never fetches it, and it is not a research source
    (artifacts keep `hubspot://`).
  - It is shown to ADM, REV and AUR. AUR page views are already audited.
- **Admin "Sync now"**: an ADM button that calls the guarded subject action
  `CRM.start_sync_run/2` (kind `incremental`, mode `apply`). In one
  transaction this creates the run, its Operation and its Oban job.
  - Every request goes through the Gate, so it is serialized and metered
    against the daily cap.
  - It is refused, with a visible reason, when a run of that kind is already
    running (unique running run), when the credential is not `verified`, or
    when the day's cap is exhausted.
  - It never bypasses preflight or the budget, and progress shows in the
    Operations view. A denial for a non-ADM caller is audited.

**Research (H1c).**
- `fetch_record(%CrmRef{})` goes through the Gate, so it is serialized and
  metered.
- Read-only resolution of the current link and watermark uses
  `CRM.research_ref/2`, a read action for AGT scoped to one `contact_id`,
  returning the link and watermark fields only.
- `crm_record` (`trust_level: :medium`) holds structured properties.
- `crm_activity` is enabled **only for the families H0 proved readable with
  the granted scopes** (notes, and tasks if proven). Email engagements are
  **unsupported in H1**: `sales-email-read` is not granted, nothing is
  fetched, and the artifact omits them.
- Credentials are never widened and no write is made to make research work.
- Prompt templates get a version bump and render every source inside a
  delimited data block marked as data and never instructions. The model
  still has no tools, grounded quotes are required, and Tier-0 approval
  still applies.
- Notes carrying our marker are excluded from evidence.

### 5. WRITEBACK (Gate B; re-submitted later)

The revision-2 design follows, with these corrections from the
round-2 review's optional comments, which take precedence:

- **Result predicate, stated literally:** `state = attempting AND
  claimed_by_job_id = $job AND lease_token = $token AND lease_expires_at >
  now() AND claim_epoch = current_epoch`. A late outcome that fails the
  predicate is stored only as `late_observation`.
- **Unique marker property.** A provider-unique `sdr_write_key` makes a
  retry safe *against a duplicate record*. It does not make downstream
  workflow or task notifications exactly-once.
- **Human resolution.** `resolve_unknown_as_absent` is an explicit human
  *override* that accepts duplicate risk, not proof. The UI says so, and the
  AE records it.
- **Open residual window.** A suppression, mode change, revocation or portal
  change committing between claim and send is an *open* question for the
  Gate B review (OQ-E). It is not accepted here.

#### Revision-2 writeback design (Gate B, carried forward)

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

- The result transition is a conditional update using the full literal
  predicate from the corrections above (job, lease token, lease expiry and
  epoch).
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

### 6. SYNC (Gate B)

The carried-forward design below applies, with this qualification: the daily full fingerprint scan
bounds the completeness lag to **one successful full scan after the record
becomes visible in HubSpot's list/search results, within the request
budget**. Scans that fail or hit the budget extend the lag, and are reported
as attention. It is not a hard 24-hour guarantee.

#### Revision-2 sync design (Gate B, carried forward; the qualification above applies)

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
  semantic fingerprints. A test portal is small, so this is bounded. A
  record missed by a late index is caught by the next *successful* full
  scan once it is visible (see the qualification above).
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
- ADM edits of HubSpot-owned fields on linked rows are refused (OQ-B decided 2026-10-07; enforced in H1b through `crm_managed`, §4).

### 7. Grants

**Gate A1 (H1a)**

| Resource | Delta |
|---|---|
| `CrmApiCall` | `:reserve` and `:finish` by the caller's actor, per the purpose/route table (§3). `:cleanup_incarnation` by REC. Reads: ADM, AUR, AUD; CRS for its own run's calls; REC. |
| `CrmRequestDay` | Conditional increment inside `:reserve` only. Reads: ADM, AUR, AUD. |
| `IntegrationCredential` | KRN `:register`, `:begin_boot_epoch`. CRS `:record_preflight` (evidence contract, §2). ADM `request_preflight`, `update_reference`, `set_allowlisted_portal`, `revoke` (all guarded). Field-scoped reads: ADM all; REV and AUR provider, status, `last_verified_at`; CRS, AGT, REC status, epoch, `verified_until`, `allowlisted_portal_id` (CRW is Gate B). |
| `AuditEvent` | `:preflight_evidence`: CRS, one event by id, fixed metadata fields. |
| `Payload` | `:store` += CRS (preflight response). `:read_crm_content` under `PreflightEvidenceScope` only (`crm_preflight`, fail-closed AuditAccess, guarded). |
| `AuditAccess` | Purpose value += `crm_preflight` (kernel-written). |
| `Failure` | `@system` += `:crm_sync`. `:resolve` unchanged (REC; opener via `FailureResolver`). |
| `Operation` | Kinds += `crm_preflight` on queue `crm` (CRS). No ADM `:retry` for crm kinds. Reads += CRS. |

**Gate A2 (H1b, H1c)**

| Resource | Delta |
|---|---|
| `CrmLink`, `CrmImportRecord`, `CrmRemoteWatermark`, `CrmSyncRun` | CRS create/advance as specified. CRS reads (lookup, high-water). AGT scoped `research_ref` read. ADM, REV, AUR, AUD metadata reads. |
| Account, Contact, Lead, Suppression | The actions in the binding matrix (CRS). Reads += CRS. Account and Contact `crm_managed` set by CRS only, plus the ADM edit refusals (OQ-B). |
| `CRM.start_sync_run/2` ("Sync now") | ADM, guarded (denial audited); metered via the Gate. |
| `IntegrationCredential.ui_domain` | Written by `:record_preflight` from evidence. Readable by ADM, REV, AUR for the "Edit in HubSpot" link. |
| `SuppressionContext` | `@types` += `:crm_sync`. |
| CampaignEnrollment | Policy unchanged; covered through `SuppressionContext`. |
| `ApplySuppression` | Advisory key before `Locks.targets`; `stop_reason(:crm_opt_out) = :unsubscribe`. |
| Decision | Kinds `crm_import_filter` and `crm_lead_rule` (CRS). |
| ResearchArtifact | `provider` `hubspot`, `source_type` `crm_activity`, `hubspot://` URI, watermark metadata (AGT). |
| `Payload :store` | `observation_sha256` snapshots (CRS). |
| Operation | Kinds `crm_import`, `crm_scan` (CRS). |

**Gate B (deferred; not part of any A PASS):** the CRW actor; Payload
`crm_dispatch` and `crm_reconciliation` scopes; AuditEvent `:crm_feed`; all
`CrmWriteOperation` and `CrmSyncCursor` grants; `write_mode`;
`retire_portal`; conflict resolution; and Failure `@system` += `:crm_writer`.

### 8. Tests and the external smoke escape hatch

- Hermetic `Req.Test` stubs with synthetic fixtures. The client refuses to
  run in `:test` without a stub, refuses foreign hosts, `http` and 3xx, and
  never contacts HubSpot in CI.
- The only escape is `HubSpot.Client.live_smoke!/0`. It requires all of:
  - `MIX_ENV=test`;
  - `SDR_HUBSPOT_EXTERNAL_SMOKE=1`;
  - `:external` in `ExUnit.configuration()[:include]`;
  - `CI` unset.

  It allows only the bootstrap preflight route and one contact search page,
  through the same Gate, metering and evidence contract. A CI guard test
  fails if the variable is set.

### 9. Dependencies

None.

### 10. Setup ordering (owner-run; no agent handles the key)

0. **Secrets PR (coordinator, separate and small).** It adds the
   `.gitignore` entry and the `.sops.yaml` creation rule for
   `secrets/hubspot.local.sops.yaml`. Once it merges, the owner can store
   the key.
1. **H1a ships hermetic only.** It adds the `bin/with-secrets` mapping, the
   holder, `ChildEnv`, the Gate, preflight and the smoke hatch. Its live
   transport is reachable only through the smoke hatch, and there is no
   remote enablement.
2. **H0** (after the secrets PR; independent of H1a). The owner creates the
   test account and the service key (OQ-D), and writes the flat sops file in
   the ignored path.
   - The owner runs the independent owner-only probe at once, or the smoke
     hatch after H1a merges:
     `sops exec-env secrets/hubspot.local.sops.yaml 'curl -sS -H "Authorization: Bearer $hubspot_service_key" https://api.hubapi.com/account-info/v3/details'`.
     It prints account type and portal id only, for the owner to read.
   - The owner reports the facts in prose; agents never see the key.
3. **H1b and H1c** start only after the H0 facts are recorded and the gating
   owner answers are in.

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
- Rotating the key needs a restart, and losing the holder fails closed until a restart.
- Polling latency is up to 15 minutes. Completeness relies on the next successful daily full scan, so there is no hard bound.
- The gate is a deliberate single-node bottleneck.
- The test portal expires after 90 idle days.

### Neutral

- New top domain `SdrAgent.CRM`; the layering becomes
  `… <- Outreach <- CRM`. ADR-0009 §7 needs an amendment when this ADR is
  accepted.
- `STANDARD` portals stay out of scope.
