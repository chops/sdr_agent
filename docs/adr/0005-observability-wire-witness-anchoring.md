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
The C2* demo-exception amendment (2026-10-27) in the wire witness section is
accepted as D-223, owner acceptance delegated by D-219, after Codex's static
PASS (ca0e5bec); its text is published as reviewed, so its own Status line
still reads PROPOSED.
Addendum 1 to the C2* amendment (2026-10-27; two operation-snapshot owner
entries, `:agent_finish` and `:stale_run_recover`), published after it, is
accepted as D-227, owner acceptance delegated by D-219, after Codex's
exact-text PASS (9f90b710); its own Status line still reads PROPOSED.
Addendum 4 to the C2* amendment (2026-10-27; a send-gate refusal records
its true reason, `:demo_exception_not_in_use`, on the approval), published
after addendum 1, is accepted as D-228, owner acceptance delegated by D-219,
after Codex's exact-text PASS (5685d6f0); its own Status line still reads
PROPOSED. Addenda 2 and 3 (2026-10-27; the origin-run and cited-invocation
coverage of exception-derived drafts, and the server-derived release label on
a new proposed-draft event), published between addenda 1 and 4, are accepted
as D-230, owner acceptance delegated by D-219, after Codex's exact-text PASS
(c151946f; addendum 3 with Codex's one-line correction); their own Status
lines still read PROPOSED.
Addendum 5 to the C2* amendment (2026-10-28; the policy expiry and the
environment end move to 2026-11-07T07:00:00Z exclusive), published after
addendum 4, is accepted as D-247 on the owner's direct decision D-240, after
Codex's independent exact-text PASS (m_codex_d240_r8_review_1793158304526,
review 7ab1cc15), not under the D-219 delegation; its own Status line still
reads PROPOSED. The amendment, addenda 1-4 and their accepted hashes are
unchanged.
The D-237 local prototype amendment (2026-10-28; one real, labelled journey
in a separate local prototype database, operated by agents), published after
C2* addendum 5, is accepted as D-249 under the owner's prospective conditional
acceptance D-242, after Codex's FINAL independent exact-text PASS
(m_codex_d237_r6_verdicts_1793163169000, review c3157ad2). The owner did not
read the final bytes. Its own heading still reads PROPOSED. It does not cover
the separately hashed log residual clause, agent-session processing of
personal data, the budget worksheet, provisioning or any real call; those stay
activation gates in its text.

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


#### R0-05 amendment (2026-10-16): operator input in crash reports, option B

**Status: ACCEPTED.** The owner accepted this amendment on 2026-10-16
(America/Denver, about 13:20 MDT), at the text Codex passed for owner
acceptance at `d0c80ff`; the reply was "2. yes" (D-143). The owner had
chosen option B and accepted its residual risks earlier that day (D-141).
Acceptance permits R0-05's MF3 implementation; it is not merge,
activation or spend approval, and it does not cover SettingsLive
(OQ-R5-1). It builds on the accepted C4 amendment, "metadata-only
database logging and spans" (D-117), and its primary filter
`SdrAgent.Logger.ExceptionFilter`, which merged with C4-01a (#165,
`e34172c`).

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

#### Response-layout amendment (2026-10-20): projection v4

**Status: ACCEPTED.** The owner accepted this amendment on 2026-10-20
(D-182), at the exact text Codex approved for owner presentation
(witness response-block plan r5, section 8). Acceptance starts the T1 to
T6 grammar slice only; it is not proof, enablement, merge or spend
approval.

**Context.** G-DEMO attempt 2's one ordinary Opus output was withheld
(`witness_missing`): its response was not exactly one text block
(`response_block_unsupported`). Which blocks it held is not established.
This amendment adds a candidate grammar; it attributes no cause.

**Decision.**
1. **Grammar.** Add `claude-message-json/4+prompt-builder/1`: v3's request
   contract and prompt-builder guard, unchanged, plus a response of 1 to 4
   leading `thinking` or `redacted_thinking` blocks in total, then exactly
   one `text` block, with nothing after it. `tool_use` stays a mismatch.
   The stream first passes the unchanged shared v1 to v3 parser; its
   refusals stay v3 refusals. A v4-only validator then checks each
   reasoning block syntactically:
   - `thinking` starts as exactly `{type, thinking: "", signature: ""}`,
     with zero or more string `thinking_delta`s, then one or more string
     `signature_delta`s with a non-empty combined value, then stop;
   - `redacted_thinking` is exactly `{type, data: <string>}` with no deltas;
   - anything else is `reasoning_unparsed`.

   There is no local authentication, decryption or benignity claim.
2. **Claim and privacy.** The stdin and the structured output are equal.
   CLI context is recorded, not proven equal or benign. The v4 application
   link evidence adds only a closed layout label and, for an admitted
   layout, block counts. It adds no reasoning text, signature, encrypted
   data or per-block digest to application evidence. The owner's existing
   raw proxy capture, its retention and its access controls are unchanged.
   Reasoning contents are not part of the equality claim.
3. **Selection.** v2, then v3, then v1 as before. v4 is evaluated only for
   a v3-selected request when all of these hold: the current prompt
   builder; a passing v3 contract; a `:match`ed request; a decodable
   application output; a stream the shared parser accepts; no `tool_use`;
   and a block list other than one text block. These are exactly v3's
   response-layout refusal. Everything else keeps its v3, v2 or v1 result:
   v2-admitted requests, single-text responses, mismatches, malformed
   streams, unreadable application output and contract-invalid evidence.
   Invalid evidence is never healed by v4, and a failed v4 contract never
   falls back to v3. v4 is never evaluated first.
4. **Evidence.** `response_layout` is a closed enum. The thinking and
   redacted-thinking counts are present only for `reasoning_then_text`,
   totalling 1 to 4. They are never zero-filled or saturated, and refusals
   carry no counts. The full v3 request group is required. Downgrades keep
   the whole group without a projection. R is refused for v1 to v3. Each
   other refusal has one closed code. The 4096-byte cap is unchanged.
5. **Inapplicability.** `projections_inapplicable` keeps its request-only
   meaning; a v4 link carries `["v2"]`.
6. **Lineage.** A v4 successor never supersedes a mismatch head. This is
   enforced in `put_link`, in the link action's lineage validation, and in
   the database by a new migration that replaces the lineage function's
   body (its down restores the exact previous body). C3 is otherwise
   unchanged.
7. **Proof and enablement.** No v4 allowlist entry ships with the grammar.
   First, the reviewed harness: the closed `calibrate claude_cli_opus
   --projection v4` syntax; typed `V4` confirmation; a one-attempt Opus
   proof-grant family with owner-fixed start and expiry and no runtime
   override; and the distinct `:binding_family` launch check. Then one
   owner-granted synthetic calibration call with `calibration-prompt/1`.
   Only `match` counts as v4 evidence. `projection_differs`, `missing` and
   every other outcome are STOP: no retry, no relabel, no widening. Then
   Codex's independent evidence PASS. Then a separate enablement change for
   the exact Opus tuple. Sonnet needs its own proof.
8. **Unchanged.** Admission before spend, the result gate, release
   immutability, "never released to the original run", concurrency 1,
   the test-only overrides, the G-R0 family, and the existing single-text
   v2 and v3 behaviour, including release when the tuple is enabled.

**Consequences.** A response with leading reasoning blocks can become
releasable only after the proof and enablement. Other v4-eligible layouts
stay withheld, with a finer code. One more projection is to be maintained.
The proof may STOP without v4 evidence if the model replies with a single
text block, or with a layout outside the grammar.

<!-- BEGIN ADR-0005 C2* DEMO-EXCEPTION AMENDMENT: text as reviewed by Codex (ca0e5bec) -->

#### C2* demo-exception amendment (2026-10-27, PROPOSED): a scoped, expiring release of a positively matched v4 candidate that has not been independently calibrated

**Status: PROPOSED.** This amendment has not been accepted or implemented.

To be accepted, it follows ADR-0014 Amendment 3 (accepted, D-222):

- Codex gives an independent static PASS of this exact text and of its entity/action delta.
- A decision row then cites D-219, the commit and this file's SHA256, and records "owner acceptance delegated by D-219".

The owner's direction for this amendment is D-218 item 3. Accepting it approves no grant, spend, tuple enablement, merge, delivery or data access.

**Context.**

- **What can be released today.** Only a `reconciled` result is released (R0 amendment item 4).
  - The immutable release allows exactly three pairings: `released ↔ reconciled`, `withheld ↔` five reasons, and `calibration ↔ calibration`. Both the resource and a database CHECK enforce them (`lib/sdr_agent/agents/model_result_release.ex:64-72,106-132`; `priv/repo/migrations/20261012214848_r0_07a_result_release.exs:104-108`).
  - `:released` needs three things: a valid output, this invocation's current reconciled primary link, and an exact allowlisted tuple (`lib/sdr_agent/agents/changes/release_decision.ex:286-310`).
- **Projection v4 (D-182).**
  - v4 is evaluated only after v3 refuses a response layout (`lib/sdr_agent/agents/witness.ex:564-597`; `lib/sdr_agent/agents/witness/projection.ex:396-431`).
  - No v4 allowlist entry ships (`config/config.exs:224-251`).
  - A positive v4 comparison therefore becomes an `inferred` primary link. The `method_not_enabled` code is added after the observation's warnings are collected (`witness.ex:461-465,889-894`), so a fresh positive v4 match opens no attention (`test/sdr_agent/agents/witness/reconciler_test.exs:973-998`).
  - The gate then withholds the output as `witness_missing` / `method_not_enabled` (`lib/sdr_agent/agents/result_gate.ex:296-310`).
- **The gate mode cannot provide release.** The mode is compiled in. Any mode other than `:enforced` refuses calls rather than releasing them (`result_gate.ex:67-85`; `lib/sdr_agent/agents/admission/gate.ex:101-108`).
- **Admission is unchanged.** Opus 2.1.294 is promoted by its v3 entry (`config/config.exs:235-242`; `witness.ex:208-220`; `projection.ex:373-379`).
- **The enforced path.** The ordinary route to enforced v4 is the response-layout amendment's item 7 (T7), which comes after the Friday work (D-218 item 11).

**Decision.**

