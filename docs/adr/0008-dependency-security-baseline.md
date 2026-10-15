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

## Amendment (2026-10-10): EEF-CVE-2026-101028

**Status: accepted** by the owner in the private Claude session chat on
2026-10-10 ("accept the amendment."), after Codex's independent approval of
369ea97 (reply 12cf8940; exact-head CI 38075894593 green).

### Advisory

- **EEF-CVE-2026-101028** (MEDIUM), aka CVE-2026-101028, GHSA-xj24-8f5c-pp5p.
- `Ash.count/2`, `Ash.exists/2` and `Ash.aggregate/3` applied only the root
  resource's read policy. Filters and sorts that cross a relationship (for
  example `comments.body`, or an aggregate over one) skipped the related
  resource's read policy, so a caller who controls such a filter could infer
  hidden related rows.
- Affected: `ash` 2.6.0 to 3.34.5. Fixed in **3.34.6** (2026-10-09).
- Found by the blocking `mix hex.audit` step on CI run 38074932795 (PR #37),
  as rule 4 of the policy above intends.

### Exposure in this project

Every call to an affected function in `lib/` filters only on attributes of
the root resource, with values fixed in server code. None crosses a
relationship, none sorts, none takes caller-supplied filter input
(`filter_input`/`sort_input`), and no resource defines aggregates:

| Call site | Function | Filter |
|---|---|---|
| `lib/sdr_agent/agents.ex:265` | `Ash.count!` | `tenant_id`, `reserved_at` on ModelInvocation |
| `lib/sdr_agent/sales/changes/require_steps.ex:19` | `Ash.count!(authorize?: false)` | `sequence_id` (attribute) on SequenceStep |
| `lib/sdr_agent/sdr/followup_worker.ex:80` | `Ash.exists?` | `idempotency_key`, `tenant_id` on Decision |
| `lib/sdr_agent/audit/anchoring.ex:181` | `Ash.exists?` | `anchor_id` (attribute), `sink`, `status` on AnchorSinkReceipt |
| `lib/sdr_agent/accounts/changes/first_user_only.ex:53` | `Ash.count!` | `tenant_id` on the user resource |
| `lib/sdr_agent/outreach/webhooks.ex:451` | `Ash.exists?(authorize?: false)` | `tenant_id`, `message_id` on Reply |

So the vulnerable path is not reachable today. We bump anyway rather than
ignore the advisory: a fix exists, the change is a patch release, and future
slices (for example counts on the home screen) could add relationship
filters.

### Decision

Pin `ash` to `== 3.34.6`. The lock changes only the `ash` entry; no other
package moves (`mix deps.update ash` also offered `decimal` 3.1.1 to 3.1.2,
which is not required and was reverted). No `ignore_advisories` entry.

Changes between 3.34.3 and 3.34.6, from the upstream changelog: the security
fix; operator type-casting and embedded-resource equality fixes; notification
return shapes normalized; a field-policy related-filter fix; temporal
(`as_of`) write fixes; an opt-out for `run` compile-time dependencies. None
changes a behaviour this project relies on; the full gate below is the check.

## Amendment (2026-10-12): EEF-CVE-2026-97853

**Status: accepted** by the owner in the private Claude session chat on
2026-10-12 ("accept PR #40"), after Codex's independent approval of
233a91e (reply 01a12e51; exact-head CI 38202840312 green).

### Advisory

- **EEF-CVE-2026-97853** (MEDIUM), aka CVE-2026-97853, GHSA-6c27-994x-c52f.
- `Decimal.round/2,3` builds the result for the requested number of decimal
  places before applying context precision, so a large caller-supplied
  `places` value allocates memory in proportion to it (denial of service).
- Affected: `decimal` 0.1.0 to 3.1.1. Fixed in **3.1.2**.
- Found by the blocking `mix hex.audit` step on CI run 38202020126 (PR #39),
  as rule 4 of the policy above intends.

### Exposure in this project

`decimal` is a transitive dependency (through Ash and Postgrex). Nothing in
`lib/` calls `Decimal.round`; the app's only `round` calls are
`Kernel.round/1` and `Float.round/2` on percentages. The only dependency
call site is Ash's `round/2` query expression
(`ash/lib/ash/query/function/round.ex`), which no resource or query in this
project uses. So the vulnerable path is not reachable today. We bump anyway
rather than ignore the advisory: a fix exists and it is a patch release.

### Decision

Lock `decimal` at **3.1.2**. Only the `decimal` entry in `mix.lock`
changes; `mix.exs` is unchanged (`mix deps.update decimal` alone offered the
3.2.0 minor release, which is not required, so the patch release was
selected). No `ignore_advisories` entry.

## Amendment (2026-10-15, proposed): EEF-CVE-2026-105659

**Status: proposed.** The owner chose option B on 2026-10-15 ("(B)", D-130):
prepare a temporary, immutable upstream Git pin with HTTP/2 disabled, through
this amendment and independent review. Accepting this amendment and merging
the change remain separate owner decisions.

### Advisory

- **EEF-CVE-2026-105659** (HIGH), aka CVE-2026-105659, GHSA-69m6-wcv4-rwcf
  (OSV, published 2026-10-14 16:54 UTC).
- Bandit's HTTP/2 implementation does not bound data queued against the
  connection and stream send windows, so a peer that never lets the window
  progress (for example with no-progress SETTINGS or a stalled
  `WINDOW_UPDATE`) makes the server buffer without limit (resource
  exhaustion before any authentication).
- Affected: `bandit` from 1.4.0, with **no fixed Hex release**: 1.12.5
  (2026-08-20) is still the newest on Hex as of 2026-10-15 09:58 MDT. The fix
  is upstream commit `d88b21953c65061f21136ea76a89a4f95a2ac7a1`, with tests.
  OSV names disabling HTTP/2 as a workaround.
- Found by the blocking `mix hex.audit` step on main run 38632782130 (head
  `3b09183`), as rule 4 of the policy above intends. It blocks every merge.

### Exposure in this project

- Bandit 1.12.5 enables HTTP/2 by default and accepts the cleartext
  prior-knowledge preface, without TLS or ALPN. **Plain HTTP does not remove
  the exposure**, and no project setting disabled HTTP/2.
- Listeners: dev `127.0.0.1:4120`, test `127.0.0.1:4002`, the calibration
  console `127.0.0.1:4124`, the demo smoke server (loopback), and production,
  which binds all IPv6 interfaces (`config/runtime.exs`). The local listeners
  are loopback only. Production reachability depends on the host, firewall
  and proxy, none of which is verified here. Authentication does not help: the
  path is pre-auth.

### Options considered

- **A. Wait for a fixed Hex release.** Keeps the source unchanged, but merges
  stay blocked with no known date.
- **B. A temporary Git pin to the fixed commit, with HTTP/2 disabled
  (chosen).** Removes the vulnerable code now and the protocol that reaches
  it, at the cost of unreleased upstream code.
- **C. Ignore the HIGH.** Not allowed by rule 2 of the policy; not proposed.
- **HTTP/2 off alone** removes today's reachable path but leaves the
  vulnerable library, so it does not clear the policy gate by itself.

### Decision (proposed)

1. **Source.** `{:bandit, github: "mtrudel/bandit", ref:
   "d88b21953c65061f21136ea76a89a4f95a2ac7a1", override: true}` in `mix.exs`.
   The full SHA, never a branch or tag. `override: true` is required because
   Phoenix, `websock_adapter`, `swoosh` and `opentelemetry_bandit` declare
   Hex requirements on `bandit`; it overrides the source only, and the
   reviewed lock records the commit. Only the `bandit` entry and any
   transitive entries its `mix.exs` requires may change in `mix.lock`; any
   other movement is reverted or reviewed.
2. **HTTP/2 off on every Bandit listener.** `http_2_options: [enabled:
   false]` in the endpoint's base configuration, and in every place that
   rebuilds the `http:` list: the calibration console plan and the demo
   smoke server. A test asserts the effective option on every listener
   configuration, and a live test sends the HTTP/2 prior-knowledge preface
   to a test listener and observes that it is not served as HTTP/2. This
   stays after the pin is replaced, until a separate decision turns HTTP/2
   back on.
3. **Review of the whole upstream delta.** `1.12.5...d88b219` is 30 commits
   and 37 paths, including HTTP/1, HTTP/2, WebSocket and compression changes,
   not only the fix. The review covers the complete delta, the lock change,
   and compatibility with Phoenix, LiveView's WebSocket and telemetry
   (`opentelemetry_bandit`).
4. **Regression evidence for the fix itself**, as the upstream fix's own
   tests do: bounded sends for both the connection window and a stream window,
   with no-progress SETTINGS, and a slow but legitimate client that drains.
   These run against the pinned source in this repository's suite.
5. **The audit is not the proof.** A Git dependency is outside Hex's
   advisory inventory, so a green `mix hex.audit` is necessary but does not
   show the advisory is fixed. The fixed commit and the regression evidence
   above are the record.
6. **Revisit.** When a stable Hex release contains the fix, a reviewed change
   replaces the pin with that release (a Hex source again, `override`
   removed). Owner of the revisit: Claude, checking Hex at each daily
   standup. No `ignore_advisories` entry.

### Consequences

- Merges can resume once this is reviewed, accepted and merged.
- The project runs an unreleased Bandit commit until the Hex release; the
  delta review and the full gate are the mitigation.
- HTTP/2 is unavailable on all listeners. Nothing in this project needs it:
  the browser UI and LiveView use HTTP/1.1 and WebSocket.
