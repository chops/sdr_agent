---
status: proposed
date: 2026-10-23
supersedes: null
---

# ADR-0018: Fix the req_llm and plug_crypto advisories of 2026-10-23

## Status

Proposed (2026-10-23) by Claude. Codex reviews it and the owner accepts it
before the pull request merges. It amends no earlier ADR: ADR-0003's
compatibility set and ADR-0008's policy stand.

## Context

On 2026-10-23 two advisories were published against locked packages, and CI's
blocking dependency audit (ADR-0008 policy 1) now fails on every pull request:

| Advisory | Severity | Package | Locked | Fixed in | Published (UTC) |
|---|---|---|---|---|---|
| EEF-CVE-2026-107685 (CVE-2026-107685, GHSA-6vww-5m28-f26v) | CRITICAL | `req_llm` | 1.26.0 | 1.29.0 | 2026-10-23T11:00:38Z |
| EEF-CVE-2026-105963 (CVE-2026-105963, GHSA-ffw9-w85g-f2vh) | MEDIUM | `plug_crypto` | 2.2.0 | 2.2.1 | 2026-10-23T09:56:58Z |

Affected ranges are from `https://api.osv.dev/v1/vulns/<id>`: `req_llm`
from 1.9.0 to before 1.29.0, and `plug_crypto` from 1.0.0 to before 2.2.1.

- `req_llm` is not a direct dependency. It comes in through the Git-pinned
  `jido_ai` (ADR-0003), which requires `{:req_llm, "~> 1.25"}`. The
  application's code does not reference `ReqLLM` or `Jido.AI`.
- `plug_crypto` comes in through `phoenix` and `plug`. `plug` 1.20.3 requires
  `~> 1.1.1 or ~> 1.2 or ~> 2.0`.
- ADR-0008 policy 2: a CRITICAL advisory is never ignored. It is fixed by a
  reviewed pin change in an ADR that names it. Both fixes are stable releases,
  so the pre-release stop condition doesn't apply.

## Options Considered

### Option 1: `mix deps.update req_llm plug_crypto`

**Cons:** it also moves `castore`, `decimal`, `jsv`, `sourceror` and
`spitfire`, which no advisory or new requirement needs.

### Option 2: unlock only `req_llm`, `llm_db` and `plug_crypto`, then `mix deps.get`

**Pros:** the smallest lock change that clears both advisories. `req_llm`
1.29.0 requires `llm_db ~> 2026.10.4`, so `llm_db` has to move with it.
**Cons:** `req_llm` 1.29.0 declares `zoi ~> 0.18.11`, while ADR-0003 holds
`zoi` at exactly 0.18.10 with `override: true`, because 0.18.11 removes
`Zoi.Types.Default` and breaks the pinned `jido_action`. The override
resolves `req_llm` against 0.18.10, below its declared range.

### Option 3: ignore the advisories

Not allowed for the CRITICAL one (ADR-0008 policy 2).

## Decision

We will use Option 2. `mix.lock` changes in exactly three entries, and
`mix.exs` does not change:

| Package | From | To |
|---|---|---|
| `plug_crypto` | 2.2.0 | 2.2.1 |
| `req_llm` | 1.26.0 | 1.29.0 |
| `llm_db` | 2026.9.8 | 2026.10.6 |

`zoi` stays at 0.18.10 under ADR-0003's override.

## Consequences

- `mix hex.audit` reports "No retired or security advisory packages found",
  and the blocking CI step passes again.
- `req_llm` runs against `zoi` 0.18.10, below its declared `~> 0.18.11`. It
  compiles with the rest of the application under `--warnings-as-errors`
  (dev and test), and the application doesn't call it directly. A `req_llm`
  path that relies on a 0.18.11-only `zoi` feature would fail at runtime
  rather than at compile time. Any later direct use of `ReqLLM` or `Jido.AI`
  model calls must prove that path first, or come with an ADR-0003 amendment
  that moves the whole Jido/Zoi set.
- The ADR-0003 regression test, which pins the Jido/Zoi set, is unaffected.

## Verification

- `mix hex.audit`: clean.
- `mix compile --warnings-as-errors` in dev and test: clean.
- The full test suite runs in CI on the pull request, which is the gate for
  this lock-only change.
