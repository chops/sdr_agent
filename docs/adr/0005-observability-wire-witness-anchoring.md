---
status: accepted
date: 2026-10-06
supersedes: null
---

# ADR-0005: OpenTelemetry, Wire Witness, and Audit-Chain Anchoring

## Status

Accepted (2026-10-06, owner decision recorded in ADR-0001: "OpenTelemetry as a
first-class concern, model-content spans and an independent wire witness both
in the MVP, and audit-chain anchoring to a private Git repository plus
OpenTimestamps"). Details amended by Codex consultations 11 and 13. The R0
amendment in the wire witness section (2026-10-12) is accepted. The C4
database-logging amendment in the OpenTelemetry section (2026-10-12) is
accepted (2026-10-14). The R0-07 calibration harness amendment (2026-10-13)
is accepted (2026-10-14).

## Context

ADR-0002 makes Postgres the audit system of record. The owner also wants to
see, live, every trace and what is sent to and received from the model, and
wants evidence that does not depend solely on the application's own database
and code. Three mechanisms answer three different questions:

1. **App telemetry (OTel):** what did the app do and ask for, in one trace?
2. **Wire witness:** what actually left the machine toward the provider?
3. **Anchoring:** has the ledger been rewritten since a point in time?

Local facts: Grafana Tempo accepts OTLP/HTTP on `127.0.0.1:4318` (168h
retention). The owner's `llm-otel-proxy` (`~/src/nix-darwin/packages/llm-otel-proxy`,
`127.0.0.1:8787`, `/openai-codex` route for ChatGPT OAuth traffic, sha256 blobs)
correlates only via `X-Ai-Pair-*` headers and does not read W3C
`traceparent`. With Codex app-server, app-server, not our app, makes the
upstream HTTP call, so our headers do not reach the proxy unless app-server
forwards them.

## Options Considered

### Option 1: Postgres ledger only

**Pros:** simplest.
**Cons:** no live trace view; no corroboration independent of app code; no
evidence outside the database.

### Option 2: OTel content spans only

**Pros:** live inspectability in one trace.
**Cons:** records what the app asked for, not what app-server sent upstream;
Tempo is not durable.

### Option 3: OTel content spans, plus proxy wire witness, plus external anchoring

**Pros:** each mechanism covers a gap the others leave.
**Cons:** more moving parts; correlation between app trace and proxy is
initially inferred.

## Decision

We will use Option 3.

### OpenTelemetry (first class, from S4)

- `opentelemetry` SDK with the OTLP/HTTP exporter to `127.0.0.1:4318`;
  instrumentation for Phoenix, Bandit, Ecto, Oban, Req, and Ash; custom spans
  for each Jido signal, action, flow, and agent run.
- GenAI semantic conventions (`gen_ai.*` attributes) on model spans.
- **Content:** full prompt and completion content as span events in **dev,
  for synthetic data only**; everywhere else spans carry IDs and content
  hashes only. Turning content on for real data requires an explicit,
  recorded policy (ADR-0002 retention stance).
- `trace_id` and `span_id` on every audit record; Logger metadata carries them.
- OTel is **diagnostic corroboration, not the system of record**. Tests run
  with exporting disabled; exporter loss never affects the ledger.

#### S4 implementation amendment (2026-10-06)

S4 pins `opentelemetry` 1.7.0, `opentelemetry_api` 1.5.0,
`opentelemetry_exporter` 1.11.0, `opentelemetry_phoenix` 2.0.1,
`opentelemetry_bandit` 0.3.0, `opentelemetry_ecto` 1.2.0,
`opentelemetry_oban` 1.2.0, `opentelemetry_req` 1.0.0, and
`opentelemetry_ash` 0.1.4. Hex package metadata and `mix.lock` checksums are
the provenance record. The OpenTelemetry packages are Apache-2.0; the Ash
adapter is MIT.

Only development loads the OTLP exporter and sends OTLP/HTTP to
`http://127.0.0.1:4318`. Production exports nothing until a later deployment
decision configures a collector. Tests use a local in-memory exporter and
never contact a collector, keeping CI hermetic. Phoenix and Bandit are both
attached deliberately: Phoenix traces framework routing while Bandit traces
the HTTP server boundary. Req tracing is opt-in through
`SdrAgent.Telemetry.instrument_req/1`, preventing instrumentation from being
silently skipped when clients are constructed later.

`SdrAgent.Telemetry.GenAI` emits `gen_ai.*` spans with invocation identifiers
and SHA-256 content hashes. Prompt and completion bodies are span events only
when `:sdr_agent, :otel_capture_content` is explicitly true; that switch is
true only in development and false by default and in tests. S4 adds no audit
resources or trace columns; S3 owns persisted correlation fields.

#### C4 amendment (2026-10-12): metadata-only database logging and spans

**Status: ACCEPTED.** The owner accepted this amendment on 2026-10-14
(America/Denver, about 11:48 MDT), in the private Claude session chat,
after first questioning whether values reproduced later might differ from
the originals; the reply was "no, i accept the C4 logging amendment
as-is." Codex approved revision 2 for owner consideration at 7f6d97d. The
PostgreSQL server-log prerequisite below remains separate and open.
Drafted by Claude for
contract C4 (`docs/product/c4/readiness.md`, sections 3.6 and 7). Codex's
round-2 entity review of that packet (PASS at a15cf8b, qualification 4)
requires an explicit observability decision on this point before C4
implementation is approved; the entity PASS is not acceptance of this
amendment. Revision 2 answers Codex's review of revision 1 (1f88700,
REQUEST_CHANGES, one security must-fix: the Ecto span error status).
It is in force for C4 implementation from its acceptance.

**Context.**

- **Ecto logs query parameters.** `SdrAgent.Repo` has no `log:` setting,
  so Ecto's default logger writes every query and its bound parameters at
  `:debug`. Development logs at `:debug` (`config/dev.exs` sets no level);
  tests log at `:warning`, production at `:info`.
- **What the parameters now carry.** C4 stores the owner's business text
  (offering profile, writing guide, research brief guidance, booking
  link) and must not copy it outside its row and the authorized model
  payload seam. With the real-data switch (ADR-0014 amendment 2, C5-04),
  queries also carry real company and person fields.
- **The owner's instance runs in development.** `config/runtime.exs`
  refuses `SDR_MODEL_PROVIDER=claude_cli` in production, so the owner's
  local instance with real data is a dev build. A production-only control
  does not protect it.
- **Error paths copy values.** PostgreSQL errors carry `DETAIL` and
  `HINT` text such as "Failing row contains (…)" or "Key (…)=(…) already
  exists", and Postgrex's exception message includes them (and sometimes
  the SQL). `config/dev.exs` also sets
  `show_sensitive_data_on_connection_error: true`.
- **Ecto spans copy the exception message.** `SdrAgent.Telemetry` calls
  `OpentelemetryEcto.setup/1` (`opentelemetry_ecto` 1.2.0). Its
  `db_statement: :disabled` default keeps the SQL text out, but on an
  error `handle_event/4` sets the span status description to
  `Exception.message/1` of the error, `DETAIL` and `HINT` included. Codex
  reproduced this with a synthetic SDK probe (one span, canary present).
  The same handler copies the Repo's configured `url` verbatim into
  `db.url`; production configures the Repo from `DATABASE_URL`
  (`config/runtime.exs`), which can carry a password.
- **Automatic exception reports.** A raised Postgrex or Ash error that
  escapes a process is rendered by crash reports, Oban job error records
  and framework error logs, not only by hand-written Logger calls.