1. **One closed policy entry.** There is exactly one reviewed code entry, `c2star-demo-v4/1`. Its fields are:
   - `environment_id: "agentenv-1"` (ADR-0004's agent-environment amendment);
   - `starts_at: 2026-10-27T06:00:00.000000Z` (inclusive) and `expires_at: 2026-11-01T06:00:00.000000Z` (exclusive). This is the outer technical window. It supplies no budget;
   - `identity`: `provider: :claude_cli`, `cli_version: "2.1.294"`, `profile_id: :claude_cli_opus`, `model_id: "claude-opus-5-5"`, `prompt_builder: "prompt-builder/1"`, `ledger_generation: 2`;
   - `projection_version: "claude-message-json/4+prompt-builder/1"` and `method: :propagated_id`;
   - `usage_origins: [:assignment]` and `purposes: [:qualification, :evidence_extraction, :outreach_proposal]`;
   - `lead_ids`: the exact fixture leads of `SdrAgent.Demo.Fixtures` with `expected_outcome: :qualify`:
     - `019b8eac-1180-74d8-9f38-54127081d946`
     - `019b8eac-1180-7c3d-a4ad-c369e27a97f1`
     - `019b8eac-1180-761c-9fad-f113afaa661b`
     - `019b8eac-1180-7ac2-81bb-c970986aa7be`
     - `019b8eac-1180-742a-89d2-cc1ca61efd6a`

     The source is `lib/sdr_agent/demo/fixtures.ex:136-179,219-223`.
   - `authorization_id`: the one authorization of ADR-0004's amendment that may fund an eligible call. It is unset until the owner's caps exist; while unset, nothing is eligible;
   - `label: "demo exception - v4 not independently calibrated"`;
   - `acceptance_ref`: the delegated-acceptance decision row.

   `entry_sha256` is the `sdr-canonical-json/1` SHA256 of all of these fields. There is no wildcard and no runtime-supplied field. Changing or extending the entry needs a reviewed code change and a new accepted amendment.

2. **Selector, operation snapshot and effective window.**
   - **Selector.** `SDR_DEMO_EXCEPTION` is read in `config/runtime.exs`. Unset means off. The only accepted value is `c2star-demo-v4/1`, and only in `dev`. Any other value, or any value in `test` or `prod`, refuses boot. The selector is never authority on its own.
   - **Operation snapshot.** This is an observation of the agent environment's lease, environment binding and authorization binding (ADR-0004 amendment). It produces a snapshot with a per-VM monotonic `generation`, the observation instant, and the three file digests and their validity.
     - **Entry points.** Each of these is an entry point. Each one applies the owner-or-inherit rule below on entry:
       - the agent actions that reserve real calls, create `:llm` Decisions or run the hand-off, each at its `perform/2`;
       - `ModelProvider.complete/2`;
       - `reserve_model_invocation/3`;
       - `admit_launch/3`;
       - `ResultGate.gate/3`;
       - `ResultGate.Recovery.run/3`;
       - `Agents.released_output/2` and `ReleasedOutput.fetch/2`;
       - the `DecisionRules` invocation check;
       - `SDR.proposal/2`;
       - `Outreach.edit_draft/3`, `Outreach.approve/3` and `Outreach.inbox_command/2`;
       - `Delivery.attempt/2`;
       - `CaptureAdapter.deliver/3`;
       - `Outreach.record_receipt/2` and the `DeliveryReceipt :record` capture check.
     - **Owner-or-inherit rule** (one outermost logical operation per process):
       1. **Inherit.** If the process already has an active snapshot, the entry inherits that same reference. It does not observe files, does not replace the reference and does not invalidate it. A nested return leaves the parent's snapshot active.
       2. **Own.** Otherwise, if no transaction is open, the entry becomes the OUTERMOST owner. It observes, then registers the snapshot as the active one before its first transaction. Only its own completion or raise invalidates the snapshot. The next top-level operation observes anew.
       3. **Refuse.** Otherwise, with no active snapshot and a transaction already open, an observation would be file I/O under locks. So the entry refuses, as "not in use", and observes nothing.
     - **Where the rule applies.**
       - Outside an attested agent environment (`SDR_AGENT_ENV` unset, for example the owner's instance), the rule is inert: nothing is observed, and no check consults a snapshot.
       - Inside one, a rule-3 refusal affects only the checks that need the snapshot: demo-exception decision and use authority (this item), and agent-environment funding (ADR-0004 item 9a). An ordinary reconciled, generation-1 or Fake output never needs it, and is unchanged.
     - **Synchronous nesting today.** For example:
       - `HandOffProposal.perform/2` opens `Audit.transaction` (`lib/sdr_agent/sdr/actions/hand_off_proposal.ex:55-67`). The enroll step then calls `SDR.proposal/2` (line 151), which calls `Agents.released_output/2` (`lib/sdr_agent/sdr.ex:266`).
       - `DecisionRules` runs its invocation check in a `before_action` hook inside the Decision's create transaction (`lib/sdr_agent/agents/changes/decision_rules.ex:37,116`).
       - `Delivery.attempt/2` runs the send gate, then `CaptureAdapter.deliver/3`, then the receipt insert.

       Each of those inner entries inherits the snapshot that its outer action or job observed before its first transaction.
     - **No cross-process reuse.** A snapshot belongs to one process. Launch admission runs in the model server's process (`lib/sdr_agent/ai/model_provider/claude_cli.ex:63-67`), so there it is its own outermost operation. It observes before its own transaction, beside the existing pre-lock store observation (`admission/gate.ex:91-97`).
     - **What the authoritative checks may do.** They take only the active reference. They never do file I/O and never take a lock for the snapshot.
     - **Sampling boundary.** A snapshot is a sample at its owner's start. It can be as old as the owning operation; for an agent action that includes a model call, that means up to the call timeout plus the gate wait. A file change after the sample is seen by the next top-level operation, not by this one. Launch admission samples separately, in its own process, just before spend. Database-serialized facts (grant, links, Failures, release) are re-read under the head regardless. There is no background observer.
   - **Effective window of a funded call.** It is computed per invocation, from that invocation's own funding allocation.
     - `effective_starts_at` is the latest of: the policy start, the authorization start, the grant's `starts_at`, and that allocation's `available_from` (when set).
     - `effective_expires_at` is the earliest of: the policy expiry, the environment end (2026-11-01T06:00:00Z), the authorization expiry, the grant's `expires_at`, and that allocation's `available_until` (when set).
     - An output funded in one window never gains the authority of a later window.
   - **Decision authority** for a new demo exception at instant `t` (`SdrAgent.Clock`) requires all of the following:
     - the selector names the entry;
     - the snapshot is valid and attests `agentenv-1`;
     - the live database and tenant equal the environment binding;
     - the authorization binding is complete and names the entry's `authorization_id` with its current digest;
     - the funding grant is `:active`;
     - `effective_starts_at ≤ t < effective_expires_at`.
   - **Use authority** for an existing demo-exception record at instant `t` requires all of the following:
     - the selector names the entry, and the entry's current `entry_sha256` equals the one in the record's basis;
     - the snapshot is valid, and its binding digests equal those in the basis;
     - `t < exception_expires_at`;
     - the funding grant is not revoked;
     - no link of the invocation, current or superseded, is a mismatch;
     - no critical `reconciliation_required` Failure exists for the invocation.

3. **Admission guard (reservation and launch).** This applies in an environment whose selector is on, to real calls only. It is checked after the single funding allocation is selected (at reservation) or read (at launch).
   - **Refusal rule.** A real call is refused before anything is sent (`:demo_exception_window`) unless both hold:
     - `effective_starts_at ≤ now`;
     - `now < effective_expires_at − (SDR_CLAUDE_CLI_TIMEOUT_MS + ResultGate.wait_ms() + 60 s)`.
   - **Charging.**
     - A reservation refusal rolls the whole reservation back. Nothing is charged; the existing Failure and refusal event are recorded (`lib/sdr_agent/agents.ex:291-307`).
     - A launch refusal moves the reserved row to `failed` without sending. It keeps the reservation's charge (`agents.ex:585-597`).
     - No consumed attempt is ever refunded.
   - **What the guard does and does not promise.** The guard is a scheduling guard. It does not prove that a process or provider cannot outlive the deadline under suspension or failure. Release and capture are therefore checked again at their actual instants. A charged call whose decision comes too late is withheld, never released under the exception.
   - **Funded scope comes first.** ADR-0004's funded-scope predicate (its agent-environment amendment, item 9a) applies to every agent-environment call at reservation and at launch, whether or not the selector is on. It funds only `assignment` × {`qualification`, `evidence_extraction`, `outreach_proposal`}, together with its profile, binding and authorization checks. So a call outside the C2* origins and purposes is refused at reservation, before it is charged. It is not charged and then merely withheld at release. If it is refused again at launch, it is never spawned, and the launch refusal keeps the reservation's existing charge. E1 below re-checks the same scope at release.
   - **Admission is otherwise unchanged.** The existing admission checks are unchanged (`admission/gate.ex:128-171`). This guard only adds refusals.

4. **Eligibility (all must hold, from persisted rows under the item 6 locks).**
   - **E1 Scope.**
     - Decision authority holds at the captured instant (item 6).
     - The run is running, is not a `:proof` run, and has `usage_origin` in the entry.
     - The invocation's `purpose` is in the entry.
     - The invocation is charged to the bound delegated grant, through one of that grant's allocations.
     - The run's lead id is in `lead_ids`, in the bound tenant.
     - The lead has exactly one `sales.lead.created` event in that tenant, with actor type `seeder` (its `:seed` action, `lib/sdr_agent/sales/lead.ex:131-137`).
     - The lead's account domain and contact email pass the reserved-name guards at that instant (`lib/sdr_agent/sales/synthetic.ex:22-43`).
   - **E2 Identity.**
     - The invocation is a generation-2 ClaudeCLI invocation, `:completed`, with `validation_status: :valid`.
     - Its recorded provider, CLI version, profile, model and prompt builder equal the entry's identity.
   - **E3 Only the v4 promotion is missing.**
     - `Witness.allowlisted?(invocation, v3, :propagated_id)` is true.
     - `Witness.allowlisted?(invocation, v4, :propagated_id)` is false. If a v4 entry ships, the ordinary `:released` path applies instead.
   - **E4 Positive v4 comparison.** This is checked on the receipt's primary link, which must be this invocation's single current primary link, with no successor.
     - `WitnessEvidence.validate/1` accepts the link's full evidence unchanged (`lib/sdr_agent/agents/witness_evidence.ex:166-176`).
     - `WitnessEvidence.validate_claim/1` returns `:ok` (`witness_evidence.ex:261-268`).
     - The extracted group passes `exact_v4_group?/1` (`witness_evidence.ex:245-250`). The group is the evidence restricted to the v3 context-group keys plus the R keys present. The helper is never applied to the full evidence map.
     - `link_status` is `:inferred`, `method` is `:propagated_id`, `classification` is `"primary"`, `projection_version` is exactly the v4 id, and `projections_inapplicable` is `["v2"]`.
     - `response_layout` is `"reasoning_then_text"`. `response_thinking_count` and `response_redacted_thinking_count` are integers 0 to 4 whose total is 1 to 4.
     - The ordinary release's identity check passes (`release_decision.ex:344-350`).
     - All four of `projected_request_sha256`, `observed_request_projection_sha256`, `projected_response_sha256` and `observed_response_projection_sha256` are present and are lowercase hex-64 (`witness_evidence.ex:82-85`). Each projected digest equals its observed digest. An absent digest never matches another absent digest.
     - The capture is complete: outcome complete, HTTP 200, both captures complete, stream complete, a reviewed proxy version (`witness.ex:624-631,669-674`).
     - **Reason codes.** These are compared as a set, on a comparison copy only.
       - The persisted `reason_codes` list must have no duplicate.
       - Its set must be exactly {`method_not_enabled`} or {`method_not_enabled`, `cli_injected_context`}.
       - Persisted order is irrelevant. The reconciler emits `["method_not_enabled", "cli_injected_context"]`, because it prepends `method_not_enabled` and then de-duplicates in order (`witness.ex:894,936`).
       - The persisted evidence is never rewritten, sorted or repaired, so `validate/1` and `validate_claim/1` see it unchanged.
       - Any unknown code refuses.
       - These codes are consistency checks only, never the basis.
   - **E5 Clean invocation.**
     - Every other current link is `ancillary`.
     - No current link is `unclassified` or `ambiguous`, and no exchange is open.
     - No link of the invocation, current or superseded, has ever been a `mismatch`.
     - No `reconciliation_required` Failure for the invocation is a critical one (live or resolved) or a live warning.
     - The receipt's status is `:inferred`, and its codes are a subset of `method_not_enabled` and `cli_injected_context`.
     - The store was configured and trusted for the observation.

     A fresh unpromoted v4 positive match satisfies E5 without any waived warning (Context).
   - **E6 New decision only.** E6 applies to a new decision only. The existing-row branch of item 7 runs first.

5. **Refusals.** Anything else keeps today's withheld outcome, reason, classification and cause. That includes:
   - any mismatch, including a retained or earlier one;
   - invalid output;
   - an unconfigured, untrusted or unreadable store;
   - a missing, incomplete, open, ambiguous or timed-out capture;
   - an unclassified exchange;
   - another projection or v4 layout, or a contract-invalid group;
   - stale or conflicting evidence;
   - another identity, origin, purpose, lead, grant or allocation;
   - a lack of decision authority;
   - an audit failure;
   - any unknown code.

   While the selector is on, the withheld event records one metadata-only refusal code from a closed set: `exception_off`, `environment_unattested`, `outside_window`, `scope_mismatch`, `identity_mismatch`, `promotion_gap_not_v4`, `link_not_eligible`, `invocation_not_clean`, `output_invalid`. A bounded attempt that fails stays failed. Rules are never widened ad hoc.

6. **Authority, locks and the decision instant.**
   - **Who may decide.** A NEW `:demo_exception` decision is accepted only from the result-gate finalizer. It must run under its registered `ReleaseDecision.Prelocked` context, extended with these bindings:
     - `finalizer: :result_gate`;
     - the primary link, the sorted current link ids, the funding grant and allocation, and the active operation snapshot reference (item 2). The reference is inherited from the owning agent action, or owned by `ResultGate.gate/3` when it is top-level;
     - `receipt_id: nil`.

     The context's registration, process, transaction and marker rules are unchanged (`lib/sdr_agent/agents/release_decision/prelocked.ex:47-114`). A standalone `:decide` (no context) refuses this disposition, and so does any other context, Recovery's included (`release_decision.ex:142-154`).
   - **Lock order in `ResultGate.finalize/4` for the exception branch.** No lock is taken after the chain head.
     1. The run, `FOR UPDATE`.
     2. Its Operation, `FOR SHARE`.
     3. The invocation, `FOR SHARE`.
     4. The primary link and every other current link, `FOR SHARE`.
     5. The funding grant, `FOR SHARE`.
     6. The funding allocation, `FOR SHARE`.
     7. The chain head.

     Withheld paths keep their existing order, including the selected cause `FOR UPDATE` before the head (`result_gate.ex:312-327,364-428`). This order follows the reservation (grant → allocation, `lib/sdr_agent/agents/admission.ex:10-26`) and the reconciler (invocation `FOR UPDATE` → head, `witness.ex:686-689`). It adds no cycle.
   - **Under the head.**
     - One instant is captured. It is used for decision authority, eligibility, the basis's `decided_at` and the record's `decided_at`.
     - The authoritative rechecks are plain reads, of two kinds:
       - state protected by the locks above: links, grant, allocation;
       - head-serialized state, re-read fresh: the invocation's `reconciliation_required` Failures (`Failure :open`/`:resolve` append under the head: `lib/sdr_agent/operations/failure.ex:110-149`; `lib/sdr_agent/audit/kernel.ex:299-309`), and the lead, account, contact and seed event. Every writer of those also appends under the head.
     - There is no row lock and no filesystem or store I/O.
     - `ReleaseDecision` re-validates E1-E6 against the same bindings and instant. It is authoritative.
   - **Recheck failure.** If an under-head recheck fails, the transaction rolls back with nothing written. The gate then repeats `finalize/4` once with the exception disabled, which is the ordinary withheld path with its own cause locks. A refusal of that repeat falls to the existing one-shot Recovery (`result_gate.ex:185,196-208`).
   - **Recovery** never decides a demo exception (`lib/sdr_agent/agents/result_gate/recovery.ex:48-51`).

7. **Replay.** `ReleaseDecision`'s existing-row branch runs first (`release_decision.ex:120-123`).
   - **Existing demo-exception row.**
     - The request is an identical replay only when all of these hold: its disposition, reason, link, `evidence_sha256` (NULL) and `exception_policy_id` equal the row's; and the basis re-derived from the locked state, using the row's stored `decided_at`, has a digest equal to `exception_basis_sha256`.
     - An identical replay creates no row and no event. Before any output is returned, use authority is checked separately at the current instant (item 9).
     - Any difference in identity, evidence or basis raises `ReleaseConflict`. It is never treated as a fresh decision.
   - **Existing row of another disposition.** A demo exception against such a row (for example an earlier withheld) is a `ReleaseConflict`. An earlier withheld record never becomes an exception.
   - **No existing row.** The decision is made once, with the item 6 instant.

8. **The record and its closed basis.**
   - **Kept from the existing release.**
     - One row per invocation, under its unique index.
     - Append-only.
     - Composite FKs to the invocation and to this invocation's link.
     - The link's projection and method are copied onto the row.
   - **Added columns.**
     - `exception_policy_id`.
     - `exception_expires_at`: the effective end.
     - `exception_basis`: the closed map below.
     - `exception_basis_sha256`: the lowercase hex SHA256 of the map's `sdr-canonical-json/1` encoding.
   - **Pairing and CHECKs.** `:demo_exception` pairs only with reason `:v4_uncalibrated`. For a `demo_exception` row, every predicate below must evaluate to TRUE. SQL UNKNOWN counts as a violation: each predicate is written as `(…) IS TRUE` or `COALESCE(…, false)`, and every nullable column is tested with an explicit `IS NOT NULL` before it is compared. The database CHECKs require:
     - the pair;
     - a non-NULL link;
     - a non-NULL `projection_version` equal to the v4 id;
     - a non-NULL `method` equal to `propagated_id`;
     - NULL `evidence_sha256`;
     - all four exception columns non-NULL;
     - `decided_at < exception_expires_at`;
     - `jsonb_typeof(exception_basis) = 'object'` and `jsonb_typeof(exception_basis->'policy') = 'object'`;
     - `exception_basis->>'schema' = 'c2star-basis/1'`;
     - `exception_basis->'policy'->>'id' = exception_policy_id`.

     An empty object, a missing key, a JSON `null` or a scalar therefore rejects. Every other disposition has the four columns NULL. The existing `released`, `withheld` and `calibration` branches are already NULL-safe and are unchanged. Application code keeps the full closed-schema and size validation. This is not a general database JSON-schema system.
   - **Basis schema `c2star-basis/1`.** Every listed object and key is required. No other key may appear, and no value may be NULL. The basis holds no content and no copy of a larger mutable evidence blob.

     | Object | Key | Type / allowed value |
     |---|---|---|
     | (top) | `schema` | the literal `"c2star-basis/1"` |
     | `policy` | `id` | the literal `"c2star-demo-v4/1"` |
     | | `entry_sha256` | hex-64; equals the compiled entry's digest at decision |
     | | `acceptance_ref` | string `^D-[0-9]{3,4}$`; equals the entry's `acceptance_ref` |
     | `environment` | `id` | the literal `"agentenv-1"` |
     | | `binding_sha256` | hex-64 of the environment binding (ADR-0004 amendment) |
     | | `tenant_id` | lowercase canonical UUID; equals the binding's tenant |
     | `funding` | `authorization_id` | a compiled authorization registry id; equals the entry's |
     | | `authorization_sha256` | hex-64 of that registry entry; equals the authorization binding's |
     | | `grant_id`, `allocation_id` | UUID; the invocation's charged grant and allocation |
     | `invocation` | `id`, `run_id`, `lead_id` | UUID |
     | | `usage_origin` | `"assignment"` |
     | | `purpose` | one of `"evidence_extraction"`, `"outreach_proposal"`, `"qualification"` |
     | `identity` | `provider` | `"claude_cli"` |
     | | `cli_version` | `"2.1.294"` |
     | | `profile_id` | `"claude_cli_opus"` |
     | | `model_id` | `"claude-opus-5-5"` |
     | | `prompt_builder` | `"prompt-builder/1"` |
     | | `ledger_generation` | integer `2` |
     | `evidence` | `link_id` | UUID; the primary link |
     | | `projection_version` | `"claude-message-json/4+prompt-builder/1"` |
     | | `method` | `"propagated_id"` |
     | | `response_layout` | `"reasoning_then_text"` |
     | | `response_thinking_count`, `response_redacted_thinking_count` | integers 0..4, total 1..4 |
     | | `reason_codes` | the basis copy of the link's code set, sorted bytewise: exactly `["method_not_enabled"]` or `["cli_injected_context","method_not_enabled"]` (the persisted link order is not copied) |
     | | `projected_request_sha256`, `observed_request_projection_sha256`, `projected_response_sha256`, `observed_response_projection_sha256` | hex-64; equal in pairs |
     | | `current_link_ids` | sorted, de-duplicated UUIDs, 1 to 64 of them; must include `link_id` |
     | `eligibility` | `v3_allowlisted` | literal `true` |
     | | `v4_allowlisted` | literal `false` |
     | `window` | `starts_at` | the effective start (item 2) |
     | | `effective_expires_at` | the effective end; equals `exception_expires_at` |
     | | `decided_at` | the item 6 instant; equals the record's `decided_at` |

     - **Formats.** UUIDs are lowercase canonical `8-4-4-4-12`. Hex-64 is `^[0-9a-f]{64}$`. Timestamps are UTC, rendered exactly as `YYYY-MM-DDTHH:MM:SS.ffffffZ` (six fraction digits).
     - **Size and validity.** The canonical encoding is at most 8192 bytes. An oversize or invalid basis is refused, never truncated or repaired. `starts_at ≤ decided_at < effective_expires_at`.

9. **Use authority and per-path outcomes.** A demo-exception output may be used only under use authority (item 2). The common invariant is that an output without it never escapes. Each path keeps its existing API shape:

   | Path | Without use authority (or an ineligible decision) | With use authority, or a new eligible decision |
   |---|---|---|
   | `ResultGate.gate/3` / `SDR.Model` (`lib/sdr_agent/sdr/model.ex:168-175`) | `{:withheld, release, run}` or `{:error, reason}`, as today | `{:released, release, output}`, with `release.disposition == :demo_exception` |
   | `ReleasedOutput.fetch/2`, `Agents.released_output/2` (`lib/sdr_agent/agents/released_output.ex:25-66`) | `{:error, :result_not_released}` | `{:ok, output}` |
   | Output field policy (`lib/sdr_agent/agents/model_invocation.ex:185-192`) | `%Ash.ForbiddenField{}` | readable only through the `ReleasedOutputRead` mark |
   | `DecisionRules` (`lib/sdr_agent/agents/changes/decision_rules.ex:113-129`) | `ResultNotReleased` changeset error | decision created |
   | `SDR.proposal/2` / `HandOffProposal` (`lib/sdr_agent/sdr.ex:239-290`; `lib/sdr_agent/sdr/actions/hand_off_proposal.ex:151-152`) | `{:error, :result_not_released}`; no draft | proposal returned; draft proposed |
   | `AssessmentRules` (`lib/sdr_agent/outreach/changes/assessment_rules.ex:45-56`) | `ResultNotReleased` error. Its purpose is never eligible, so this path never holds an exception. | n/a |
   | `ResultGate.unreleased?/1`, `unreleased_invocations/1` (`result_gate.ex:218-244`) | `true`; the invocation is included in `{:ok, [...]}` | `false`; excluded |
   | `ResultGate.Recovery.run/3` (`recovery.ex:118-166`) | **Running run:** stopped `witness_unreconciled` on a deduplicated warning cause (message "demo exception not in use") opened under the head, as the existing selection does (`recovery.ex:44-46`); returns `{:withheld, release, run}`, with `release` as stored. **Terminal run:** `{:withheld, release, run}`. Never a new row. | `{:released, release, output}` (the `:not_gated` rollback at `recovery.ex:166` gains this clause) |
   | `StaleRunSweeper`, `Witness.ScanWorker` (`lib/sdr_agent/sdr/stale_run_sweeper.ex:512-522`; `lib/sdr_agent/agents/witness/scan_worker.ex:105-109`) | unchanged: any release counts as decided | unchanged |
   | Draft edit, approval, Home command, send gate | item 10 | item 10 |
   | `DeliveryReceipt :record` for a NEW `captured` receipt (`lib/sdr_agent/outreach/delivery_receipt.ex:77-104`; reached through `Outreach.record_receipt/2`, `lib/sdr_agent/outreach.ex:162-170`) | item 10: the insert rolls back; `CaptureAdapter.deliver/3` returns `{:error, {:permanent, :demo_exception_not_in_use}}` | the receipt is recorded as today |
   | `DeliveryReceipt :record` replay of an existing receipt; `CaptureAdapter.lookup/2`; delivery reconciliation | unchanged: the stored receipt is returned or reported (history is never denied) | unchanged |

   No new detail, retry or replay route reads raw output. A retry stays an explicit, budget-counted operator action with its own decision.

10. **Drafts, approvals and capture.**
    - **When a revision is exception-derived.** Follow its ancestry: the revision itself, then every revision reachable through `parent_revision_id` and `ai_baseline_revision_id` (`lib/sdr_agent/outreach/changes/new_revision.ex:69-75`; `lib/sdr_agent/outreach/draft_revision.ex:6-18`). If any agent revision in it has a `model_invocation_id` whose release is `:demo_exception`, the revision is exception-derived. A human edit never removes it.
    - **The check.** The same use-authority check (item 2) runs:
      - at `Draft :edit`, on the parent revision;
      - at `Approval :approve`, on the exact revision being approved (`lib/sdr_agent/outreach.ex:104-117`);
      - in the delivery send gate, as an early refusal (`lib/sdr_agent/outreach/delivery.ex:9-23,82-123`);
      - in the transaction that creates the NEW `captured` DeliveryReceipt. This is the authoritative capture-time check.
    - **Why capture needs its own check.** The send gate commits its claim before the adapter runs, and the adapter is handed the message outside that transaction (`delivery.ex:74-75,301-305`). `CaptureAdapter` then records the `captured` receipt in its own transaction (`lib/sdr_agent/outreach/delivery/capture_adapter.ex:27-34,62-73`). Expiry, revocation or a mismatch can land between those two transactions.
    - **The capture-time check itself.**
      - It lives in the `DeliveryReceipt :record` action, so every caller of `record_receipt/2` is subject to it, including any direct one.
      - It applies only when a NEW `captured` row is inserted for an operation whose approved revision (`draft_revision_id`) is exception-derived.
      - **Callback order.** The check is an `after_action` callback, appended (not prepended) by a change listed after `AppendEvent`.
        - `AppendEvent` appends its event inside its own `after_action` callback (`lib/sdr_agent/audit/changes/append_event.ex:66-77`), not in `change/3`.
        - Ash 3.37.2 appends default callbacks in order and runs them in list order (`deps/ash/lib/ash/changeset/changeset.ex:5380-5410,7578-7592`, installed under `.devenv/state/deps/`).
        - So the check runs after the event append, with the chain head held.
      - **What it reads.** It re-reads the authority facts there as plain reads, with no new lock and no file I/O. It uses the active operation snapshot: inherited from `Delivery.attempt/2` through `CaptureAdapter.deliver/3`, or owned by a direct top-level `record_receipt/2` call (item 2).
      - **Replays.** A replayed existing row is marked `sdr_replayed` by `MarkExisting`'s earlier callback (`lib/sdr_agent/research/changes/mark_existing.ex:7-8,13-19`). `AppendEvent` and this check both honour that mark. The replay skips the check and is returned unchanged.
      - A refusal rolls the insert and its event back, so no receipt is ever recorded for it. The adapter maps the refusal to `{:error, {:permanent, :demo_exception_not_in_use}}`. Delivery then takes its existing permanent-failure path (`delivery.ex:339-352`): `failed_permanent`, the `delivery_failed` Failure, and the draft marked failed. No `accepted` receipt and no acceptance are fabricated.
      - An already captured message stays captured. Its later `accepted` receipt, `lookup/2` and reconciliation are unchanged.
    - **How the other checks are evaluated.** Each consuming action plain-reads the authority facts before its verdict. It reads them again after its first chain-head append in the same transaction: grant revocation, link and Failure writers all append under that head. Any difference rolls the action back with no effect, and a retry then sees the new state. No row lock is added to the Outreach lock order.
    - **Refusals.**
      - Edit and approve are refused with a typed `DemoExceptionNotInUse` error.
      - Home commands map that error to `blocked(:demo_exception_not_in_use)`, alongside the existing blocked outcomes (`lib/sdr_agent/outreach/inbox_commands.ex:212-218`).
      - The send gate returns `refuse`, reason `demo_exception_not_in_use`, with the existing refuse effects (`delivery.ex:16-17`).
      - An approval granted before expiry, or a quiet-hours deferral whose not-before is at or after expiry, is refused at the send gate. Authority that ends after the gate's claim is caught at the receipt insert. Either way, no NEW `captured` receipt is recorded without use authority.
    - **Always allowed.** Reject and revoke stay allowed. Reading drafts, revisions, citations and their labelled history is not a use of model output and stays available, including for the owner's final inspection after expiry.

11. **Expiry.**
    - **When the enforced policy applies again.** It applies with no further action at `effective_expires_at`, at the policy expiry, when the selector is off, when the entry is removed or changed, or when the grant is revoked.
    - **History.** Historical rows are never deleted or relabelled.
    - **No extension.** There is no automatic extension, including if T7 is late. A later exception (for example, for the conference) needs its own entry, window and accepted amendment.

12. **No reconciled fabrication, and no rewritten history.**
    - The link stays `inferred`/`method_not_enabled`.
    - The invocation's witness answer stays `inferred` (`witness.ex:1058-1074`).
    - No link status, release reason, event type, export, UI string or status for this record says "reconciled" or "verified research".
    - Later reconciliation, such as after T7's enablement, may append link successors. It never rewrites this record, and it never retroactively releases an earlier withheld invocation.
    - No tuple is promoted.

13. **Audit and UI.**
    - The decision appends `model.result.demo_exception`. Its arguments are the policy id, the basis digest and the fixed label, with no content.
    - Run detail, draft review and draft detail, any rendered Home row, and exports show exactly `"demo exception - v4 not independently calibrated"` for the record and for every exception-derived draft.
    - Reconciled releases keep their presentation.

14. **Grants nothing else.** This exception grants no calls, spend, delivery, data access or allowlist entry. Caps, grant accounting, the synthetic guard, authorization, deterministic claim and citation checks, exact approval binding, suppression checks and capture-only delivery all stay.

15. **Unchanged.**
    - Admission before spend, and the compiled `:enforced` gate.
    - The reconciled-only `:released` path and its read contract, including "a link superseded later leaves the release as the historical decision" (`model_result_release.ex:45-46`).
    - The withheld reasons.
    - Terminal invocation immutability (ADR-0009).
    - v4 lineage: a v4 observation never supersedes a mismatch (`witness.ex:865-869`).
    - Concurrency 1.
    - The empty test allowlist and the test-only overrides.
    - The calibration harness and G-R0.
    - The v4 proof and enablement path.

**Residual risks (stated, not solved).**

- The v4 grammar has hermetic tests only, not the independent captured proof the enforced policy requires. It may be wrong, or it may not fit the next response.
- A match shows that the stdin and the structured output are equal. It does not show that the research is factually correct, or that CLI-added context is benign.
- A call can still be withheld or fail. Accepting this guarantees no successful run.
- G-DEMO attempt 2's diagnostic does not show that the next call meets E1-E6.
- The launch margin is a scheduling guard, not a deadline proof.

**Consequences.**

- **Positive:** a positively matched v4 output can drive the Friday journey with a truthful label, a closed persisted basis and finite authority.
- **Negative:**
  - one disposition and four columns;
  - a use-authority check on every business read and draft action;
  - more verification of release, replay, consumers and expiry.
- **Neutral:** no new dependency, process or table.

**Cross-references.**

- **This ADR:**
  - R0 amendment item 3 (admission) and item 4. Its "Release" and "No bypass" bullets are extended only as stated here. "Release evidence", "The invocation itself is untouched" and "Later reconciliation" are unchanged.
  - The response-layout amendment, items 6-8.
  - The S12d rule that a new tuple needs a new proof.
- **ADR-0004:** the agent-environment amendment, including its funded scope (item 9a), its provisioning and spend-ready attestation (items 4 and 5), and its per-allocation windows (item 11).
- **ADR-0009:** append-only and terminal-immutable rows.
- **ADR-0014:** Amendment 3 (acceptance, D-222), and non-waivable constraints 1-7.

<!-- END ADR-0005 C2* DEMO-EXCEPTION AMENDMENT -->

<!-- BEGIN ADR-0005 C2* ADDENDUM 1: text as reviewed by Codex (9f90b710) -->

#### C2* demo-exception amendment, addendum 1 (2026-10-27, PROPOSED): two more operation-snapshot entry points

**Status: PROPOSED.** To be accepted, it follows ADR-0014 Amendment 3 (D-222):
- Codex gives an independent exact-text PASS.
- A decision row then records "owner acceptance delegated by D-219".

It changes nothing else in the C2* amendment, and it grants no call, spend, release or use.

**Context.**
- **What item 2 does.** It applies the owner-or-inherit rule at the entry points it names. A consumer
  with no active snapshot can establish no use authority, whether or not a transaction is open.
- **What item 9 promises.** For `ResultGate.unreleased?/1` and `unreleased_invocations/1`, `false`, with
  the invocation excluded, under use authority.
- **Two callers reach that check with no owner:**
  - the assignment worker's terminal step (`AgentWorker.finish/4`, which asks `unreleased?/1` inside its
    `Audit.transaction`);
  - the stale-run sweeper's per-run recovery (`StaleRunSweeper` `recover/3`, which asks
    `unreleased_invocations/1` in its unlocked prefilter and again under its locks).

  Both run after every action's snapshot has been invalidated.
