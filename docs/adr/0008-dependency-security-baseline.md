---
status: accepted
date: 2026-10-06
supersedes: null
---

# ADR-0008: Dependency Security Baseline and Blocking Audit

## Status

Accepted (2026-10-06) on Codex's approving verdict on the S0b pull request:
https://github.com/chops/sdr_agent/pull/2#issuecomment-6026997407
(ADR-0001: agent design ADRs are accepted on peer approval; the owner can veto).
Proposed earlier the same day by Claude in slice S0b. It amends ADR-0007 decision
step 3 (the audit step stops being advisory); the rest of ADR-0007 stands.

## Context

ADR-0001 forbids changing a dependency pin without a reviewed ADR. ADR-0007
recorded that the factory pins carry published advisories and left
`mix hex.audit` as an advisory CI step (`continue-on-error: true`), following
the doctrine "Dependency audits remain advisory until promoted". Slice S5
builds password authentication on `ash_authentication`, so the
CRITICAL/HIGH advisories against it must be fixed first.

Facts on 2026-10-06 (Hex 2.5.1 `mix deps.get` / `mix hex.audit`, which read
the EEF advisory database; affected ranges confirmed against
`https://api.osv.dev/v1/vulns/<id>`):

- `ash_authentication` 4.14.2: 5 CRITICAL, 5 HIGH, 2 MEDIUM, 3 LOW.
- `ash_authentication_phoenix` 2.17.3: 1 CRITICAL, 1 HIGH (both shared with
  `ash_authentication`).
- `ash` 3.32.3: 1 HIGH, 3 MEDIUM.
- `igniter` 0.8.3 and `usage_rules` 1.2.7: 1 LOW each.
- Every advisory has a fixed **stable** release; the 5.0.0-rc / 3.0.0-rc
  lines also carry fixes but are not needed.
- `mix hex.audit` exits non-zero on any non-ignored advisory or retirement,
  whatever its severity. Accepted findings can be listed in the project's
  `hex: [ignore_advisories: [...], ignore_retirements: [...]]` config.
- `bin/verify-workflow` does not pin `mix.lock` or the `deps` list of
  `mix.exs`. Its only `mix.exs` unit is the `usage_rules` project config. The
  receipt's `generators` records (which name igniter 0.8.3 and usage_rules
  1.2.7 as the scaffolding tools) are provenance and are not compared with the
  lock, so the bumps below need no receipt change.

## Options Considered

### Target versions: minimal stable fix vs. latest stable vs. RC

The smallest stable release outside every affected range keeps the change
reviewable and limits unrelated behaviour changes. Latest stable differs only
for `ash` (3.34.4 vs. 3.34.3, no advisory difference). The RC lines
(`ash_authentication` 5.0.0-rc, `ash_authentication_phoenix` 3.0.0-rc) are
major-version pre-releases and are not needed for any fix.

### Fixing LOW findings in dev-only tooling

`igniter` and `usage_rules` are dev/test-only and the LOW findings need a
malicious package's metadata. Both fixes are patch releases with no lock
churn, and fixing them leaves the audit with nothing to accept, so a blocking
audit starts from a clean baseline instead of an ignore list.

### Blocking policy: severity filter vs. fail closed with a reviewed ignore list

A severity filter would parse `mix hex.audit` text output and fail only on
CRITICAL/HIGH. Parsing human-readable output fails open if the format
changes. Running `mix hex.audit` as a blocking step fails on any new finding;
a reviewed LOW/MEDIUM acceptance goes into `hex: [ignore_advisories: ...]`
with an ADR, which `hex.audit` honours by ID or alias. This blocks a little
more than CRITICAL/HIGH (an unreviewed LOW also blocks) but cannot fail open.

## Decision

### Pin changes (all Hex, source unchanged)

| Package                      | Old (factory) | New    | Scope    |
|------------------------------|---------------|--------|----------|
| `ash`                        | 3.32.3        | 3.34.3 | runtime  |
| `ash_authentication`         | 4.14.2        | 4.15.0 | runtime  |
| `ash_authentication_phoenix` | 2.17.3        | 2.17.4 | runtime  |
| `igniter`                    | 0.8.3         | 0.8.4  | dev/test |
| `usage_rules`                | 1.2.7         | 1.2.8  | dev      |

No transitive lock entry changes. `mix deps.update ash_authentication
ash_authentication_phoenix` also floated `ash_sql` 0.7.1 to 0.8.1, which
nothing requires (`ash_sql` 0.7.1 accepts `ash ~> 3.32`); that was reverted
and `ash_sql` stays at 0.7.1.

### Code change required by the upgrade