**Options considered.**

1. **Keep Ecto's default logging and spans (status quo).**
   - Pros: full debugging detail; no code.
   - Cons: settings text and real prospect data in dev logs at every
     query and in span status on every error; credentials can reach
     `db.url`. Contradicts C4-R12 and ADR-0014 amendment 2 rule 2.
2. **Metadata-only logging and spans, all environments (recommended).**
   The default Ecto logger and `OpentelemetryEcto.setup/1` are both
   removed. One sanitizer (`SdrAgent.Repo.SafeMetadata`) turns each
   `[:sdr_agent, :repo, :query]` event into allowlisted fields; a logging
   handler (`SdrAgent.Repo.QueryLog`) and a span handler
   (`SdrAgent.Telemetry.RepoSpans`) emit only those fields.
   - Pros: one control for every table, present and future, so a new
     table cannot leak by default; covers settings and real data alike;
     the span error status is safe by construction; testable with
     canaries without any database traffic.
   - Cons: developers lose parameter values, SQL text and error detail
     when debugging; a query must be reproduced in a test or `psql`. The
     app owns span code that the dependency used to provide.
3. **Per-query or per-table redaction.** Keep Ecto logging and redact
   chosen parameters (custom Ecto types whose inspected form is masked, or
   a handler that filters by `source`).
   - Pros: keeps detail for harmless tables.
   - Cons: fails open: every new table or column with sensitive content
     needs its own marking; Ecto logs dumped values, so Ash `sensitive?`
     does not reach the log; does nothing for the span status or `db.url`.
4. **Disable Repo logging only in production (or only when the real-data
   switch is on).**
   - Pros: dev keeps full detail on synthetic data.
   - Cons: does not protect the owner's instance, which runs in dev;
     settings text is present with the switch off; leaves spans unchanged.
5. **Raise the dev log level to `:info`.**
   - Pros: one line of config.
   - Cons: hides every other debug log; trivially reverted per session;
     does nothing for spans or crash reports; not a reviewed control.

**Decision (accepted 2026-10-14).** Option 2.

- **Sanitized fields** (the complete list; anything else is dropped):
  - `repo` (module name);
  - `source`: a table name from the fixed set of tables declared by the
    app's Ash resources, else `"other"`;
  - `command`: one of `select`, `insert`, `update`, `delete`, `other`;
  - durations as integers in microseconds: `query_time_us`,
    `queue_time_us`, `decode_time_us`, `idle_time_us`, `total_time_us`;
  - `rows`: the result row count, when the result has one;
  - `outcome`: `ok` or `error`;
  - for an error: `error_module` from a fixed allowlist (`Postgrex.Error`,
    `DBConnection.ConnectionError`, `DBConnection.OwnershipError`, else
    `"other"`), `pg_code` (the SQLSTATE condition atom from Postgrex's
    fixed table, else `"other"`), and `constraint`: a constraint or index
    name from the fixed set declared in the app's migrations, else
    `"other"`.

  These are fixed schema and application identifiers, never free text
  from a query, a value or a user.
- **Never emitted** in a log, span attribute, span event or span status:
  bound parameters; SQL text, in full or as a digest; the exception
  message or any `inspect` of an exception or error struct; PostgreSQL
  `DETAIL`, `HINT`, `where` or `column` values; the Repo URL, user name,
  password or connection options. An error that does not match the
  allowlist is reported as `error_module: "other"` without inspecting it.
- **Spans.** `RepoSpans` emits one client span per query with the same
  name scheme and parent (`$callers` propagation) as the dependency did,
  attributes `db.system` (`postgresql`), `db.name` (the configured
  database name, a fixed config value), the sanitized fields above, and on
  error the status `:error` with a description built only from
  `error_module`, `pg_code` and `constraint`. It never sets `db.url` or
  `db.statement`. `opentelemetry_ecto` stays pinned but is no longer
  attached; removing the dependency is a later, separate change. Vendor
  code is not edited.
- **Error boundaries and automatic reports.** Database errors are mapped
  to typed domain errors at the domain boundary by constraint name or
  SQLSTATE, never by echoing the message, so no raw Postgrex exception is
  carried to a later renderer. A primary `:logger` filter
  (`SdrAgent.Logger.ExceptionFilter`) rewrites any log event whose message,
  report or metadata holds a Postgrex, DBConnection or Ash error struct
  into the sanitized summary, so crash reports and framework error logs
  are covered. Oban workers rescue database exceptions at their boundary
  and return sanitized error reasons, so `oban_jobs.errors` holds no
  exception message. Dev sets `show_sensitive_data_on_connection_error:
  false`.
- **Scope.** Every environment, so tests exercise the same handlers.
- **Tests** (synthetic only; no real credentials; the first three need no
  database):
  - a synthetic `[:sdr_agent, :repo, :query]` event with a
    `%Postgrex.Error{}` whose message, `DETAIL` and `HINT` hold a canary:
    the canary is absent from every exported span attribute, event and
    status description, and from captured logs at `:debug`;
  - the same event with a Repo config holding a credential-bearing URL
    (`postgres://user:canary@db.invalid/x?sslpassword=canary`): no canary
    and no `db.url` in any span or log;
  - an unknown error struct carrying a canary is reported as `"other"`;
  - against the test database: a valid insert, a check-constraint and a
    unique violation with a canary value; a raised error that crashes a
    process; an Oban job that hits a constraint error. The canary is
    absent from logs, spans and `oban_jobs.errors`;
  - the default Ecto logger and `OpentelemetryEcto` handlers are not
    attached; `QueryLog` and `RepoSpans` are.
- **PostgreSQL server log: a separate prerequisite, not solved here.**
  The app's controls do not reach the PostgreSQL server's own log, which
  can record error `DETAIL` (failing row contents) and statements. That
  configuration (for example `log_error_verbosity`,
  `log_min_error_statement`, `log_statement`, set per database or per
  session rather than on a shared server) is a separate project
  configuration decision, owned by the owner with Claude and Codex
  proposing. It is a gate: before private settings content is saved or
  the real-data switch is turned on, either that decision is accepted
  with its own test or the owner accepts an explicit retention exception
  for the server log. No server setting is changed by this amendment or
  its review.

**Consequences.**

- Positive: settings text, real prospect data, error detail and
  credentials stay out of app logs, query spans and job error records
  everywhere, by default, for every table.
- Negative: less detail when debugging queries in dev; the app maintains
  its own Repo span handler instead of the dependency's.
- Neutral: query timing, outcome, error class and trace parentage stay
  visible, so slow queries and errors are still diagnosable; the audit
  ledger is unaffected. The server-log prerequisite remains open until
  decided separately.

**Acceptance.** Recorded in this amendment's Status paragraph above (owner,
2026-10-14). The server-log prerequisite's direction was approved the same
day. The prerequisite itself stays open until its own test, activation
check and retention decision pass, as the gate above requires; accepting
its proposal alone does not close it.

### Wire witness (S12)

- Route Codex app-server's upstream traffic through `llm-otel-proxy`; the
  proxy records request and SSE response blobs by sha256.
- Until an end-to-end test proves stable matching, the link between a
  ModelInvocation and a proxy record is labelled **inferred** (time window,
  serialized calls per ADR-0004, app-server PID and version, proxy request
  sequence and timestamps).
- S12 adds explicit invocation or witness-ID propagation (proxy and/or
  app-server configuration) and a reconciliation job that compares
  **canonical payload hashes**, not assumed raw-byte equality. Only after that
  e2e hash test passes may a link be labelled **reconciled**.
