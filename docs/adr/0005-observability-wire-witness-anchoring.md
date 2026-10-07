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
OpenTimestamps"). Details amended by Codex consultations 11 and 13.

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
  exceed the window and is then processed as earlier rows age out.
- **Test scope.** The hermetic end-to-end tests use a fake CLI that writes
  protocol-shaped store files itself. It is a functional fixture pipeline,
  **not** proof of transport or independence. S12a's real shim/proxy checks
  and the mandatory S12d real proof still apply. `traceparent` equality is
  not claimed, because no expected-context source is persisted.

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
