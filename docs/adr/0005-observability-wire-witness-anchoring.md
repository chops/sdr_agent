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

## Justification

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