- **The effect without owners.** A demo-exception run with use authority is never succeeded by its
  worker. The sweeper's Recovery then honours the release (`{:released, …}`), which its caller treats as
  "not running", on every pass.

**Decision.**

1. **Two more entry points.** Item 2's entry-point list gains:
   - `AgentWorker.finish/4`, as one operation enclosing its terminal transaction;
   - each per-run call of `StaleRunSweeper` `recover/3`, as one operation enclosing its prefilter, its
     locked re-check and any Recovery it runs.

   Each applies the owner-or-inherit rule exactly as item 2 states it. It observes before its first
   transaction, inherits if a snapshot is already active, and is invalidated only by its own completion
   or raise.
2. **Enclosing wrappers.** An entry point may be applied at a function that immediately encloses a named
   entry, with the same owner-or-inherit effect. The cases are:
   - `SDR.Action.execute/3`, which encloses every action's `perform/2`;
   - `Outreach.InboxCommands.execute/2`, behind `Outreach.inbox_command/2`.

   A directly called `perform/2` remains its own entry point. Enclosing only widens the owning operation,
   and so its sampling age (item 2, "Sampling boundary").
3. **Sampling.**
   - The worker's snapshot is sampled after the run's actions end and before its terminal transaction.
   - The sweeper's is sampled per run, before its prefilter.
   - Database-serialized facts are still re-read under the locks, as item 2 states.
