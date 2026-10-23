---
status: accepted
date: 2026-10-23
supersedes: null
---

# ADR-0018: Fix the req_llm and plug_crypto advisories of 2026-10-23

## Status

Accepted (2026-10-23) by the owner on the standup page
(`answers/2026-10-23__adr0018`, choice `accept`, 16:58:39Z; D-200), including
the residual under Consequences. Codex gave technical approval on the
reviewed text at `ecf6b2b`, whose CI passed. Proposed the same day by Claude.
It amends no earlier ADR: ADR-0003's compatibility set and ADR-0008's policy
stand.

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
**Cons:** `req_llm` 1.29.0 and `llm_db` 2026.10.6 both declare
`zoi ~> 0.18.11`, while ADR-0003 holds `zoi` at exactly 0.18.10 with
`override: true`, because 0.18.11 removes `Zoi.Types.Default` and breaks the
pinned `jido_action`. The override resolves both packages against 0.18.10,
below their declared range.

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

- Once this merges with a green CI run, `mix hex.audit` stops blocking pull
  requests. CI passed on the reviewed text at `ecf6b2b`.
- **Residual, for the owner to accept:** `req_llm` and `llm_db` run against
  `zoi` 0.18.10, below their declared `~> 0.18.11`.
  - "Not called directly" is not "not executed". `ReqLLM.Application` starts
    with the application and initializes provider discovery, a schema cache
    and child services. The pinned `jido_ai` resolves models through
    `LLMDB.Model` and `ReqLLM.model`, whose model and provider paths are
    Zoi-validated.
  - A path that relies on a 0.18.11-only `zoi` feature would fail at runtime,
    not at compile time. No such path is known to be reached today, and none
    is claimed to be safe.
  - **Revisit trigger:** before any use of `ReqLLM`, `LLMDB` or `Jido.AI`
    model, catalog or schema paths, direct or through Jido, that path needs
    its own compatibility evidence, or an ADR-0003 amendment that moves the
    whole Jido/Zoi set.
- The ADR-0003 regression test, which pins the Jido/Zoi set, should be
  unaffected; it runs in CI.

## Verification

Each item says how strong it is.

1. **Local, author-reported:** `mix hex.audit` clean;
   `mix compile --warnings-as-errors` clean in dev and test; `mix format
   --check-formatted`, `mix credo` and `bin/verify-workflow` pass.
2. **CI:** application start, the ADR-0003 lock test and the full suite
   passed at `ecf6b2b` (run 39980779092). The accepted head needs its own green
   run before merge.
3. **Not exercised:** `ReqLLM` and `LLMDB` paths beyond application start.
   They are the residual above.

**Usage rules:** of the three packages, only `req_llm` ships a
`usage-rules.md`. It is a transitive dependency and isn't in the project's
synced set, so this change adds no usage-rules section. `mix usage_rules.sync`
does propose changes, but only for packages this PR doesn't touch (`ash`,
`ash_authentication`, `jido`, `jido_action`, `jido_ai`). That is existing
drift, and syncing it is a separate change.
