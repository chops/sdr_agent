---
status: accepted
date: 2026-10-06
supersedes: null
---

# ADR-0002: Audit-First Architecture (System-of-Record Ledger)

## Status

Accepted (2026-10-06, owner decision recorded in ADR-0001: "audit-first
architecture with OpenTelemetry as a first-class concern"). Detailed design
amended by Codex consultations 11 and 13; those amendments are binding here.

## Context

The owner asked for full transparency: an auditor examining any action the SDR
agent took (a qualification, a draft, an approval, a delivery, a suppression)
must be able to reconstruct who did what, why, from which inputs, with which
code, model, prompt and policy versions, and must be able to detect tampering.

An earlier proposal treated model prompts and responses as disposable debug
data (truncated bodies, TTLs, metadata-only) and traced only LLM steps. It
would fail a real audit:

- the exact, complete model exchange behind each draft or decision was not
  durable;
- deterministic decisions (suppression, quota, policy, approval validation,
  phase transitions) were not reconstructable with their inputs and rule
  versions;
- there was no tamper evidence, no record of who viewed or exported audit data,
  and no stored diff between the AI proposal and the human-approved revision;
- OpenTelemetry and Postgres were not linked, and local Tempo retention (168h)
  is not audit-grade.

## Options Considered

### Option 1: OpenTelemetry traces as the audit record

**Pros:** one pipeline; good tooling.
**Cons:** sampling, retention limits, no integrity guarantees, and exporters
can drop data silently. Traces are diagnostic, not evidence.

### Option 2: Event sourcing via `ash_events`

**Pros:** every change is an event; replay.
**Cons:** makes event sourcing the write model for the whole domain (a large
architectural commitment for an MVP); no built-in hash chain, sequencing gap
detection, or anchoring; replay promises determinism we cannot give for model
calls.

### Option 3: Entity diffs via `AshPaperTrail` alone

**Pros:** cheap per-resource version history.
**Cons:** per-entity tables, no global ordering, no chain, no decisions or
model payloads.

### Option 4: Custom append-only, hash-chained ledger in Postgres

**Pros:** exactly the integrity, ordering and linkage properties an auditor
needs; small, testable kernel; independent of any one library.
**Cons:** we own the canonicalization, chaining and verification code.

## Decision

We will make Postgres (through Ash) the **system of record** for audit, with a
custom append-only, hash-chained ledger (Option 4). OpenTelemetry is
diagnostic corroboration linked by IDs, never the record (ADR-0005).
`AshPaperTrail` may be added later for entity diffs only; `ash_events` is not
used.

### Ledger concepts (named at concept level; schema is fixed in S2/S3)

- **AuditEvent** — the append-only ledger entry. Per tenant, a monotonically
  increasing `sequence` with gap detection; `prev_hash` and `event_hash` over a
  canonical serialization; UTC timestamp from a single injectable clock source;
  actor identity (human user, agent, or service) and the authorization
  decision that permitted the action; causation and correlation IDs;
  idempotency key and retry attempt; `trace_id`/`span_id`. Covers domain state
  changes, approvals, deliveries, suppressions, and operator views and exports
  of audit data.
- **Provenance snapshot** carried on, or referenced by, every record: build git
  SHA, dependency lock hash, runtime versions (OTP, Elixir), configuration,
  prompt template, policy/rule and schema versions, and canonicalization
  version.
- **ModelInvocation** — one model call: provider, model id, parameters, prompt
  template id and version, structured-output schema, full request and full
  response (raw, parsed, Zoi validation result, refusal or error), usage,
  latency, plan-call count, and links to the agent run and decision.
- **ModelPayload** — content-addressed (sha256) request/response bodies,
  deduplicated, stored in full.
- **ToolInvocation** — one Jido Action execution: action module and version,
  inputs, outputs, errors, duration, external request references.
- **Decision** — every branch point, LLM or deterministic: kind, input
  references, rule/policy version, outcome, rationale, evidence ids, model
  invocation ids.
- **DraftRevision** — immutable; approval binds the revision hash and the
  recipient; a stored diff records AI-proposed versus human-final content.
- **DeliveryReceipt** — provider acceptance or capture-adapter receipt linked
  to the delivery operation and its idempotency key.
- **Retention record** — retention class, legal hold, and deletion tombstones.
  A deletion leaves a tombstone event in the chain; it never rewrites history.
- **Anchor record** — a signed, externally anchored chain head (ADR-0005).

### Canonical serialization

A versioned canonical form (sorted keys, UTF-8, fixed number and timestamp
encodings, no insignificant whitespace) is specified in S3 and recorded as
`canonicalization_version` on every hashed record. Changing it requires a new
version, never an in-place edit.

### Exports

`mix sdr.audit.export` (S11) produces a bundle with records, payloads, the
chain segment, and its anchor proofs, signed with the audit-anchor key whose
provenance is recorded (`docs/audit/anchor-signing-key.pub`). Every export
states its **assurance level**: chain-verified only, signed, Git-anchored
(owner trust domain), or OpenTimestamps-anchored (third-party time proof).

### Reconstruction acceptance test

"Given a sent (captured) email, reconstruct every step — lead, evidence,
qualification, decisions, model invocations with full payloads, policy checks,
draft revisions and diff, approval, delivery receipt, replies, suppression —
from Postgres alone, with all Jido processes stopped and Tempo unavailable;
the chain verifies and the anchored head matches." This is part of the golden
path (S13).

We promise **reconstructability**, not deterministic replay: model outputs are
recorded, not re-derived.

### Threat model summary

- **Detects:** silent edits, deletions, reordering or insertion in the ledger
  (hash chain plus sequence gaps); divergence between database and anchored
  heads; tampered exports (signature).
- **Corroborates:** model traffic via the independent wire witness and OTel
  spans (ADR-0005), with stated correlation caveats.
- **Does not defend against the owner.** The owner is GitHub admin of the
  anchors repository and holds the sops/age key that decrypts the signing key.
  GitSink anchoring proves continuity only within the owner's trust domain;
  OpenTimestamps adds a third-party proof that a head existed at a time.
- **Out of scope for the MVP:** host compromise while running, multi-tenant
  isolation, and insider threat beyond the single owner.

### Retention stance

The MVP processes **synthetic fictional data only**, so full content (prompts,
responses, drafts, replies) is stored with no redaction. Before any real data,
a policy must define field classification, encryption at rest, access-audit,
and retention per class. Content is never silently truncated or dropped;
reduction happens only through an explicit, recorded policy and leaves
tombstones.

## Justification

Only a custom ledger gives ordering, integrity, linkage and anchoring together
without committing the domain to event sourcing. Keeping OTel as corroboration
keeps sampling and retention limits from weakening the record.

## Consequences

### Positive

- An auditor can verify integrity independently of the running app.
- Deterministic and probabilistic decisions are equally reconstructable.
- Viewing and exporting audit data is itself audited.

### Negative

- More persisted data and write amplification per step.
- We own canonicalization and chain-verification code; it needs exhaustive
  tests (S3).
- Same-owner trust limit remains until third-party anchoring is verified.

### Neutral

- Real-data deployment is blocked on a separate data-classification ADR.