- TLS and provider internals remain outside what the witness can prove.
- Owner checkpoint: deploying the proxy change needs `sudo darwin-rebuild
  switch` (ADR-0001).

#### S12 approved protocol and assurance amendment (2026-10-07)

Accepted design under the correlated entity verdict
`m_1791381869820530000_6005c06e` and plan/supplementary Payload verdict
`m_1791382326635826000_6c0f992b` (Claude). Their binding C1–C9, S1–S3 and
P1–P10 conditions are recorded in `notes/features/s12-wire-witness.org`.
Implementation and deployment remain pending; this amendment does **not**
enable reconciled assurance.

- The real provider is ClaudeCLI, not the disabled CodexAppServer. A reserved
  ModelInvocation UUID and caller W3C `traceparent` travel through per-call
  environment values and the shim's native Claude custom-header channel.
  The local proxy honors correlation only from loopback, parents its span,
  and strips the correlation headers before upstream forwarding, including
  redirects/retries and WebSocket paths. Init/model/version/tool/MCP/slash
  attestation remains mandatory and unchanged; SDR-stamped calls cannot
  bypass local proxy routing.
- Shared traces provide convenient linkage, **not independence**. Independent
  corroboration rests on the separately written proxy store and raw digests.
  The existing preview spills contain normalized text, not complete HTTP
  exchanges. S12 introduces a versioned, header-free exchange inventory,
  start/final records and bounded raw request/response blobs for SDR calls,
  with explicit completeness/truncation flags and owner-only permissions.
  No request headers, account identifiers or raw bodies enter SDR evidence
  or telemetry metadata. Raw Claude bodies (including CLI system text and
  account-derived `metadata.user_id`) stay only in the local proxy store;
  its retention/cleanup and raw-reverification limits must be documented.
  Raw bodies use `<blobDir>/witness/sha256/<aa>/<digest>.json`, separate from
  legacy preview `<blobDir>/sha256` and its mtime-based cleanup. Witness
  retention is reference-aware and owner-managed, never legacy preview GC.
- WireWitnessLink lineage is per `(tenant, invocation, proxy_record_ref)`.
  Corrections append successors, with a same-subject current-head guard and
  database no-fork uniqueness. A same-projection-version mismatch cannot
  be rewritten as reconciled. Missing/incomplete/ambiguous records raise
  idempotent warning attention without fabricated links; mismatches raise
  critical attention. Every observed extra exchange must be classified;
  only the same-id, non-generating count-tokens response is ancillary.
- The full application payload digests retain their original meaning.
  Versioned projections compare the exact rendered stdin prompt (derived
  from stored prompt and schema using the recorded prompt-builder version)
  and structured JSON completion against the observed message exchange.
  A historical unsupported builder stays inferred. Projection equality
  does not claim whole-wire-byte equality for CLI-injected fields. Raw
  bodies are not imported into Payload: Postgres reconstruction proves
  recorded projection-equality claims; raw re-verification requires the
  proxy store while it exists.
- Reconciliation uses a new, narrow Payload action: REC identity, same
  tenant, Agents-owned private scope limited to that invocation's two
  payload hashes, and fixed purpose. Existing general content/read policies
  remain untouched. An AuditAccess append must succeed before content is
  returned; access replays are real accesses, not duplicate witness links.
- Model calls and the reconciliation queue stay at concurrency one until
  lifted by a reviewed ADR amendment. Invocation status is `unwitnessed`
  without records; `reconciled` requires one current reconciled primary
  exchange and every observed extra classified, with no mismatched or
  unclassified exchange ignored.
- Ship the runtime reconciled-method allowlist **empty**. S12a is a separate
  nix-darwin PR; after review the owner alone runs `sudo darwin-rebuild`.
  S12b/c remain hermetic and may proceed while deployment is pending. A
  single budgeted synthetic external call must prove the real transformation.
  Only a separate reviewed S12d enablement PR may activate a method, citing
  deployment, record IDs/digests, CLI version and projection version. Failed
  or unsupported proof never raises assurance.

S12a refinement accepted in `m_1791387015901435000_7691c93f`: the launcher
validates bounded JSON from the active daemon's loopback-only
`/healthz/witness` before an SDR CLI launch. Exact schema 1 and the three
strip declarations are required; old/missing/unknown/malformed/timed-out
capability refuses with exit 65. Ordinary Claude/Codex never probe this route
and legacy `/healthz` remains unchanged. The probe is not atomic with the
model request: a daemon swap between them can still expose an unsupported
proxy. This residual TOCTOU is acknowledged; S12b/c treat absent records as
unwitnessed with attention, not reconciled. No additional mitigation or
assurance is claimed. jq is reused from the existing pinned Nix input for
strict bounded JSON validation; no new Hex/Go dependency is added.

#### S12c reconciliation implementation and queue tradeoff (2026-10-07)

Implemented under Codex RED verification `0c16f778-779e-428c-9af4-b4254f1426de`
and queue ruling `c22df84e-c201-4e86-9e17-b44247864bd1`.

- **Shared serial queue.** The Oban `reconciliation` queue runs at
  concurrency **1**. Model wire-witness reconciliation (C8) and S8's
  delivery reconciliation share it, so delivery reconciliation also
  serialises. This tradeoff is accepted for serial witness correctness. Only
  a reviewed amendment to this ADR may raise the limit.
- **Inert by default.** `SdrAgent.Agents.Witness` reconciles only when
  `store_root` names the deployed proxy's blob directory; it ships `nil`.
  The reconciled-method allowlist ships **empty**, so a matching projection
  is recorded as `inferred` (`method_not_enabled`). A per-call method
  override exists only under test configuration. Only the separate S12d
  change, citing real proof, may add a method.
- **Scheduling and recovery.** A five-minute bounded scan enqueues each
  terminal ClaudeCLI invocation it finds: at most 50 invocations, updated
  within the last 24 hours. Each job is REC-owned and runs on the shared
  queue, as one Oban job plus one `reconcile_model` Operation written in the
  same transaction and keyed `reconcile_model:<id>:<generation>`. While a
  warning condition stays live (missing, open, incomplete, ambiguous,
  unclassified or unsupported), the scan re-drives the invocation at most
  four generations in total, each at least ten minutes after the previous
  one finished. Jobs have three attempts of sixty seconds each. Nothing
  re-sends a model call.
- **Evidence path.** The store reader is bounded and read-only, and reads
  raw blobs only from `witness/sha256`. Each record must satisfy the
  schema-v1 key set and match its own path. Raw digests are re-verified,
  and no symlink is followed.
  The projection is `claude-message-json/1+prompt-builder/1`, the ClaudeCLI
  stdin builder `prompt-builder/1` recorded in provenance; any other builder
  is unsupported. Links are written in one transaction that locks the
  invocation first. That transaction keeps at most one live critical
  condition (mismatch) and one live warning per invocation; an unreadable
  inventory downgrades current links with successors.
- **Freshness, a bounded exception to "no file I/O under locks".** Two
  things are captured before any content is read: the observation identity
  (`lstat` metadata of at most 64 record entries, plus the blobs those
  records name). Under the invocation lock, only that metadata is checked
  again. If it changed, the pass writes nothing and returns
  `stale_observation`, an error, so the worker retries with a fresh
  observation. Content reads and audited payload reads remain outside the
  lock.