`ash` 3.33.0 makes `config :ash, default_string_length_count:` mandatory (the
fix for EEF-CVE-2026-82752). `config/config.exs` sets `:codepoints`, the value
the Ash installer now writes. `:mixed` would keep the vulnerable grapheme
counting. `mix igniter.apply_upgrades` for the `ash_authentication` and
`ash_authentication_phoenix` ranges proposes no changes (dry run). `ash` has
no upgrade task. The project has no OAuth2, magic-link, API-key or audit-log
strategy yet, so the 4.15.0 breaking change (OAuth2/OIDC needs an
`identity_resource`) does not apply now. It is a constraint for any later
OAuth2 work.

### Advisories resolved

| Advisory (EEF-CVE-2026-) | Severity | Package(s)                          | Fixed in      |
|--------------------------|----------|-------------------------------------|---------------|
| 86533                    | CRITICAL | ash_authentication, …_phoenix       | 4.15.0, 2.17.4 |
| 88952                    | CRITICAL | ash_authentication                  | 4.15.0        |
| 76949                    | CRITICAL | ash_authentication                  | 4.15.0        |
| 82761                    | CRITICAL | ash_authentication                  | 4.15.0        |
| 85500                    | CRITICAL | ash_authentication                  | 4.15.0        |
| 86688                    | HIGH     | ash_authentication                  | 4.15.0        |
| 80218                    | HIGH     | ash_authentication                  | 4.15.0        |
| 81632                    | HIGH     | ash_authentication, …_phoenix       | 4.15.0, 2.17.4 |
| 82685                    | HIGH     | ash_authentication                  | 4.15.0        |
| 82760                    | HIGH     | ash_authentication                  | 4.15.0        |
| 94201                    | HIGH     | ash                                 | 3.34.3        |
| 78223                    | MEDIUM   | ash_authentication                  | 4.15.0        |
| 86522                    | MEDIUM   | ash_authentication                  | 4.15.0        |
| 86338                    | MEDIUM   | ash                                 | 3.33.4        |
| 82752                    | MEDIUM   | ash                                 | 3.33.0        |
| 93477                    | MEDIUM   | ash                                 | 3.33.11       |
| 81637                    | LOW      | ash_authentication                  | 4.15.0        |
| 82723                    | LOW      | ash_authentication                  | 4.15.0        |
| 82759                    | LOW      | ash_authentication                  | 4.15.0        |
| 82584                    | LOW      | igniter                             | 0.8.4         |
| 82710                    | LOW      | usage_rules                         | 1.2.8         |

Residual LOW/MEDIUM: none. `mix hex.audit` reports "No retired or security
advisory packages found", and OSV `v1/query` returns no vulnerabilities for
any of the five new versions.

### Policy

1. CI step "Dependency audit" runs `mix hex.audit` online after `mix deps.get`
   and is **blocking** (no `continue-on-error`). This promotes the dependency
   audit under the static-analysis doctrine.
2. CRITICAL and HIGH advisories are never ignored. They are fixed by a
   reviewed pin change (an ADR naming the advisory). If the only fix is a
   pre-release, the run stops and the owner decides (ADR-0001 stop condition:
   a security check fails).
3. A LOW or MEDIUM advisory with no acceptable fix may be accepted only by
   adding its ID to `hex: [ignore_advisories: [...]]` in `mix.exs`. The same
   change must carry an ADR (or an amendment to this one) with the reason it
   does not affect this project and a revisit trigger. Retirements follow the
   same rule via `ignore_retirements`.
4. Because the audit reads live advisory data, a newly published advisory
   can turn CI red on an unrelated change. That is intended: the next slice
   fixes or accepts it before merging.

## Justification

The minimal stable versions remove every CRITICAL/HIGH finding without a
pre-release or a transitive bump. Fixing the LOW findings too costs two patch
releases and gives the blocking audit a clean baseline. Fail-closed
`hex.audit` with an ADR-reviewed ignore list enforces "CRITICAL/HIGH block
CI" with no text parsing that could fail open.

## Consequences

### Positive

- S5 builds password authentication on a release with no known advisories.
- New advisories against any locked package, direct or transitive, block
  merges until someone reviews them.

### Negative

- CI depends on live Hex advisory data. A new advisory or a Hex outage can
  block an unrelated PR.
- An unreviewed LOW/MEDIUM finding blocks too, which is stricter than a
  CRITICAL/HIGH-only filter.
- "Never ignore CRITICAL/HIGH" is enforced by review, not automation: the
  ignore list holds IDs, not severities.

### Neutral

- The dependency-generated skills and the usage-rules section of `AGENTS.md`
  were produced from the old package versions. They are refreshed only when
  `mix usage_rules.sync` next runs, which is not part of this change.
- The factory receipt still records igniter 0.8.3 / usage_rules 1.2.7 as the
  generator versions. That is history and stays unchanged.