4. **Unchanged.**
   - Item 9's outcomes.
   - The sweeper's terminal-run path, where any release counts as decided.
   - `ReplyWorker`, whose reply runs hold no demo-exception release.
   - Every other entry point and every other item.

**Consequences.**
- **Positive.** An exception run with use authority can terminate normally. A run without use authority
  stays as item 9 states.
- **Negative.** Two more owner boundaries: one additional snapshot observation per finished
  assignment run and one per recovered run, each reading the three files once when it owns rather
  than inherits.

<!-- END ADR-0005 C2* ADDENDUM 1 -->

<!-- BEGIN ADR-0005 C2* ADDENDUM 2: text as reviewed by Codex (c151946f) -->

#### C2* demo-exception amendment, addendum 2 (2026-10-27, PROPOSED): one validated rule for exception-derived drafts, covering their origin run and cited claims

**Status: PROPOSED.** To be accepted, it follows ADR-0014 Amendment 3 (D-222):

- Codex gives an independent exact-text and entity/action PASS.
- A decision row then records "owner acceptance delegated by D-219".

It only narrows use and adds labels. It grants no call, spend, release, use or eligibility.

**Context.**

- Item 10 derives the exception fact only from agent revisions' own `model_invocation_id`, which is the call that proposed the text.
- A draft also depends on its origin run's earlier outputs: the evidence it cites and the qualification that enrolled its lead.
- A draft may cite any accepted claim of its lead, and each claim names the invocation that extracted it.
- So a draft whose proposal call was reconciled, but whose cited evidence is exception-derived, would be neither checked nor labelled.

**Decision.**

1. **Lineage.** The lineage of a revision R is R plus every revision reachable from R through `parent_revision_id` and `ai_baseline_revision_id`. It is valid only if every member satisfies all of these:
   - it is in R's tenant and R's draft;
   - a parent's revision number is exactly one lower than its child's;
   - a baseline is an agent revision with a lower number than the revision that names it;
   - a member has no parent exactly when it is number 1;
   - an agent member names its run, its Decision and its model invocation, and that invocation exists in the tenant and belongs to that run.

   Any other lineage is malformed.
2. **Covered releases.** R's covered releases are the `:demo_exception` releases, in R's tenant, of these model invocations, and of no others:
   - **(a) Origin run.** For each agent member A: every invocation whose `agent_run_id` is A's `agent_run_id` and whose `sequence_in_run` is at most that of A's own invocation. A's own invocation is one of them.
   - **(b) Cited claims.** For each lineage member and each of its citations: the invocation that the cited EvidenceClaim names in `model_invocation_id`, when it names one. Every such named invocation is read by its id, whatever its release, and must exist in R's tenant. Only then is its release, if it has one, classified.

   No other run of the lead, and no lead-wide or tenant-wide set, is consulted. A withheld, calibration or released release, or the absence of a release, is not covered and grants nothing.
3. **Exception-derived.** R is exception-derived exactly when it has at least one covered release. This replaces the first bullet of item 10, "When a revision is exception-derived". A human edit never removes the fact: a human revision's lineage contains its predecessors, and its carried citations come from its parent.
4. **Use authority.** Wherever item 10 requires use authority for an exception-derived revision, it requires use authority (item 2) for every covered release, without duplicates and never just one of them.
   - The read before the verdict evaluates all of them at one instant.
   - The read after the first chain-head append evaluates all of them again, at a fresh instant, and freshly re-reads the grant, link and Failure facts.
5. **One rule everywhere.** The same rule decides:
   - item 10's four checks;
   - Home visibility of the record and the label on every rendered draft surface (item 13);
   - the label on a new `outreach.draft.proposed` event (addendum 3), and so the label in draft-scoped exports.
6. **Unavailable or malformed facts are errors.** These cases are an error, never "not exception-derived": a lineage member, an agent member's invocation, a cited claim, or an invocation a claim names is not found in R's tenant or cannot be read; a release read fails; or the lineage is malformed.
   - Edit and approve are refused with a typed `DraftLineageUnavailable` error.
   - The send gate rolls back with no effect.
   - The capture-time check refuses the insert, and the adapter maps the refusal to `{:error, {:permanent, :lineage_unavailable}}`.
   - A label surface is withheld, never shown unlabelled.

   An invocation that was read and has no release, or has a released, withheld or calibration release, is a fact (that invocation is not covered), not an error.
7. **Bounded reads.** Collecting these facts takes at most six read statements for any batch of revisions, and at most five for a prospective proposal (addendum 3), whatever the number of revisions, drafts, citations or invocations.
   - Each statement reads one resource, selects only the metadata it needs and loads no relationship.
   - It takes no row lock and does no file I/O.
   - The bound covers fact collection only. Each use-authority evaluation (item 2) adds its own plain reads for every covered release, at each read of decision 4.
8. **Unchanged.**
   - Item 10's check sites, callback order, replay handling, refusals and always-allowed reads.
   - Items 1-9, including eligibility.
   - Every reconciled record's presentation.

**Entity delta (narrowing; no schema change).**

| Entity | Change |
|---|---|
| DraftRevision | The derived "exception-derived" fact is defined by decisions 1-3, with lineage validation. Nothing is persisted. |
| RevisionCitation, EvidenceClaim | Read-only inputs: citation claim ids, and the claim's `model_invocation_id`. |
| ModelInvocation, ModelResultRelease | Read-only metadata. From the invocation: id, tenant, run id, `sequence_in_run`, status, validation status, generation, provider and purpose. From the release: its disposition and the exception columns that item 2's use authority reads. No output field is read. |
| Draft `:edit`, Approval `:approve`, the send gate, DeliveryReceipt `:record` (NEW `captured`) | Use authority for every covered release. A typed `DraftLineageUnavailable` or rollback on unavailable or malformed facts. |
| Home projection and console draft surfaces | Label and visibility by the same rule. Withheld on error. |

**Consequences.**

- **Positive.** A reconciled proposal cannot launder exception-derived evidence into an ordinary, unlabelled draft.
- **Negative.**
  - A few more plain reads per draft action and per labelled page.
  - A corrupted lineage now refuses an action, or withholds a page, instead of passing.

<!-- END ADR-0005 C2* ADDENDUM 2 -->

<!-- BEGIN ADR-0005 C2* ADDENDUM 3: text as reviewed by Codex (c151946f; one-line correction applied) -->

#### C2* demo-exception amendment, addendum 3 (2026-10-27, PROPOSED): the new proposed-draft event carries the server-derived label

**Status: PROPOSED.** To be accepted, it follows ADR-0014 Amendment 3 (D-222):

- Codex gives an independent exact-text and entity/action PASS.
- A decision row then records "owner acceptance delegated by D-219".

It grants nothing and rewrites nothing.

**Context.**

- Item 13 requires exports to show the label for every exception-derived draft.
- A draft-scoped export contains only events whose subject is that draft. The release's `model.result.demo_exception` event has another subject.
- A draft can be proposed directly, through the public `Outreach.propose_draft/2`, and not only after the flow has decided every earlier call. An earlier call with no release yet could later receive a demo-exception release, after an ordinary proposed event was written.

**Decision.**

1. **The argument.** A NEW `Draft :propose` whose prospective agent revision 1 is exception-derived appends `outreach.draft.proposed` with one more payload argument, `release_label`, whose value is exactly `"demo exception - v4 not independently calibrated"`.
   - Exception-derived is decided by addendum 2's rule, over the action's own inputs: the origin run (`origin_agent_run_id`), the `draft_proposal` Decision's invocation, and the citations' claims.
   - Every other proposal appends the event exactly as today; its `arguments` stays `{}`.
2. **Server-derived only.** The value is computed in the action. A caller that supplies `release_label` is refused, and nothing is written.
3. **History.** Events already appended are never rewritten, re-encoded or relabelled. Later edits do not re-emit the label. After a proposal passes decision 6, its draft's covered releases (addendum 2) can never change:
   - later revisions are human edits, whose citations come from their parents;
   - no invocation of the origin run with an equal or lower `sequence_in_run` can be added;
   - a relevant invocation's existing release cannot change; if no release exists, its resolved status proves that it can never receive a demo-exception release.

   So the label, or its absence, is a permanent fact for every revision of the draft.
4. **The propose boundary.** `Outreach.propose_draft/2` is a public AGT domain API, so this applies to every caller, not only to `HandOffProposal`.
   - `:propose` reads no model output. Its subject, body and citations are inputs. Its Decision, invocation and run provenance are recorded and validated as today.
   - It adds no use-authority check; item 10 is unchanged in that respect.
   - Decision 6's closure applies to every caller. The normal hand-off always meets it, because the flow proposes only after every earlier gated call of the run has been decided.
   - A draft proposed when use authority is absent is exception-derived and labelled. It can be read and rejected, but every edit, approval, send and NEW capture still requires use authority for every covered release (item 10, addendum 2).
5. **Exports.** A draft-scoped export therefore contains the label in that draft's proposed event. A run-scoped export contains both that event and the release's own event.
6. **Closure at proposal.** Before the event is appended, every relevant invocation must be resolved. The relevant invocations are addendum 2's origin-run and cited invocations, for the prospective revision 1. An invocation is resolved when any of these holds:
   - it has a release, of any disposition;
   - it is not a generation-2 `claude_cli` invocation;
   - its purpose is outside item 1's purposes;
   - it is terminal and can never be eligible: `failed`, `unknown`, or `completed` without a valid output.

   Otherwise the proposal is refused with a typed `DraftLineageUnavailable` error (`unresolved`), and nothing is written.

   This is a lineage condition only. It reads no output, and checks no selector, snapshot, grant, link, Failure or clock. It is not a use-authority check.

**Entity delta.**

| Entity | Change |
|---|---|
| AuditEvent `outreach.draft.proposed` | Payload `arguments` gains `release_label` (fixed string), only on new events of exception-derived proposals. The event type, category, links and subject are unchanged. No column changes. |
| Draft `:propose` | A server-set argument. A caller-supplied value is refused. A proposal with an unresolved relevant invocation is refused (decision 6). No new authority check. Provenance is unchanged. |

**Consequences.**

- **Positive.** Every export of an exception-derived draft is labelled, without rewriting history.
- **Negative.**
  - One more payload key on such events. Verifiers and exports read it as an ordinary argument.
  - A direct proposal whose relevant call is still undecided is refused until that call is decided.

<!-- END ADR-0005 C2* ADDENDUM 3 -->

<!-- BEGIN ADR-0005 C2* ADDENDUM 4: text as reviewed by Codex (5685d6f0) -->

#### C2* demo-exception amendment, addendum 4 (2026-10-27, PROPOSED): a send-gate refusal records its true reason on the approval

**Status: PROPOSED.** To be accepted, it follows ADR-0014 Amendment 3 (D-222):

- Codex gives an independent exact-text and entity/action PASS.
- A decision row then records "owner acceptance delegated by D-219".

It grants nothing.

**Context.**

- Item 10's send-gate refusal uses "the existing refuse effects", which invalidate a granted approval.
- The existing mapping gives an unlisted refusal reason the approval reason `campaign_closed`, which would be false for an active campaign.

**Decision.**

1. **One more reason.** Approval `invalidated_reason` (an existing attribute, written only by the existing `:invalidate` action) gains `demo_exception_not_in_use`.
2. **The mapping.** A send-gate refusal with reason `demo_exception_not_in_use` invalidates a granted approval with exactly that reason. It never uses the `campaign_closed` default.
   - The same reason is recorded in the delivery's `last_error`, in the draft's `status_reason` ("delivery refused: demo_exception_not_in_use") and in the `send_gate` Decision's outcome detail.
   - The refusal is evaluated after every existing send-gate refusal, and before timing, claim or capture.
3. **Unchanged.**
   - Every other reason mapping, including the existing defaults.
   - The approval lifecycle, its terminal-immutability trigger and its binding columns.
   - Every existing row and event.
4. **Persistence.** There is no new column, value-list CHECK or index. The column's only reason-related constraint ties the `invalidated` status to a non-null reason. Any generated snapshot or migration delta is determined by `mix ash.codegen --check` at the gate, not assumed.

**Entity delta.**

| Entity | Change |
|---|---|
| Approval | `invalidated_reason` value set gains `demo_exception_not_in_use`. The `:invalidate` transition is unchanged. |
| DeliveryOperation, Draft, the `send_gate` Decision | Carry the same reason string as today's refusals do. No schema change. |

**Consequences.**

- **Positive.** Approval, delivery, draft and Decision agree on why the send was refused.
- **Negative.** One more value for readers of `invalidated_reason`.