- **Recovery uses Oban's real job state.** Interrupted work is settled only
  when its Oban job is confirmed dead and the Operation has not changed for
  ten minutes. A generation that ended discarded or cancelled is re-driven
  within the same four-generation bound. The scan window is bounded by rows
  (500), not proven by the budget. Terminal invocations are immutable, so
  each row's `updated_at` is set once, but a crash-recovery backlog could
  exceed the window. Rows beyond it may then age out of the 24-hour window
  unprocessed. This is a known limitation to resolve before higher volume,
  not a promise of eventual processing.
- **Test scope.** The hermetic end-to-end tests use a fake CLI that writes
  protocol-shaped store files itself. It is a functional fixture pipeline,
  **not** proof of transport or independence. S12a's real shim/proxy checks
  and the mandatory S12d real proof still apply. `traceparent` equality is
  not claimed, because no expected-context source is persisted.

#### S12d status (2026-10-07): real proofs recorded, NOT enabled

Both owner-budgeted synthetic calls were witnessed end to end by the
deployed proxy 0.2.0, with exactly one complete exchange each, and the
response projections were equal. Neither proved the request projection.

- The first call showed that v1 cannot read Claude Code 2.1.291's request
  shape.
- The second call came after the narrow projection
  `claude-message-json/2+prompt-builder/1` was added (entity PASS
  `f04a7e44`). That projection records CLI context as typed evidence and
  does not claim it equal or benign. The real request still fell outside
  v2's grammar on three structural points: the reminder's trailing newline,
  `cache_control.ttl`, and a message-level `output_config`.

The runtime reconciled-method allowlist therefore stays **empty**.
Allowlist entries must name an exact `(provider, attested CLI version,
projection version, method)`.

Enablement requires all of the following, in a separate reviewed change:
a reviewed grammar revision, a new owner-approved real call, and
independent review of its evidence. Evidence:
`docs/audit/s12d-wire-witness-proof-{1,2}.json`.

#### S12d projection v3 (hermetic; entity PASS 2026-10-07)

`claude-message-json/3+prompt-builder/1` is v2 with three bounded
relaxations, taken from the structure of proofs 1 and 2:

- a reminder may end with its close tag plus exactly one LF, and its digest
  and byte count cover the original bytes;
- `cache_control` may carry `ttl: "1h"`, and only that value;
- a trailing system message may carry a message-level `output_config` of
  the top-level shape.

Its manifest is version 3. It tags each trailing message's `output_config`,
and its context group adds `trailing_output_config`, giving 9 keys. The
evaluation order is v2, then v3, then v1: a request that v2 admits is
always evaluated and labelled v2.

The outer diagnostic `projections_inapplicable` (`[]`, `["v2"]` or
`["v2","v3"]`) records which request grammars were inapplicable.

The claim is unchanged: the stdin and the structured output are equal, and
the context is recorded, not proven equal or benign. v3 is hermetic until a
new owner-approved real call and a separately reviewed enablement, and the
runtime allowlist stays empty.

The owner approved up to two more synthetic real calls for the v3 proof on
2026-10-07. They may be spent one at a time, and only after Codex has
verified v3 RED and approved v3 GREEN and the #24 fixes. If v3 does not
match the real shape, the work stops and is reported; the rules are not
widened ad hoc.

Proof 3 (2026-10-07, `docs/audit/s12d-wire-witness-proof-3.json`) was one
complete witnessed exchange, evaluated under v3 with the stdin and response
projections equal. It reconciled under the test-only exact entry
`(claude_cli, 2.1.291, claude-message-json/3+prompt-builder/1,
propagated_id)`. The runtime allowlist stays empty until a separate,
reviewed enablement change.

#### S12d enablement (2026-10-07; entity PASS 78f47754)

The shipped runtime allowlist (`config/config.exs`) holds exactly one exact
entry:

    %{provider: :claude_cli, cli_version: "2.1.291",
      projection_version: "claude-message-json/3+prompt-builder/1",
      method: :propagated_id}

The evidence for it is proof 3 (`docs/audit/s12d-wire-witness-proof-3.json`)
and Codex's independent evidence PASS `c9a2bba3`. Any other provider, CLI
version, projection or method stays `inferred` (`method_not_enabled`). A
Fake or ineligible invocation stays `skipped`. The test environment keeps
an empty allowlist, and per-call overrides are test-only. The
reconciliation queue stays at concurrency 1. Model-call routing, budgets
and lifecycle are unchanged.

The store root is opt-in. `SDR_WITNESS_STORE_ROOT`, read in non-test
environments only, is the proxy blob directory, used verbatim; unset
leaves reconciliation inert. The root must be:

- absolute and syntactically clean (no NUL, `://`, empty, `.` or `..`
  segment);
- reached through ancestors that are all real directories (no symlinks),
  owned by root or the effective UID, and not group- or world-writable;
- itself a real directory owned by the effective UID and not group- or
  world-writable.

Nothing is created or changed. A configured root that is missing or
untrusted refuses boot, with a fixed message that names only the error code.
The root is revalidated on every store read, including explicit overrides.
A failure at use is a typed unreadable store (`store_root_untrusted` /
`store_root_missing`), never "unconfigured": current non-mismatch links get
an `inferred` successor with a warning attention, and mismatches stay
sticky. Changing the entry requires a reviewed amendment, and a new CLI
version or projection requires a new proof.

#### R0 amendment (2026-10-12): profile-exact tuples, calibration, per-invocation result gate

**Status: ACCEPTED.** The owner accepted this amendment on 2026-10-12
(America/Denver), in the private Claude session chat, with the words
"accept PR #128". This followed Codex's independent approval of 48de82c
(reply 01a13152). The result gate and tuple promotion still need an
independent entity/action PASS (story R0-07) before they are implemented.

**Context.**

- **The owner's decision (D-108, G5-R0):** "we should be accurate out of the
  gate and not infer anything we don't have to".
- **What R0 changes.** The app moves to its own pinned Claude CLI 2.1.294
  and adds a second profile, Sonnet (ADR-0004 R0 amendment).
- **The allowlist** names `(provider, cli_version, projection_version,
  method)` only. It has no model or profile, so a Sonnet call on an enabled
  CLI version would not be distinguished from an Opus call.
- **Reconciliation is asynchronous.**
  - It runs from a five-minute scan on a concurrency-1 queue shared with
    delivery reconciliation.
  - A completed call's output is returned to its caller, and used, before
    any reconciliation.
  - A missing exchange, a timeout or an unconfigured store leaves the call
    `unwitnessed` or `inferred`, and the run continues.

**Decision.**

1. **Profile-exact tuples.**
   - An allowlist entry names exactly `(provider, cli_version, profile_id,
     model_id, projection_version, method)`. `projection_version` keeps its
     prompt-builder suffix.
   - `enabled?` compares every field with the invocation's recorded values.
   - The existing `2.1.291` entry becomes `profile_id: nil, model_id:
     "claude-opus-5-5"`, matching only pre-R0 rows, which carry no profile.
     It applies to those historical rows only.
   - The evidence-key allowlist gains `model_id` and `profile_id`.
