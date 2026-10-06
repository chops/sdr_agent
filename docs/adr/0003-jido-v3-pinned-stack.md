---
status: accepted
date: 2026-10-06
supersedes: null
---

# ADR-0003: Jido v3 Pinned Agent Stack

## Status

Accepted (2026-10-06, owner decision recorded in ADR-0001: "Jido v3
pinned"). Amended by S1 after the compatibility spike and peer consultation
`m_1791327080724639250_3bee5fdc` approved the exact source set below.

## Context

The owner's spec names Jido v3, Jido AI v3 and Zoi as the agent plane ("Jido
decides"). On 2026-10-06 the v3 line is pre-release:

| Package       | Source                                             | Exact requirement / pin                         | License (verified 2026-10-06) |
|---------------|----------------------------------------------------|-------------------------------------------------|-------------------------------|
| `jido`        | Git `github.com/agentjido/jido`, `release/v3`       | `8c75f94958cad682834af787cb164536c5b513ea`      | Apache-2.0 (repo LICENSE)     |
| `jido_action` | Git `github.com/agentjido/jido_action`, `release/v3` | `af16008f79e8b76d3f3995935b1366bb2a0d7031`      | Apache-2.0 (repo LICENSE)     |
| `jido_signal` | Hex                                                | `3.0.0-beta.4` (locked)                         | Apache-2.0 (Hex metadata)     |
| `jido_ai`     | Git `github.com/agentjido/jido_ai`, `release/v3`    | `b6fbd846f58f7629a0a68b2209f67848e242bdfe`      | Apache-2.0 (repo LICENSE)     |
| `zoi`         | Hex                                                | `== 0.18.10`                                    | Apache-2.0 (Hex metadata)     |

`jido_ai` 3.x is not published on Hex. The S1 attempt with Hex `jido`
3.0.0-beta.1 and Hex `jido_action` 3.0.0-beta.12 did not form a compatible
stack: beta.1 rejects the `ai:` route target required by the pinned `jido_ai`,
and beta.12 still calls `Zoi.Types.Default`, removed in Zoi 0.18.11. The
approved Git commits are the exact `jido` and `jido_action` pins declared by
the pinned `jido_ai` commit. All three commits are reachable from their
upstream `release/v3` branches and GitHub reports valid verified signatures:

| Repository    | Commit date (UTC)     | Subject                                                      |
|---------------|-----------------------|--------------------------------------------------------------|
| `jido`        | 2026-09-27 20:59:24   | `refactor(plugin): use one callback authoring form (#384)`    |
| `jido_action` | 2026-09-27 01:51:31   | `feat(exec): preserve optional effect lists through flows`    |
| `jido_ai`     | 2026-09-27 21:05:33   | `fix(v3): align AI with current core APIs (#371)`             |

Their Apache-2.0 LICENSE files have the same SHA-256:
`5ef76176b7be1574f8006b1060a94f01518fc133ea1fb3136819d0fa7b473c8f`.
The Hex lock records `jido_signal` 3.0.0-beta.4 package checksum
`d916deccd7395685cc1b09e0d3760a914ba8d54d54a0e20d07914594812b07ba`
and `zoi` 0.18.10 package checksum
`35419e576865f05a59e3db095c1866b01e4fa7495702711b5435e0940e765901`.
Zoi 0.18.10 is the newest release retaining `Zoi.Types.Default`; 0.18.11 does
not compile with this Jido Action line.

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
- **Exact pins:** `jido`, `jido_action`, and `jido_ai` are referenced by full
  40-character commit SHA (`ref:`), never by branch. `jido_signal` remains the
  compatible Hex beta.4 and Zoi is held at exactly 0.18.10. The S1 regression
  test fails if the lock differs from this set.
- **Overrides:** top-level `override: true` on `jido`, `jido_action`,
  `jido_signal`, and `zoi` makes this reviewed compatibility set authoritative
  over the dependency declarations inside the Git-pinned `jido_ai` tree.
- **No silent substitution:** if the spike fails, the fallback is an internal
  behaviour-backed fake for the failing capability plus a new ADR recording
  the failure. We never silently swap to the 2.3 line.
- **Changes:** any change to a source, pin, or requirement range of these
  packages requires a reviewed ADR amendment (ADR-0001 invariant).
- **Return to published packages:** watch for mutually compatible Jido and
  Jido AI v3 Hex releases. Move back to Hex when available, through the same
  reviewed ADR amendment and compatibility proof; do not float Git refs.

## Justification

The owner explicitly chose the v3 line. Exact pins plus a spike turn beta risk
into a bounded, early, recorded check instead of a late surprise.

## Consequences

### Positive

- The agent plane matches the spec from the first slice.
- Supply chain is explicit: Hex checksums in `mix.lock`, Git SHA in `mix.exs`.

### Negative

- Beta churn: upgrades need deliberate review.
- Three Git dependencies are fetched from GitHub during the online dependency
  phase before the hermetic verification gate.

### Neutral

- Fallback, if used, is visible as its own ADR.
