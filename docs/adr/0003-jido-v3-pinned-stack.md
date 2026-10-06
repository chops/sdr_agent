---
status: accepted
date: 2026-10-06
supersedes: null
---

# ADR-0003: Jido v3 Pinned Agent Stack

## Status

Accepted (2026-10-06, owner decision recorded in ADR-0001: "Jido v3
pinned"). The `jido_ai` commit SHA is **to be confirmed by S1**; S1 records the
confirmation (or the fallback) as an amendment to this ADR.

## Context

The owner's spec names Jido v3, Jido AI v3 and Zoi as the agent plane ("Jido
decides"). On 2026-10-06 the v3 line is pre-release:

| Package       | Source                                         | Requirement / pin              | License (verified 2026-10-06)  |
|---------------|------------------------------------------------|--------------------------------|--------------------------------|
| `jido`        | Hex                                            | `== 3.0.0-beta.1`              | Apache-2.0 (Hex metadata)      |
| `jido_action` | Hex                                            | `~> 3.0.0-beta.11`             | Apache-2.0 (Hex metadata)      |
| `jido_signal` | Hex                                            | `~> 3.0.0-beta.4`              | Apache-2.0 (Hex metadata)      |
| `jido_ai`     | Git `github.com/agentjido/jido_ai`, `release/v3` | `ref: b6fbd846f58f7629a0a68b2209f67848e242bdfe` | Apache-2.0 (repo LICENSE) |
| `zoi`         | Hex                                            | `~> 0.18`                      | Apache-2.0 (Hex metadata)      |

`jido_ai` 3.x is not published on Hex; its `release/v3` head on 2026-10-06 is
`b6fbd846f5` ("fix(v3): align AI with current core APIs (#371)", committed
2026-09-27). The beta requirements are ranges, so `mix.lock` is the exact pin
(for example `~> 3.0.0-beta.11` currently resolves to beta.12; S1 records the
resolved versions and their Hex checksums).

All packages are Apache-2.0, compatible with this Apache-2.0 public repository.

## Options Considered

### Option 1: Stable Jido 2.3 line behind a v3-shaped seam

**Pros:** published, stable.
**Cons:** does not validate the owner's central architecture; a later v3
migration is a rewrite of the agent plane.

### Option 2: Pinned Jido v3 betas plus `jido_ai` at an exact Git SHA, spike first

**Pros:** spec-faithful; exact pins make the supply chain reviewable.
**Cons:** beta APIs may change; an unpublished Git dependency needs SHA
verification and has no Hex checksum.

## Decision

We will use Option 2.

- **Spike first (S1):** before any domain code depends on Jido, prove that the
  pinned set resolves, compiles with `--warnings-as-errors`, and runs one
  agent with one action and one Zoi-validated structured output on the fake
  model (ADR-0004).
- **Exact pins:** `jido_ai` is referenced by full commit SHA (`ref:`), never by
  branch; S1 adds a CI check that fails if the locked SHA differs from this
  ADR.
- **No silent substitution:** if the spike fails, the fallback is an internal
  behaviour-backed fake for the failing capability plus a new ADR recording
  the failure. We never silently swap to the 2.3 line.
- **Changes:** any change to a source, pin, or requirement range of these
  packages requires a reviewed ADR amendment (ADR-0001 invariant).

## Justification

The owner explicitly chose the v3 line. Exact pins plus a spike turn beta risk
into a bounded, early, recorded check instead of a late surprise.

## Consequences

### Positive

- The agent plane matches the spec from the first slice.
- Supply chain is explicit: Hex checksums in `mix.lock`, Git SHA in `mix.exs`.

### Negative

- Beta churn: upgrades need deliberate review.
- A Git dependency is fetched from GitHub at build time.

### Neutral

- Fallback, if used, is visible as its own ADR.