<!-- END ADR-0005 C2* ADDENDUM 4 -->

<!-- BEGIN ADR-0005 C2* ADDENDUM 5: text as reviewed by Codex (m_codex_d240_r8_review_1793158304526) -->

#### C2* demo-exception amendment, addendum 5 (2026-10-28, PROPOSED): the policy expiry and the environment end move to 2026-11-07T07:00:00Z

**Status: PROPOSED.** The owner decided this change (D-240). To be accepted, this exact text needs Codex's independent PASS and a decision row that cites D-240, the commit, this file's SHA256 and the hash of the bytes between these markers.

**The owner's decision.** D-240 (2026-10-28). The owner answered "yes to both" (chat, received 2026-10-28T02:38:32Z) to Claude's pick "extend all four through 2026-11-07 07:00 UTC". This is the explicit owner decision that ADR-0014 Amendment 3 requires for an extension.

**The change.** Two instants in the C2* amendment are read as `2026-11-07T07:00:00.000000Z` (exclusive):

- item 1's `expires_at` of `c2star-demo-v4/1`, `2026-11-01T06:00:00.000000Z` (exclusive);
- item 2's environment-end operand of `effective_expires_at`, 2026-11-01T06:00:00Z (ADR-0004's agent-environment end, moved by its own D-240 addendum).

The new end is epoch 1794034800: Saturday 2026-11-07 00:00 MST, the end of Friday Nov 6 in America/Denver. The old end was epoch 1793512800. The difference is 522000 s, six days plus one hour across the end of daylight saving time.

**Only the end changes.**

- The policy id stays `c2star-demo-v4/1`. `starts_at` stays `2026-10-27T06:00:00.000000Z` (inclusive).
- Every other item 1 field is unchanged: the environment, the identity, the projection version and method, the usage origins and purposes, the lead ids, the authorization id, the label and the acceptance reference.
- `effective_expires_at` is still the earliest of the policy expiry, the environment end, the authorization expiry, the grant's `expires_at` and the allocation's `available_until`. A shorter authorization, grant or allocation window still wins.
- The admission guard is unchanged: `effective_starts_at ≤ now < effective_expires_at − (T + ResultGate.wait_ms() + 60 000 ms)`, now computed over the later minimum end. There is still no launch at equality.
- D-240 grants no calls, spend, scope or authority, resets no grant cap or consumption, and resurrects no withheld output or capture.

**Records keep their values, and the digest check stays.**

- The entry's canonical encoding includes `expires_at`, so the new entry has a new `entry_sha256`.
- Existing demo-exception releases keep their recorded `exception_expires_at`, `exception_basis` and `exception_basis_sha256`. Their events and record hashes are unchanged, and historical replay and audit verification still use the recorded basis.
- Current use authority still compares today's `entry_sha256` with the recorded basis. So once the new entry ships, a release decided under the old entry is refused current use (`:entry_changed`), even before its recorded expiry. That is the accepted fail-closed behaviour. This addendum does not renew old output; continuity for older live releases would need its own decision.

**Code bindings take effect only when they land.** `SdrAgent.Agents.DemoException` (`@entry.expires_at`, `@environment_end` and their docs) changes only through its own reviewed edit with boundary tests, carried to the final combined head. Until then the compiled entry still ends at 2026-11-01T06:00:00Z, and that earlier instant governs.

**The text above is unchanged.** The C2* amendment and addenda 1 to 4 keep their reviewed bytes and accepted hashes (D-223, D-227, D-228, D-230). This addendum supersedes only the two instants named here.

<!-- END ADR-0005 C2* ADDENDUM 5 -->

<!-- BEGIN ADR-0005 D-237 PROTOTYPE AMENDMENT: text as reviewed by Codex (m_codex_d237_r6_verdicts_1793163169000) -->

#### D-237 local prototype amendment (2026-10-28, PROPOSED): one real, labelled journey in a separate local prototype database, operated by agents

**Status: PROPOSED.** This amendment has not been accepted or implemented.