2. **Calibration (the bootstrap exception the owner accepted).**
   - **Hermetic work first.** Candidate projections for (2.1.294,
     `claude_cli_opus`, `claude-opus-5-5`) and (2.1.294, `claude_cli_sonnet`,
     `claude-sonnet-5-5`) are built and reviewed hermetically first. v3 may
     already fit; if not, a reviewed grammar revision is made.
   - **The calibration calls.** The four G-R0 attempts are calibration
     calls:
     - run through the external proof harness, with synthetic input, in an
       isolated test database and witness store;
     - under test-only exact overrides, one at a time;
     - never part of a business flow.
   - **Quarantine.** Their evidence is recorded as **unreviewed calibration
     evidence** (`docs/audit/r0-calibration-*.json`, synthetic content only)
     and is never presented as reconciled.
   - **Promotion.** Codex reviews each captured exchange independently. Only
     after an evidence PASS does a separate reviewed enablement change add
     that exact tuple to the shipped allowlist.
   - **When the grammar does not fit.** If a captured exchange falls outside
     the grammar, the work stops and is reported; the rules are not widened
     ad hoc. Further attempts need a new owner grant.
3. **Admission before any spend.**
   - **Refusal before reservation.** An ordinary (non-calibration) real
     `claude_cli` call is refused, with nothing reserved, charged or sent,
     when either:
     - its exact tuple (provider, pinned CLI version, profile, resolved
       model, current prompt builder's projection, method) is not on the
       shipped allowlist; or
     - the result gate is not active.
   - **Launch re-check.** The same check is repeated at launch admission
     (ADR-0004 R0 amendment, `admit_launch/2`). An invocation whose tuple
     is no longer promoted, or whose gate is no longer active, is refused at
     launch, and is never sent.
   - **Calibration stays confined.** The calibration exception applies only
     inside the reviewed external proof harness, with its test-only exact
     overrides. There is no caller, job or runtime flag that lets an
     ordinary call bypass this admission.
4. **Per-invocation result gate.**
   - **Which calls.** It applies to every R0-generation `claude_cli`
     invocation outside calibration.
   - **Mechanism.** After the response is validated and stored, the facade
     reconciles **that** invocation at once, in-process, with the same
     reconciliation code. It does not wait for the scan. The wait is
     bounded, and configuration may only shorten it.
   - **Release.** Only a `reconciled` result is released to the caller.
   - **A mismatch** withholds the result. The run fails with
     `witness_mismatch`, and a critical attention item opens.
   - **A missing exchange, a timeout, an unreadable store or a tuple that is
     not enabled** also withholds the result. The run fails with
     `witness_unreconciled`, and a warning item opens.
   - **On every failure.** The invocation keeps its ledger outcome and
     charged attempt, the evidence is kept, and no new call is made
     automatically.
   - **Later reconciliation.** A later scan may upgrade the link, but it
     never releases a withheld result to the original run. A re-run is an
     explicit, budget-counted operator action.
   - **Release evidence.** The release decision is a **separate, immutable
     release record** for the invocation: released, or withheld with its
     reason. It is written once, after the invocation's terminal outcome.
   - **The invocation itself is untouched.** The terminal invocation and its
     outcome are never updated; terminal rows stay immutable (ADR-0009).
   - **No bypass.** Every business read of a model output (the facade's
     return, replay, retry, decisions) requires a released record. The
     witness's own evidence and reconciliation reads stay available while a
     business output is withheld.
   - **Detail in R0-07.** The release record's attributes, actions and
     read gating are specified in R0-07's entity delta.
   - **No locks held while waiting.** No run, chain-head or database lock is
     held while waiting for the capture to appear.
   - **What the allowlist compares.** It compares the invocation's recorded
     identity (provider, CLI version, profile, model) together with the
     projection and method actually evaluated for the exchange.
5. **Fail-closed store.** A real `claude_cli` call is refused before
   reservation when the witness store root is not configured or not
   trusted. It is no longer allowed to run with reconciliation inert.
6. **Unchanged.**
   - The claim stays the same: the stdin and the structured output are
     equal, and the CLI-added context is recorded, not proven equal or
     benign. "Reconciled" does not mean the research is factually right.
   - Fake calls stay `skipped`.
   - The test environment keeps an empty allowlist, and overrides stay
     test-only.
   - The scan stays as a backfill.
   - Changing an entry needs a reviewed amendment. A new CLI version,
     profile or projection needs a new owner-granted proof.

**Consequences.**

- No ordinary real call's output is used unless its own wire record
  matches.
- Each call is slower by the time reconciliation takes.
- Calls to the CLI stay one at a time (D-069). The facade's wait for its
  own reconciliation adds latency to that call's run. Whether later calls
  wait behind it depends on where the wait sits relative to the serialized
  CLI server; R0-07 places it after the server has released the call, and
  measures the result.
- Every CLI bump or new profile costs a projection review, calibration
  calls and an enablement change.

#### R0-07 calibration harness amendment (2026-10-13): the harness as built

**Status: ACCEPTED.** The owner accepted this amendment on 2026-10-14
(America/Denver, about 10:14 MDT), in the private Claude session chat,
with the word "accept". This followed Codex's approval of its content for
owner presentation at 7c0753c2 (reply 5712f2fc). It records how the R0
amendment's calibration exception (item 2) is confined in the harness on
PR #146. It enables no tuple, grants no spend and adds no dependency.
**OQ-E3 is not accepted here.** The conservative default stays:
recovering an outstanding sent call (a `launch_pending` or `launched`
record) needs the owner's typed `STOPPED`.
The contracts and their reviews are in
`docs/product/r0/r0-07-witness.md`, sections 8.2–8.14.

**Context.**

- **What the R0 amendment requires.** The four G-R0 calibration calls
  must run in an isolated harness, never in a business flow. Their
  evidence must be quarantined until it is reviewed.
- **Where the harness sits.** It is built as the console subcommands
  `calibrate <profile>` and `calibrate-recover`, in test-seam builds
  only.
- **What remains to be decided.** The harness can't prove some physical
  facts, such as process quiescence or durability across power loss.
  This amendment records each such limit and the conservative choice
  made where it applies.

**Decision.**

1. **Confinement.**
   - **The module.** The orchestration (`CalibrationConsole.Calibrate`)
     exists only in test-seam builds. A non-seam build has neither the
     module nor a working subcommand, and the dev-VM proofs check this.
   - **The private server.** The command starts one unnamed ClaudeCLI
     server, linked to itself. It is never registered under the Runtime's
     name, and the console's Runtime provider stays the Fake.
   - **The authority.** A sealed, one-shot authority registry in a
     protected ETS table binds the call's invocation, run, tenant,
     profile, the command and server pids, the prompt and schema
     commitments, and the console instance. The staging exemption
     consumes that entry before the launch. Any mismatch keeps
     `:real_model_staged`. The registry revokes the entry when either pid
     dies.
   - **The wrapper.** A seam-only reserved-call wrapper
     (`ModelProvider.calibration_call/3`) re-checks the reserved row,
     the run and the request hash before any provider effect. It then runs
     the facade's own shared invoke, validate and settle path, so `sent`,
     completion and failure settle exactly as for an ordinary call.
   - **Threat model.** This is a trusted in-process boundary. It stops
     other callers, workers, second calls, servers and replays in the
     same VM. It does not defend against code the owner runs inside the
     console VM.
2. **Admission and binding.**
   - **The reservation.** The call is reserved under the calibration
     marker on a `:proof` run with no Operation.
   - **What the original reservation event records:**
     - the G-R0 binding (grant, revision, allocation, profile);
     - the console's claim (`calibration_claim.instance_id`);
     - the exact tuple.
   - **The launch re-check.** Launch admission re-derives exactly that
     one event. Admission itself is run-neutral: a typed launch refusal is
     stopped by the command (`SDR.Model.stop_refused/3`) before the latch.
3. **Single flight, written before `sent`.** The command alone writes the
   launch record (schema 3):
   - `claimed` → `launch_pending` (written before the call, so before
     `sent`) → `launched` (only on a verified receipt) → `finished`;
   - `aborted` and `recovered` are the other final states.

   The record names the owner VM's OS pid and its start identity. Another
   recoverer refuses with `:owner_alive` while that VM lives.
4. **The isolation is observed, not enforced.**
   - **No wrapper.** The Port child already leads its own process group,
     so no wrapper is added. A preflight launches a held synthetic target
     and confirms it has its own group, and that its cleanup completed.
   - **The launch receipt.** The request names its observer: the
     command's own pid and a reference. Inside the call, the server reads
     the root's start identity and its group membership, and sends one
     correlated receipt to that observer. It arrives before the call's
     reply. The command reads it only after the call returns, by reference,
     invocation and server, and ignores stale or foreign messages. There
     is no observer process, so the command stays the record's only
     writer.
   - **Unverified means unknown.** An unverified or missing receipt never
     writes `launched` and never claims a cleanup.
   - **The limit.** The observable is the CLI's process group. A
     descendant that changes its group escapes it.
5. **Recovery is attended (OQ-E3 stays open).**
   - **The prompts.** `calibrate-recover` takes an explicit target, and
     every state change needs `RECOVER <id>`.
     - **An outstanding sent call** (a `launch_pending` or `launched`
       record with sent history) also needs `--owner-verified-stopped`
       and `STOPPED <id>`, and goes through the attestation below. For a
       `launched` record, live work observed in its group refuses before
       that prompt.
     - **The final-replay exception.** An already-`finished` (or
       `aborted`) record, with exactly the history, latch and frozen file
       it attests, is replayed with `RECOVER <id>` alone: no `STOPPED`, no
       attestation. Its release re-checks quiescence.
   - **The probe's other uses.** Beyond that live-group check, the probe
     also checks the owner's identity when recovery is claimed, and
     quiescence at a final release.
   - **The attestation.** It is audited database-first: the
     `calibration.owner_attested` event, deduplicated by
     `attestation_id`, then `attestation.json` in the recovery ticket.
   - **Live work and probe failures are never permission.** Live work
     seen through the probe refuses even with `STOPPED`. A probe error is
     never read as absence.
   - **Hard stops.** A ticket is never adopted. An unprovable state is a
     hard owner-conflict stop that keeps the filesystem single-flight
     lock, and any ticket. These are two separate barriers:
     - **The lock** blocks every later `calibrate` on this console.
     - **The database predecessor barrier** (B4') is separate. An
       **unlatched** real calibration invocation blocks later real
       calibration attempts across every profile in the tenant. A hard
       conflict that happens after a successful latch keeps the lock, but
       its invocation already satisfies the predecessor condition.
   - **No automatic quiescence, and no orphan repair.** The code has no
     automatic-quiescence recovery path, and no automatic repair of an
     orphaned lock, ticket or barrier. Adding automatic quiescence needs
     the owner's acceptance of OQ-E3 and then a reviewed code change. Any
     repair workflow is a separately reviewed slice.
6. **Evidence and quarantine.**
   - **Observation.** One bounded observation runs with the recorded
     tuple, outside any lock, and only the receipt's own link is used.
   - **The file (E2).** It is published create-only and private, in the
     `r0-calibration-evidence/1` schema, under
     `~/.local/state/sdr-agent/calibration/evidence/`. It is never
     replaced.
   - **The latch (E1).** The latch is a `:calibration` release carrying
     the file's hash. Calibration output is never `:released` to any
     business read.
   - **Publication.** Nothing is published to the repository unless the
     owner accepts OQ-E1. Promotion of a tuple remains the R0 amendment's
     separate, reviewed enablement change.

**Qualifications (stated, not solved).**

- **Durability.** The temp file is fsynced before `link(2)`, but the
  directory is not fsynced. A power loss can lose a published name. A
  missing file under a latch is then an owner conflict, and the file is
  never recreated. The launch record has the same qualification.
- **Pid identity.** `ps` start times have one-second resolution. A pid
  reused within the same second reads as alive, which is a conservative
  false-busy. On this macOS host the session id is 0 for every process,
  which is why the process group, not the session, is observed.
- **Trust boundary.** The owner's console VM is trusted (item 1).

**Consequences.**

- A calibration call can run only through this attended, single-flight
  path. Its output never reaches a business flow.
- There is no unattended repair. After a crash or uncertainty, the
  owner uses the reviewed, attended `calibrate-recover` where it applies.
  A hard owner conflict waits for a separately reviewed repair workflow.
  It is never cleared by deleting a lock, ticket or predecessor evidence.
  That is slower, and deliberate.
- **As accepted,** this amendment covers the harness as reviewed at PR
  #146. Any change to the authority, receipt, isolation or recovery rules
  needs a further reviewed amendment.
- **Not decided here:**
  - OQ-E1 (publishing evidence to the repository);
  - OQ-E2 (one profile and one attempt per command, with each attempt's
    evidence reviewed before the next; the harness already behaves this
    way and never batches);
  - OQ-E3 (automated process-group proof of quiescence).


#### R0-05 amendment (2026-10-16, proposed): operator input in crash reports, option B

**Status: proposed.** The owner chose option B and accepted its residual
risks (D-141). This text still needs Codex review, then the owner's
acceptance, before R0-05's MF3 implementation. It builds on the accepted
C4 amendment, "metadata-only database logging and spans" (D-117), and its
primary filter `SdrAgent.Logger.ExceptionFilter`. That amendment is on
the C4-01a branch (#165), so this one lands after #165.

**Context.** R0-05's resolver collects a typed confirmation. The valid
text is `STOPPED <switch id>`: a fixed word plus an id the page already
shows and the database already stores. It is not a credential; the
operation is authorized by authentication, the current-admin check, the
frozen review identity, the lifecycle fences and domain validation. A
mistyped text, though, can be anything, including an accidentally pasted
secret. `config :phoenix, :filter_parameters` covers only Phoenix's
parameter logger. Codex reproduced these crash-report paths
(`codex-r005-8de4fca-green-review.md`, `codex-r005-379e701-rulings.md`,
`codex-r005-03a16a2-adr-review.md`):
- **the socket state:** the LiveView channel's `format_status` state,
  printed at `:debug`. The opaque `Confirmation` wrapper already redacts
  this;
- **the last message:** a GenServer crash report always prints it, at
  every level: the raw `change_resolution` or `confirm_resolution` payload;
- **downstream holders:** the resolution task, `ProfileSwitches`, and the
  registered coordinator, which receives the confirmation in its
  `resolve_blocked` request and keeps the attestation in its state while
  an unknown outcome settles;
- **secondary reports:** a supervisor's report about a crashed child
  (Phoenix's socket pool is a DynamicSupervisor) is emitted by the
  supervisor and does not carry the child's logger metadata.

The first draft of this amendment (option A, `03a16a2`) tagged every
holder. Codex found the coordinator and secondary reports uncovered
(NEEDS-REVIEW). Covering them means tagging the coordinator for its
lifetime and attributing supervisor reports, about a day more. The owner
chose B instead: minimize what leaves the page, and accept the rest.

**Decision.**
1. **Only the valid text leaves the page.** In `:editing`, the page
   compares the submitted binary byte for byte with
   `"STOPPED " <> review.switch_id`, using the switch id held in the
   socket's review, never one from the browser. There is no trimming, case
   folding, coercion or synthesis. A mismatch is refused by the page
   before any attestation is built, before anything is stored, and before
   any task, domain or coordinator call. A `change_resolution` event keeps
   only whether the text matches (a boolean), never the text. A local
   refusal is not a domain refusal: it claims no audit, rollback or
   recorded attempt, and its wording never includes the text.
2. **The valid bytes are forwarded as they were typed.** The page wraps
   the original matching binary in `Confirmation` and reveals it only at
   the existing domain call. "Check again" resends the same frozen
   identity; nothing is rebuilt. The backend stays authoritative: the
   domain's closed-shape, exact-confirmation, actor, replay and
   coordinator checks are unchanged, and so is the public domain contract.
3. **The AdminLive channel process is tagged.** It sets the logger
   metadata `sdr_sensitive_input: true` in `mount/3`, before any operator
   input arrives, and never clears it. The facts and resolution tasks are
   not tagged: the facts task holds no input, and the resolution task holds
   only the valid text, whose diagnostic copies are accepted (5).
4. **A tagged process's error reports become a fixed diagnostic.** The
   primary filter gains a second, fixed classification. An event from a
   tagged process is replaced when it is any of:
   - a crash, `proc_lib` or termination report (OTP report
     `domain: [:otp, ...]`, an Elixir translator report, or a
     `crash_reason` in metadata);
   - any event at `:error` or above.

   The replacement is the message `"diagnostic withheld: process holds
   operator input"`, at the original level, with only the validated
   standard metadata (the C4 `scan_limit` shapes: `pid`, `gl`, `time`,
   `line`, `mfa`, `file`, `domain`) plus `sdr_sensitive_input: true`.
   Nothing from the message, report, format arguments or other metadata is
   kept. The tag check is one bounded metadata lookup, made before the C4
   scan. The filter never raises and never fails open: a failed
   classification of an event that may be tagged is replaced, and the
   filter stays attached. Untagged events, including the C4
   database-error path, are unchanged.
5. **Accepted residual risks (owner, D-141).** This amendment does not
   close every crash-report path. The owner accepted:
   - **the valid phrase in downstream reports:** crash or error reports
     from untagged downstream processes (the resolution task,
     `ProfileSwitches` callers, the coordinator, including its retained
     settlement state) may contain `STOPPED <switch id>` in arguments,
     exit reasons or state. The allowance covers only these diagnostic
     copies. It does not allow the phrase in ordinary UI errors, audit
     payloads, stored columns, span attributes or new telemetry events;
   - **mistyped input in secondary reports:** the text can be anything. The
     tag classifies only the channel's own reports. A report another
     process writes about the channel, such as a supervisor's, is not
     classified and can carry the crash reason or stack. SASL reports being
     off by default (`handle_sasl_reports: false`) reduces one visible path;
     it is not a control, and a logging configuration change can expose
     it. Process metadata does not propagate to reporters;
   - **lost detail:** the channel's error-or-higher diagnostics lose their
     detail (the reason, stack and last message), not only its crash
     reports. Debugging a page crash then needs a reproduction.

   **Lifetime wording.** Input also exists in browser and transport
   buffers, and in the documented raw in-process `handle_event` telemetry
   (R0-05, test 15). A callback may leave VM-managed terms until garbage
   collection. The application does not deliberately retain or forward a
   mismatched text after handling the event; it does not claim the text
   exists in one place only, or that memory is erased.
6. **Unchanged:** the error level and the fact that something failed; the
   logger configuration and its minimum level; Phoenix's parameter
   filtering; the `Confirmation` wrapper; the domain and coordinator
   contracts.

**Not covered: SettingsLive (OQ-R5-1).** C4-01b's settings page holds
private settings content in its state and its `settings_content` event
payload. The valid-phrase allowance above does not apply to it, and the
C4 private-content guarantee is not satisfied by this amendment. It needs
a separate, owner-owned follow-up that identifies its holders and
reporters, the mitigation and the acceptance gate, or a separate explicit
risk decision. Codex and Claude recommend full protection for it.

**Consequences.**
- **Positive:** arbitrary operator input never crosses the page boundary
  into tasks, the domain or the coordinator. The channel's own crash and
  error reports carry no input at any level. Coordinator diagnostics keep
  their detail.
- **Negative:** the residual risks in (5), accepted by the owner. The
  promise is narrower than "the confirmation never appears in any log".
- **Neutral:** no new dependency, process or table.

**Tests (RED first, synthetic canaries only):**
- **Minimization, traced with positive controls:** an arbitrary mismatched
  canary, typed and force-submitted, is never stored in the review or
  socket assigns, and is never passed to a task, `Agents`,
  `ProfileSwitches` or the coordinator (trace the actual calls). The valid
  text is passed, as the operator's own bytes, so an empty trace cannot
  pass.
- **The tagged channel:** a LiveView crash while handling
  `change_resolution`, and while handling `confirm_resolution`, with the
  real form-encoded payload, with a valid and a mismatched canary; a crash
  while frozen in `:submitting` and in `:uncertain`. The canary is absent,
  at `:debug` and at `:warning` minimum, from the captured message and
  report, the format arguments, and metadata keys and values; the
  diagnostic is present at its level.
- **Controls:** an untagged crash keeps its normal report; the C4
  database-error path and its bounded fail-closed scan are unchanged; a
  tagged `:info` event is unchanged; a failed classification is replaced;
  the filter is still attached after every test.
- **The accepted limit, shown separately:** one test demonstrates that a
  supervisor-emitted report about the tagged channel is not classified (it
  pins the residual in (5)). It is never written as an absence assertion,
  and no general absence assertion is weakened to accommodate it.
- **Regressions kept:** the valid flow, the frozen exact retry, the actor
  and redirect checks, the stored-row binding, and test 15's absence of
  the text from ordinary logs, URLs, stored rows, audit payloads, captured
  application telemetry and exported spans.

### Anchoring (S11)

- `SdrAgent.Audit.AnchorSink` behaviour; sinks: `FileSink` (tests),
  `GitSink` (private repository `chops/sdr_agent-audit-anchors`, protected
  against force-push and deletion, append-only signed head files), and
  `OpenTimestampsSink` (only hashes leave the machine; pending and completed
  proofs bundled).
- Cadence: every N events or 15 minutes, and on every export.
- Each anchor record carries: key id, key rotation/revocation status,
  sequence and event range, chain-head hash, prior anchor hash,
  canonicalization version, sdr_agent git commit, anchor-repo commit and blob
  ids, and the sink receipt.
- Signing key: ed25519, private key in `secrets/sdr_agent.sops.yaml`
  (`audit_anchor/ed25519_private_key`), public key and key id committed at
  `docs/audit/anchor-signing-key.pub`.
- **Assurance limits:** GitSink proves continuity and authenticity **within
  the owner's trust domain only** (the owner administers the repository and
  holds the decryption key). OpenTimestamps adds a third-party proof that a
  head existed at a time. Exports state which levels apply (ADR-0002).

#### Executable S11 clarifications

- Anchor creation is serialized per tenant on the audit chain-head lock. The
  genesis range begins at sequence 1; later ranges begin at the preceding
  anchor's `to_sequence + 1`. Anchor-publication events alone do not force a
  recursive anchor. An export with no new anchorable event reuses the latest
  anchor.
- The signed `sdr-canonical-json/1` statement binds tenant, anchor number,
  event range, chain-head hash, prior-anchor hash, canonicalization version,
  application Git SHA, trigger, key id, and signing-time key status.
- Rotation does not invalidate a historically valid signature. Revocation is
  timestamped separately from retirement and is immutable. A signature made
  before `revoked_at` remains valid with explicit reduced assurance; a
  signature made at or after `revoked_at` is invalid.
- Private signing material must derive to the active key's registered public
  key before any append-only anchor or export is written. Offline verification
  never treats a bundle-embedded key as a trust root: it requires the pinned
  public-key file (or an explicitly supplied out-of-band equivalent), matches
  `key_id`, and applies the same revocation-time rules.
- Export scope is enforced before payload reads. Only events selected by the
  requested lead, agent-run, draft or sequence range and content-addressed
  payloads referenced by those events enter the bundle. Output paths remain
  beneath the operator-selected root and bundles are mode 0600.
- OpenTimestamps pending and upgraded proofs are distinct append-only sink
  receipts. A pending proof never yields `ots_anchored` assurance; an upgraded
  proof must also pass Bitcoin-attestation verification. Git/OTS receipt status
  alone never raises offline assurance without a validating verifier.
- Sink failures are append-only receipts and an empty-range retry republishes
  the existing anchor. Export failures transition their request to `failed`
  and remove any partially written bundle.

#### S11 review correction: trust sets, time evidence and retry semantics

- Offline verification uses `docs/audit/trusted-keys.json`, an out-of-band
  manifest of pinned PEM files with key id, activation, retirement and
  revocation metadata. Retain historical key files through rotation; each
  anchor resolves its own signing key. Never source this set from a bundle.
- The bundle's anchor `inserted_at` is not trusted time. A revoked key's
  historical anchor needs a verified OTS Bitcoin attestation for its exact
  digest strictly before `revoked_at`; without it the report is
  `valid?: false`, `chain_verified`, `revocation_time_unproven`. A Git author
  or committer date can also be backdated and is not independent time evidence.
  Even proven historical revoked signatures retain reduced assurance.
- OTS calendar responses are wrapped in the v1 detached-proof header with
  OpSHA256 and the submitted anchor digest. Verification uses `ots verify -d
  DIGEST PROOF`, checks the digest before invoking the CLI, and requires a
  successful Bitcoin attestation. The CLI reports a UTC day; use the next
  midnight as a conservative upper bound, never infer a finer timestamp.
- Confirmed sinks are skipped on retry; identical existing File/Git statements
  are successful replays and conflicting bytes fail. Cadence excludes anchor
  bookkeeping and never fires an interval anchor without new work. Explicit
  retry/export may still republish unconfirmed sinks.
- `mix sdr.audit.verify` supports `--key-set MANIFEST` and the single-key
  compatibility option `--public-key PATH`. Its Git assurance ceiling is
  `signed`: it has no Git fetch verifier. Programmatic callers may provide a
  verifier that fetches the trusted repository/commit and checks the statement
  digest; a confirmed receipt alone never raises offline assurance. OTS
  verification requires the operator's `ots` CLI and Bitcoin node; unavailable
  evidence cannot raise assurance.
- Compilation tracks Git HEAD, its branch ref and packed refs, so anchor
  provenance recompiles after commits in a worktree. Releases retain their
  compiled build SHA.

#### Child-process environment (security fix, 2026-10-07)

The anchor signing key reaches the BEAM through
`bin/with-secrets SDR_AUDIT_ANCHOR_PRIVATE_KEY -- ...`, and `System.cmd/3`
and `Port.open/2` children inherit the whole environment. So every external
launch takes its environment from `SdrAgent.ChildEnv`. That covers the
ClaudeCLI port, the GitSink and OpenTimestamps subprocesses, and the git
calls in provenance and anchoring. Each child receives only:

- a base allowlist (`PATH HOME USER LOGNAME LANG TMPDIR TZ LC_*`);
- the names its tool needs;
- the launcher's own values (for example the S12 witness ids).

Every other name is removed. Names that look like secrets (`*_KEY`,
`*_TOKEN`, `*_SECRET`, `*_PASSWORD`, `*_CREDENTIALS`) are removed even if
allowlisted. Per-call ClaudeCLI attestation and the Bedrock/Vertex/Foundry
refusal are unchanged. Real-child canary tests cover each launcher.

## Justification

### S11b runtime/tool amendment

Approved under ADR-0001 by Claude, consultation reply
`01a114a4-e5a3-71bd-93a0-647c4fb3541c`, with TDD/implementation permission
`01a114af-889d-761e-82d5-d6fe3c205351`.

- Dev and prod enable Git plus OpenTimestamps by default. The explicit
  `SDR_ANCHOR_SINKS=none` or `file` override supports offline operation;
  test retains empty sinks regardless of the operator environment.
- `opentimestamps-client` **0.7.2** is provided by the unchanged flake.lock
  nixpkgs revision `e8be7818e19ada32105a8af937a6a473b38167ca`. Invocation
  checks `ots --version`, failing closed
  on missing/different binaries. No Hex source or version changes.
- This LGPL-3.0 tool (upstream LGPL-3.0-or-later; Nix metadata
  LGPL-3.0-only) is executed as a separate program through `System.cmd`.
  It is not linked into or vendored as application code; this use does not
  change the application's Apache-2.0 license. The audit signing private-key
  variable is removed from the tool's environment; only public proof/digest
  data reaches its arguments/files. A Bitcoin node remains operator-configured.
- Every ten minutes, a bounded dispatcher selects unresolved anchors and
  inserts unique per-anchor/pending-receipt jobs. Live jobs exclude duplicates
  without a time-window expiry. Jobs have three attempts, bounded backoff,
  and a 60-second execution timeout. Offline mode does no dispatch/network work.
- A confirmed upgrade appends one immutable receipt, serialized under the
  chain-head lock after external verification; replay reuses the receipt.
  An incomplete proof remains pending without a new receipt. Real failures
  append failed sink evidence and surface through Oban retry/discard state;
  S7 owns the Operations/Failure attention integration.
- Existing pending OTS submissions are reused during publication retries.
  No idle interval creates anchors or republishes a failed sink. Optional
  offline retirement/bundle-key assurance changes remain separately tracked.

Packaging amendment approved by Claude, reply
`01a114c2-f102-70bd-b5bc-f9c7baac3e95`: all production OTS invocations run
through configurable `bin/with-audit-tools`. It executes
`nix shell --no-write-lock-file --inputs-from REPO_ROOT
nixpkgs#opentimestamps-client --command ...`, preserving literal argv and
clearing inherited credentials with an explicit public cache/TLS environment
allowlist. Missing wrapper/Nix or a client version other than 0.7.2 fails
closed on attempted proof operations. `SDR_AUDIT_TOOLS_WRAPPER` can select the
deployment's wrapper path; the default is `bin/with-audit-tools` under the
runtime working directory.

This is an interim workaround for factory defect F6: its receipt treats
`devenv.nix` (and bin/verify/project-facts) as exact-owned although project
environment settings are described as project-owned. Managed Nix files,
the lock, receipt, recipe and validator remain byte-for-byte unchanged.
No project-factory or proposals changes are part of S11b.

The three mechanisms answer different audit questions; none substitutes for
the Postgres ledger, and each is labelled with exactly the assurance it
provides, so no artifact over-claims.

## Consequences

### Positive

- Live, single-trace inspectability during development.
- Independent transport corroboration of model traffic.
- Ledger rewrites become detectable against off-database anchors.

### Negative

- Content in Tempo duplicates prompt bodies in a second, non-durable store
  (accepted for synthetic data).
- Wire-witness correlation is weak until S12 proves propagation.
- Same-owner trust limit for GitSink.

### Neutral

- Tempo retention (168h) is irrelevant to audit durability by design.