- **Acceptance (D-242, prospective and conditional).** The owner accepted in advance the exact bytes that Codex's FINAL independent exact-text PASS covers.
  - At that PASS, the decision record names the commit, this file's SHA256, these between-marker bytes' SHA256 (including the BEGIN line's newline), the review correlation and D-242.
  - It does not claim the owner read these bytes.
  - A PASS on a slice, on code, on an entity table, or on a changed text accepts nothing.
- **Build preapproval (D-241).** It begins only after Codex and Claude independently agree on this text, its entity and action model, and the implementation plan.
- **Activation is separate.** Activation and real-call readiness are separate from acceptance and from build preapproval. They need the conditions of item 9.
- **No authority by acceptance.** Acceptance grants no call, grant or deployment by itself. It also does not accept the separately hashed log residual clause (item 7), and it does not answer the pending agent-session question (item 7).

**Why.**

- **The owner's direction (D-237).** "no, a real AI model is not a paid API integration. we can keep using my subscription locally." (2026-10-28T02:08:44Z). Then: "i'm inclined to let unverified real output through just to demonstrate that the product works, and then to instrument everything around it for verification and evaluation after the fact. the most important thing we can do right now is to show a working prototype that does everything we need from a product standpoint. then once we have all of the features working, we can instrument verifications, tests, evals, etc etc etc" (02:14:53Z).
- **Funding (D-238, D-239).**
  - 60 attempts in total, shared across every real-call route, with no refund or reset.
  - Usable from 2026-10-28T02:38:32Z until 2026-11-07T07:00:00Z exclusive.
- **Operation (D-243).** "i want you and codex to do this. you can run this from the backend. you don't need me. you have my permission to do this."
- **Seed (D-244).** "i want you and codex to seed this with sensible defaults. you can use gtm as a company (see ~/src/gtm or gtmscape.com) and come up with whatever company profile and writing guide make sense."
- **Real prospects (D-245).**
  - "no, i want you and codex to find some real businesses and contacts based on whatever makes sense for the company profile and writing guide above."
  - "ack", to "Emailing real people stays off".
- **What stands in the way today** (source at main `6779216`):
  - **Release.** Only a `reconciled` result is released (R0 amendment item 4; `lib/sdr_agent/agents/model_result_release.ex:64-72,110-131`; `lib/sdr_agent/agents/changes/release_decision.ex:286-310`).
  - **Admission.** It requires a trusted witness store and a promoted tuple, at reservation and at launch (`lib/sdr_agent/agents/admission/gate.ex:128-171,239`).
  - **Business reads.** They require `:released` (`lib/sdr_agent/agents/released_output.ex:66-74`; `lib/sdr_agent/agents/model_invocation.ex:185-192`).
  - **Synthetic names.** Every account domain, contact email, sender address and research source must be under a reserved name (ADR-0009 item 9; `lib/sdr_agent/sales/validations/reserved.ex`).
  - **Human operators only.** Every operator is a human `User` (ADR-0009 item 8).

**Decision.**

1. **Scope and assurance.**
   - **The permission.** In one separate local prototype database only, schema-valid ClaudeCLI output may drive research, qualification, evidence, a draft, a delegated approval and capture, without v4 witness matching or tuple calibration. The research uses an agent-curated dossier of real businesses and their public business contacts.
   - **The assurance.** All output is **UNVERIFIED (PROTOTYPE)**. Permission to use it makes no claim that a record equals an externally observed exchange, or that it is true.
   - **Witness.** The app's witness store is explicitly absent.
   - **Delivery.** Delivery stays captured only. Nothing is sent to anyone.
   - **Hosted.** The hosted copy stays Fake-only and synthetic (ADR-0001 Amendment 1).
   - **Login.** The subscription login stays on the owner's machine and is never read.
   - **One closed policy entry, `d237-prototype/1`.** It is reviewed code with these fields and no others:
     - `database: "sdr_agent_prototype"`;
     - `dataset_class: :real_prototype`;
     - `identity`: `provider: :claude_cli`, `ledger_generation: 2`, `profile_ids: [:claude_cli_opus]`;
     - `usage_origins: [:assignment]`;
     - `purposes: [:qualification, :evidence_extraction, :outreach_proposal]`;
     - `witness_mode: :absent`;
     - `funding_id: "d237-funding/1"` (item 4);
     - `max_contacts: 3` (item 7);
     - `label: "UNVERIFIED (PROTOTYPE)"`;
     - `acceptance_ref`: the decision row that records the acceptance;
     - `text_sha256`: the SHA256 of these bytes.

     `entry_sha256` is its `sdr-canonical-json/1` SHA256. There is no wildcard and no runtime-supplied field.

2. **Structural isolation.**
   - **Development build only.**
     - The prototype authority module is compiled only under a flag that only `config/dev.exs` and `config/test.exs` set.
     - The production build contains no such module and no reference to one; it holds refusal stubs only.
     - Tests are hermetic and make no real call.
   - **Its own PostgreSQL 18 cluster.** The prototype database lives in an agent-owned scratch cluster.
     - **What is pinned:**
       - the executable (the devenv PostgreSQL 18 store path, recorded at init);
       - the data directory and an ownership marker that records the cluster's `system_identifier`;
       - the log directory;
       - the socket directory `/private/tmp/d237-pg`;
       - the port number 5541, which names the socket only.
     - **Connections.** No TCP listener (`listen_addresses = ''`). One Unix socket in that private directory.
     - **Logging** is set before the first start (item 7).
     - **Untouched:** the owner's clusters, databases (`sdr_agent_dev`, `sdr_agent_calibration`), roles and services.
     - **Owned and identified, fail-closed:**
       - **Init** refuses an existing data path or an existing ownership marker, and never overwrites a marker.
       - **One identity proof before start, status and stop.** It holds only when all of these match:
         - the marker;
         - the real, owned, mode-0700 data directory;
         - the pinned executable;
         - the marker's `system_identifier` equals `pg_controldata`'s;
         - a real, owned, mode-0700 socket directory, by `lstat`.
       - **Running clusters.** For a running cluster, the connected `system_identifier` and data directory must also equal the marker's. Only then may `pg_ctl` stop it. A missing, mismatched or unresponsive identity refuses and reports.
       - **Preparing the socket directory.** Init alone creates the socket directory, if it is absent, or verifies it, before init completes. Either way the exact socket pair (socket and lock file) must be absent. Start, status and stop never create a directory.
       - **First start.** Before the first start, the exact socket pair must still be absent. A residual pair is refused, never removed or adopted.
       - **A TCP listener on 5541** refuses.
       - **Never:** process-command-line or environment inspection, inference from process ids, signals to a foreign process, or deletion.
     - **A project fact.** The service is recorded in project-owned configuration, in the cluster script's constants, and in a prototype-runtime document. The document states that 5520 is the ordinary development service and 5541 only the isolated prototype socket endpoint. `.workflow/project-facts.md` and its receipt stay untouched; any future edit to that receipt-pinned unit uses its reviewed revision process.
   - **The binding.** `PrototypeDatabaseBinding` is a create-only singleton row in that database.
     - **What it records:** its id; an instance UUID; the tenant; the operator anchor user and at most one auditor user, each in the binding's tenant (database-enforced); the dataset class `real_prototype`; the policy id and `entry_sha256`; the funding id; the witness mode `absent`; the database name and oid; the cluster's `system_identifier`.
     - **Fixed.** Its fixed values are checked by the database.
     - **Immutable.** A trigger rejects update, delete and truncate. Foreign keys are `RESTRICT`.
   - **Setup, once, into a fresh database.**
     - **What it starts.** Only the configuration and the Repo. It never starts the application tree, the job system, the model provider, the live-event relay or the endpoint, and it refuses if any of them is running.
     - **Its order:**
       1. A preflight with no database write: the exact Repo target, the cluster identity, and the seed files parsed and validated. Before the target database exists, the identity read uses the owned cluster's own maintenance database. That is an identity read only, never a data read and never an owner service.
       2. A database that did not exist before, created before the Repo starts. Then the existing migrations, then this amendment's migrations, in one fixed order.
          - **The one recovery path** is a bounded resume, used after a step-4 rollback. It applies only to the exact owned cluster and database, holding exactly the pinned migration set and no tenant, user, binding, delegation, chain-head or business row.
          - Anything else refuses. Setup never drops, recreates or adopts a database.
       3. A refusal unless the database holds no tenant, user or business row.
       4. **One transaction**, by setup-only actions that no operator or user can call: the tenant, the operator anchor, the optional auditor, the binding and the setup session's delegation. Any error rolls all of it back.
       5. The boot check of the table below: the same check as a fresh serve boot, after step 4 commits. Bootstrap authority never bypasses it.
       6. The item-7 seed. A failed seed is retried only by the separate seed command, on its own checks.
     - **The auditor credential file** lies outside the transaction. It is created exclusively and never overwritten; a file left by a rolled-back attempt is reported as stale.
     - **Afterwards.** Provisioning (item 4) is a separate later step, and only a fresh boot runs the queues, the provider and the endpoint.
   - **Process kinds.**
     - **The serve process** runs the full application with the boot check as a child after the Repo and before the provider.
     - **Operator command processes** start the configuration and the Repo, then pass the boot check. Only commands that enqueue then start job insertion, with no queues, plugins or peer coordination, and with periodic staging disabled. Jobs never execute outside the serve process, and never inline. These processes start no provider, relay or endpoint.
     - **Any other start with the switch set** passes the same boot check or refuses.
   - **The switch.**
     - It is `SDR_PROTOTYPE` (the policy id) and `SDR_PROTOTYPE_INSTANCE` (the instance UUID).
     - It is read in `dev` only, and it selects the prototype cluster and database.
     - In `test` or `prod`, any value refuses boot.
     - Together with the agent-environment configuration or the C2* selector, it refuses boot.
   - **Boot.** The check runs after the Repo, and before the provider, the queues and the endpoint.

     | Switch | Binding | Witness store root | Result |
     |---|---|---|---|
     | off | absent | (ordinary rules) | ordinary runtime |
     | on | present and exact | unset | prototype runtime |
     | on | present and exact | set | refuse |
     | on | absent | any | refuse |
     | off | present | any | refuse |

     **Exact** means all of these hold:
     - the binding row exists exactly once (an unbound database refuses);
     - the instance and policy digest equal the switch and the compiled entry;
     - the live database name, oid and `system_identifier` equal the row's;
     - the suppression check is the Store implementation;
     - the users are exactly the operator anchor plus, if bound, the one auditor.

     The runtime is fixed for the VM's life. "Prototype runtime" below means the second row.
   - **Production.** The production build has no switch. It refuses to boot on a database that holds a binding row.
   - **Checked again.** The binding is re-read at reservation, at launch, at release and at each prototype business-use entry.
   - **No conversion.** No supported conversion, import or export path moves prototype rows into an ordinary database, or relabels them.

3. **The machine principal (D-243).**
   - **Representation.** The operator is a system actor of the new type `:prototype_operator`, never a human `User`.
     - **The delegation.** Each acting agent session is one create-only `PrototypeDelegation` row. It records the fixed reference `D-243`, the agent (`claude_code` or `codex_cli`) and a session correlation.
       - **How it is created.** Only by the operator commands' common session entry, and by setup for its own session.
       - **What the caller supplies.** Only the agent and the correlation. The binding, the tenant and the anchor come from the boot-verified binding, and the database refuses a delegation that names any other anchor.
       - **What the correlation is.** An audit label, not an authority.
     - **Resolution.** Every operator action resolves its actor from the delegation id against the live binding: the delegation exists, it is in the binding's tenant, it belongs to this binding, it names the binding's anchor, and the live database still equals the binding. A failure names its cause and refuses. An actor struct is never accepted as proof by itself.
     - **Audit identity.** Every event the operator causes records actor type `prototype_operator` and that delegation's id as the actor id. No event claims a human actor, human approval or the owner's product acceptance.
   - **The anchor.** Where an existing schema requires a user id, the value is one credential-less operator anchor user of role `:agent_operator`. That applies to an approval's approver and to a grant's creator and updater. It is a foreign-key value only.
     - **No credential.** The anchor has no password; the database requires that for this role, and only for it. Password sign-in, session-subject lookup and current-operator resolution all refuse it, so it never receives a session or token.
     - **Never an actor.** The anchor is never used as an actor.
     - **Immutable role.** No action changes a role to or from `:agent_operator`, and the role marks the user as a machine.
     - **Scoped approver attribution.** The change that records an approval's approver records the anchor only on the three approval actions (approve, reject, revoke), and only for a resolved operator. Everywhere else the operator stays unattributed, so the row's own constraints refuse it (for example, a manual suppression).
     - **No user administration in prototype runtime.** User creation, seeding, role, status and password changes are refused for every actor.
   - **Content access is scoped.** The operator stores its own inputs, and reads one captured message for review, only through two dedicated content actions.
     - **What bounds them:** each is limited to the exact digests that its domain function computed or re-read in the binding's tenant, and each records the access under the operator's own identity. Each also requires the operator's live resolution against the binding. A scope or an actor struct alone is never authority.
     - **What the operator never gets:** generic content storage or reading.
     - **Settings.** It writes settings only through the seed action, and never reads settings content.
   - **Allowed actions** (closed list), each in prototype runtime only:
     - run setup, whose setup-only actions create the tenant, the anchor, the auditor, the binding and the first delegation (item 2);
     - provision the one funded grant (item 4);
     - import the dossier;
     - seed the item-7 settings;
     - assign a lead;
     - read runs, drafts and receipts for review;
     - approve, reject or revoke a draft approval (item 8);
     - revoke the grant.

     Capture is performed by the existing delivery worker.
   - **Refused for the operator:**
     - user administration, beyond what setup creates;
     - any grant creation or change other than the one provisioning, and any allocation edit;
     - settings writes outside the seed;
     - run retry;
     - any change to the delivery path.
   - **What no one else gets.**
     - No human signs in as the owner, and no owner credential is read.
     - The real model gets no tools, no principal capability and no grant authority.
   - **The optional auditor.** One read-only owner auditor account may be bound.
     - **Its credential** is generated by setup into a private 0600 file. It is never printed or transmitted.
     - **What it may do.** It may read prototype views, as the existing auditor role does.
     - **What it may not do.** It cannot assign, fund, provision, approve, capture, administer or reset any principal.

4. **Funding and admission.** This reuses the contract of ADR-0004's agent-environment items 8, 9 and 9a, not their code.
   - **One compiled funding entry, `d237-funding/1`.**
     - `total_attempts: 50`. This is a **ceiling**, not a target. One canary, then up to two more contacts, needs far fewer.
     - `starts_at: 2026-10-28T02:38:32.000000Z`, `expires_at: 2026-11-07T07:00:00.000000Z`;
     - `profile_ids: [:claude_cli_opus]`;
     - `funded_scope: [{:assignment, [:qualification, :evidence_extraction, :outreach_proposal]}]`;
     - one allocation: key `:b1`, `applies_to: [:b1]`, profile `:claude_cli_opus`, 50 attempts;
     - decision references D-238, D-239 and D-243.
   - **The remaining-budget precondition (D-238's shared 60).** Provisioning first requires a private, counts-only remaining-budget worksheet. It covers the window since 2026-10-28T02:38:32Z, and every route sharing the 60:
     - this prototype;
     - each owner database (development and calibration);
     - hosted;
     - any other owner route;
     - all previous prototype bindings.

     **Its rules:**
     - **Unknown is not zero.** A missing route, or a route without a count, stops provisioning.
     - **Owner routes need the owner's word.** Agents cannot observe owner routes, so each needs an owner-shared aggregate or an owner attestation (for example, "unused"), consistent with the known receipts. An agent never reads an owner database for it.
     - **The ceiling must fit.** Provisioning proceeds only if 60 minus all counted consumption is at least the entry's 50. Otherwise it stops, and a lower total needs a new reviewed entry.
     - **No reset.** Database recreation, a replacement binding or a retry renews nothing. A later worksheet deducts all earlier consumption.

     **Its records:**
     - **Real records.** Every count cites a real record: a private receipt file named by its hash, holding either this prototype's own counts or the owner's exact words with their time and source. An invented reference fails.
     - **Disjoint scopes.** The current binding and the earlier bindings are counted separately.
     - **Replay.** An identical provisioning replay is not a new allocation.

     The worksheet's SHA256 is recorded on the provisioning event. This precondition binds provisioning and activation, not this text.
   - **Provisioning.** The operator's one creating grant action takes only the funding id. It materializes exactly the entry's terms and allocation, with the operator anchor as creator and updater. It appends `model.grant.provisioned` with the funding id, its digest, the decision references, the worksheet digest and the delegation.
     - An identical replay returns the grant.
     - A second grant is refused.
     - No term change, allocation change, release or ordinary creation is possible for any actor in prototype runtime. Revocation is allowed.
   - **One funded route.** This is the only route agents launch.
     - The owner's databases, the old G-DEMO grant included, are recorded as unused by this delegation. Agents never touch them.
     - A new database or binding renews nothing. Another route needs a reviewed partition of the shared 60.
   - **Partitioned admission.** Admission dispatches on the runtime before any scope or eligibility check.
     - In prototype runtime only the prototype path exists.
     - A refused call is refused before it is charged, and never falls back to ordinary admission.
     - The call's purpose is passed explicitly to the gate.
     - The run's origin and the call's purpose must be in the funded scope.
     - A `:proof` run is refused.
     - The store root must be unset.
   - **Recorded at reservation.** The reservation records the authority on its one original `model.invocation.reserved` event: the policy id and digest, the funding id, the binding id, the instance, the tenant, the operator anchor, the dataset class, the profile, the purpose, the grant and its revision, the allocation, and the witness mode. Only admission sets it.
   - **Re-derived at launch.** Launch compares every recorded value with the binding, the invocation's charge, and the grant's current revision, creator and updater.
     - Any difference refuses, as does a missing, duplicated or malformed record. A launch refusal keeps its charge.
   - **What is waived, and nothing else:** the trusted-store requirement (store absent), and tuple promotion.
   - **What stays:**
     - the enforced gate;
     - the pinned CLI and its identity;
     - per-call init attestation (model, version, and empty tools, MCP servers and slash commands);
     - the frozen profile;
     - the switch fence;
     - grant and allocation windows;
     - per-run and per-day limits;
     - accounting;
     - concurrency 1;
     - no refund or automatic retry.

5. **Prospective release.**
   - **The runtime decides first.** In prototype runtime the ordinary `:released` branch is unreachable. A new decision is `released_unverified`, paired only with `owner_prototype_unverified`, or withheld.
   - **The new withheld reason** is `prototype_authority_refused`.
   - **Known evidence first.** After the run (`FOR UPDATE`), its Operation (`FOR SHARE`) and the invocation (`FOR SHARE`), the finalizer plain-reads every wire-witness link of the invocation and every `reconciliation_required` Failure of it.
     - Link writers lock the invocation `FOR UPDATE`, so the links are stable.
     - Failure writers append under the chain head, so the Failures are re-read under the head.
   - **What known evidence decides.**
     - A link with status `mismatch` means withheld `witness_mismatch`, on the invocation's critical cause as run recovery selects it.
     - Any other link, a critical Failure without such a link, or a live warning Failure means withheld `prototype_authority_refused`.
       - The code is `witness_evidence_present`, or `known_integrity_signal` for a critical Failure.
       - A usable live critical cause stays the bound cause, with its identity and severity unchanged.
       - No mismatch is claimed.
     - The absent store's empty receipt never clears known evidence.
   - **Eligibility,** all at the decision instant under the head:
     - the binding equals the recorded authority;
     - a completed, valid, generation-2 ClaudeCLI invocation of a running, non-proof run, in the funded scope;
     - its grant is active and unchanged since reservation, created and updated by the anchor;
     - the instant is inside the window (item 9);
     - the observation is `store_unconfigured`;
     - no known evidence.
   - **Outcomes.**
     - **All hold:** `released_unverified`.
     - **Known mismatch:** `witness_mismatch`.
     - **Otherwise:** `prototype_authority_refused`, with one code from this closed set: `binding_mismatch`, `authority_unrecorded`, `authority_mismatch`, `scope_mismatch`, `identity_mismatch`, `operator_mismatch`, `grant_changed`, `grant_not_eligible`, `outside_window`, `witness_mode_mismatch`, `witness_evidence_present`, `known_integrity_signal`, `output_invalid`.
     - **What the withheld event records:** the true observation classification.
     - **The run.** It stops `witness_mismatch` for an actual mismatch, and `witness_unreconciled` otherwise, with the exact reason kept.
     - **A reconciled receipt** cannot occur with the store absent. If one appears, it is refused (`witness_mode_mismatch`).
   - **A bounded repeat.** If an under-head recheck fails, nothing is written, and the gate decides once more in refusal-only mode.
     - Recovery never decides a release of either kind.
     - Only the facade's own gate step decides `released_unverified`, under its prelocked context.
     - It is reached only through the existing result-gate finalizer. No caller supplies the authority, the basis or a decision: the step derives them from the locked rows, the boot-verified binding and the reservation's one original event.
     - An interrupted or timed-out gate never releases. A timeout keeps its existing withheld classification.
     - No existing withheld or calibration row is converted.

6. **Persistence, replay and recovery.**
   - **The row.** One immutable decision per invocation, append-only.
     - Its link, projection, method and `evidence_sha256` are NULL.
     - It claims no witness link, projection, method or calibration evidence.
   - **The event.** `model.result.released_unverified` in the same transaction.
     - Its arguments are the canonical basis `d237-basis/1` and its SHA256.
     - **What the basis holds:** the policy; the funding; the binding; the window and the decision instant; the invocation's and response's ids and digests; the runtime identity; the observation; the assurance `unverified`.
     - It holds no content.
   - **New decision or existing row.**
     - The finalizer reads the existing release first, after the invocation lock.
     - With no release, it validates a new decision (item 5).
     - With a release, it never re-derives authority from live state.
   - **Existing-row replay.**
     - **Valid only when all of these hold:**
       - exactly one original event exists;
       - its basis's canonical digest equals the recorded digest;
       - the basis's bindings equal the row (invocation, tenant, `decided_at`), the invocation (run, charge, identity, digests) and the recorded reservation authority.
     - **Historical facts come from the basis only.** The historical grant, window, observation and policy facts come only from the basis. Later grant changes, revocation, window end, links and configuration do not alter a replay.
     - **Outcomes.**
       - An identical replay writes nothing.
       - A missing, duplicated, unreadable or inconsistent basis refuses, with no output.
       - A different requested basis is a `ReleaseConflict`.
       - A caller basis is only compared.
   - **Current use is separate.** An existing `released_unverified` output is used only in prototype runtime, with the live binding equal to the basis's binding.
   - **Recovery.** It returns an existing output only on the same verification, and never decides one.
   - **Lock and cause order.**
     1. The run.
     2. The Operation.
     3. The invocation.
     4. Plain reads.
     5. By branch, before the head: the grant, then the allocation, `FOR SHARE` (release); the selected critical cause `FOR UPDATE` (mismatch); the gate cause `FOR UPDATE` (refusal).
     6. The chain head.

     No lock is taken after the head.
   - **Migration.**
     - Constraint changes only, for the new values, roles and actor type. No new column is added to any existing audited resource, so earlier records' hashes are unchanged.
     - The down migration refuses while any new-value row exists. It never deletes or rewrites a row.

7. **Real data, sources and logs (D-244, D-245).**
   - **Permitted data.** Minimal professional and company data is permitted:
     - a company's name, domain and public website;
     - company-level facts from public pages: size, location and industry;
     - for one person per company: a public business name and role, and a work email on the company's domain that a checked public page explicitly links to that exact person;
     - per-field source references and retrieval times;
     - facts quoted or summarized from public business pages.

     **Excluded:**
     - sensitive categories, personal-life data and private addresses;
     - login-only or terms-restricted sources;
     - guessed, enriched or directory-listed addresses, company-only addresses, and pages that merely mention a person.

     These names and emails are personal data.
   - **Size.** At most 3 distinct imported contacts for the binding, canary included. The cap holds across commands and dossiers, under a lock, and an identical replay uses no slot.
     - The dossier holds at most 15 companies.
     - One eligible canary is enough to start. Three is a ceiling, not a research quota.
     - If no row qualifies, that fact is reported and the rule is not weakened.
   - **Contacts are people.** The existing contact record is unchanged: first name, last name and email stay required (`lib/sdr_agent/sales/contact.ex:145-147`). There is no team contact, no placeholder name and no display name. A team contact would need its own reviewed amendment.
   - **The dossier.**
     - It is one private local file, mode 0600, outside the repository. It is never committed, attached or echoed in reports, envelopes or chat.
     - It uses the one supported schema, `sdr-agent.prototype-dossier` version 1. Its exact key sets and closed enums are pinned in the interface freeze:
       - stable row ids;
       - company-only rows, which are never imported;
       - closed skip reasons;
       - honest source types;
       - exactly one claim each for name, role and email, each with its basis and attribution;
       - fact kinds `quote`, `fact` and `inference`;
       - company-level topic facts with their statement dates;
       - email kinds `personal_work`, `role_mailbox` and `unavailable`;
       - every contact classified `unverified`.
     - Import names the file by its full sha256. The reviewed file is never changed in place, and a changed file is a new dossier.
     - Its content is untrusted data: it cannot issue commands or set authority.
   - **The contact-source rule.**
     - **The email claim** qualifies only from:
       - a page on the company's own site, where the company publishes the person's address;
       - a page the person authored; or
       - a public, terms-permitted third-party post or article that its publisher attributes to the person.

       In every case the checked page must explicitly connect the exact named person to the exact published work address.
     - **The evidence of that link** is its exact excerpt, or a byte-verified private copy. It holds both the name and the address inside one literal UTF-8 byte window of at most 300 bytes.
       - **That window is a mechanical bound only, never sufficient attribution.** The person-to-address relation itself is the spot-check's explicit link mark.
       - A byline and an unrelated mailbox in the same window fail.
       - The bound is never expanded, and disconnected text is never stitched together.
     - **Honest labels.** The source type is kept exactly. A third-party or directory source is never relabelled as the company's own.
     - **What never supports any contact claim:** a directory listing, an enrichment record, or a page that only mentions the person.
     - **What is mechanical, and what is declared.** The host only establishes company host versus other host, which is a necessary syntax check and not proof. Person authorship, publisher attribution and directory status are declared, source-supported classifications that the spot-check confirms.
     - **Directories and company facts.** A directory may support a company-level fact only when the check confirms that exact company's statement, date and meaning. It remains directory evidence, unverified, never the company's own word.
     - **The role claim** must confirm the current person, company and role association.
     - **Conflicts.** A conflicting address, link or person source keeps the row out. A conflict is never resolved by picking the convenient source.
     - **What attribution is not:** proof of identity, deliverability, consent or current ownership. Every contact stays `unverified`.
   - **Spot-check before import.**
     - **What is re-read.** Each selected row's claims and excerpts, once, with no login and inside the site's terms.
     - **What is recorded.** A private manifest binds each result to its exact claim or fact, source and final URL, with the actual retrieval time and its time zone.
     - **What is never done.** The dossier is never edited, and no precise time is reconstructed from a date-only record.
     - **Where its digest goes.** Every imported row records it.
     - **What `verified` means.** An agent re-read found the text. It is not proof that the claim is true.
   - **Qualification inputs.**
     - **What an importable row needs.** A verified, dated company-level statement of total headcount or a headcount range, and one of the company's own location. A founder count, an office address or accelerator participation alone does not qualify.
     - **The freshness floor.** The statement date must be on or after 2025-10-28, and on or before the date of its check.
       - A future-dated statement refuses.
       - A statement with no date is insufficient.
       - Retrieval time is not publication time.
       - This is a conservative eligibility ceiling, not a guarantee of currency.
     - **These must reach qualification.** They must become accepted evidence claims that reach the qualification call. Existing only in the dossier or the notes is not enough.
     - **What the import does not do.** It sets no company size, industry or geography field.
     - **Nothing is forced.** Nothing is prefilled from the ICP target, and an unknown never passes.
     - **A truthful disqualification** moves the run on to the next eligible row.
   - **What is imported.**
     - **Contacts.** Only rows that pass the rules above.
     - **Rows not imported.** Company-only, role-mailbox, unavailable, unconfirmed-link, unconfirmed-role and conflict rows stay research reserve. No placeholder or invented address is imported, no person is bound to a role inbox, and no required contact field is weakened.
     - **Targeting notes, not evidence.** Inference facts and `why_fit` are kept as labelled targeting notes. They never become evidence or a quotation.
     - **Evidence.** A quote or fact enters the quotable evidence path only as a verbatim excerpt from one source that the spot-check re-confirmed. This is what `lib/sdr_agent/sdr/prompts.ex:30-31` requires, and an excerpt never mixes pages. Unconfirmed or conflicting claims stay research notes.
   - **How it is imported.**
     - The one import action reads each input once, by its digest, through a bounded parser. It refuses the whole input, with value-free errors, on any of:
       - unknown, oversized, duplicate or malformed records;
       - repeated JSON keys at any depth, found before any conversion;
       - nesting beyond the minimum depth that the exact schema needs;
       - decoded text outside its field's rule (seed settings text by the ordinary settings content rules; dossier text by a defined control-character rule, with nothing normalized away first);
       - unsupported contact types;
       - unsafe URLs.
     - It makes no network fetch and never evaluates the dossier, or model text, as code.
     - It refuses an over-cap selection before any write.
     - It imports each row atomically through domain APIs, idempotently by dossier sha256 plus row id, and refuses conflicts.
     - After a failure, committed rows stay, and the same command resumes.
   - **Dataset class.** The binding's create-only dataset class `real_prototype` is truthful: these rows are real and prototype, never "synthetic".
     - **Accounts and contacts.** In prototype runtime only, imported accounts and contacts may have non-reserved domains and emails. Each must equal its dossier entry.
     - **Sender address and booking link.** The reserved-name guard stays on the campaign sender address and the booking link.
     - **Other databases.** The guard is never disabled anywhere else.
   - **Evidence type.** The confirmed excerpts become research evidence of the new provider `:public_dossier`.
     - It carries the real final URL, the spot-check's retrieval time, trust `unverified`, and whether each excerpt is a quotation or a supported fact.
     - It is never labelled `fixture_search` or `fixture_web`, and never presented as a live fetch.
     - Citations point to those sources.
   - **Suppression.** Suppression keeps its normalized matching (`lib/sdr_agent/outreach/suppression.ex:68-69`) and the send gate's execution-time check (`lib/sdr_agent/outreach/delivery.ex:139-140,615-620`). Boot requires the Store suppression check.
   - **Sender profile and guide (D-244).**
     - **Content: seed r4.** Its four files are pinned by SHA256, and setup refuses any other bytes:
       - `offering_profile.json` `d4c9efd26da61929e202df2cf00a2f20f03769f5da58eb6e782a7252991e1d54`;
       - `writing_guide.json` `ba6ae5b1c864c5633c378070f3b702f00ef17eb8d59d4a6e30456caea35ef7eb`;
       - `campaign.json` `4cdfbb7920e713f98015e8501868a9768c0cda30027a4a795921df7fb861f969` (the ICP, the one sequence step, the sender name);
       - `provenance.json` `4395554919aaaefe36097b3de6f28e681697e55fad5729d1c0643cd4d72dc95f`.
     - **Provenance.**
       - The seed is mixed-provenance and never called wholly public.
       - `public: true` means every supporting source is a public page. `public: false` means authored, non-public or mixed, with the source kinds kept.
       - **Must be public:** the profile name and summary, and every feature, use case, outcome and proof point. Each is no broader than supported behaviour.
       - **May be non-public:** instructions (the writing guide, the sequence step, the `limit` items), which are never evidence or a claim to a prospect; and targeting (the audience, the ICP).
       - Both honesty limits stay. No field is added to the seed bytes to describe a class.
     - **The ICP.** Matching and exclusion guidance lives in the criteria strings, because only the ICP name, version and criteria reach qualification. The description is a human note. No deterministic exclusion is claimed from natural-language criteria.
     - **Where it lives.** One private directory, mode 0700, outside the repository, holding the four plain JSON files, each mode 0600. It is never committed (C4, D-123).
     - **How it is seeded.**
       - Setup reads the directory through a bounded parser and never evaluates it as code.
       - It saves the settings through prototype seed actions. They run the same validators as the ordinary settings action, with no bypass, and errors are value-free.
       - Provenance is never stored as settings keys.
       - Setup does not open the SettingsLive first-private-save path.
     - **Sender.** The sender name is exactly the 17 bytes `the GTMscape team`, a truthful brand sender, and the sender address stays reserved. The writing guide names that exact sender, so the header and the model's sign-off agree. The text never claims that a person wrote or approved a draft.
     - **Sequence.** One step, no follow-up, and no deferred work scheduled after capture.
   - **Agent sessions: authority PENDING the owner.**
     - **What is already authorized.** The existing authority covers the application's own Anthropic CLI processing (ADR-0014 Amendment 2). It forbids real-person data in chat transcripts shared outside the owner's machine. D-245 directs finding the contacts, but it is not informed acceptance of agent-session copies at Anthropic or OpenAI and their retention.
     - **The focused ask names:**
       - the minimal public business identity and work email;
       - agent research and review;
       - which providers (Anthropic, OpenAI, or both);
       - provider-side retention outside local control;
       - no screenshots, publication or secrets;
       - this bounded prototype and window.
     - **Disclosed.** Before the pause, the research session already processed contact identities at Anthropic, together with fetched pages and tool output. That is a recorded exposure fact, not approved retroactively. Those copies stay private, unopened, unreplicated and undeleted, with a counts-only inventory. A later yes is prospective.
     - **Until the answer:** no further prospect data enters any agent session; no import; no activation.
     - **If Anthropic only:** Claude sessions may handle the minimal data. Codex reviews synthetic fixtures, schema, hashes and content-free counts only.
     - **If both providers:** both sessions may handle it, within this prototype and window.
     - An Anthropic yes is not an OpenAI yes. Reviewers check the dossier through a local, counts-only validator. Nothing about a real person leaves the machine by any other agent channel.
   - **Application logs and command output in prototype runtime, and during setup.**
     - **Content-free logging.** A logging filter replaces every log event that is not a coded prototype event with a fixed content-free line, keeping only its level and validated standard metadata. That covers formatted strings, reports, and crash, termination and supervisor reports, from any library.
       - Coded events carry closed codes, ids and counts only. A kept event is rebuilt from its code and validated ids and counts alone; its original message and arguments are discarded.
     - **The sink.** Log output goes to one private 0600 file.
     - **Command output.** The operator commands print only codes, counts and ids, and their errors are value-free.
     - **Telemetry.** OpenTelemetry content capture is off and traces export nowhere.
     - **Database queries.** The existing database-query logging stays off (`config/config.exs:100-103`).
     - **Testing.** Synthetic canary markers only, through setup, import and parser errors, worker and provider errors, formatted strings, termination and supervisor reports, and command failures.
   - **Server logs (D-118/5b).** Before the cluster's first start, its configuration sets:
     - `log_min_messages = fatal`;
     - `log_min_error_statement = panic`;
     - `log_statement = none`;
     - `log_min_duration_statement = -1`, `log_min_duration_sample = -1`, `log_transaction_sample_rate = 0`;
     - `log_error_verbosity = terse`;
     - `log_parameter_max_length = 0`, `log_parameter_max_length_on_error = 0`;
     - `log_connections = ''`, `log_disconnections = off`;
     - `log_autovacuum_min_duration = -1`;
     - `log_checkpoints = off`;
     - `log_lock_waits = off`, `log_lock_failures = off`;
     - `log_temp_files = -1`;
     - `shared_preload_libraries = ''`, `session_preload_libraries = ''` (so no `auto_explain`);
     - `logging_collector = off`, with stderr written to one file in the cluster's private log directory.

     **Canary proof.** Before any real-data load, a canary proves that synthetic marker values driven through the error, slow, lock and constraint paths do not appear in that file.
     - **What it proves.** Zero hits is scoped evidence for the tested paths. It is not proof that every log path is safe.
     - **No residual:** this satisfies the 5b requirement for this cluster only.
     - **A residual:** the separate log residual clause is a template. It is filled from the actual canary report, rehashed and reviewed, and real data is loaded only after the owner explicitly accepts that filled clause. D-242 does not cover it.
     - **What this is not.** It is not 5b's closure for the owner's clusters.
   - **Where copies live, and for how long.**
     - **Copies:**
       - the cluster (data and server log);
       - the application log file;
       - the dossier, the seed directory, the spot-check manifest and any retained private source copies;
       - the proxy's raw model captures;
       - the database's prompts, payloads and outputs;
       - any export or result bundle.
     - **Agent sessions, local and at the provider:**
       - the operator commands' output, which by contract holds codes, counts and ids only;
       - each agent CLI's locally stored transcripts;
       - terminal scrollback;
       - the providers' retained copies, outside local control;
       - the pre-pause research session and its fetched pages.
     - **Retention.** Each class is kept until the D-239 window ends, and then until a separate owner-approved disposal step. The local transcript and provider retention periods are each CLI's and provider's own; they are recorded in the inventory, not assumed.
     - **No backup** is made by this plan.
     - **Dropping the database alone does not remove every copy.**
     - **Nothing is deleted** under this amendment.
     - ADR-0014 Amendment 2's review point (2026-12-06) applies.

8. **Delegated approval, capture and assurance in data.**
   - **The approval.** The operator's approval states delegated machine approval.
     - **Its event** `outreach.approval.granted` carries `approval_mode: "delegated_machine"`, the delegation id and the assurance block.
     - **Its approver** is the operator anchor.
     - **What it still binds:** the exact revision, content hash and recipient, and the suppression, citation and campaign checks of today's approval.
     - **Whose approval it is not:** the owner's, and not a human's.
   - **Capture.** A NEW `captured` receipt is recorded only for an approval by the operator anchor, in prototype runtime. Its event carries the assurance block.
   - **The assurance block** is `{label, policy_id, entry_sha256, instance_id, dataset_class}`.
     - It travels with every capture, serialization and export from the prototype database.
     - It is never written into the approved message bytes.
     - Exports carry it inside the signed payload.
     - Any future standalone download must carry it.
   - **Serialization.** One output serializer is the only standalone representation of prototype business output.
     - **Two channels, never mixed.** Command output and logs carry codes, counts and ids only. Content goes only into a private, exclusively created, labelled 0600 bundle file, read only within the owner's provider scope (item 7).
     - **Before approval**, the pending-revision view shows the current revision's subject, body, revision id and canonical content digest, together with the recipient's contact id and exact email address from the draft's own recipient. Nothing in it suggests the revision is approved.
     - **Approving the reviewed draft.** The delegated approval takes the reviewed revision, its digest and the reviewed recipient address as explicit inputs. It never refills the address from the current contact. The existing check that refuses an approval whose reviewed address no longer matches the current recipient is unchanged.
     - **The capture view** shows the captured rendered message and its digest.
     - **Typed digests.** The revision-content digest and the rendered-message digest are never interchangeable, and each is compared only with its own bound source. Neither byte stream is altered, and the label never enters either.
     - Every view carries the assurance block. Every other serializer or export path refuses in prototype runtime, and so does an export without the block.
   - **UI.** Every prototype page shows a fixed `UNVERIFIED (PROTOTYPE)` banner. The Home projection keeps withholding non-reserved contacts (`lib/sdr_agent/outreach/inbox.ex:94`).
   - **Checks that remain.** Deterministic business checks, exact citations, suppression, idempotency and capture-only delivery.

9. **Activation, order and window.**
   - **Activation needs all of these:**
     - this text accepted (D-242);
     - an implementation head with Codex's exact-head APPROVE, green CI and the full gate;
     - the production-artifact proof, which no schedule cut removes;
     - the item-2 setup;
     - the item-7 canary proof (and, if a residual remains, the owner's acceptance of the filled residual clause);
     - the owner's answer on agent-session processing (item 7), which bounds who may handle the real data;
     - the item-4 remaining-budget worksheet, and the funded grant;
     - at least one dossier row that passes item 7's rules and its spot-check;
     - a fresh boot on the second row of the boot table.
   - **Order.**
     1. One canary contact journey first.
     2. Then the remaining eligible contacts, one at a time and never in parallel. There are at most two, under the binding-wide cap of three, bounded by the remaining attempts and the per-run limits.

     Headroom is kept for disqualification and failure. No answer is retried into existence.
   - **The window.** After 2026-11-07T07:00:00Z there is no new business-use permission: no reservation, launch, `released_unverified` decision, delegated approval or capture.
     - **Still allowed after it:** recording a late withheld or failed outcome, charging a consumed attempt, historical replay, revocation and reading.
     - **Prototype mode off** opens no ordinary access.

10. **Unchanged, and no authority by acceptance alone.**
    - **Unchanged:** capture-only delivery, suppression, exact approval binding, idempotency, the append-only audit trail, tenant authorization and secrets protections.
    - **What acceptance does not do.** It gives no access to the owner's databases or services. It makes no claim of human or owner approval of any output.

**Entity and action delta:**

| Entity | Change |
|---|---|
| PrototypeDatabaseBinding | New, create-only singleton (item 2). |
| PrototypeDelegation | New, create-only rows: D-243, agent, session. The binding, tenant and anchor are database-bound to the binding (item 3). |
| Actor, AuditEvent, AuditAccess | New system actor type `prototype_operator`, in both actor-type constraints. |
| Payload | Changed policy boundary: two new scoped content actions for the operator (store its inputs; read one captured message). The existing actions are unchanged (item 3). |
| User | New non-human role `agent_operator`, with no credential; sign-in, session lookup and role change refuse it. A unique `(id, tenant_id)` key. Password required for every other role. |
| ModelCallGrant, ModelCallAllocation | The one funded provisioning action, after the remaining-budget worksheet. Prototype-runtime refusals of every other write except revoke. No new column. |
| ModelInvocation `:reserve`, launch | The partitioned path, explicit purpose and recorded authority (item 4). |
| ModelResultRelease | The new pair and the new withheld reason. Constraint-only (items 5 and 6). |
| SettingsRevision | Changed policy boundary: a prototype seed action, with the ordinary create policy narrowed to the ordinary action and still admin-only. No operator read of settings content (item 7). |
| IcpDefinition, Sequence, Campaign | Prototype seed actions for the four pinned seed files (item 7). |
| Account, Contact, Lead | One import path. Dataset-aware domain and email validation. A binding-wide cap of three contacts. The contact record is unchanged and person-only (item 7). |
| DossierEntry, DossierSource, ResearchArtifact | A new per-row import record keyed by dossier sha256 plus row id, with exactly one source-bound claim each for name, role and email, and the spot-check digest; per-source rows holding verified excerpts; provider `public_dossier` (item 7). |
| Approval, DeliveryReceipt | Delegated approval and capture checks; event arguments only; approver attribution scoped to the three approval actions (items 3 and 8). |

**Later, after instrumentation (D-248), each with its own review:**
- configured witness mode;
- calibration, v4 and T7;
- evaluations and dashboards;
- other profiles and providers;
- a real-web adapter;
- generic import;
- team or role-inbox contacts, and contacts without an email (a separately reviewed amendment, if ever);
- automatic discovery;
- replies and follow-ups;
- run retry;
- per-record badges;
- a Home rendering of real contacts;
- hosted changes;
- emailing.

**Unchanged.**
- The C2* amendment and addenda (D-223, D-227, D-228, D-230) in `agentenv-1`.
- ADR-0004's agent-environment items, including item 10, in `agentenv-1`.
- The reconciled-only `:released` path in ordinary runtime.
- G-R0, and the v4 proof path.
- Terminal immutability.
- The test allowlist.

**Residual risks (stated, not solved).**
- Nothing checks the output against the wire or the truth. The label is the protection.
- Public contact data can be stale or wrong, and permission to contact is not established. Capture-only bounds the effect.
- The shared total of 60 is not code-enforced across databases. The remaining-budget worksheet depends on the owner's word for owner routes.
- Agent sessions already hold contact identities at Anthropic from before the pause. Any further transfer waits for the owner's answer.
- A compile flag and create-only rows stop mistakes, not a deliberate same-account change.

**Cross-references.**
- **This ADR.** R0 amendment items 3, 4 and 5 are narrowed or extended for prototype runtime only.
- **ADR-0001.** The invariants are unchanged. Amendment 1: hosted stays Fake-only.
- **ADR-0004.** Agent-environment items 8, 9 and 9a are reused as a contract. R0 items 1, 2, 5 and 7 are unchanged.
- **ADR-0009.**
  - Item 8 gains the non-human `agent_operator` role and the `prototype_operator` actor type, for prototype runtime only.
  - Item 9's synthetic guard is replaced, for imported accounts and contacts in prototype runtime only.
  - Record hashes are unchanged.
- **ADR-0014.**
  - Constraints 1-6 are unchanged.
  - Constraint 7 and Amendment 2 govern the real data. This text adds the agent-curated dossier flow to Amendment 2's rule 3 flow, for this prototype only. It does not itself authorize agent-session transfer, which is pending the owner (item 7).
  - Amendment 2's rule 4 applies (no telemetry content).

<!-- END ADR-0005 D-237 PROTOTYPE AMENDMENT -->

<!-- BEGIN ADR-0005 D-237 TASK BOUNDARY AMENDMENT: text as accepted by the owner (D-264; Codex exact-text PASS 88e6d251) -->

#### D-237 task boundary amendment (2026-10-29, PROPOSED): a value-free terminal presentation boundary for the prototype tasks

**Status: PROPOSED.** Owner acceptance of these exact bytes is outstanding.

- **Who decides.** Only the owner can accept this amendment, directly or by a prospective acceptance scoped to it. D-219's delegation is limited to ADR texts needed for the D-218 scope and does not extend to this amendment.
- **What does not decide it.** D-241's build preapproval is not acceptance of these bytes. D-242 and D-249 cover only the D-237 local prototype amendment, which contains no task boundary.
- **Before installation.** The acceptance and the exact publication pins are recorded before the `run/3` implementation is installed, not merely before it merges.
- **No inference.** No owner quote or acceptance time is inferred.

**Context.**

- The prototype's SafeLog filter contains Logger output only.
- Mix and Kernel.CLI print uncaught raises, throws, exits and linked crashes, with their values and stacktraces, to stderr (Elixir 1.20.4 `kernel/cli.ex:154-157,169-171`; `mix/cli.ex:130-151`).
- They report several failures as status 0 (`kernel/cli.ex:147-152`).
- `MIX_DEBUG` and enabled task profiling can expose task arguments before the task runs (`mix/task.ex:521-533`). An empty `MIX_PROFILE` still enters profiling setup and flags parsing (`mix/cli.ex:28-30`); it is not claimed by itself to print task argv (`mix/task.ex:540-546`). Invalid or leftover profile flags can be rendered by `Mix.raise` (`mix/cli.ex:32-34`).

**Decision.**

- Every `sdr.prototype.*` task, and `sdr.audit.export` when the prototype switch is set, has a `run/1` of exactly two statements: `attached = SafeLog.attach(file: nil)` and then `TaskBoundary.run(task, attached, body)`.
- A future `SafeLog.attach()` (`attach/0`) form is a separately reviewed successor, after a total, fail-closed `attach/0` and the corresponding adoption grammar are ready; it is not an executable requirement of this `run/3` window. Both attachment forms remain outside boundary containment; a raise there is non-deciding.
- `SdrAgent.Prototype.TaskBoundary.run/3` takes these steps, in order:
  1. **Nested.** A call from a body process (it carries the boundary's nesting key) re-checks steps 2 and 3, then runs the body inline in the same process, with no catch and no presentation. A failed re-check raises a fixed implementation exception, so the outer boundary presents the outcome with the outer task.
  2. **Inputs.** `task` is one of `:setup`, `:provision`, `:import`, `:op`, `:serve` and `:export`, and `body` is a zero-arity function, checked by guards so that no `FunctionClauseError` surfaces; otherwise it aborts at stage `entry`.
  3. **Attach.** `attached` is exactly `:ok`; otherwise it aborts at stage `attach`. The input check precedes the attach check.
  4. **Entry guard.** The pure `entry_decision/2` decides over two observations, each recorded as `{:returned, value}` or `{:raised, kind}` with the raised value never bound: `SdrAgent.Prototype.RepoState.repo_state/0` and `SdrAgent.AgentEnv.OperationSnapshot.current/0`.
     - It is clear only when `repo_state/0` returned `:not_started` or `{:started, false}` and `current/0` returned `:inert` or `{:error, :snapshot_not_in_use}`; every other observation, including a raise, exit or throw, an unexpected value or a malformed observation, refuses at stage `entry`.
     - RepoState is reached by a dynamic call, so a build without that module observes `{:raised, :error}` and refuses.
     - The observations read the caller's process-local state plus public registry and application observations. They are bounded and not linearizable.
  5. **Crash dumps.** It sets `ERL_CRASH_DUMP_BYTES=0` for its VM.
  6. **Body process.** It runs the body in a fresh, unlinked, monitored process whose `$callers` is the caller followed by the caller's own `$callers`, plus the nesting key. Nothing else is copied: no caller dictionary, capability, connection or transaction is transferred. A raise in steps 5 or 6 aborts at stage `entry`.
  7. **Outcome.** Only `:ok` (exit 0) and `:refused` (exit 2, the body having printed its closed code) are known. Every other result, raise, throw, exit or death of the body process aborts at stage `body` (exit 70). The caller takes the body's outcome message and then demonitors with flush, or takes the body's `:DOWN` with any reason as aborted. Caught values and `:DOWN` reasons are never read.
  8. **Presentation.** `:ok` returns `:ok`; `:refused` exits `{:shutdown, 2}`; an abort prints at most one fixed line, `prototype: task_aborted task=<task> stage=<stage>`, through `SafeLog.say/2`, then exits `{:shutdown, 70}`. The line is printed inside its own catch, so a broken or refusing output device gives no line and the exit with 70 still happens. An invalid task prints SafeLog's withheld line instead.
- There is at most one boundary-decided presentation per invocation, by the outermost boundary; an attach raise and parent death are non-deciding.
- The boundary never reads, formats, logs or classifies a failure value, owns no transaction, and changes no Logger configuration, filter or handler.
- The supported top-level task domain authority (session, delegation, actor, connection and transactions) is created inside the body process. This is not generic capability erasure: VM-global state stays shared with the caller.
- The planned, held launcher `bin/d237` refuses when `MIX_DEBUG`, `MIX_PROFILE` or `MIX_PROFILE_FLAGS` is present, sets `ERL_CRASH_DUMP_BYTES=0`, and maps only `setup`, `provision`, `import`, `op` and `export`. This is the planned, held launcher contract, not a claim of measured or cleared launcher behaviour. Serve has no cleared launcher yet.

**Build partition.**

- `TaskBoundary` is compiled only when `:prototype_authority_compiled` is set, which `config/dev.exs` and `config/test.exs` set; the production build does not contain it.
- RepoState is compiled under the same gate, and no production module references it.
- It is prototype-only; production has no prototype tasks.
- The development-build gate is not a route around this amendment's acceptance.

**Alternatives rejected.**

- In-process `try/catch`: exit signals cannot be caught; an author probe printed the sentinel for a linked crash and a `Task` crash.
- Trapping exits: after a linked crash the body continues and can commit.

**Consequences.**

- The body's process identity, dictionary, links and connection and transaction ownership differ from the task process's.
- After `run/3`, the caller continues on a normal return, and after an exit only if it catches it; an uncaught exit terminates it (in a fresh VM, the CLI halts with that status).
- **There is no cancellation and no atomicity.** If the caller dies, the body keeps running and may perform effects and commit until the VM halts (a fresh CLI VM). In an existing VM it may outlive the caller, potentially indefinitely, unless the body finishes or the VM ends; existing-VM use remains unsupported. A commit made before a halt stays committed.
- **Current residuals:**
  - The caller's wait has no timeout, and no timeout or cancellation is promised.
  - `ERL_CRASH_DUMP_BYTES=0` is a VM-wide setting, and it is already set when the spawn in step 6 fails.
  - The outcome reply followed by a demonitor with flush does not acknowledge the body process's `:DOWN` before the caller returns. It is not proof of synchronous body death, resource teardown or process lifetime.
  - Real connection and supervisor lifetimes, for processes the body starts, remain separate obligations.
  - The K0 entry token is not implemented by this boundary.
  - A nested call from a process the body spawned (it carries no nesting key) is treated as outermost.
  - Output before `run/1`; direct non-launcher runs (not cleared for private data); erts halt slogans; signals (not verified); dependency writes straight to a device; descendants that leave their process group.
  - These residuals and the non-deciding paths are disclosed, not cleared for private data.
  - These disclosures are not general privacy clearance. D-263 already accepts real Claude CLI descendants surviving cutoff; that residual alone is not a blocker and does not require a termination solution. This does not waive the separate task-body parent-death and possible-commit residual above, and it expands no call or data permission.
- **The status contract** 0, 2, 70 (1 = outside the boundary; 64 and 71 = launcher) is subject to the coordinator's shared agreement.
- **No persisted change.** The SafeLog line is not an audit event.
- **Entity and diagram.** The entity delta is Codex's scoped contract and entity r6 PASS (correlation `m_1793198546483495500_ce1130d0`). That PASS is not acceptance of this amendment. The runtime sequence diagram is due at task adoption; no existing diagram changes.

**Decision scope.**

- Owner acceptance of these bytes would record, in ADR-0005, the `run/1` shape, the `run/3` steps, the build partition and the residuals above.
- It would not grant installing, measuring, merging or landing the `run/3` source. A meaningful measurement needs the exact full composite with S1's RepoState and the reviewed Part B codes and fixture, reviewed pins and a fresh execution reservation.
- It would not grant the launcher, task adoption, the harness or any process or signal case, the status agreement, private or real data, activation, or any real call.
- It would not change the D-237 local prototype amendment (D-249) or any other ADR-0005 text.
- It raises no live-model provider or billing question, and it does not ask the owner to re-accept D-263 or to solve CLI descendants: D-263 stands, and direct Anthropic API use remains prohibited.

<!-- END ADR-0005 D-237 TASK BOUNDARY AMENDMENT -->

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
